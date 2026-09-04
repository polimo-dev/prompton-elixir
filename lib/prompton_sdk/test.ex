defmodule PromptOnSDK.Test do
  @moduledoc """
  Test mode helpers (§7.6). With `config :prompton_sdk, mode: :test`:

  * There is no HTTP at all: `PromptOnSDK.Snapshot` loads nothing, and `PromptOnSDK.log/1` /
    `feedback/1` send `{:prompton_generation, gen}` / `{:prompton_feedback, map}` to the
    **calling process** instead of the Buffer. As with HeyDiary's `AIStubs`,
    `Oban.Testing.perform_job/3` runs in the calling process, so you can `assert_receive`
    directly. The supervisor (`{PromptOnSDK, []}`) need not be started: the snapshot lives in
    `:persistent_term`, so no process is required.
  * Snapshots are injected with `put_snapshot/1` (map, JSON file, or `%SnapshotData{}`) or
    `stub/2` (a minimal entry for one UseCase).

  ## Usage

      # test_helper.exs
      Application.put_env(:prompton_sdk, :mode, :test)

      # in a test
      setup do
        PromptOnSDK.Test.stub("diary_generation", %{model: "openai/gpt-5-mini",
          messages: [%{role: "system", content: "You are a diary writer."}, %{role: "user", content: "{{ text }}"}],
          params: %{temperature: 0.5}})
        on_exit(&PromptOnSDK.Test.clear/0)
      end

  Named prompts (language branches) are stubbed with `prompt:`:
  `stub("chat", %{model: ..., prompt: "ko", ...})` corresponds to `resolve("chat", prompt: "ko")`.
  Calling it several times for the same key with different names accumulates pins.

      test "worker logs a generation" do
        assert :ok = perform_job(MyWorker, %{...})
        # partial match (map pattern)
        assert_logged(%{"use_case" => "diary_generation", "status" => "ok"})
      end

  `stub/2` **accumulates** onto the existing test snapshot (multiple UseCases). `put_snapshot/1`
  replaces it as a whole. `stub/2` options: `model:` (required, the provider model string),
  `provider:` (default `:openrouter`), `messages:` (chat) or `text_template:` (text), `kind:`
  (default `:chat`; `:embedding` has no prompt), `prompt:` (the prompt name, default
  `"default"`), `params:`, `provider_options:`, `payload_policy:`, `environment:`.
  """

  alias PromptOnSDK.Snapshot.Store
  alias PromptOnSDK.SnapshotData

  @doc """
  Injects a snapshot: a `map` (§6.2 format, string/atom keys) | `{:file, path}` (JSON) |
  `%SnapshotData{}`. `source: :manual`, `etag: "test"`. Raises on a decode failure.
  """
  @spec put_snapshot(map() | {:file, String.t()} | SnapshotData.t(), keyword()) :: :ok
  def put_snapshot(snapshot, opts \\ [])

  def put_snapshot({:file, path}, opts) do
    case SnapshotData.decode_json(File.read!(path)) do
      {:ok, data, _warnings} -> put_snapshot(data, opts)
      {:error, reason} -> raise ArgumentError, "invalid snapshot file #{path}: #{inspect(reason)}"
    end
  end

  def put_snapshot(%SnapshotData{} = data, opts) do
    Store.put(
      Store.new_entry(data, Keyword.get(opts, :source, :manual),
        etag: Keyword.get(opts, :etag, "test"),
        last_modified: Keyword.get(opts, :last_modified)
      )
    )
  end

  def put_snapshot(map, opts) when is_map(map) do
    case SnapshotData.decode(map) do
      {:ok, data, _warnings} -> put_snapshot(data, opts)
      {:error, reason} -> raise ArgumentError, "invalid snapshot: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a minimal snapshot entry for one UseCase and merges it into the current test snapshot
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
        %{source: :manual, data: %SnapshotData{} = data} -> data
        _ -> %SnapshotData{environment: Map.get(spec, :environment)}
      end

    pins =
      case Map.get(base.deployments, key) do
        %{prompt_pins: pins} when is_map(pins) -> pins
        _ -> %{}
      end

    pins = if prompt_version, do: Map.put(pins, prompt, ids.pv), else: %{}

    {:ok, uc_data, _} =
      SnapshotData.decode(%{
        "schema_version" => SnapshotData.schema_version(),
        "use_cases" => %{key => stub_use_case(key, kind, spec)},
        "deployments" => %{key => stub_deployment(key, ids, pins, spec)},
        "prompt_versions" => if(prompt_version, do: %{ids.pv => prompt_version}, else: %{}),
        "models" => %{ids.model => stub_model(ids.model, model, spec)}
      })

    merged = %SnapshotData{
      base
      | use_cases: Map.merge(base.use_cases, uc_data.use_cases),
        deployments: Map.merge(base.deployments, uc_data.deployments),
        prompt_versions: Map.merge(base.prompt_versions, uc_data.prompt_versions),
        models: Map.merge(base.models, uc_data.models)
    }

    merged = %SnapshotData{
      merged
      | use_cases:
          Map.new(merged.use_cases, fn {k, uc} ->
            {k, %{uc | deployment: Map.get(merged.deployments, k)}}
          end)
    }

    put_snapshot(merged, [])
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

  @doc "Clears the test snapshot (`resolve/3` → `{:error, :not_ready}`)."
  @spec clear() :: :ok
  def clear do
    Store.erase()
    :ok
  end

  @doc """
  Asserts with a pattern on a `{:prompton_generation, gen}` message received by the calling
  process (`assert_receive`). `gen` is a **string-keyed** map in the §6.4 format (after the
  payload policy is applied). Returns the matched gen.

      gen = assert_logged(%{"use_case" => "diary_generation"})
      assert gen["status"] == "ok"
  """
  defmacro assert_logged(pattern, timeout \\ 100) do
    quote do
      ExUnit.Assertions.assert_receive(
        {:prompton_generation, unquote(pattern) = gen},
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

  @doc "Drains every generation map accumulated so far in the calling process's mailbox (in order)."
  @spec logged() :: [map()]
  def logged, do: drain([])

  defp drain(acc) do
    receive do
      {:prompton_generation, gen} -> drain([gen | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
