defmodule PromptOnSDK.Test do
  @moduledoc """
  Test mode helpers (§7.6). With `config :prompton_sdk, mode: :test`:

  * There is no HTTP at all: the use-case document loader is idle, and `PromptOnSDK.log/1` /
    `feedback/1` send `{:prompton_log, gen}` / `{:prompton_feedback, map}` to the
    **calling process** instead of the Buffer. `Oban.Testing.perform_job/3` runs in the calling
    process too, so you can `assert_receive` directly. The supervisor (`{PromptOnSDK, []}`) need
    not be started: the document lives in `:persistent_term`, so no process is required.
  * Documents are injected with `put_use_case_document/1` (map, JSON file, or
    `PromptOnSDK.UseCaseDocument.t()`) or
    `stub/2` (a minimal entry for one UseCase).

  ## Usage

      # test_helper.exs
      Application.put_env(:prompton_sdk, :mode, :test)

      # in a test
      setup do
        PromptOnSDK.Test.stub("support_reply", %{model: "openai/gpt-4o-mini",
          messages: [
            %{role: "system", content: "You are a friendly support agent for Acme. Answer in two or three sentences; if you are not sure, say so and offer to escalate."},
            %{role: "user", content: "{{ question }}"}
          ],
          params: %{temperature: 0.3}})
        on_exit(&PromptOnSDK.Test.clear/0)
      end

  Named prompts (language branches) are stubbed with `prompt:`:
  `stub("support_reply", %{model: ..., prompt: "ko", ...})` corresponds to
  `PromptOnSDK.use_case("support_reply", prompt: "ko")`. Calling it several times for the same key with
  different names accumulates pins.

      test "worker records a log" do
        assert :ok = perform_job(MyApp.Workers.SupportReply, %{...})
        # partial match (map pattern)
        assert_logged(%{"use_case" => "support_reply", "status" => "ok"})
      end

  `stub/2` **accumulates** onto the existing test document (multiple UseCases). `put_use_case_document/1`
  replaces it as a whole. `stub/2` options: `model:` (required, the provider model string),
  `provider:` (default `:openrouter`), `messages:` (chat) or `text_template:` (text), `kind:`
  (default `:chat`; `:embedding` has no prompt), `prompt:` (the prompt name, default
  `"default"`), `params:`, `provider_options:`, `payload_policy:`, `environment:`.
  """

  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.UseCaseDocument

  @doc """
  Injects a use-case document: a `map` (§6.2 format, string/atom keys) | `{:file, path}` (JSON) |
  `PromptOnSDK.UseCaseDocument.t()`. `source: :manual`, `etag: "test"`. Raises on a decode
  failure.
  """
  @spec put_use_case_document(map() | {:file, String.t()} | UseCaseDocument.t(), keyword()) :: :ok
  def put_use_case_document(document, opts \\ [])

  def put_use_case_document({:file, path}, opts) do
    case UseCaseDocument.decode_json(File.read!(path)) do
      {:ok, data, _warnings} ->
        put_use_case_document(data, opts)

      {:error, reason} ->
        raise ArgumentError, "invalid use-case document file #{path}: #{inspect(reason)}"
    end
  end

  def put_use_case_document(%UseCaseDocument{} = data, opts) do
    Store.put(
      Store.new_entry(data, Keyword.get(opts, :source, :manual),
        etag: Keyword.get(opts, :etag, "test"),
        last_modified: Keyword.get(opts, :last_modified)
      )
    )
  end

  def put_use_case_document(map, opts) when is_map(map) do
    case UseCaseDocument.decode(map) do
      {:ok, data, _warnings} -> put_use_case_document(data, opts)
      {:error, reason} -> raise ArgumentError, "invalid use-case document: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a minimal use-case document entry for one UseCase and merges it into the current test document
  (creating one if there is none). One Deployment pin → one PromptVersion/Model. Calling it again
  for the same use case with only `prompt:` changed **adds** a pin under that name (the model and
  params of the last call win).
  """
  @spec stub(String.t() | atom(), map() | keyword()) :: :ok
  def stub(use_case_key, spec) do
    key = to_string(use_case_key)
    spec = Map.new(spec)
    kind = Map.get(spec, :kind, :chat)
    model = Map.get(spec, :model) || raise ArgumentError, "stub/2 requires :model"
    prompt = to_string(Map.get(spec, :prompt, "default"))

    ids = %{pv: "stub-pv-#{key}-#{prompt}", model: "stub-model-#{key}"}
    prompt_version = stub_prompt_version(kind, ids.pv, spec)

    base =
      case Store.get() do
        %{source: :manual, data: %UseCaseDocument{} = data} -> data
        _ -> %UseCaseDocument{environment: Map.get(spec, :environment)}
      end

    pins =
      case Map.get(base.deployments, key) do
        %{prompt_pins: pins} when is_map(pins) -> pins
        _ -> %{}
      end

    pins = if prompt_version, do: Map.put(pins, prompt, ids.pv), else: %{}

    {:ok, uc_data, _} =
      UseCaseDocument.decode(%{
        "schema_version" => UseCaseDocument.schema_version(),
        "use_cases" => %{key => stub_use_case(key, kind, spec)},
        "deployments" => %{key => stub_deployment(key, ids, pins, spec)},
        "prompt_versions" => if(prompt_version, do: %{ids.pv => prompt_version}, else: %{}),
        "models" => %{ids.model => stub_model(ids.model, model, spec)}
      })

    merged = %UseCaseDocument{
      base
      | use_cases: Map.merge(base.use_cases, uc_data.use_cases),
        deployments: Map.merge(base.deployments, uc_data.deployments),
        prompt_versions: Map.merge(base.prompt_versions, uc_data.prompt_versions),
        models: Map.merge(base.models, uc_data.models)
    }

    merged = %UseCaseDocument{
      merged
      | use_cases:
          Map.new(merged.use_cases, fn {k, uc} ->
            {k, %{uc | deployment: Map.get(merged.deployments, k)}}
          end)
    }

    put_use_case_document(merged, [])
  end

  defp stub_prompt_version(:embedding, _pv_id, _spec), do: nil

  defp stub_prompt_version(:text, pv_id, spec) do
    %{
      "id" => pv_id,
      "number" => 1,
      "engine" => to_string(Map.get(spec, :engine, :liquid)),
      "text_template" => Map.get(spec, :text_template) || ""
    }
  end

  defp stub_prompt_version(_chat, pv_id, spec) do
    %{
      "id" => pv_id,
      "number" => 1,
      "engine" => to_string(Map.get(spec, :engine, :liquid)),
      "messages" => Map.get(spec, :messages) || []
    }
  end

  defp stub_use_case(key, kind, spec) do
    %{
      "id" => "stub-uc-#{key}",
      "kind" => to_string(kind),
      "input_schema" => Map.get(spec, :input_schema, []),
      "default_params" => %{},
      "payload_policy" => Map.get(spec, :payload_policy)
    }
  end

  defp stub_deployment(key, ids, pins, spec) do
    %{
      "id" => "stub-deployment-#{key}",
      "revision" => 1,
      "model_id" => ids.model,
      "params" => Map.get(spec, :params, %{}),
      "provider_options" => Map.get(spec, :provider_options, %{}),
      "prompt_pins" => pins
    }
  end

  defp stub_model(model_id, model, spec) do
    %{
      "id" => model_id,
      "provider" => to_string(Map.get(spec, :provider, :openrouter)),
      "model_id" => model,
      "display_name" => model,
      "metadata" => %{},
      "provider_options" => %{},
      "capabilities" => []
    }
  end

  @doc "Clears the test document (`PromptOnSDK.use_case/2` → `{:error, :not_ready}`)."
  @spec clear() :: :ok
  def clear do
    Store.erase()
    :ok
  end

  @doc """
  Asserts with a pattern on a `{:prompton_log, gen}` message received by the calling
  process (`assert_receive`). `gen` is a **string-keyed** map in the §6.4 format (after the
  payload policy is applied). Returns the matched gen.

      gen = assert_logged(%{"use_case" => "support_reply"})
      assert gen["status"] == "ok"
  """
  defmacro assert_logged(pattern, timeout \\ 100) do
    quote do
      ExUnit.Assertions.assert_receive(
        {:prompton_log, unquote(pattern) = gen},
        unquote(timeout)
      )

      gen
    end
  end

  @doc "The `{:prompton_feedback, map}` variant."
  defmacro assert_feedback(pattern, timeout \\ 100) do
    quote do
      ExUnit.Assertions.assert_receive(
        {:prompton_feedback, unquote(pattern) = fb},
        unquote(timeout)
      )

      fb
    end
  end

  @doc "Drains every log map accumulated so far in the calling process's mailbox (in order)."
  @spec logged() :: [map()]
  def logged, do: drain([])

  defp drain(acc) do
    receive do
      {:prompton_log, gen} -> drain([gen | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
