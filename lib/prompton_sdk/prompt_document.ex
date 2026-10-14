defmodule PromptOnSDK.PromptDocument do
  @moduledoc """
  Decodes `GET /prompts` and `GET /prompts/:key` responses into the SDK's prompt document structure.

  The SDK reads **schema v9, schema v8, schema v7, schema v6, and legacy v5**. Prepared requests require v6+
  metadata. A document contains deployed prompts, their deployments,
  pinned template versions, and model records. The decoded value is consumed by
  `PromptOnSDK.prompt/2` and by test helpers.

  Atom-keyed maps are accepted for hand-written tests, but server responses and bundle files are
  expected to be JSON/string-keyed maps.
  """

  @schema_version 9
  @kinds ~w(chat decision text embedding)
  @apis ~w(chat_completions decisions)
  @engines ~w(liquid raw)
  @payload_modes ~w(full hash none)
  @variable_types ~w(string number boolean list map)
  @providers ~w(openrouter groq openai anthropic google other)
  @model_statuses ~w(active deprecated)
  @revision_pattern ~r/\Av\d{4}\.\d{2}\.\d{2}-[1-9]\d*\z/
  @known_values @kinds ++
                  @apis ++
                  @engines ++ @payload_modes ++ @variable_types ++ @providers ++ @model_statuses
  @known_value_atom_lookup Map.new(@known_values, &{&1, String.to_atom(&1)})

  @atom_keys ~w(
    api capabilities content context_length decision default_params deployments description display_name encrypt
    encrypt? engine environment example id input_schema kind max_bytes messages metadata mode
    model model_id models name number output_examples output_schema parallel_tool_calls params payload_policy
    pricing project prompt prompt_template_id prompt_version template_pins prompt_versions provider provider_options required
    required? retention_days revision role request_path sample_rate schema_version status text_template
    tool_choice tools type prompts
  )
  @atom_key_lookup Map.new(@atom_keys, &{&1, String.to_atom(&1)})

  @type warning :: {atom(), term()}

  @type deployment :: %{
          id: String.t() | nil,
          prompt_key: String.t(),
          revision: String.t() | nil,
          model_id: String.t() | nil,
          api: :chat_completions | :decisions | nil,
          request_path: String.t() | nil,
          params: map(),
          provider_options: map(),
          template_pins: %{String.t() => String.t()}
        }

  @type prompt :: %{
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
          prompt_template_id: String.t() | nil,
          number: integer() | nil,
          engine: :liquid | :raw,
          kind: atom() | nil,
          decision: map() | nil,
          messages: [PromptOnSDK.Prompt.message()] | nil,
          tools: map() | nil,
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
          prompts: %{String.t() => prompt()},
          deployments: %{String.t() => deployment()},
          prompt_versions: %{String.t() => prompt_version()},
          models: %{String.t() => model()}
        }

  defstruct schema_version: @schema_version,
            project: nil,
            environment: nil,
            prompts: %{},
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
      {:ok, _other} -> {:error, {:invalid_prompt_document, "top level must be an object"}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @doc "Converts a decoded map (string or atom keys) into a `t:t/0`."
  @spec decode(map()) :: {:ok, t(), [warning()]} | {:error, term()}
  def decode(%__MODULE__{} = data), do: {:ok, data, []}

  def decode(map) when is_map(map) do
    with {:ok, version, warnings} <- schema_version(map),
         {:ok, map} <- normalize_schema9_single_prompt(map, version),
         {:ok, prompts_raw} <- fetch_map(map, "prompts"),
         :ok <- validate_schema8_references(map, version) do
      {prompts, warnings} = decode_prompts(prompts_raw, warnings)
      {deployments, warnings} = decode_deployments(get(map, "deployments"), version, warnings)

      {prompt_versions, warnings} =
        decode_by_id(
          get(map, "prompt_versions"),
          &decode_prompt_version(&1, version, &2),
          warnings
        )

      {models, warnings} = decode_by_id(get(map, "models"), &decode_model/2, warnings)

      data = %__MODULE__{
        schema_version: version,
        project: to_str(get(map, "project")),
        environment: to_str(get(map, "environment")),
        prompts: attach_deployments(prompts, deployments),
        deployments: deployments,
        prompt_versions: prompt_versions,
        models: models
      }

      {:ok, data, Enum.reverse(warnings)}
    end
  end

  def decode(_), do: {:error, {:invalid_prompt_document, "prompt document must be a map"}}

  @doc "The Deployment for a prompt key. `nil` when there is none."
  @spec deployment(t(), String.t() | atom()) :: deployment() | nil
  def deployment(%__MODULE__{} = data, prompt_key) when is_atom(prompt_key),
    do: deployment(data, Atom.to_string(prompt_key))

  def deployment(%__MODULE__{} = data, prompt_key),
    do: Map.get(data.deployments, prompt_key)

  # ---------------------------------------------------------------------------
  # top level

  defp schema_version(map), do: check_schema_version(get(map, "schema_version"))

  defp check_schema_version(version) when version in [5, 6, 7, 8, @schema_version],
    do: {:ok, version, []}

  defp check_schema_version(v) when is_integer(v) and v > 0,
    do: {:error, {:unsupported_schema_version, v}}

  defp check_schema_version(nil),
    do: {:error, {:invalid_prompt_document, "schema_version is required"}}

  defp check_schema_version(other),
    do:
      {:error,
       {:invalid_prompt_document,
        "schema_version must be a positive integer, got: #{inspect(other)}"}}

  defp fetch_map(map, key) do
    case get(map, key) do
      v when is_map(v) ->
        {:ok, v}

      nil ->
        {:error, {:invalid_prompt_document, "#{key} is required"}}

      other ->
        {:error, {:invalid_prompt_document, "#{key} must be an object, got: #{inspect(other)}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # prompts

  defp decode_prompts(map, warnings) do
    Enum.reduce(map, {%{}, warnings}, fn {key, raw}, {acc, warnings} ->
      key = to_str(key)

      case raw do
        raw when is_map(raw) ->
          {prompt, warnings} = decode_prompt(key, raw, warnings)
          {Map.put(acc, key, prompt), warnings}

        other ->
          {acc, [{:invalid_prompt, {key, other}} | warnings]}
      end
    end)
  end

  defp decode_prompt(key, raw, warnings) do
    {kind, warnings} = to_enum(get(raw, "kind"), @kinds, :chat, :unknown_kind, warnings)
    {input_schema, warnings} = decode_input_schema(get(raw, "input_schema"), warnings)
    {payload_policy, warnings} = decode_payload_policy(get(raw, "payload_policy"), warnings)

    prompt = %{
      id: to_str(get(raw, "id")),
      key: key,
      kind: kind,
      input_schema: input_schema,
      default_params: to_string_key_map(get(raw, "default_params")),
      payload_policy: payload_policy,
      deployment: nil
    }

    {prompt, warnings}
  end

  # Attach the top-level deployments to the prompt with the same key (so the app only has to
  # look in one place).
  defp attach_deployments(prompts, deployments) when map_size(deployments) == 0, do: prompts

  defp attach_deployments(prompts, deployments) do
    Map.new(prompts, fn {key, prompt} ->
      {key, %{prompt | deployment: Map.get(deployments, key)}}
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
  # schema v9 single-prompt envelope

  defp normalize_schema9_single_prompt(map, version) when version != 9, do: {:ok, map}

  defp normalize_schema9_single_prompt(map, 9) do
    with :ok <- reject_schema9_mixed_shape(map),
         {:ok, prompt} <- required_object(map, "prompt"),
         {:ok, deployment} <- required_object(map, "deployment"),
         {:ok, prompt_version} <- required_object(map, "prompt_version"),
         {:ok, model} <- required_object(map, "model"),
         {:ok, key} <- required_string(get(prompt, "key"), "prompt.key"),
         :ok <- validate_schema9_identity(key, deployment, prompt_version, model) do
      normalized =
        map
        |> Map.delete("prompt")
        |> Map.delete(:prompt)
        |> Map.delete("deployment")
        |> Map.delete(:deployment)
        |> Map.delete("prompt_version")
        |> Map.delete(:prompt_version)
        |> Map.delete("model")
        |> Map.delete(:model)
        |> Map.put("prompts", %{key => prompt})
        |> Map.put("deployments", %{key => deployment})
        |> Map.put("prompt_versions", %{
          "#{key}@#{get(prompt_version, "number")}" => prompt_version
        })
        |> Map.put("models", %{"#{get(model, "provider")}:#{get(model, "model")}" => model})

      {:ok, normalized}
    end
  end

  defp reject_schema9_mixed_shape(map) do
    Enum.find_value(~w(prompts deployments prompt_versions models), :ok, fn key ->
      if has_key?(map, key) do
        {:error,
         {:invalid_prompt_document, "schema 9 single prompt document must not include #{key}"}}
      else
        false
      end
    end)
  end

  defp validate_schema9_identity(key, deployment, prompt_version, model) do
    with {:ok, version_prompt} <-
           required_string(get(prompt_version, "prompt"), "prompt_version.prompt"),
         :ok <-
           require_equal_value(
             version_prompt,
             key,
             "prompt_version.prompt #{version_prompt} must match prompt.key #{key}"
           ),
         {:ok, version_number} <-
           strict_positive_integer(get(prompt_version, "number"), "prompt_version.number"),
         {:ok, deployment_version} <-
           strict_positive_integer(get(deployment, "prompt_version"), "deployment.prompt_version"),
         :ok <-
           require_equal_value(
             deployment_version,
             version_number,
             "deployment.prompt_version #{deployment_version} must match prompt_version.number #{version_number}"
           ),
         {:ok, deployment_provider} <-
           required_string(get(deployment, "provider"), "deployment.provider"),
         {:ok, deployment_model} <- required_string(get(deployment, "model"), "deployment.model"),
         {:ok, model_provider} <- required_string(get(model, "provider"), "model.provider"),
         {:ok, model_name} <- required_string(get(model, "model"), "model.model"),
         :ok <-
           require_equal_value(
             {deployment_provider, deployment_model},
             {model_provider, model_name},
             "deployment provider/model #{deployment_provider}:#{deployment_model} must match model #{model_provider}:#{model_name}"
           ) do
      :ok
    end
  end

  defp required_object(map, key) do
    case get(map, key) do
      value when is_map(value) ->
        {:ok, value}

      nil ->
        {:error, {:invalid_prompt_document, "#{key} is required"}}

      other ->
        {:error, {:invalid_prompt_document, "#{key} must be an object, got: #{inspect(other)}"}}
    end
  end

  defp require_equal_value(value, value, _message), do: :ok

  defp require_equal_value(_left, _right, message),
    do: {:error, {:invalid_prompt_document, message}}

  # schema v8/v9 validation

  defp validate_schema8_references(_map, version) when version < 8, do: :ok

  defp validate_schema8_references(map, _version) do
    with {:ok, deployments} <- optional_object(map, "deployments"),
         {:ok, prompt_versions} <- optional_object(map, "prompt_versions"),
         {:ok, models} <- optional_object(map, "models"),
         :ok <- validate_schema8_prompt_versions(prompt_versions || %{}),
         :ok <- validate_schema8_models(models || %{}) do
      validate_schema8_deployments(deployments || %{}, prompt_versions || %{}, models || %{})
    end
  end

  defp optional_object(map, key) do
    case get(map, key) do
      value when is_map(value) ->
        {:ok, value}

      nil ->
        {:ok, nil}

      other ->
        {:error, {:invalid_prompt_document, "#{key} must be an object, got: #{inspect(other)}"}}
    end
  end

  defp validate_schema8_prompt_versions(prompt_versions) do
    validate_each(prompt_versions, &validate_schema8_prompt_version/2)
  end

  defp validate_schema8_prompt_version(key, raw) do
    with :ok <- require_map(raw, "prompt_versions.#{key}"),
         {:ok, prompt} <- required_string(get(raw, "prompt"), "prompt_versions.#{key}.prompt"),
         {:ok, number} <-
           strict_positive_integer(get(raw, "number"), "prompt_versions.#{key}.number") do
      require_equal_key(
        key,
        "#{prompt}@#{number}",
        "prompt_versions key",
        "embedded prompt version"
      )
    end
  end

  defp validate_schema8_models(models) do
    validate_each(models, &validate_schema8_model/2)
  end

  defp validate_schema8_model(key, raw) do
    with :ok <- require_map(raw, "models.#{key}"),
         {:ok, provider} <- required_string(get(raw, "provider"), "models.#{key}.provider"),
         {:ok, model} <- required_string(get(raw, "model"), "models.#{key}.model") do
      require_equal_key(key, "#{provider}:#{model}", "models key", "embedded model")
    end
  end

  defp validate_schema8_deployments(deployments, prompt_versions, models) do
    validate_each(deployments, fn key, raw ->
      validate_schema8_deployment(key, raw, prompt_versions, models)
    end)
  end

  defp validate_schema8_deployment(key, raw, prompt_versions, models) do
    with :ok <- require_map(raw, "deployments.#{key}"),
         {:ok, number} <-
           strict_positive_integer(
             get(raw, "prompt_version"),
             "deployments.#{key}.prompt_version"
           ),
         {:ok, provider} <- required_string(get(raw, "provider"), "deployments.#{key}.provider"),
         {:ok, model} <- required_string(get(raw, "model"), "deployments.#{key}.model"),
         prompt_version_key = "#{key}@#{number}",
         model_key = "#{provider}:#{model}",
         :ok <-
           require_map_key(
             prompt_versions,
             prompt_version_key,
             "deployment #{key} references missing prompt version #{prompt_version_key}"
           ) do
      require_map_key(
        models,
        model_key,
        "deployment #{key} references missing model #{model_key}"
      )
    end
  end

  defp validate_each(map, validator) do
    Enum.find_value(map, :ok, fn {key, raw} ->
      case validator.(to_str(key), raw) do
        :ok -> false
        {:error, message} -> {:error, {:invalid_prompt_document, message}}
      end
    end)
  end

  defp require_map(value, _label) when is_map(value), do: :ok
  defp require_map(_value, label), do: {:error, "#{label} must be an object"}

  defp require_equal_key(key, expected, subject, detail) do
    if key == expected,
      do: :ok,
      else: {:error, "#{subject} #{key} must match #{detail} #{expected}"}
  end

  defp require_map_key(map, key, message) do
    if Map.has_key?(map, key), do: :ok, else: {:error, message}
  end

  defp required_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp required_string(value, field) when is_binary(value),
    do: {:error, "#{field} must be a non-empty string"}

  defp required_string(nil, field), do: {:error, "#{field} is required"}
  defp required_string(_value, field), do: {:error, "#{field} must be a string"}

  defp strict_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp strict_positive_integer(_value), do: :error

  defp strict_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp strict_positive_integer(nil, field), do: {:error, "#{field} is required"}
  defp strict_positive_integer(_value, field), do: {:error, "#{field} must be a positive integer"}

  # ---------------------------------------------------------------------------
  # deployments (v3: pins)

  defp decode_deployments(nil, _version, warnings), do: {%{}, warnings}

  defp decode_deployments(map, version, warnings) when is_map(map) do
    Enum.reduce(map, {%{}, warnings}, fn {key, raw}, {acc, warnings} ->
      key = to_str(key)

      case raw do
        raw when is_map(raw) ->
          {deployment, warnings} = decode_deployment(key, raw, version, warnings)
          {Map.put(acc, key, deployment), warnings}

        other ->
          {acc, [{:invalid_deployment, {key, other}} | warnings]}
      end
    end)
  end

  defp decode_deployments(other, _version, warnings),
    do: {%{}, [{:invalid_deployments, other} | warnings]}

  defp decode_deployment(key, raw, version, warnings) do
    {pins, warnings} = decode_prompt_pins(raw, key, version, warnings)

    {api, warnings} =
      to_enum(if(version >= 6, do: get(raw, "api")), @apis, nil, :unknown_api, warnings)

    request_path = if version >= 6, do: get(raw, "request_path")

    {%{
       id: if(version >= 8, do: nil, else: to_str(get(raw, "id"))),
       prompt_key: to_str(get(raw, "prompt_key")) || key,
       revision: to_revision(get(raw, "revision")),
       model_id:
         if(version >= 8, do: readable_model_key(raw), else: to_str(get(raw, "model_id"))),
       api: api,
       request_path: if(is_binary(request_path), do: request_path),
       params: to_string_key_map(get(raw, "params")),
       provider_options: to_string_key_map(get(raw, "provider_options")),
       template_pins: pins
     }, revision_warnings(get(raw, "revision"), key, warnings)}
  end

  defp to_revision(nil), do: nil
  defp to_revision(value) when is_binary(value), do: if(value =~ @revision_pattern, do: value)
  defp to_revision(_value), do: nil

  defp revision_warnings(nil, _key, warnings), do: warnings

  defp revision_warnings(value, _key, warnings) when is_binary(value) do
    if value =~ @revision_pattern, do: warnings, else: [{:invalid_revision, value} | warnings]
  end

  defp revision_warnings(value, key, warnings), do: [{:invalid_revision, {key, value}} | warnings]

  defp decode_prompt_pins(raw, key, version, warnings) when version >= 8 do
    case strict_positive_integer(get(raw, "prompt_version")) do
      {:ok, n} ->
        {%{"default" => "#{key}@#{n}"}, warnings}

      :error ->
        {%{}, [{:invalid_prompt_version_pin, {key, get(raw, "prompt_version")}} | warnings]}
    end
  end

  defp decode_prompt_pins(raw, key, _version, warnings),
    do: decode_template_pins(get(raw, "template_pins"), key, warnings)

  defp decode_template_pins(nil, _key, warnings), do: {%{}, warnings}

  defp decode_template_pins(map, key, warnings) when is_map(map) do
    Enum.reduce(map, {%{}, warnings}, fn {name, version_id}, {acc, warnings} ->
      case {to_str(name), to_str(version_id)} do
        {name, version_id} when is_binary(name) and is_binary(version_id) ->
          {Map.put(acc, name, version_id), warnings}

        _ ->
          {acc, [{:invalid_template_pin, {key, name}} | warnings]}
      end
    end)
  end

  defp decode_template_pins(other, key, warnings),
    do: {%{}, [{:invalid_template_pins, {key, other}} | warnings]}

  # ---------------------------------------------------------------------------
  # template versions / models

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

  defp decode_prompt_version(raw, version, warnings) do
    {kind, warnings} =
      to_enum(
        if(version >= 6, do: get(raw, "kind")),
        @kinds,
        nil,
        :unknown_version_kind,
        warnings
      )

    {engine, warnings} = to_enum(get(raw, "engine"), @engines, :liquid, :unknown_engine, warnings)
    {messages, warnings} = decode_messages(get(raw, "messages"), warnings)

    {%{
       id:
         if(version >= 8,
           do: readable_prompt_version_key(raw),
           else: to_str(get(raw, "id"))
         ),
       prompt_template_id:
         if(version >= 8,
           do: to_str(get(raw, "prompt")),
           else: to_str(get(raw, "prompt_template_id"))
         ),
       number: to_int(get(raw, "number"), nil),
       engine: engine,
       kind: kind,
       decision: if(version >= 6, do: PromptOnSDK.Decisions.normalize(get(raw, "decision"))),
       messages: messages,
       tools: decode_tools(get(raw, "tools")),
       text_template: to_str(get(raw, "text_template"))
     }, warnings}
  end

  defp decode_messages(nil, warnings), do: {nil, warnings}

  defp decode_messages(list, warnings) when is_list(list) do
    Enum.map_reduce(list, warnings, fn
      msg, warnings when is_map(msg) ->
        {decode_message(msg), warnings}

      other, warnings ->
        {nil, [{:invalid_message, other} | warnings]}
    end)
    |> then(fn {msgs, warnings} -> {Enum.reject(msgs, &is_nil/1), warnings} end)
  end

  defp decode_messages(other, warnings), do: {nil, [{:invalid_messages, other} | warnings]}

  defp decode_message(msg) do
    base = PromptOnSDK.Decisions.normalize(msg)

    message = %{role: to_str(get(msg, "role"))}

    message =
      if Map.has_key?(base, "content") do
        Map.put(message, :content, base["content"])
      else
        message
      end

    message =
      case to_str(get(msg, "name")) do
        nil -> message
        name -> Map.put(message, :name, name)
      end

    extras =
      base
      |> Map.drop(~w(role content name))
      |> normalize_retired_message_slot()

    Map.merge(extras, message)
  end

  defp normalize_retired_message_slot(%{"type" => :slot} = message),
    do: %{message | "type" => "slot"}

  defp normalize_retired_message_slot(message), do: message

  defp decode_tools(nil), do: nil
  defp decode_tools(raw) when is_map(raw), do: PromptOnSDK.Decisions.normalize(raw)
  defp decode_tools(_), do: nil

  defp decode_model(raw, warnings) do
    {%{
       id: readable_model_id(raw),
       provider: to_known_atom_or_nil(get(raw, "provider"), @providers),
       model_id: to_str(get(raw, "model")) || to_str(get(raw, "model_id")),
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

  defp readable_prompt_version_key(raw) do
    case {to_str(get(raw, "prompt")), strict_positive_integer(get(raw, "number"))} do
      {prompt, {:ok, number}} when is_binary(prompt) ->
        "#{prompt}@#{number}"

      _ ->
        to_str(get(raw, "id"))
    end
  end

  defp readable_model_id(raw), do: readable_model_key(raw) || to_str(get(raw, "id"))

  defp readable_model_key(raw) do
    case {to_str(get(raw, "provider")), to_str(get(raw, "model"))} do
      {provider, model} when is_binary(provider) and is_binary(model) -> "#{provider}:#{model}"
      _ -> nil
    end
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

  defp has_key?(map, key) when is_map(map) and is_binary(key) do
    Map.has_key?(map, key) or Map.has_key?(map, @atom_key_lookup[key])
  end

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
