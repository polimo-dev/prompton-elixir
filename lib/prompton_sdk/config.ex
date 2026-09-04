defmodule PromptOnSDK.Config do
  @moduledoc """
  Reads, validates, and normalizes the SDK runtime configuration (§7.2).

  Settings come from `Application.get_env(:prompton_sdk, key)`, and the `opts` of the
  `{PromptOnSDK, opts}` child spec override the same keys. `PromptOnSDK.Supervisor` stores the
  result of `load/1` in `:persistent_term {PromptOnSDK, :config}` at boot, and the other modules
  read it with `get/0` (tests that do not start the supervisor compute it on the fly from the app
  env).

  | Key | Default | Description |
  |---|---|---|
  | `api_key` | `nil` | `ptn_<project_slug>_…` format (project key). `nil` means disk/bundle only, no remote calls |
  | `environment` | `"production"` | Environment slug this app reads. The `GET /snapshot?environment=…` query and the disk/bundle guard reference |
  | `base_url` | `nil` | `https://prompton.example/api/v1` (trailing `/` removed) |
  | `poll_interval` | `30_000` | ETag polling interval (ms). Also the minimum for failure backoff |
  | `disk_cache` | `nil` | Snapshot disk cache path. `nil` disables it |
  | `bundle` | `nil` | `{:file, path}`: the last-resort fallback bundle |
  | `log` | below | `flush_interval: 2_000, flush_size: 100, flush_bytes: 1_000_000, max_buffer: 10_000, redact: nil` |
  | `http` | `[]` | Req options (`receive_timeout: 5_000` by default; tests may inject `plug:`) |
  | `mode` | `:live` | `:live` / `:test` / `:offline` |
  | `hash_end_user` | `false` | When `true`, `end_user_ref` is sent as a sha256 hex |
  | `client` | `PromptOnSDK.Client.Req` | `PromptOnSDK.Client` implementation module (test injection) |
  | `payload_defaults` | `%{mode: :full, sample_rate: 1.0, max_bytes: 262_144}` | Default payload policy used when the snapshot has none |

  The environment is decided by **configuration, not the key** (2026-09-01): an ApiKey is per
  project and the environment is a request parameter. `env_slug` is the `environment` value as is
  and is the reference for the disk/bundle environment guard (§7.3(b)).
  """

  @type mode :: :live | :test | :offline

  @type t :: %{
          api_key: String.t() | nil,
          environment: String.t(),
          base_url: String.t() | nil,
          poll_interval: pos_integer(),
          disk_cache: String.t() | nil,
          bundle: {:file, String.t()} | nil,
          log: %{
            flush_interval: pos_integer(),
            flush_size: pos_integer(),
            flush_bytes: pos_integer(),
            max_buffer: pos_integer(),
            redact: (map() -> map()) | nil
          },
          http: keyword(),
          mode: mode(),
          hash_end_user: boolean(),
          client: module(),
          payload_defaults: map(),
          env_slug: String.t()
        }

  @key {PromptOnSDK, :config}

  @log_defaults %{
    flush_interval: 2_000,
    flush_size: 100,
    flush_bytes: 1_000_000,
    max_buffer: 10_000,
    redact: nil
  }

  @payload_defaults %{mode: :full, sample_rate: 1.0, max_bytes: 262_144}

  @default_environment "production"

  @doc """
  Merges the app env with `opts` into a normalized configuration map. Raises `ArgumentError` on
  an invalid value.
  """
  @spec load(keyword() | map()) :: t()
  def load(opts \\ []) do
    opts = Map.new(opts)
    env = Map.new(Application.get_all_env(:prompton_sdk))
    merged = Map.merge(env, opts)

    api_key = fetch_string(merged, :api_key)
    mode = fetch_mode(merged)
    environment = fetch_string(merged, :environment) || @default_environment

    %{
      api_key: api_key,
      environment: environment,
      base_url: merged |> fetch_string(:base_url) |> trim_slash(),
      poll_interval: fetch_pos_int(merged, :poll_interval, 30_000),
      disk_cache: fetch_string(merged, :disk_cache),
      bundle: fetch_bundle(merged),
      log: fetch_log(merged),
      http: fetch_http(merged),
      mode: mode,
      hash_end_user: Map.get(merged, :hash_end_user, false) == true,
      client: Map.get(merged, :client) || PromptOnSDK.Client.Req,
      payload_defaults: fetch_payload_defaults(merged),
      env_slug: environment
    }
  end

  @doc "Active configuration: the supervisor-stored value if any, else computed from the app env."
  @spec get() :: t()
  def get do
    case :persistent_term.get(@key, nil) do
      nil -> load([])
      config -> config
    end
  end

  @doc false
  @spec put(t()) :: :ok
  def put(config), do: :persistent_term.put(@key, config)

  @doc false
  @spec erase() :: boolean()
  def erase, do: :persistent_term.erase(@key)

  @doc "Current mode."
  @spec mode() :: mode()
  def mode, do: get().mode

  @doc "Environment slug this app reads (the `environment` setting, default `\"production\"`)."
  @spec environment() :: String.t()
  def environment, do: get().environment

  @doc "Environment slug used when none is configured."
  @spec default_environment() :: String.t()
  def default_environment, do: @default_environment

  # ---------------------------------------------------------------------------

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      nil -> nil
      "" -> nil
      v when is_binary(v) -> v
      other -> raise ArgumentError, "prompton_sdk #{key} must be a string, got: #{inspect(other)}"
    end
  end

  defp trim_slash(nil), do: nil
  defp trim_slash(url), do: String.trim_trailing(url, "/")

  defp fetch_mode(map) do
    case Map.get(map, :mode, :live) do
      m when m in [:live, :test, :offline] ->
        m

      other ->
        raise ArgumentError,
              "prompton_sdk mode must be :live | :test | :offline, got: #{inspect(other)}"
    end
  end

  defp fetch_pos_int(map, key, default) do
    case Map.get(map, key, default) do
      nil ->
        default

      v when is_integer(v) and v > 0 ->
        v

      other ->
        raise ArgumentError,
              "prompton_sdk #{key} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp fetch_bundle(map) do
    case Map.get(map, :bundle) do
      nil ->
        nil

      {:file, path} when is_binary(path) ->
        {:file, path}

      path when is_binary(path) ->
        {:file, path}

      other ->
        raise ArgumentError, "prompton_sdk bundle must be {:file, path}, got: #{inspect(other)}"
    end
  end

  defp fetch_log(map) do
    given = map |> Map.get(:log, []) |> Map.new()

    log = Map.merge(@log_defaults, Map.take(given, Map.keys(@log_defaults)))

    for key <- [:flush_interval, :flush_size, :flush_bytes, :max_buffer] do
      case Map.fetch!(log, key) do
        v when is_integer(v) and v > 0 ->
          :ok

        other ->
          raise ArgumentError,
                "prompton_sdk log.#{key} must be a positive integer, got: #{inspect(other)}"
      end
    end

    case log.redact do
      nil ->
        :ok

      f when is_function(f, 1) ->
        :ok

      other ->
        raise ArgumentError,
              "prompton_sdk log.redact must be a 1-arity function, got: #{inspect(other)}"
    end

    log
  end

  defp fetch_http(map) do
    http = Map.get(map, :http, [])

    unless Keyword.keyword?(http) do
      raise ArgumentError, "prompton_sdk http must be a keyword list, got: #{inspect(http)}"
    end

    Keyword.put_new(http, :receive_timeout, 5_000)
  end

  defp fetch_payload_defaults(map) do
    given = map |> Map.get(:payload_defaults, %{}) |> Map.new()
    Map.merge(@payload_defaults, Map.take(given, [:mode, :sample_rate, :max_bytes]))
  end
end
