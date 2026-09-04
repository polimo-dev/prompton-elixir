defmodule PromptOnSDK.Template do
  @moduledoc """
  Prompt template rendering: a Liquid subset (`solid` ~> 1.3, observed with 1.3.3).

  The SDK (`PromptOnSDK.render/2`) and the server (lint and `detected_variables` when saving a
  PromptVersion, Playground rendering) use the same code.

  ## solid API used

  * `Solid.parse/2`: the `tags:` option **restricts the allowed tag map** (a parser-level
    whitelist).
  * `Solid.render/3`: `strict_variables: true`. Returns `{:ok, iodata, errors}` |
    `{:error, errors, partial}`.

  ## P0 whitelist (§5.5) and how it is linted

  | Item | Allowed | Enforced by |
  |---|---|---|
  | Output | `{{ var }}`, `{{ a.b }}`, `{{ a[0] }}` | (always) |
  | Tags | `for` (+ `else`/`endfor`, `forloop.*`), `if`/`elsif`/`else`/`endif`, `unless`/`endunless`, `assign`, `break`, `continue` | The `tags:` map of `Solid.parse/2`; any other tag (`capture`, `case`, `comment`, `raw`, `render`, `cycle`, `increment`, `tablerow`, `echo`, `liquid`, ...) is a parse error `Unexpected tag 'x'` |
  | Filters | `size`, `join`, `default` | solid has **no** filter-whitelist parser option (`strict_filters` only catches "undefined filters"). So after parsing we walk the AST, collect `%Solid.Filter{function: f}`, and check them |
  | Whitespace control | `{%-`, `-%}`, `{{-`, `-}}` are **forbidden** | solid handles it in the lexer and leaves no trace in the AST, so the raw source is scanned (only inside `{{`/`{%` blocks) |
  | Escaping | None (raw substitution) | solid default behavior |

  `lint/1` checks all three and returns `:ok | {:error, [reason]}`. `parse/2` uses the same tag
  map, so a template with a tag outside the whitelist also fails at the render stage.

  ## `strict_variables` behavior (observed, solid 1.3.3)

  * Variables in branches that are not executed are not checked: rendering
    `{% if mode == "x" %}{{ missing }}{% endif %}` with `mode: "y"` gives `""` with no error.
    With `mode: "x"` it gives `{:missing_variable, "missing"}`.
  * **Undefined variables inside `if`/`elsif` condition expressions are not reported** (a solid
    1.3.3 quirk): when the condition evaluates to false, `IfTag` discards the context errors
    accumulated while evaluating it. Rendering `{% if missing == "x" %}…{% endif %}` with `%{}`
    gives `""` with no error. By contrast, an undefined variable in `unless` (false condition →
    body execution path), a `for` enumerable, `assign`, or `{{ }}` output is always an error.
    That is, "missing required variable = error" is guaranteed at **output positions**, while
    variables referenced only in condition expressions are caught by `variables/1` (the server's
    `detected_variables`) and the UseCase `input_schema`.
  * The `default` filter does **not** rescue an undefined variable: `{{ x | default: "n" }}` is an
    error when the `x` key is absent altogether. A key whose value is `nil` (`%{"x" => nil}`)
    counts as defined and `default` applies ("n"). For optional variables, the app passes `nil`
    explicitly or wraps them in `{% if x %}`.
  * For nested access `{{ a.b }}` where `a` exists but `b` does not, the `original_name` `"a.b"`
    is carried in the error.

  ## Value rendering

  Strings as is, numbers in Liquid notation (`1.5`), lists as their elements concatenated with no
  separator (same as Liquid), `nil` as `""`. `{{ forloop.index }}` (1-based), `forloop.last`,
  etc. are available. A golden test guarantees byte equality with HeyDiary's `numbered/1`.

  ## Variable map

  Atom keys in `vars` are recursively normalized to strings (including inside maps and lists;
  structs excluded), because Liquid variable lookup uses string keys.

  ## `engine: :raw`

  Passing `engine: :raw` to `render/3` or `render_messages/3` returns the source as is, without
  parsing (for prompts whose source contains `{{`/`{%`, §5.5).
  """

  @allowed_tags %{
    "for" => Solid.Tags.ForTag,
    "if" => Solid.Tags.IfTag,
    "unless" => Solid.Tags.IfTag,
    "assign" => Solid.Tags.AssignTag,
    "break" => Solid.Tags.BreakTag,
    "continue" => Solid.Tags.ContinueTag
  }

  @allowed_filters ~w(size join default)

  # Variables solid injects itself at render time (not input variables)
  @builtin_variables ~w(forloop)

  @type parsed :: Solid.Template.t()
  @type engine :: :liquid | :raw
  @type render_error :: {:missing_variable, String.t()} | {:render, term()} | {:parse, term()}
  @type lint_reason ::
          {:whitespace_control, String.t()}
          | {:disallowed_tag, String.t()}
          | {:disallowed_filter, String.t()}
          | {:parse, String.t()}

  @doc "The list of allowed tag names."
  @spec allowed_tags() :: [String.t()]
  def allowed_tags, do: Map.keys(@allowed_tags) |> Enum.sort()

  @doc "The list of allowed filter names."
  @spec allowed_filters() :: [String.t()]
  def allowed_filters, do: @allowed_filters

  @doc """
  Parses a template (allowed tags only). On failure, `{:error, %Solid.TemplateError{}}`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, parsed()} | {:error, Solid.TemplateError.t()}
  def parse(source, opts \\ []) when is_binary(source) do
    Solid.parse(source, tags: Keyword.get(opts, :tags, @allowed_tags))
  end

  @doc """
  Renders. `source_or_parsed` is the source string or the result of `parse/2`. `opts`:

  * `engine: :liquid | :raw` (default `:liquid`): `:raw` returns the source as is.

  Returns `{:ok, binary}` |
  `{:error, {:missing_variable, name} | {:render, errors} | {:parse, error}}`.
  """
  @spec render(String.t() | parsed(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, render_error()}
  def render(source_or_parsed, vars, opts \\ [])

  def render(source, vars, opts) when is_binary(source) and is_list(opts) do
    case Keyword.get(opts, :engine, :liquid) do
      :raw -> {:ok, source}
      _ -> with {:ok, parsed} <- parse_for_render(source, opts), do: render(parsed, vars, opts)
    end
  end

  def render(%Solid.Template{} = parsed, vars, opts) when is_list(opts) do
    vars = normalize_vars(vars)

    try do
      case Solid.render(parsed, vars, strict_variables: true) do
        {:ok, iodata, []} ->
          {:ok, IO.iodata_to_binary(iodata)}

        {:ok, _iodata, errors} ->
          {:error, classify_errors(errors)}

        {:error, errors, _partial} ->
          {:error, classify_errors(errors)}
      end
    rescue
      e -> {:error, {:render, e}}
    catch
      kind, value -> {:error, {:render, {kind, value}}}
    end
  end

  defp parse_for_render(source, opts) do
    case parse(source, opts) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, error} -> {:error, {:parse, error}}
    end
  end

  @doc """
  Renders the `content` of each message in a list (`[%{role, content}]`). If any one fails, that
  error is returned. Other keys such as `role`/`name` are preserved as is.
  """
  @spec render_messages([map()], map() | nil, keyword()) ::
          {:ok, [map()]} | {:error, render_error()}
  def render_messages(messages, vars, opts \\ []) when is_list(messages) do
    vars = normalize_vars(vars)

    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      content = content_of(message)

      case render(content || "", vars, opts) do
        {:ok, rendered} -> {:cont, {:ok, [put_content(message, rendered) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  @doc """
  The names of the **top-level input variables** the template references (sorted, deduplicated).
  `for` loop variables, `assign` targets, and `forloop` are excluded. If parsing fails, the
  `{{ ident` / `{% tag ident` patterns are scraped conservatively with a regex.
  """
  @spec variables(String.t()) :: [String.t()]
  def variables(source) when is_binary(source) do
    case parse(source, tags: Solid.Tag.default_tags()) do
      {:ok, %Solid.Template{parsed_template: tree}} ->
        referenced = collect(tree, &variable_identifier/1)
        bound = collect(tree, &bound_identifier/1)

        referenced
        |> Enum.reject(&(&1 in bound or &1 in @builtin_variables))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        regex_variables(source)
    end
  end

  @doc """
  P0 whitelist lint. `:ok` or `{:error, [reason]}`.

  reason: `{:whitespace_control, marker}` | `{:disallowed_tag, name}` |
  `{:disallowed_filter, name}` | `{:parse, message}`.
  """
  @spec lint(String.t()) :: :ok | {:error, [lint_reason()]}
  def lint(source) when is_binary(source) do
    reasons =
      whitespace_control_reasons(source) ++
        liquid_tag_reasons(source) ++ tag_and_filter_reasons(source)

    case reasons do
      [] -> :ok
      reasons -> {:error, Enum.uniq(reasons)}
    end
  end

  # ---------------------------------------------------------------------------
  # lint internals

  defp whitespace_control_reasons(source) do
    ~r/\{\{-|\{%-|-\}\}|-%\}/
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&inside_block?(source, &1))
    |> Enum.map(&{:whitespace_control, &1})
  end

  # An opening marker is itself a block start. A closing marker is inside a block only if an open
  # `{{`/`{%` precedes it.
  defp inside_block?(_source, marker) when marker in ["{{-", "{%-"], do: true

  defp inside_block?(source, marker) do
    Regex.match?(~r/(\{\{|\{%)(?:(?!\}\}|%\}).)*?#{Regex.escape(marker)}/s, source)
  end

  # `{% liquid … %}` is special-cased by the solid lexer without going through the tag map, so it
  # is caught in the raw source.
  defp liquid_tag_reasons(source) do
    if Regex.match?(~r/\{%-?\s*liquid\b/, source), do: [{:disallowed_tag, "liquid"}], else: []
  end

  defp tag_and_filter_reasons(source) do
    case parse(source) do
      {:ok, %Solid.Template{parsed_template: tree}} ->
        tree
        |> collect(&filter_name/1)
        |> Enum.reject(&(&1 in @allowed_filters))
        |> Enum.uniq()
        |> Enum.map(&{:disallowed_filter, &1})

      {:error, %Solid.TemplateError{errors: errors}} ->
        Enum.map(errors, fn %Solid.ParserError{reason: reason} ->
          case Regex.run(~r/^Unexpected tag '([^']+)'$/, reason) do
            [_, name] -> {:disallowed_tag, name}
            _ -> {:parse, reason}
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # AST walking (generic over structs / lists / maps / tuples)

  defp collect(term, picker) do
    term
    |> walk([], picker)
    |> Enum.reverse()
  end

  defp walk(%Solid.Parser.Loc{}, acc, _picker), do: acc

  defp walk(%_{} = struct, acc, picker) do
    acc =
      case picker.(struct) do
        nil -> acc
        picked -> [picked | acc]
      end

    struct |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &walk(&1, &2, picker))
  end

  defp walk(map, acc, picker) when is_map(map) do
    map |> Map.values() |> Enum.reduce(acc, &walk(&1, &2, picker))
  end

  defp walk(list, acc, picker) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, &2, picker))
  end

  defp walk(tuple, acc, picker) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, &2, picker))
  end

  defp walk(_other, acc, _picker), do: acc

  defp filter_name(%Solid.Filter{function: name}), do: name
  defp filter_name(_), do: nil

  defp variable_identifier(%Solid.Variable{identifier: id}) when is_binary(id), do: id
  defp variable_identifier(_), do: nil

  defp bound_identifier(%Solid.Tags.ForTag{variable: %Solid.Variable{identifier: id}}), do: id
  defp bound_identifier(%Solid.Tags.AssignTag{argument: %Solid.Variable{identifier: id}}), do: id
  defp bound_identifier(_), do: nil

  defp regex_variables(source) do
    ident = ~r/^[A-Za-z_][A-Za-z0-9_]*/

    outputs =
      ~r/\{\{-?\s*([A-Za-z_][A-Za-z0-9_]*)/
      |> Regex.scan(source)
      |> Enum.map(fn [_, name] -> name end)

    tags =
      ~r/\{%-?\s*(?:if|unless|elsif)\s+([A-Za-z_][A-Za-z0-9_]*)|\{%-?\s*for\s+\w+\s+in\s+([A-Za-z_][A-Za-z0-9_]*)/
      |> Regex.scan(source)
      |> Enum.flat_map(fn
        [_, a] -> [a]
        [_, "", b] -> [b]
        [_, a, _] -> [a]
      end)

    (outputs ++ tags)
    |> Enum.filter(&Regex.match?(ident, &1))
    |> Enum.reject(&(&1 in @builtin_variables or &1 in ~w(true false nil empty blank)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # helpers

  defp classify_errors(errors) do
    errors
    |> Enum.sort_by(fn
      %{loc: %{line: l, column: c}} -> {l, c}
      _ -> {0, 0}
    end)
    |> Enum.find(&match?(%Solid.UndefinedVariableError{}, &1))
    |> case do
      %Solid.UndefinedVariableError{original_name: name} -> {:missing_variable, name}
      nil -> {:render, errors}
    end
  end

  defp content_of(%{content: c}), do: c
  defp content_of(%{"content" => c}), do: c
  defp content_of(_), do: nil

  defp put_content(%{content: _} = m, c), do: %{m | content: c}
  defp put_content(%{"content" => _} = m, c), do: %{m | "content" => c}
  defp put_content(m, c) when is_map(m), do: Map.put(m, :content, c)

  @doc false
  @spec normalize_vars(map() | nil) :: map()
  def normalize_vars(nil), do: %{}
  def normalize_vars(map) when is_map(map) and not is_struct(map), do: normalize_value(map)

  defp normalize_value(%_{} = struct), do: struct

  defp normalize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {key_to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(other), do: other

  defp key_to_string(k) when is_binary(k), do: k
  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k), do: to_string(k)
end
