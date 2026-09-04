defmodule PromptOnSDK.UseCaseDocument do
  @moduledoc """
  Decodes the `GET /use-cases` response into the SDK's use-case document structure.

  The SDK reads **schema v4 only**. A document contains deployed use cases, their deployments,
  pinned prompt versions, and model records. The decoded value is consumed by
  `PromptOnSDK.use_case/2` and by test helpers.

  Atom-keyed maps are accepted for hand-written tests, but server responses and bundle files are
  expected to be JSON/string-keyed maps.
  """

  @schema_version 4
  @kinds ~w(chat text embedding)
  @engines ~w(liquid raw)
  @payload_modes ~w(full hash none)
  @variable_types ~w(string number boolean list map)
  @providers ~w(openrouter groq openai anthropic google other)
  @model_statuses ~w(active deprecated)
  @known_values @kinds ++
                  @engines ++ @payload_modes ++ @variable_types ++ @providers ++ @model_statuses
  @known_value_atom_lookup Map.new(@known_values, &{&1, String.to_atom(&1)})

  @atom_keys ~w(
    capabilities content context_length default_params deployments description display_name encrypt
    encrypt? engine environment example id input_schema kind max_bytes messages metadata mode
    model_id models name number payload_policy pricing project prompt_id prompt_pins
    prompt_versions provider provider_options required required? retention_days revision role
    sample_rate schema_version status text_template use_cases
  )
  @atom_key_lookup Map.new(@atom_keys, &{&1, String.to_atom(&1)})

  @type warning :: {atom(), term()}

  @type deployment :: %{
          id: String.t() | nil,
          use_case_key: String.t(),
          revision: integer() | nil,
          model_id: String.t() | nil,
          params: map(),
          provider_options: map(),
          prompt_pins: %{String.t() => String.t()}
        }

  @type use_case :: %{
          id: String.t() | nil,
          key: String.t(),
          kind: atom(),
          input_schema: [map()],
          default_params: map(),
          payload_policy: map() | nil,
          deployment: deployment() | nil
        }

  @type prompt_version :: %{
          id: String.t(),
          prompt_id: String.t() | nil,
          number: integer() | nil,
          engine: :liquid | :raw,
          messages: [PromptOnSDK.UseCase.message()] | nil,
          text_template: String.t() | nil
        }

  @type model :: %{
          id: String.t(),
          provider: atom() | nil,
          model_id: String.t() | nil,
          display_name: String.t() | nil,
          metadata: map(),
          provider_options: map(),
          capabilities: [String.t()],
          pricing: map() | nil,
          context_length: integer() | nil,
          status: atom() | nil
        }

  @type t :: %__MODULE__{
          schema_version: integer(),
          project: String.t() | nil,
          environment: String.t() | nil,
          use_cases: %{String.t() => use_case()},
          deployments: %{String.t() => deployment()},
          prompt_versions: %{String.t() => prompt_version()},
          models: %{String.t() => model()}
        }

  defstruct schema_version: @schema_version,
            project: nil,
            environment: nil,
            use_cases: %{},
            deployments: %{},
            prompt_versions: %{},
            models: %{}

  @doc false
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Decodes a JSON string."
  @spec decode_json(binary()) :: {:ok, t(), [warning()]} | {:error, term()}
  def decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> decode(map)
      {:ok, _other} -> {:error, {:invalid_use_case_document, "top level must be an object"}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc "Converts a decoded map (string or atom keys) into a `t:t/0`."
  @spec decode(map()) :: {:ok, t(), [warning()]} | {:error, term()}
  def decode(%__MODULE__{} = data), do: {:ok, data, []}

  def decode(map) when is_map(map) do
    with {:ok, version, warnings} <- schema_version(map),
         {:ok, use_cases_raw} <- fetch_map(map, "use_cases") do
      {use_cases, warnings} = decode_use_cases(use_cases_raw, warnings)
      {deployments, warnings} = decode_deployments(get(map, "deployments"), warnings)

      {prompt_versions, warnings} =
        decode_by_id(get(map, "prompt_versions"), &decode_prompt_version/2, warnings)

      {models, warnings} = decode_by_id(get(map, "models"), &decode_model/2, warnings)

      data = %__MODULE__{
        schema_version: version,
        project: to_str(get(map, "project")),
        environment: to_str(get(map, "environment")),
        use_cases: attach_deployments(use_cases, deployments),
        deployments: deployments,
        prompt_versions: prompt_versions,
        models: models
      }

      {:ok, data, Enum.reverse(warnings)}
    end
  end

  def decode(_), do: {:error, {:invalid_use_case_document, "use-case document must be a map"}}

  @doc "The Deployment for a use case key. `nil` when there is none."
  @spec deployment(t(), String.t() | atom()) :: deployment() | nil
  def deployment(%__MODULE__{} = data, use_case_key) when is_atom(use_case_key),
    do: deployment(data, Atom.to_string(use_case_key))

  def deployment(%__MODULE__{} = data, use_case_key),
    do: Map.get(data.deployments, use_case_key)

  # ---------------------------------------------------------------------------
  # top level

  defp schema_version(map), do: check_schema_version(get(map, "schema_version"))

  defp check_schema_version(@schema_version), do: {:ok, @schema_version, []}

  defp check_schema_version(v) when is_integer(v) and v > 0,
    do: {:error, {:unsupported_schema_version, v}}

  defp check_schema_version(nil),
    do: {:error, {:invalid_use_case_document, "schema_version is required"}}

  defp check_schema_version(other),
    do:
      {:error,
       {:invalid_use_case_document,
        "schema_version must be a positive integer, got: #{inspect(other)}"}}

  defp fetch_map(map, key) do
    case get(map, key) do
      v when is_map(v) ->
        {:ok, v}

      nil ->
        {:error, {:invalid_use_case_document, "#{key} is required"}}

      other ->
        {:error, {:invalid_use_case_document, "#{key} must be an object, got: #{inspect(other)}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # use cases

  defp decode_use_cases(map, warnings) do
    Enum.reduce(map, {%{}, warnings}, fn {key, raw}, {acc, warnings} ->
      key = to_str(key)

      case raw do
        raw when is_map(raw) ->
          {use_case, warnings} = decode_use_case(key, raw, warnings)
          {Map.put(acc, key, use_case), warnings}

        other ->
          {acc, [{:invalid_use_case, {key, other}} | warnings]}
      end
    end)
  end

  defp decode_use_case(key, raw, warnings) do
    {kind, warnings} = to_enum(get(raw, "kind"), @kinds, :chat, :unknown_kind, warnings)
    {input_schema, warnings} = decode_input_schema(get(raw, "input_schema"), warnings)
    {payload_policy, warnings} = decode_payload_policy(get(raw, "payload_policy"), warnings)

    use_case = %{
      id: to_str(get(raw, "id")),
      key: key,
      kind: kind,
      input_schema: input_schema,
      default_params: to_string_key_map(get(raw, "default_params")),
      payload_policy: payload_policy,
      deployment: nil
    }

    {use_case, warnings}
  end

  # Attach the top-level deployments to the use case with the same key (so the app only has to
  # look in one place).
  defp attach_deployments(use_cases, deployments) when map_size(deployments) == 0, do: use_cases

  defp attach_deployments(use_cases, deployments) do
    Map.new(use_cases, fn {key, use_case} ->
      {key, %{use_case | deployment: Map.get(deployments, key)}}
    end)
  end

  defp decode_input_schema(list, warnings) when is_list(list) do
    Enum.map_reduce(list, warnings, fn
      var, warnings when is_map(var) ->
        {type, warnings} =
          to_enum(get(var, "type"), @variable_types, :string, :unknown_variable_type, warnings)

        {%{
           name: to_str(get(var, "name")),
           type: type,
           required?: get(var, "required") == true or get(var, "required?") == true,
           description: to_str(get(var, "description")),
           example: get(var, "example")
         }, warnings}

      other, warnings ->
        {nil, [{:invalid_variable, other} | warnings]}
    end)
    |> then(fn {vars, warnings} -> {Enum.reject(vars, &is_nil/1), warnings} end)
  end

  defp decode_input_schema(_, warnings), do: {[], warnings}

  defp decode_payload_policy(nil, warnings), do: {nil, warnings}

  defp decode_payload_policy(raw, warnings) when is_map(raw) do
    {mode, warnings} =
      to_enum(get(raw, "mode"), @payload_modes, :full, :unknown_payload_mode, warnings)

    {%{
       mode: mode,
       sample_rate: to_number(get(raw, "sample_rate"), 1.0),
       max_bytes: to_int(get(raw, "max_bytes"), 262_144),
       retention_days: to_int(get(raw, "retention_days"), nil),
       encrypt?: get(raw, "encrypt") == true or get(raw, "encrypt?") == true
     }, warnings}
  end

  defp decode_payload_policy(other, warnings),
    do: {nil, [{:invalid_payload_policy, other} | warnings]}

  # ---------------------------------------------------------------------------
  # deployments (v3: pins)

  defp decode_deployments(nil, warnings), do: {%{}, warnings}

  defp decode_deployments(map, warnings) when is_map(map) do
    Enum.reduce(map, {%{}, warnings}, fn {key, raw}, {acc, warnings} ->
      key = to_str(key)

      case raw do
        raw when is_map(raw) ->
          {deployment, warnings} = decode_deployment(key, raw, warnings)
          {Map.put(acc, key, deployment), warnings}

        other ->
          {acc, [{:invalid_deployment, {key, other}} | warnings]}
      end
    end)
  end

  defp decode_deployments(other, warnings), do: {%{}, [{:invalid_deployments, other} | warnings]}

  defp decode_deployment(key, raw, warnings) do
    {pins, warnings} = decode_prompt_pins(get(raw, "prompt_pins"), key, warnings)

    {%{
       id: to_str(get(raw, "id")),
       use_case_key: to_str(get(raw, "use_case_key")) || key,
       revision: to_int(get(raw, "revision"), nil),
       model_id: to_str(get(raw, "model_id")),
       params: to_string_key_map(get(raw, "params")),
       provider_options: to_string_key_map(get(raw, "provider_options")),
       prompt_pins: pins
     }, warnings}
  end

  defp decode_prompt_pins(nil, _key, warnings), do: {%{}, warnings}

  defp decode_prompt_pins(map, key, warnings) when is_map(map) do
    Enum.reduce(map, {%{}, warnings}, fn {name, version_id}, {acc, warnings} ->
      case {to_str(name), to_str(version_id)} do
        {name, version_id} when is_binary(name) and is_binary(version_id) ->
          {Map.put(acc, name, version_id), warnings}

        _ ->
          {acc, [{:invalid_prompt_pin, {key, name}} | warnings]}
      end
    end)
  end

  defp decode_prompt_pins(other, key, warnings),
    do: {%{}, [{:invalid_prompt_pins, {key, other}} | warnings]}

  # ---------------------------------------------------------------------------
  # prompt versions / models

  defp decode_by_id(nil, _fun, warnings), do: {%{}, warnings}

  defp decode_by_id(map, fun, warnings) when is_map(map) do
    Enum.reduce(map, {%{}, warnings}, fn {id, raw}, {acc, warnings} ->
      id = to_str(id)

      case raw do
        raw when is_map(raw) ->
          {entry, warnings} = fun.(raw |> put_default_id(id), warnings)
          {Map.put(acc, entry.id, entry), warnings}

        other ->
          {acc, [{:invalid_entry, {id, other}} | warnings]}
      end
    end)
  end

  # The list form (`[%{"id" => ...}]`) is accepted too.
  defp decode_by_id(list, fun, warnings) when is_list(list) do
    Enum.reduce(list, {%{}, warnings}, fn
      raw, {acc, warnings} when is_map(raw) ->
        {entry, warnings} = fun.(raw, warnings)
        {Map.put(acc, entry.id, entry), warnings}

      other, {acc, warnings} ->
        {acc, [{:invalid_entry, other} | warnings]}
    end)
  end

  defp decode_by_id(other, _fun, warnings), do: {%{}, [{:invalid_collection, other} | warnings]}

  defp put_default_id(raw, id) do
    if is_nil(get(raw, "id")), do: Map.put(raw, "id", id), else: raw
  end

  defp decode_prompt_version(raw, warnings) do
    {engine, warnings} = to_enum(get(raw, "engine"), @engines, :liquid, :unknown_engine, warnings)
    {messages, warnings} = decode_messages(get(raw, "messages"), warnings)

    {%{
       id: to_str(get(raw, "id")),
       prompt_id: to_str(get(raw, "prompt_id")),
       number: to_int(get(raw, "number"), nil),
       engine: engine,
       messages: messages,
       text_template: to_str(get(raw, "text_template"))
     }, warnings}
  end

  defp decode_messages(nil, warnings), do: {nil, warnings}

  defp decode_messages(list, warnings) when is_list(list) do
    Enum.map_reduce(list, warnings, fn
      msg, warnings when is_map(msg) ->
        message = %{role: to_str(get(msg, "role")), content: to_str(get(msg, "content")) || ""}

        message =
          case to_str(get(msg, "name")) do
            nil -> message
            name -> Map.put(message, :name, name)
          end

        {message, warnings}

      other, warnings ->
        {nil, [{:invalid_message, other} | warnings]}
    end)
    |> then(fn {msgs, warnings} -> {Enum.reject(msgs, &is_nil/1), warnings} end)
  end

  defp decode_messages(other, warnings), do: {nil, [{:invalid_messages, other} | warnings]}

  defp decode_model(raw, warnings) do
    {%{
       id: to_str(get(raw, "id")),
       provider: to_known_atom_or_nil(get(raw, "provider"), @providers),
       model_id: to_str(get(raw, "model_id")),
       display_name: to_str(get(raw, "display_name")),
       metadata: to_string_key_map(get(raw, "metadata")),
       provider_options: to_string_key_map(get(raw, "provider_options")),
       capabilities:
         raw
         |> get("capabilities")
         |> List.wrap()
         |> Enum.map(&to_str/1)
         |> Enum.reject(&is_nil/1),
       pricing: get(raw, "pricing"),
       context_length: to_int(get(raw, "context_length"), nil),
       status: to_known_atom_or_nil(get(raw, "status"), @model_statuses)
     }, warnings}
  end

  # ---------------------------------------------------------------------------
  # helpers

  # String key first, otherwise the atom key of the same name.
  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, @atom_key_lookup[key])
    end
  end

  defp get(_, _), do: nil

  defp to_str(nil), do: nil
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v) when is_number(v), do: to_string(v)
  defp to_str(_), do: nil

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(v, _default) when is_float(v), do: trunc(v)

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> default
    end
  end

  defp to_int(_, default), do: default

  defp to_number(v, _default) when is_number(v), do: v
  defp to_number(_, default), do: default

  defp to_known_atom_or_nil(nil, _allowed), do: nil

  defp to_known_atom_or_nil(v, allowed) when is_atom(v),
    do: to_known_atom_or_nil(Atom.to_string(v), allowed)

  defp to_known_atom_or_nil(v, allowed) when is_binary(v) do
    if v in allowed, do: @known_value_atom_lookup[v]
  end

  defp to_known_atom_or_nil(_v, _allowed), do: nil

  # A known value becomes an atom; an unknown value gets a warning and falls back to the default
  # without creating atoms from remote values; nil gives the default.
  defp to_enum(nil, _allowed, default, _warning_tag, warnings), do: {default, warnings}

  defp to_enum(v, allowed, default, warning_tag, warnings) do
    str = to_str(v)

    cond do
      is_nil(str) -> {default, [{warning_tag, v} | warnings]}
      str in allowed -> {@known_value_atom_lookup[str], warnings}
      true -> {default, [{warning_tag, str} | warnings]}
    end
  end

  defp to_string_key_map(map) when is_map(map), do: PromptOnSDK.Params.stringify_keys(map)
  defp to_string_key_map(_), do: %{}
end
