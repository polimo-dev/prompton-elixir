#!/usr/bin/env elixir
# Generates conformance/*.json by executing this SDK, so the expected values in the fixtures are
# what the reference implementation actually produces.
#
#     mix run scripts/gen_conformance.exs
#
# Every file is deterministic: no timestamps, no random ids, no wall-clock dependent values. The
# only field that changes between runs is `generated_from.commit`.

defmodule GenConformance do
  alias PromptOnSDK.{Payload, Resolver, UseCaseDocument, StopKind, Template}

  @out_dir Path.expand("../conformance", __DIR__)

  # --------------------------------------------------------------------------
  # entry point

  def run do
    File.mkdir_p!(@out_dir)

    write("template.json", template())
    write("use_case.json", use_case_cases())
    write("truncation.json", truncation())
    write("stop_kind.json", stop_kind())
    write("log_record.json", log_record())

    IO.puts("wrote #{@out_dir}")
  end

  defp write(name, payload) do
    body = Jason.encode!(Map.merge(envelope(name), payload), pretty: true) <> "\n"
    File.write!(Path.join(@out_dir, name), body)
    IO.puts("  #{name} (#{byte_size(body)} bytes)")
  end

  defp envelope(name) do
    %{
      "conformance" => Path.rootname(name),
      "format_version" => 1,
      "generated_from" => %{
        "sdk" => "prompton_sdk",
        "sdk_version" => PromptOnSDK.version(),
        "language" => "elixir",
        "repo" => "https://github.com/polimo-dev/prompton-elixir",
        "commit" => git_commit()
      }
    }
  end

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: Path.expand("..", @out_dir)) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  # ==========================================================================
  # template.json

  defp template do
    cases =
      [
        {"output/plain", "Hello {{ name }}!", %{"name" => "World"}, []},
        {"output/no_spaces", "{{name}}", %{"name" => "x"}, []},
        {"output/extra_spaces", "{{    name    }}", %{"name" => "x"}, []},
        {"output/multiline", "Line 1: {{ a }}\nLine 2: {{ b }}\n", %{"a" => "x", "b" => "y"}, []},
        {"output/repeated_variable", "{{ a }}-{{ a }}", %{"a" => "z"}, []},
        {"output/no_escaping", "{{ html }}", %{"html" => "<b>&amp;</b>"}, []},
        {"missing/top_level", "Hello {{ name }}", %{}, []},
        {"missing/nested_leaf", "{{ user.name }}", %{"user" => %{}}, []},
        {"missing/with_default_filter", "{{ x | default: \"fb\" }}", %{},
         [
           note:
             "the default filter does NOT rescue an absent key; only a key present with a nil/false/empty value"
         ]},
        {"missing/inside_unless", "{% unless flag %}off{% endunless %}", %{}, []},
        {"missing/inside_for", "{% for i in items %}{{ i }}{% endfor %}", %{}, []},
        {"missing/inside_taken_if_branch", "{% if flag %}{{ other }}{% endif %}",
         %{"flag" => true}, []},
        {"missing/untaken_branch_is_not_checked",
         "{% if mode == \"a\" %}{{ only_for_a }}{% endif %}", %{"mode" => "b"},
         [note: "variables in a branch that is not executed are never looked up"]},
        {"nested/map_access", "{{ user.name }} <{{ user.email }}>",
         %{"user" => %{"name" => "Ada", "email" => "ada@example.com"}}, []},
        {"nested/deep", "{{ a.b.c }}", %{"a" => %{"b" => %{"c" => "deep"}}}, []},
        {"nested/list_index", "{{ items[0] }}/{{ items[2] }}", %{"items" => ["a", "b", "c"]}, []},
        {"nested/map_in_list", "{{ rows[1].label }}",
         %{"rows" => [%{"label" => "one"}, %{"label" => "two"}]}, []},
        {"stringify/integer", "{{ n }}", %{"n" => 3}, []},
        {"stringify/float", "{{ n }}", %{"n" => 1.5}, []},
        {"stringify/float_integral", "{{ n }}", %{"n" => 2.0},
         [note: "an integral float keeps its decimal point"]},
        {"stringify/negative", "{{ n }}", %{"n" => -12}, []},
        {"stringify/true", "{{ b }}", %{"b" => true}, []},
        {"stringify/false", "{{ b }}", %{"b" => false}, []},
        {"stringify/nil", "[{{ x }}]", %{"x" => nil}, [note: "a present nil renders as empty"]},
        {"stringify/empty_string", "[{{ x }}]", %{"x" => ""}, []},
        {"stringify/list", "{{ items }}", %{"items" => ["a", "b"]},
         [note: "a list renders as its elements concatenated with no separator (Liquid rule)"]},
        {"stringify/list_of_numbers", "{{ items }}", %{"items" => [1, 2, 3]}, []},
        {"for/basic", "{% for i in items %}{{ i }},{% endfor %}", %{"items" => ["a", "b"]}, []},
        {"for/empty_list", "{% for i in items %}{{ i }}{% endfor %}", %{"items" => []}, []},
        {"for/else", "{% for i in items %}{{ i }}{% else %}none{% endfor %}", %{"items" => []},
         []},
        {"for/forloop_index_and_last",
         "{% for i in items %}{{ forloop.index }}:{{ i }}{% unless forloop.last %} {% endunless %}{% endfor %}",
         %{"items" => ["a", "b", "c"]}, []},
        {"for/forloop_index0_first_length",
         "{% for i in items %}{{ forloop.index0 }}{{ forloop.first }}{{ forloop.length }};{% endfor %}",
         %{"items" => ["a", "b"]}, []},
        {"for/break",
         "{% for i in items %}{% if i == \"c\" %}{% break %}{% endif %}{{ i }}{% endfor %}",
         %{"items" => ["a", "b", "c", "d"]}, []},
        {"for/continue",
         "{% for i in items %}{% if i == \"b\" %}{% continue %}{% endif %}{{ i }}{% endfor %}",
         %{"items" => ["a", "b", "c"]}, []},
        {"for/over_maps", "{% for row in rows %}- {{ row.label }}\n{% endfor %}",
         %{"rows" => [%{"label" => "one"}, %{"label" => "two"}]}, []},
        {"if/then", "{% if n > 2 %}big{% endif %}", %{"n" => 5}, []},
        {"if/elsif", "{% if n > 2 %}big{% elsif n > 0 %}small{% else %}none{% endif %}",
         %{"n" => 1}, []},
        {"if/else", "{% if n > 2 %}big{% elsif n > 0 %}small{% else %}none{% endif %}",
         %{"n" => -1}, []},
        {"if/string_equality", "{% if lang == \"ko\" %}안녕{% else %}hi{% endif %}",
         %{"lang" => "ko"}, []},
        {"if/truthiness_of_nil", "{% if x %}yes{% else %}no{% endif %}", %{"x" => nil}, []},
        {"if/truthiness_of_false", "{% if x %}yes{% else %}no{% endif %}", %{"x" => false}, []},
        {"if/truthiness_of_empty_string", "{% if x %}yes{% else %}no{% endif %}", %{"x" => ""},
         [note: "an empty string is truthy in Liquid"]},
        {"if/and_or", "{% if a and b %}both{% endif %}{% if a or c %}some{% endif %}",
         %{"a" => true, "b" => false, "c" => false}, []},
        {"unless/false_condition", "{% unless flag %}off{% endunless %}", %{"flag" => false}, []},
        {"unless/true_condition", "{% unless flag %}off{% endunless %}", %{"flag" => true}, []},
        {"assign/literal", "{% assign greeting = \"hi\" %}{{ greeting }} {{ name }}",
         %{"name" => "Ada"}, []},
        {"assign/from_variable", "{% assign copy = name %}{{ copy }}", %{"name" => "Ada"}, []},
        {"assign/with_filter", "{% assign n = items | size %}{{ n }}", %{"items" => [1, 2, 3]},
         []},
        {"filter/size_list", "{{ items | size }}", %{"items" => [1, 2, 3]}, []},
        {"filter/size_string", "{{ s | size }}", %{"s" => "abcd"}, []},
        {"filter/size_string_multibyte", "{{ s | size }}", %{"s" => "한글"},
         [note: "size counts characters, not bytes"]},
        {"filter/join_with_argument", "{{ items | join: \", \" }}", %{"items" => ["a", "b"]}, []},
        {"filter/join_without_argument", "{{ items | join }}", %{"items" => ["a", "b"]},
         [note: "the default separator is a single space"]},
        {"filter/default_on_nil", "{{ x | default: \"fallback\" }}", %{"x" => nil}, []},
        {"filter/default_on_empty_string", "{{ x | default: \"fb\" }}", %{"x" => ""},
         [note: "an empty string is blank, so default applies"]},
        {"filter/default_on_false", "{{ x | default: \"fb\" }}", %{"x" => false}, []},
        {"filter/default_on_present_value", "{{ x | default: \"fb\" }}", %{"x" => "v"}, []},
        {"filter/default_without_argument", "{{ x | default }}", %{"x" => nil}, []},
        {"filter/chained", "{{ items | join: \"|\" | size }}", %{"items" => ["ab", "cd"]}, []},
        {"raw_engine/passthrough", "Hello {{ name }} {% if x %}kept{% endif %}",
         %{"name" => "ignored"}, [engine: "raw"]},
        {"raw_engine/unparseable_source_is_returned_verbatim", "{% include \"x\" %} {{ a", %{},
         [engine: "raw", note: "the raw engine never parses, so nothing can fail"]},
        {"rejected/include", "{% include \"other\" %}", %{}, []},
        {"rejected/capture", "{% capture x %}y{% endcapture %}{{ x }}", %{}, []},
        {"rejected/raw_tag", "{% raw %}{{ a }}{% endraw %}", %{}, []},
        {"rejected/case", "{% case n %}{% when 1 %}one{% endcase %}", %{"n" => 1}, []},
        {"rejected/cycle", "{% cycle \"a\", \"b\" %}", %{}, []},
        {"rejected/comment", "{% comment %}hidden{% endcomment %}", %{}, []},
        {"rejected/unclosed_tag", "{% if a %}no end", %{"a" => true}, []}
      ]
      |> Enum.map(&template_case/1)

    nonnormative =
      [
        {"nonnormative/unknown_filter_is_applied_at_render_time", "{{ s | upcase }}",
         %{"s" => "abc"},
         "The filter whitelist is enforced by lint/1 (and by the server when a prompt version is committed), NOT by render. solid applies any filter it knows. An SDK whose template engine only implements size/join/default may raise instead; both are acceptable, because such a template can never be committed to PromptOn."},
        {"nonnormative/whitespace_control_renders", "{%- if a -%}x{%- endif -%}", %{"a" => true},
         "Whitespace control is rejected by lint/1 but the renderer honours it. Behaviour of a template that lint rejects is unspecified."},
        {"nonnormative/map_value_stringification", "{{ m }}", %{"m" => %{"a" => 1}},
         "Rendering a map into an output position produces a language-specific debug string (here Elixir's inspect). Never rely on it."},
        {"nonnormative/undefined_variable_in_if_condition", "{% if flag == \"x\" %}y{% endif %}",
         %{},
         "solid 1.3.x discards the undefined-variable error accumulated while evaluating a false if/elsif condition, so this renders empty instead of failing. An SDK that raises missing_variable here is also acceptable. Only OUTPUT positions ({{ }}), for enumerables, unless conditions and assign are guaranteed to fail."}
      ]
      |> Enum.map(fn {name, source, vars, note} ->
        %{
          "name" => name,
          "engine" => "liquid",
          "template" => source,
          "variables" => vars,
          "expect" => expect_for_render(Template.render(source, vars)),
          "normative" => false,
          "note" => note
        }
      end)

    lint_cases =
      [
        {"lint/plain_is_ok", "Hello {{ name }}"},
        {"lint/allowed_tags_are_ok",
         "{% assign a = 1 %}{% if a %}{% for i in xs %}{% unless i %}{% break %}{% endunless %}{% continue %}{% endfor %}{% endif %}"},
        {"lint/allowed_filters_are_ok",
         "{{ xs | size }}{{ xs | join: \",\" }}{{ x | default: 1 }}"},
        {"lint/unknown_filter", "{{ s | upcase }}"},
        {"lint/include_tag", "{% include \"other\" %}"},
        {"lint/capture_tag", "{% capture x %}y{% endcapture %}"},
        {"lint/liquid_tag", "{% liquid assign x = 1 %}"},
        {"lint/whitespace_control_tag", "{%- if a -%}x{%- endif -%}"},
        {"lint/whitespace_control_output", "{{- a -}}"},
        {"lint/parse_error", "{% if a %}no end"}
      ]
      |> Enum.map(fn {name, source} ->
        %{
          "name" => name,
          "template" => source,
          "expect" => expect_for_lint(Template.lint(source))
        }
      end)

    variables_cases =
      [
        {"variables/output_positions", "{{ a }} {{ b.c }}"},
        {"variables/for_enumerable_only", "{% for item in items %}{{ item }}{% endfor %}"},
        {"variables/assign_target_excluded", "{% assign x = y %}{{ x }}"},
        {"variables/condition_variables_included", "{% if mode == \"a\" %}x{% endif %}"},
        {"variables/forloop_excluded", "{% for i in xs %}{{ forloop.index }}{% endfor %}"}
      ]
      |> Enum.map(fn {name, source} ->
        %{
          "name" => name,
          "template" => source,
          "expect" => %{"variables" => Template.variables(source)}
        }
      end)

    %{
      "description" =>
        "Prompt rendering: the Liquid subset PromptOn allows. `cases` are executed with " <>
          "render(template, variables, engine: engine) and must match `expect` exactly.",
      "engines" => ["liquid", "raw"],
      "allowed_tags" => Template.allowed_tags(),
      "allowed_filters" => Template.allowed_filters(),
      "error_categories" => %{
        "missing_variable" =>
          "a variable the template reads at an output position, a for enumerable, an unless condition or an assign source is absent from `variables`. `expect.variable` is the reported name (dotted for nested access).",
        "parse_error" =>
          "the template uses a construct outside the allowed tag set, or is malformed",
        "render_error" => "the template parsed but rendering failed for another reason"
      },
      "cases" => cases ++ nonnormative,
      "lint_cases" => lint_cases,
      "variables_cases" => variables_cases
    }
  end

  defp template_case({name, source, vars, opts}) do
    engine = Keyword.get(opts, :engine, "liquid")
    result = Template.render(source, vars, engine: String.to_existing_atom(engine))

    %{
      "name" => name,
      "engine" => engine,
      "template" => source,
      "variables" => vars,
      "expect" => expect_for_render(result)
    }
    |> maybe_put("note", Keyword.get(opts, :note))
  end

  defp expect_for_render({:ok, output}), do: %{"output" => output}

  defp expect_for_render({:error, {:missing_variable, name}}),
    do: %{"error" => "missing_variable", "variable" => name}

  defp expect_for_render({:error, {:parse, _}}), do: %{"error" => "parse_error"}
  defp expect_for_render({:error, {:render, _}}), do: %{"error" => "render_error"}

  defp expect_for_lint(:ok), do: %{"lint" => "ok"}

  defp expect_for_lint({:error, reasons}) do
    %{
      "lint" => "error",
      "reasons" =>
        Enum.map(reasons, fn {kind, value} ->
          %{"kind" => to_string(kind), "value" => to_string(value)}
        end)
    }
  end

  # ==========================================================================
  # use_case.json

  # Fixed ids so the file is byte-stable.
  @uc_greeting "0198f2a1-0000-7000-8000-00000000c001"
  @uc_summarize "0198f2a1-0000-7000-8000-00000000c002"
  @uc_embed "0198f2a1-0000-7000-8000-00000000c003"
  @uc_draft "0198f2a1-0000-7000-8000-00000000c004"
  @dep_greeting_prod "0198f2a1-0000-7000-8000-00000000d001"
  @dep_summarize_prod "0198f2a1-0000-7000-8000-00000000d002"
  @dep_embed_prod "0198f2a1-0000-7000-8000-00000000d003"
  @dep_greeting_stg "0198f2a1-0000-7000-8000-00000000d011"
  @dep_broken "0198f2a1-0000-7000-8000-00000000d021"
  @pv_greeting_default "0198f2a1-0000-7000-8000-00000000a001"
  @pv_greeting_ko "0198f2a1-0000-7000-8000-00000000a002"
  @pv_summarize "0198f2a1-0000-7000-8000-00000000a003"
  @pv_greeting_stg "0198f2a1-0000-7000-8000-00000000a004"
  @pv_absent "0198f2a1-0000-7000-8000-0000000000ff"
  @model_chat "0198f2a1-0000-7000-8000-00000000e001"
  @model_embed "0198f2a1-0000-7000-8000-00000000e002"
  @model_absent "0198f2a1-0000-7000-8000-0000000000fe"
  @prompt_greeting "0198f2a1-0000-7000-8000-00000000b001"
  @prompt_summarize "0198f2a1-0000-7000-8000-00000000b002"

  defp use_case_cases do
    documents = %{
      "production" => production_document(),
      "staging" => staging_document(),
      "degraded" => degraded_document()
    }

    decoded =
      Map.new(documents, fn {ref, raw} ->
        {:ok, data, _warnings} = UseCaseDocument.decode(raw)
        {ref, data}
      end)

    cases =
      [
        %{
          name: "chat/default_prompt_without_variables",
          ref: "production",
          use_case: "greeting",
          note: "with no variables the raw message templates come back unrendered"
        },
        %{
          name: "chat/default_prompt_rendered",
          ref: "production",
          use_case: "greeting",
          variables: %{"name" => "Ada"}
        },
        %{
          name: "chat/named_prompt_rendered",
          ref: "production",
          use_case: "greeting",
          prompt: "ko",
          variables: %{"name" => "아다"},
          note: "the prompt name is the only selection axis; this is how language branching works"
        },
        %{
          name: "chat/explicit_default_prompt_name",
          ref: "production",
          use_case: "greeting",
          prompt: "default",
          variables: %{"name" => "Ada"}
        },
        %{
          name: "chat/missing_variable",
          ref: "production",
          use_case: "greeting",
          variables: %{},
          note: "use case selection succeeds; rendering fails"
        },
        %{
          name: "chat/unpinned_prompt_name",
          ref: "production",
          use_case: "greeting",
          prompt: "fr",
          note: "never falls back to \"default\""
        },
        %{
          name: "text/rendered_with_for_loop",
          ref: "production",
          use_case: "summarize",
          variables: %{"items" => ["alpha", "beta", "gamma"]}
        },
        %{
          name: "text/raw_template_without_variables",
          ref: "production",
          use_case: "summarize"
        },
        %{
          name: "embedding/no_prompt",
          ref: "production",
          use_case: "embed",
          note: "kind embedding resolves the model only: prompt and prompt_version are null"
        },
        %{
          name: "embedding/prompt_name_is_ignored",
          ref: "production",
          use_case: "embed",
          prompt: "ko",
          note: "a prompt name given for an embedding use case is ignored, not an error"
        },
        %{
          name: "error/use_case_without_deployment",
          ref: "production",
          use_case: "draft"
        },
        %{
          name: "error/unknown_use_case",
          ref: "production",
          use_case: "nope"
        },
        %{
          name: "staging/same_use_case_different_pin",
          ref: "staging",
          use_case: "greeting",
          variables: %{"name" => "Ada"},
          note: "same key, different environment: different model, params and prompt version"
        },
        %{
          name: "staging/prompt_pinned_only_in_production",
          ref: "staging",
          use_case: "greeting",
          prompt: "ko"
        },
        %{
          name: "degraded/missing_prompt_version_and_model",
          ref: "degraded",
          use_case: "greeting",
          note:
            "the document references ids it does not contain: use case selection still succeeds, with warnings and null fields"
        }
      ]
      |> Enum.map(&use_case_case(&1, decoded))

    %{
      "description" =>
        "Use case selection: use-case document + use case (+ prompt name) -> which model, params " <>
          "and prompt version to use, then filling when `variables` is present. This is " <>
          "exactly what POST /api/v1/use-cases/{key}/prompt does on the server.",
      "merge_semantics" => %{
        "params" => "use_case.default_params <- deployment.params (shallow, later wins)",
        "provider_options" =>
          "model.provider_options <- deployment.provider_options (shallow, later wins)",
        "null_values" => "an override value of null is kept as null, not deleted"
      },
      "default_prompt" => Resolver.default_prompt(),
      "error_categories" => %{
        "unknown_use_case" => "the document has no use case with that key",
        "unresolved" => "the use case exists but has no deployment in this environment",
        "unknown_prompt" =>
          "the deployment pins no prompt version under that name (no fallback to \"default\")",
        "missing_variable" =>
          "use case selection succeeded but rendering needed a variable that was absent"
      },
      "document_notes" => %{
        "production" =>
          "The everyday shape: three deployed use cases (chat with two prompt names, text, embedding) plus one use case that has never been deployed. Field for field what GET /use-cases returns.",
        "staging" =>
          "The same project in another environment: one use case, a different revision, different params and only the default prompt pinned.",
        "degraded" =>
          "Synthetic. The deployment points at a prompt version id and a model id the document does not contain, to pin down the warning path. A healthy server never emits this."
      },
      "documents" => documents,
      "cases" => cases
    }
  end

  defp use_case_case(spec, decoded) do
    data = Map.fetch!(decoded, spec.ref)
    prompt = Map.get(spec, :prompt)
    variables = Map.get(spec, :variables)

    %{
      "name" => spec.name,
      "document_ref" => spec.ref,
      "environment" => data.environment,
      "use_case" => spec.use_case,
      "expect" => use_case_expect(data, spec.use_case, prompt, variables)
    }
    |> maybe_put("prompt", prompt)
    |> maybe_put("variables", variables)
    |> maybe_put("note", Map.get(spec, :note))
  end

  defp use_case_expect(data, use_case, prompt, variables) do
    case Resolver.resolve(data, use_case, prompt: prompt) do
      {:error, :unknown_prompt} ->
        {:ok, prompts} = Resolver.prompt_names(data, use_case)

        %{
          "error" => "unknown_prompt",
          "key" => use_case,
          "prompt" => prompt || Resolver.default_prompt(),
          "prompt_names" => prompts
        }

      {:error, :unknown_use_case} ->
        %{"error" => "unknown_use_case", "key" => use_case}

      {:error, reason} ->
        %{"error" => to_string(reason)}

      {:ok, r} ->
        case fill_use_case(r, variables) do
          {:error, {:missing_variable, name}} ->
            %{"error" => "missing_variable", "variable" => name}

          {:ok, rendered} ->
            {:ok, prompts} = Resolver.prompt_names(data, use_case)

            %{
              "key" => r.use_case_key,
              "kind" => to_string(r.kind),
              "deployment_id" => r.deployment_id,
              "revision" => r.deployment_revision,
              "prompt" => r.prompt,
              "prompt_names" => prompts,
              "model_id" => r.model_id,
              "model" => r.model,
              "provider" => r.provider && to_string(r.provider),
              "params" => r.params,
              "provider_options" => r.provider_options,
              "source" => to_string(r.source),
              "prompt_version" =>
                r.prompt_version_id &&
                  %{"id" => r.prompt_version_id, "number" => r.prompt_version_number},
              "warnings" => Enum.map(r.warnings, fn {tag, detail} -> "#{tag}: #{detail}" end)
            }
            |> Map.merge(rendered)
        end
    end
  end

  defp fill_use_case(%{kind: :chat, messages: messages}, nil) when is_list(messages),
    do: {:ok, %{"messages" => Enum.map(messages, &message_map/1)}}

  defp fill_use_case(%{kind: :chat, messages: messages} = r, variables)
       when is_list(messages) do
    case Template.render_messages(messages, variables, engine: r.engine || :liquid) do
      {:ok, rendered} -> {:ok, %{"messages" => Enum.map(rendered, &message_map/1)}}
      error -> error
    end
  end

  defp fill_use_case(%{kind: :text, text_template: text}, nil) when is_binary(text),
    do: {:ok, %{"text" => text}}

  defp fill_use_case(%{kind: :text, text_template: text} = r, variables)
       when is_binary(text) do
    case Template.render(text, variables, engine: r.engine || :liquid) do
      {:ok, rendered} -> {:ok, %{"text" => rendered}}
      error -> error
    end
  end

  defp fill_use_case(_r, _variables), do: {:ok, %{}}

  defp message_map(message) do
    %{
      "role" => message[:role] || message["role"],
      "content" => message[:content] || message["content"]
    }
  end

  defp payload_policy(mode, sample_rate) do
    %{
      "mode" => mode,
      "sample_rate" => sample_rate,
      "max_bytes" => 262_144,
      "retention_days" => 30,
      "encrypt" => false
    }
  end

  defp production_document do
    %{
      "schema_version" => 4,
      "project" => "sdkfixture",
      "environment" => "production",
      "use_cases" => %{
        "greeting" => %{
          "id" => @uc_greeting,
          "kind" => "chat",
          "input_schema" => [%{"name" => "name", "type" => "string", "required" => true}],
          "default_params" => %{"temperature" => 0.7, "max_tokens" => 512},
          "payload_policy" => payload_policy("full", 1.0)
        },
        "summarize" => %{
          "id" => @uc_summarize,
          "kind" => "text",
          "input_schema" => [%{"name" => "items", "type" => "list", "required" => true}],
          "default_params" => %{"temperature" => 0.0},
          "payload_policy" => payload_policy("full", 1.0)
        },
        "embed" => %{
          "id" => @uc_embed,
          "kind" => "embedding",
          "input_schema" => [%{"name" => "text", "type" => "string", "required" => true}],
          "default_params" => %{},
          "payload_policy" => payload_policy("hash", 1.0)
        },
        "draft" => %{
          "id" => @uc_draft,
          "kind" => "chat",
          "input_schema" => [],
          "default_params" => %{},
          "payload_policy" => payload_policy("full", 1.0)
        }
      },
      "deployments" => %{
        "greeting" => %{
          "id" => @dep_greeting_prod,
          "revision" => 3,
          "model_id" => @model_chat,
          "params" => %{"temperature" => 0.2},
          "provider_options" => %{"allow_fallbacks" => true, "sort" => nil},
          "prompt_pins" => %{"default" => @pv_greeting_default, "ko" => @pv_greeting_ko}
        },
        "summarize" => %{
          "id" => @dep_summarize_prod,
          "revision" => 1,
          "model_id" => @model_chat,
          "params" => %{},
          "provider_options" => %{},
          "prompt_pins" => %{"default" => @pv_summarize}
        },
        "embed" => %{
          "id" => @dep_embed_prod,
          "revision" => 2,
          "model_id" => @model_embed,
          "params" => %{"dimensions" => 256},
          "provider_options" => %{},
          "prompt_pins" => %{}
        }
      },
      "prompt_versions" => %{
        @pv_greeting_default => %{
          "id" => @pv_greeting_default,
          "prompt_id" => @prompt_greeting,
          "number" => 2,
          "engine" => "liquid",
          "messages" => [
            %{"role" => "system", "content" => "You are a friendly greeter. Answer in one line."},
            %{"role" => "user", "content" => "Say hello to {{ name }}."}
          ],
          "text_template" => nil
        },
        @pv_greeting_ko => %{
          "id" => @pv_greeting_ko,
          "prompt_id" => @prompt_greeting,
          "number" => 1,
          "engine" => "liquid",
          "messages" => [
            %{"role" => "system", "content" => "너는 친절한 인사 도우미다. 한 줄로 답한다."},
            %{"role" => "user", "content" => "{{ name }}님에게 인사해줘."}
          ],
          "text_template" => nil
        },
        @pv_summarize => %{
          "id" => @pv_summarize,
          "prompt_id" => @prompt_summarize,
          "number" => 4,
          "engine" => "liquid",
          "messages" => [],
          "text_template" =>
            "Summarize the following notes in one paragraph.\n{% for item in items %}- {{ item }}\n{% endfor %}"
        }
      },
      "models" => %{
        @model_chat => %{
          "id" => @model_chat,
          "provider" => "openrouter",
          "model_id" => "openai/gpt-4o-mini",
          "display_name" => "GPT-4o mini",
          "provider_options" => %{"only" => ["OpenAI"], "allow_fallbacks" => false},
          "capabilities" => ["tools", "streaming"],
          "status" => "active",
          "metadata" => %{}
        },
        @model_embed => %{
          "id" => @model_embed,
          "provider" => "openrouter",
          "model_id" => "openai/text-embedding-3-small",
          "display_name" => "text-embedding-3-small",
          "provider_options" => %{},
          "capabilities" => [],
          "status" => "active",
          "metadata" => %{}
        }
      }
    }
  end

  defp staging_document do
    %{
      "schema_version" => 4,
      "project" => "sdkfixture",
      "environment" => "staging",
      "use_cases" => %{
        "greeting" => %{
          "id" => @uc_greeting,
          "kind" => "chat",
          "input_schema" => [%{"name" => "name", "type" => "string", "required" => true}],
          "default_params" => %{"temperature" => 0.7, "max_tokens" => 512},
          "payload_policy" => Map.put(payload_policy("full", 0.5), "max_bytes", 65_536)
        }
      },
      "deployments" => %{
        "greeting" => %{
          "id" => @dep_greeting_stg,
          "revision" => 7,
          "model_id" => @model_chat,
          "params" => %{"temperature" => 0.9, "top_p" => 0.8},
          "provider_options" => %{},
          "prompt_pins" => %{"default" => @pv_greeting_stg}
        }
      },
      "prompt_versions" => %{
        @pv_greeting_stg => %{
          "id" => @pv_greeting_stg,
          "prompt_id" => @prompt_greeting,
          "number" => 3,
          "engine" => "liquid",
          "messages" => [
            %{"role" => "system", "content" => "You are a greeter (staging build)."},
            %{"role" => "user", "content" => "Greet {{ name }}."}
          ],
          "text_template" => nil
        }
      },
      "models" => %{
        @model_chat => %{
          "id" => @model_chat,
          "provider" => "openrouter",
          "model_id" => "openai/gpt-4o-mini",
          "display_name" => "GPT-4o mini",
          "provider_options" => %{"only" => ["OpenAI"], "allow_fallbacks" => false},
          "capabilities" => ["tools", "streaming"],
          "status" => "active",
          "metadata" => %{}
        }
      }
    }
  end

  defp degraded_document do
    %{
      "schema_version" => 4,
      "project" => "sdkfixture",
      "environment" => "production",
      "use_cases" => %{
        "greeting" => %{
          "id" => @uc_greeting,
          "kind" => "chat",
          "input_schema" => [],
          "default_params" => %{"temperature" => 0.4},
          "payload_policy" => payload_policy("full", 1.0)
        }
      },
      "deployments" => %{
        "greeting" => %{
          "id" => @dep_broken,
          "revision" => 1,
          "model_id" => @model_absent,
          "params" => %{},
          "provider_options" => %{"only" => ["OpenAI"]},
          "prompt_pins" => %{"default" => @pv_absent}
        }
      },
      "prompt_versions" => %{},
      "models" => %{}
    }
  end

  # ==========================================================================
  # truncation.json

  defp truncation do
    config = %{
      payload_defaults: %{mode: :full, sample_rate: 1.0, max_bytes: 262_144},
      hash_end_user: false,
      log: %{}
    }

    # Deterministic filler: no random data, so the fixtures are byte-stable.
    long = String.duplicate("abcdefghij", 40)
    korean = String.duplicate("한글", 60)

    cases =
      [
        %{
          name: "passthrough/small_payload_is_untouched",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001001",
            "use_case" => "greeting",
            "status" => "ok",
            "input" => %{
              "messages" => [%{"role" => "user", "content" => "hi"}],
              "variables" => %{"name" => "Ada"}
            },
            "output" => %{"content" => "Hello, Ada!"}
          }
        },
        %{
          name: "wrapping/string_input_and_output_become_objects",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001002",
            "status" => "ok",
            "input" => "raw prompt text",
            "output" => "raw completion text"
          },
          note: "a string input becomes {\"text\": …} and a string output {\"content\": …}"
        },
        %{
          name: "truncate/single_message_content_over_max_bytes_div_8",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001003",
            "status" => "ok",
            "input" => %{"messages" => [%{"role" => "user", "content" => long}]}
          },
          note: "per-message cap is max(max_bytes / 8, 64) = 64 bytes here"
        },
        %{
          name: "truncate/input_text_over_max_bytes",
          policy: %{mode: :full, max_bytes: 128},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001004",
            "status" => "ok",
            "input" => %{"text" => long}
          },
          note: "input.text is capped at max_bytes itself"
        },
        %{
          name: "truncate/variables_over_max_bytes_div_4_are_replaced_by_a_digest",
          policy: %{mode: :full, max_bytes: 256},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001005",
            "status" => "ok",
            "input" => %{"variables" => %{"blob" => long}}
          },
          note:
            "variables are never partially cut: the whole map is replaced by {truncated, sha256, bytes}"
        },
        %{
          name: "truncate/output_content_over_max_bytes_div_4",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001006",
            "status" => "ok",
            "output" => %{"content" => long}
          }
        },
        %{
          name: "truncate/output_tool_calls_arguments_are_shrunk",
          policy: %{mode: :full, max_bytes: 1024},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001007",
            "status" => "ok",
            "output" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "search", "arguments" => long}
                }
              ]
            }
          },
          note:
            "the arguments string is shrunk to fit the cap; the call envelope (id, type, name) is preserved"
        },
        %{
          name: "truncate/output_tool_calls_fall_back_to_a_marker",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001013",
            "status" => "ok",
            "output" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "search", "arguments" => long}
                }
              ]
            }
          },
          note:
            "when the argument budget would fall below 32 bytes the whole tool_calls list is replaced by one marker entry"
        },
        %{
          name: "truncate/messages_total_over_max_bytes_stubs_the_middle",
          policy: %{mode: :full, max_bytes: 340},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001008",
            "status" => "ok",
            "input" => %{
              "messages" => [
                %{"role" => "system", "content" => "system prompt"},
                %{"role" => "user", "content" => String.duplicate("u", 60)},
                %{"role" => "assistant", "content" => String.duplicate("a", 60)},
                %{"role" => "user", "content" => String.duplicate("v", 60)},
                %{"role" => "user", "content" => "the latest turn"}
              ]
            }
          },
          note:
            "the first and last messages are always preserved; middle messages are emptied into byte-count stubs from the front until the list fits, so a later middle message can survive intact"
        },
        %{
          name: "truncate/many_messages_drop_the_middle_entirely",
          policy: %{mode: :full, max_bytes: 192},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001009",
            "status" => "ok",
            "input" => %{
              "messages" =>
                [%{"role" => "system", "content" => "sys"}] ++
                  Enum.map(1..12, fn i ->
                    %{"role" => "user", "content" => "turn #{i} #{String.duplicate("x", 20)}"}
                  end)
            }
          },
          note:
            "when stubbing is not enough, the middle messages are dropped and replaced by one marker message"
        },
        %{
          name: "truncate/utf8_boundary_is_never_split",
          policy: %{mode: :full, max_bytes: 512},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100a",
            "status" => "ok",
            "input" => %{"messages" => [%{"role" => "user", "content" => korean}]},
            "output" => %{"content" => korean}
          },
          note:
            "each Korean syllable is 3 bytes; the result must stay valid UTF-8 and within the cap"
        },
        %{
          name: "truncate/error_message_over_2048_bytes",
          policy: %{mode: :full, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100b",
            "status" => "error",
            "error" => %{
              "kind" => "http_5xx",
              "status" => 502,
              "message" => String.duplicate("E", 4000)
            }
          },
          note: "error.message has a fixed 2048-byte cap, independent of max_bytes"
        },
        %{
          name: "mode/hash_replaces_input_and_output_with_digests",
          policy: %{mode: :hash, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100c",
            "status" => "ok",
            "input" => %{"messages" => [%{"role" => "user", "content" => "hi"}]},
            "output" => %{"content" => "hello"}
          },
          note:
            "sha256 and bytes are computed over the canonical JSON of the wrapped value, with no whitespace"
        },
        %{
          name: "mode/hash_of_a_string_payload_hashes_the_wrapped_object",
          policy: %{mode: :hash, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100d",
            "status" => "ok",
            "input" => "raw prompt text",
            "output" => "raw completion text"
          },
          note: "wrapping happens before hashing, so the digest covers {\"text\":\"…\"}"
        },
        %{
          name: "mode/none_drops_input_and_output",
          policy: %{mode: :none, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100e",
            "status" => "ok",
            "input" => %{"messages" => [%{"role" => "user", "content" => "hi"}]},
            "output" => %{"content" => "hello"}
          }
        },
        %{
          name: "sampling/rate_zero_drops_a_successful_record",
          policy: %{mode: :full, sample_rate: 0.0, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-00000000100f",
            "status" => "ok",
            "stop_kind" => "stop",
            "input" => %{"text" => "hi"},
            "output" => %{"content" => "hello"}
          }
        },
        %{
          name: "sampling/errors_are_always_kept",
          policy: %{mode: :full, sample_rate: 0.0, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001010",
            "status" => "error",
            "input" => %{"text" => "hi"},
            "error" => %{"kind" => "timeout", "message" => "timed out"}
          }
        },
        %{
          name: "sampling/length_truncations_are_always_kept",
          policy: %{mode: :full, sample_rate: 0.0, max_bytes: 262_144},
          log: %{
            "id" => "0198f2a1-0000-7000-8000-000000001011",
            "status" => "ok",
            "stop_kind" => "length",
            "input" => %{"text" => "hi"},
            "output" => %{"content" => "hel"}
          }
        }
      ]
      |> Enum.map(fn spec ->
        policy = spec.policy
        expected = Payload.apply(spec.log, policy, config)

        %{
          "name" => spec.name,
          "policy" => policy_json(policy),
          "log" => spec.log,
          "expect" => %{"log" => expected}
        }
        |> maybe_put("note", Map.get(spec, :note))
      end)

    hash_end_user_case = %{
      "name" => "end_user_ref/hashed_when_hash_end_user_is_set",
      "policy" => policy_json(%{mode: :full, max_bytes: 262_144}),
      "config" => %{"hash_end_user" => true},
      "log" => %{
        "id" => "0198f2a1-0000-7000-8000-000000001012",
        "status" => "ok",
        "end_user_ref" => "user-42"
      },
      "expect" => %{
        "log" =>
          Payload.apply(
            %{
              "id" => "0198f2a1-0000-7000-8000-000000001012",
              "status" => "ok",
              "end_user_ref" => "user-42"
            },
            %{mode: :full, max_bytes: 262_144},
            %{config | hash_end_user: true}
          )
      },
      "note" => "an unkeyed sha256 hex of the raw ref; stable within a project, not anonymisation"
    }

    sampling_buckets =
      [
        "0198f2a1-0000-7000-8000-00000000100f",
        "0198f2a1-0000-7000-8000-000000001010",
        "00000000-0000-0000-0000-000000000000",
        "d2b0f1e4-6f5d-4a1e-9f3a-0b0c0d0e0f10",
        ""
      ]
      |> Enum.map(&%{"id" => &1, "bucket" => Payload.bucket(&1)})

    %{
      "description" =>
        "Monitoring-log payload policy applied by the SDK before a record is enqueued. Run " <>
          "apply(log, policy, config) and compare with expect.log.",
      "order_of_operations" => [
        "keep decision (sampling; errors and stop_kind=length are always kept)",
        "wrap a string input as {\"text\": …} and a string output as {\"content\": …}",
        "apply mode: none drops input/output, hash replaces them with digests, full truncates",
        "cap error.message at 2048 bytes",
        "hash end_user_ref when hash_end_user is set",
        "run the redact hook last"
      ],
      "limits" => %{
        "max_bytes_default" => 262_144,
        "per_message_content" => "max(max_bytes / 8, 64) bytes of the content string",
        "input_messages_json" => "max_bytes, measured on the JSON encoding of the message list",
        "input_text" => "max_bytes",
        "input_variables_json" => "max(max_bytes / 4, 64), replaced wholesale by a digest",
        "output_content" => "max(max_bytes / 4, 64) bytes",
        "output_tool_calls_json" => "max(max_bytes / 4, 64)",
        "error_message" => "2048 bytes, fixed"
      },
      "truncation_marker" => %{
        "shape" => "\\n…[truncated N bytes]…\\n where N = original_size - limit",
        "head_tail_split" =>
          "the budget left after the marker is split 60% head / 40% tail, then trimmed back to a UTF-8 character boundary",
        "flag" => "every map that lost bytes gets \"truncated\": true"
      },
      "sampling" => %{
        "formula" =>
          "bucket(id) = first 4 bytes of sha256(id) read as an unsigned big-endian 32-bit integer, mod 10000; keep when bucket < round(sample_rate * 10000)",
        "always_kept" => ["status == \"error\"", "stop_kind == \"length\""],
        "buckets" => sampling_buckets
      },
      "cases" => cases ++ [hash_end_user_case],
      "server_field_caps" => server_field_caps()
    }
  end

  defp policy_json(policy) do
    %{
      "mode" => to_string(Map.get(policy, :mode, :full)),
      "sample_rate" => Map.get(policy, :sample_rate, 1.0),
      "max_bytes" => Map.get(policy, :max_bytes, 262_144)
    }
  end

  # These two caps live on the server (PromptOn.Observability.Ingest.Record), not in the SDK: an
  # oversized field is blanked at ingest rather than rejected. Documented here so SDK authors know
  # not to expect the SDK to shrink them, and know what the stored record will look like.
  defp server_field_caps do
    params = Map.new(1..80, fn i -> {"key_#{i}", String.duplicate("v", 60)} end)
    usage_raw = Map.new(1..300, fn i -> {"k#{i}", String.duplicate("w", 60)} end)

    %{
      "applied_by" => "server",
      "note" =>
        "The SDK does not shrink params or usage.raw. The ingest endpoint blanks a field that is " <>
          "over its cap (it does not reject the record) and appends the field name to " <>
          "metadata.truncated_fields.",
      "limits" => %{
        "params" => 4096,
        "usage.raw" => 16_384,
        "context" => "2048 - over the cap the whole RECORD is rejected, not blanked",
        "metadata" => "4096 - over the cap the whole RECORD is rejected, not blanked",
        "string_fields" => "512 bytes for trace_id, end_user_ref, prompt, model, finish_reason, …"
      },
      "cases" => [
        %{
          "name" => "params_over_4096_bytes_is_blanked",
          "input" => %{
            "params_json_bytes" => byte_size(Jason.encode!(params)),
            "metadata" => %{"job" => "abc"}
          },
          "expect" => %{
            "params" => %{},
            "metadata" => %{"job" => "abc", "truncated_fields" => ["params"]}
          }
        },
        %{
          "name" => "usage_raw_over_16384_bytes_is_blanked",
          "input" => %{
            "usage_raw_json_bytes" => byte_size(Jason.encode!(usage_raw)),
            "metadata" => %{}
          },
          "expect" => %{
            "usage.raw" => nil,
            "metadata" => %{"truncated_fields" => ["usage.raw"]}
          }
        }
      ]
    }
  end

  # ==========================================================================
  # stop_kind.json

  defp stop_kind do
    raw = [
      {"stop", "OpenAI, OpenRouter"},
      {"end_turn", "Anthropic"},
      {"stop_sequence", "Anthropic"},
      {"length", "OpenAI, OpenRouter"},
      {"max_tokens", "Anthropic"},
      {"tool_calls", "OpenAI, OpenRouter"},
      {"tool_use", "Anthropic"},
      {"content_filter", "OpenAI, OpenRouter"},
      {"function_call", "OpenAI (deprecated spelling)"},
      {"STOP", "Google Gemini (upper case)"},
      {"MAX_TOKENS", "Google Gemini (upper case)"},
      {"SAFETY", "Google Gemini"},
      {"RECITATION", "Google Gemini"},
      {"OTHER", "Google Gemini"},
      {"error", "OpenRouter upstream failure"},
      {"  stop  ", "surrounding whitespace"},
      {"End_Turn", "mixed case"},
      {"tool_call", "already normalized (idempotency)"},
      {"other", "already normalized (idempotency)"},
      {"", "empty string"},
      {"totally_unknown", "unknown value"}
    ]

    cases =
      Enum.map(raw, fn {value, source} ->
        kind = StopKind.normalize(value)

        %{
          "finish_reason" => value,
          "stop_kind" => to_string(kind),
          "truncated" => StopKind.truncated?(kind),
          "source" => source
        }
      end)

    null_case = %{
      "finish_reason" => nil,
      "stop_kind" => to_string(StopKind.normalize(nil)),
      "truncated" => StopKind.truncated?(nil),
      "source" => "absent finish_reason"
    }

    %{
      "description" =>
        "Normalization of a provider's raw finish_reason into PromptOn's stop_kind. Comparison " <>
          "is case-insensitive and trims surrounding whitespace; normalization is idempotent.",
      "stop_kinds" => ["stop", "length", "tool_call", "content_filter", "other"],
      "truncated_definition" => "truncated? is true only for stop_kind == \"length\"",
      "warnings" => [
        "Google's SAFETY and RECITATION map to \"other\", not \"content_filter\": only the literal string content_filter maps there.",
        "tool_calls is NOT a truncation - it must not count towards a truncation rate."
      ],
      "cases" => [null_case | cases]
    }
  end

  # ==========================================================================
  # log_record.json

  defp log_record do
    use_case_chat = %PromptOnSDK.Resolution{
      use_case_key: "greeting",
      kind: :chat,
      prompt: "default",
      deployment_id: @dep_greeting_prod,
      deployment_revision: 3,
      prompt_version_id: @pv_greeting_default,
      prompt_version_number: 2,
      engine: :liquid,
      model_id: @model_chat,
      model: "openai/gpt-4o-mini",
      provider: :openrouter,
      params: %{"temperature" => 0.2, "max_tokens" => 512},
      provider_options: %{"only" => ["OpenAI"], "allow_fallbacks" => true},
      source: :remote
    }

    use_case_embed = %PromptOnSDK.Resolution{
      use_case_key: "embed",
      kind: :embedding,
      prompt: nil,
      deployment_id: @dep_embed_prod,
      deployment_revision: 2,
      model_id: @model_embed,
      model: "openai/text-embedding-3-small",
      provider: :openrouter,
      params: %{"dimensions" => 256},
      provider_options: %{},
      source: :disk
    }

    messages = [
      %{"role" => "system", "content" => "You are a friendly greeter. Answer in one line."},
      %{"role" => "user", "content" => "Say hello to Ada."}
    ]

    records = [
      %{
        "name" => "chat/success",
        "built_by" => "PromptOnSDK.track/3",
        "description" => "A complete successful chat log with usage, cost and output.",
        "record" =>
          build_record(
            use_case_chat,
            %{
              id: "0198f2a1-1111-7000-8000-000000000001",
              trace_id: "oban:8842",
              sequence: 1,
              end_user_ref: "user-42",
              input_messages: messages,
              variables: %{"name" => "Ada"},
              context: %{"language" => "en", "plan" => "pro"},
              metadata: %{"job_id" => 8842, "attempt" => 1}
            },
            :ok,
            %{
              content: "Hello, Ada! Lovely to see you.",
              finish_reason: "stop",
              model_used: "openai/gpt-4o-mini",
              upstream_provider: "OpenAI",
              cost_usd: 0.000112,
              cost_source: :provider,
              is_byok: false,
              usage: %{
                input_tokens: 38,
                output_tokens: 9,
                raw: %{"prompt_tokens" => 38, "completion_tokens" => 9, "total_tokens" => 47}
              }
            },
            nil,
            842
          )
      },
      %{
        "name" => "chat/error_without_output",
        "built_by" => "PromptOnSDK.track/3",
        "description" =>
          "The provider call failed. status is error, there is no output or usage, and error.kind is one of the seven canonical kinds.",
        "record" =>
          build_record(
            use_case_chat,
            %{
              id: "0198f2a1-1111-7000-8000-000000000002",
              trace_id: "oban:8843",
              sequence: 2,
              input_messages: messages,
              variables: %{"name" => "Ada"}
            },
            :error,
            nil,
            %{kind: :rate_limited, status: 429, message: "rate limited by upstream provider"},
            1503
          )
      },
      %{
        "name" => "chat/error_with_usage_preserved",
        "built_by" => "PromptOnSDK.track/3",
        "description" =>
          "The provider answered but the app could not parse the answer. status is error and the usage and output are still recorded, so the call still counts as spend and as a quality signal.",
        "record" =>
          build_record(
            use_case_chat,
            %{
              id: "0198f2a1-1111-7000-8000-000000000003",
              trace_id: "oban:8844",
              input_messages: messages,
              variables: %{"name" => "Ada"}
            },
            :error,
            %{
              content: "{\"greeting\": \"Hello, Ada!\"",
              finish_reason: "length",
              cost_usd: 0.000208,
              cost_source: :provider,
              usage: %{input_tokens: 38, output_tokens: 512}
            },
            %{kind: :parse, message: "unexpected end of JSON input"},
            2310
          )
      },
      %{
        "name" => "embedding/success",
        "built_by" => "PromptOnSDK.track/3",
        "description" =>
          "An embedding log: kind is embedding, there is no prompt or prompt_version_id, the input is text and only input_tokens are reported. source records that the use-case document came from the disk cache.",
        "record" =>
          build_record(
            use_case_embed,
            %{
              id: "0198f2a1-1111-7000-8000-000000000004",
              trace_id: "ingest:2026-09-04:batch-7",
              metadata: %{"chunk" => 12},
              variables: %{"text" => "PromptOn is the control plane for your app's LLM prompts."}
            },
            :ok,
            %{
              finish_reason: nil,
              cost_usd: 0.0000012,
              cost_source: :catalog,
              usage: %{input_tokens: 14, output_tokens: 0}
            },
            nil,
            96
          )
      },
      %{
        "name" => "text/manual_log_with_input_text",
        "built_by" => "hand-assembled map passed to PromptOnSDK.log/1",
        "description" =>
          "A record an app assembles itself, for a streaming call or a background job that does not wrap the provider call. input.text carries a single prompt string instead of a message list, and the record is minimal: only the five required fields plus what the app knows.",
        "record" => manual_text_record()
      }
    ]

    %{
      "description" =>
        "Complete monitoring-log records in the shape POST /api/v1/logs accepts, plus the " <>
          "batch envelope and the server's validation rules.",
      "endpoint" => %{
        "method" => "POST",
        "path" => "/api/v1/logs",
        "query" => %{
          "environment" => "production (default; a request parameter, not a key property)"
        },
        "headers" => %{
          "authorization" => "Bearer ptn_<project_slug>_<random>",
          "content-type" => "application/json"
        },
        "scope" => "logs",
        "max_records_per_request" => 200,
        "success_status" => 202
      },
      "batch_envelope" => %{
        "request" => %{"logs" => Enum.map(records, & &1["record"])},
        "response_example" => %{
          "accepted" => length(records),
          "duplicates" => 0,
          "rejected" => []
        },
        "response_on_resend" => %{
          "accepted" => 0,
          "duplicates" => length(records),
          "rejected" => []
        },
        "response_fields" => %{
          "accepted" => "records stored by this request",
          "duplicates" =>
            "ids this project had already stored - a resend of the same batch returns them here",
          "rejected" =>
            "per-record failures as {index, id, code, message}; the rest of the batch is still accepted"
        },
        "idempotency" =>
          "the record id is the primary key: resending the identical batch returns duplicates instead of accepted, and stores nothing new"
      },
      "field_rules" => %{
        "required" => ["id", "use_case", "model", "status", "started_at"],
        "id" =>
          "MUST be a UUIDv7 (version nibble 7). Request validation accepts any UUID string, but the database column is a UUIDv7 type and a v4 id fails on write: the record comes back in `rejected` with \"record could not be stored\". Generate v7 (48-bit unix milliseconds, then random) so records also sort by time.",
        "use_case" => "the use case key, at most 512 bytes",
        "model" => "the provider model string that was actually requested",
        "status" => "ok | error",
        "started_at" =>
          "ISO8601 with an offset. Rejected when more than 5 minutes in the future or more than 7 days in the past - regenerate this field before replaying these fixtures against a live server",
        "kind" => "chat | text | embedding (defaults to chat)",
        "provider" =>
          "openrouter | groq | openai | anthropic | google | other (unknown becomes other)",
        "stop_kind" =>
          "stop | length | tool_call | content_filter | other; derived from finish_reason when absent",
        "error.kind" => "http_4xx | http_5xx | rate_limited | timeout | transport | parse | app",
        "source" => "remote | disk | bundle | manual",
        "usage.cost_source" => "provider | catalog | unknown",
        "soft_references" =>
          "deployment_id, prompt_version_id and model_id must be a UUID or absent; they are not foreign keys, so a record survives the deletion of what it points at",
        "null_keys" =>
          "the SDK omits a TOP-LEVEL key whose value is null; nested nulls inside usage are sent as null and accepted",
        "jsonb_safety" =>
          "every string (including keys inside context/metadata/params) must be valid UTF-8 with no NUL byte, and every integer must fit in 64 bits, or the record is rejected"
      },
      "records" => records
    }
  end

  defp manual_text_record do
    %{
      "id" => "0198f2a1-1111-7000-8000-000000000005",
      "use_case" => "summarize",
      "kind" => "text",
      "model" => "openai/gpt-4o-mini",
      "provider" => "openrouter",
      "status" => "ok",
      "started_at" => "2026-09-04T09:00:00.000000Z",
      "deployment_id" => @dep_summarize_prod,
      "deployment_revision" => 1,
      "prompt" => "default",
      "prompt_version_id" => @pv_summarize,
      "model_id" => @model_chat,
      "source" => "bundle",
      "input" => %{
        "text" => "Summarize the following notes in one paragraph.\n- alpha\n- beta\n"
      },
      "output" => %{"content" => "Alpha and beta, summarised."},
      "finish_reason" => "stop",
      "stop_kind" => "stop",
      "latency_ms" => 1180,
      "usage" => %{"input_tokens" => 22, "output_tokens" => 7, "cost_source" => "unknown"},
      "sdk" => %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}
    }
  end

  defp build_record(use_case, meta, status, provider_result, error, latency_ms) do
    started_at = ~U[2026-09-04 09:00:00.000000Z]

    use_case
    |> PromptOnSDK.Generation.build(
      meta,
      meta.id,
      started_at,
      System.monotonic_time(),
      status,
      provider_result,
      error
    )
    # The wall-clock latency of the generator run is replaced by a fixed value so the file is
    # byte-stable; everything else is what the internal log builder produced.
    |> Map.put("latency_ms", latency_ms)
  end

  # ==========================================================================

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

GenConformance.run()
