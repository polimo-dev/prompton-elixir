defmodule PromptOnSDK.Snapshot.Store do
  @moduledoc """
  Snapshot store: the `:persistent_term {PromptOnSDK, :snapshot}` entry plus disk cache/sidecar
  I/O (§7.3).

  ## persistent_term entry

      %{data: %PromptOnSDK.SnapshotData{}, etag: String.t | nil, last_modified: String.t | nil,
        source: :remote | :disk | :bundle | :manual, fetched_at: DateTime.t, stale_since: DateTime.t | nil,
        environment: String.t | nil}

  **One fully parsed map** is stored as a whole; it is not split per UseCase, for update
  atomicity. Reads (`get/0`) are copy-free and lock-free. `:persistent_term` triggers a global GC
  on update, but at most once per 30 seconds that is negligible.

  ## Disk cache

  The server response's **raw bytes** are stored at `<path>`, and `etag`/`last_modified`/
  `environment`/`fetched_at` in the `<path>.meta.json` sidecar (the body carries no timestamp
  fields, because the ETag is a hash of the body, §6.2). Writes are atomic via tmp → rename.
  The bundle file produced by `mix prompton.export` has the same format, so `load_file/2` reads
  both.

  ## Environment guard

  `load_file/2` rejects a file snapshot whose `environment` differs from the configured
  `environment` (= `env_slug`) with `{:error, {:environment_mismatch, file_env, key_env}}`
  (§7.3(b): prevents the accident of booting a staging bundle with a production key).
  When `env_slug` is `nil`, the guard is skipped.
  """

  alias PromptOnSDK.SnapshotData

  @key {PromptOnSDK, :snapshot}

  @type source :: :remote | :disk | :bundle | :manual

  @type entry :: %{
          data: SnapshotData.t(),
          etag: String.t() | nil,
          last_modified: String.t() | nil,
          source: source(),
          fetched_at: DateTime.t(),
          stale_since: DateTime.t() | nil,
          environment: String.t() | nil
        }

  @doc "The current snapshot entry. `nil` when there is none."
  @spec get() :: entry() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc "Stores an entry."
  @spec put(entry()) :: :ok
  def put(%{data: %SnapshotData{}} = entry), do: :persistent_term.put(@key, entry)

  @doc "Erases the entry (tests / `PromptOnSDK.Test.clear/0`)."
  @spec erase() :: boolean()
  def erase, do: :persistent_term.erase(@key)

  @doc "Builds a new entry."
  @spec new_entry(SnapshotData.t(), source(), keyword()) :: entry()
  def new_entry(%SnapshotData{} = data, source, opts \\ []) do
    %{
      data: data,
      etag: Keyword.get(opts, :etag),
      last_modified: Keyword.get(opts, :last_modified),
      source: source,
      fetched_at: Keyword.get(opts, :fetched_at, DateTime.utc_now()),
      stale_since: Keyword.get(opts, :stale_since),
      environment: data.environment
    }
  end

  @doc """
  Reads a snapshot file (+ sidecar) and builds an entry. `source` is `:disk` or `:bundle`.
  When `env_slug` is given, the environment guard is applied.
  """
  @spec load_file(String.t(), source(), String.t() | nil) :: {:ok, entry()} | {:error, term()}
  def load_file(path, source, env_slug) do
    with {:ok, body} <- read_file(path),
         {:ok, data, _warnings} <- SnapshotData.decode_json(body),
         :ok <- guard_environment(data, env_slug) do
      meta = read_meta(path)

      {:ok,
       new_entry(data, source,
         etag: meta["etag"],
         last_modified: meta["last_modified"],
         fetched_at: parse_iso8601(meta["fetched_at"]) || DateTime.utc_now()
       )}
    end
  end

  @doc """
  Writes the raw snapshot and the sidecar atomically (tmp → rename). Creates the directory.
  """
  @spec write_file(String.t(), binary(), map()) :: :ok | {:error, term()}
  def write_file(path, body, meta) when is_binary(body) and is_map(meta) do
    with :ok <- mkdir(path),
         :ok <- atomic_write(path, body),
         {:ok, meta_json} <- Jason.encode(meta) do
      atomic_write(meta_path(path), meta_json)
    end
  end

  @doc "Sidecar path."
  @spec meta_path(String.t()) :: String.t()
  def meta_path(path), do: path <> ".meta.json"

  @doc "Reads the sidecar. An empty map when it is missing or corrupt."
  @spec read_meta(String.t()) :: map()
  def read_meta(path) do
    with {:ok, json} <- File.read(meta_path(path)),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Environment guard. Passes when `env_slug` is `nil`."
  @spec guard_environment(SnapshotData.t(), String.t() | nil) ::
          :ok | {:error, {:environment_mismatch, String.t() | nil, String.t()}}
  def guard_environment(_data, nil), do: :ok

  def guard_environment(%SnapshotData{environment: env}, env_slug) do
    if env == env_slug, do: :ok, else: {:error, {:environment_mismatch, env, env_slug}}
  end

  @doc """
  The age of the entry's snapshot in seconds. Based on the `Last-Modified` from the sidecar or
  the response headers, otherwise `fetched_at`.
  """
  @spec age_seconds(entry() | nil, DateTime.t()) :: non_neg_integer() | nil
  def age_seconds(nil, _now), do: nil

  def age_seconds(entry, now) do
    base = parse_http_date(entry.last_modified) || entry.fetched_at
    if base, do: max(DateTime.diff(now, base, :second), 0), else: nil
  end

  @doc "The `snapshot_info/0` shape."
  @spec info(entry() | nil) :: map()
  def info(nil) do
    %{
      etag: nil,
      last_modified: nil,
      source: :none,
      fetched_at: nil,
      stale?: true,
      age_seconds: nil
    }
  end

  def info(entry) do
    %{
      etag: entry.etag,
      last_modified: entry.last_modified,
      source: entry.source,
      fetched_at: entry.fetched_at,
      stale?: entry.source != :remote or not is_nil(entry.stale_since),
      age_seconds: age_seconds(entry, DateTime.utc_now())
    }
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Parses an RFC 7231 HTTP-date (`"Mon, 18 Aug 2026 09:12:03 GMT"`) or ISO8601 into a `DateTime`.
  `nil` on failure.
  """
  @spec parse_http_date(String.t() | nil) :: DateTime.t() | nil
  def parse_http_date(nil), do: nil

  def parse_http_date(str) when is_binary(str) do
    case Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/, str) do
      [_, d, mon, y, h, mi, s] ->
        with month when is_integer(month) <- month_index(mon),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(y),
                 month,
                 String.to_integer(d),
                 String.to_integer(h),
                 String.to_integer(mi),
                 String.to_integer(s)
               ) do
          DateTime.from_naive!(naive, "Etc/UTC")
        else
          _ -> nil
        end

      nil ->
        parse_iso8601(str)
    end
  end

  def parse_http_date(_), do: nil

  @doc false
  def parse_iso8601(nil), do: nil

  def parse_iso8601(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def parse_iso8601(_), do: nil

  # ---------------------------------------------------------------------------

  defp month_index(mon) do
    case Enum.find_index(@months, &(&1 == mon)) do
      nil -> nil
      i -> i + 1
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  defp atomic_write(path, content) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write, reason}}
    end
  end
end
