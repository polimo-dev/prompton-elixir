defmodule PromptOnSDK.Snapshot.Store do
  @moduledoc false

  alias PromptOnSDK.PromptDocument

  @key {PromptOnSDK, :snapshot}

  @type source :: :remote | :disk | :bundle | :manual

  @type entry :: %{
          data: PromptDocument.t(),
          etag: String.t() | nil,
          last_modified: String.t() | nil,
          source: source(),
          fetched_at: DateTime.t(),
          stale_since: DateTime.t() | nil,
          environment: String.t() | nil,
          prompt_meta: %{String.t() => map()},
          prompt_docs: %{String.t() => PromptDocument.t()}
        }

  @doc "The current snapshot entry. `nil` when there is none."
  @spec get() :: entry() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc "Stores an entry."
  @spec put(entry()) :: :ok
  def put(%{data: %PromptDocument{}} = entry), do: :persistent_term.put(@key, entry)

  @doc "Erases the entry (tests / `PromptOnSDK.Test.clear/0`)."
  @spec erase() :: boolean()
  def erase, do: :persistent_term.erase(@key)

  @doc "Builds a new entry."
  @spec new_entry(PromptDocument.t(), source(), keyword()) :: entry()
  def new_entry(%PromptDocument{} = data, source, opts \\ []) do
    %{
      data: data,
      etag: Keyword.get(opts, :etag),
      last_modified: Keyword.get(opts, :last_modified),
      source: source,
      fetched_at: Keyword.get(opts, :fetched_at, DateTime.utc_now()),
      stale_since: Keyword.get(opts, :stale_since),
      environment: data.environment,
      prompt_meta: Keyword.get(opts, :prompt_meta) || prompt_meta(data, source, opts),
      prompt_docs: Keyword.get(opts, :prompt_docs) || prompt_docs(data)
    }
  end

  @doc "The immutable document view to use for resolving one prompt key."
  @spec prompt_document(entry(), String.t() | atom()) :: PromptDocument.t()
  def prompt_document(entry, key) when is_atom(key),
    do: prompt_document(entry, Atom.to_string(key))

  def prompt_document(entry, key) do
    Map.get(entry[:prompt_docs] || %{}, key, entry.data)
  end

  @doc "Metadata for one prompt key, falling back to the entry-wide metadata."
  @spec prompt_meta(entry(), String.t() | atom()) :: map()
  def prompt_meta(entry, key) when is_atom(key), do: prompt_meta(entry, Atom.to_string(key))

  def prompt_meta(entry, key) do
    Map.get(entry[:prompt_meta] || %{}, key, %{
      etag: entry.etag,
      last_modified: entry.last_modified,
      source: entry.source,
      fetched_at: entry.fetched_at,
      stale_since: entry.stale_since
    })
  end

  @doc "Stores per-prompt metadata on an existing entry."
  @spec put_prompt_meta(entry(), String.t(), map()) :: entry()
  def put_prompt_meta(entry, key, meta) when is_binary(key) and is_map(meta) do
    %{entry | prompt_meta: Map.put(entry[:prompt_meta] || %{}, key, meta)}
  end

  @doc "Stores the immutable document view for one prompt key."
  @spec put_prompt_document(entry(), String.t(), PromptDocument.t()) :: entry()
  def put_prompt_document(entry, key, %PromptDocument{} = data) when is_binary(key) do
    %{entry | prompt_docs: Map.put(entry[:prompt_docs] || %{}, key, data)}
  end

  @doc """
  Reads a snapshot file (+ sidecar) and builds an entry. `source` is `:disk` or `:bundle`.
  When `env_slug` is given, the environment guard is applied.
  """
  @spec load_file(String.t(), source(), String.t() | nil) :: {:ok, entry()} | {:error, term()}
  def load_file(path, source, env_slug) do
    with {:ok, body} <- read_file(path),
         {:ok, data, _warnings} <- PromptDocument.decode_json(body),
         :ok <- guard_environment(data, env_slug) do
      meta = read_meta(path)
      fetched_at = parse_iso8601(meta["fetched_at"]) || DateTime.utc_now()

      base_opts = [
        etag: meta["etag"],
        last_modified: meta["last_modified"],
        fetched_at: fetched_at
      ]

      prompt_meta = decode_prompt_meta(meta["prompts"], data, source, base_opts)
      prompt_docs = decode_prompt_docs(meta["prompt_documents"], data, env_slug)

      {:ok,
       new_entry(data, source,
         etag: meta["etag"],
         last_modified: meta["last_modified"],
         fetched_at: fetched_at,
         prompt_meta: prompt_meta,
         prompt_docs: prompt_docs
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

  @doc false
  @spec document_to_map(PromptDocument.t()) :: map()
  def document_to_map(%PromptDocument{} = data) do
    data
    |> Map.from_struct()
    |> stringify_json()
  end

  @doc "Environment guard. Passes when `env_slug` is `nil`."
  @spec guard_environment(PromptDocument.t(), String.t() | nil) ::
          :ok | {:error, {:environment_mismatch, String.t() | nil, String.t()}}
  def guard_environment(_data, nil), do: :ok

  def guard_environment(%PromptDocument{environment: env}, env_slug) do
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

  @doc "The `prompt_document_info/0` shape."
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

  defp prompt_meta(data, source, opts) do
    fetched_at = Keyword.get(opts, :fetched_at, DateTime.utc_now())

    meta = %{
      etag: Keyword.get(opts, :etag),
      last_modified: Keyword.get(opts, :last_modified),
      source: source,
      fetched_at: fetched_at,
      stale_since: Keyword.get(opts, :stale_since)
    }

    Map.new(data.prompts, fn {key, _prompt} -> {key, meta} end)
  end

  defp prompt_docs(data) do
    Map.new(data.prompts, fn {key, _prompt} -> {key, data} end)
  end

  defp decode_prompt_meta(nil, data, source, opts), do: prompt_meta(data, source, opts)

  defp decode_prompt_meta(meta, data, source, opts) when is_map(meta) do
    fallback = prompt_meta(data, source, opts)

    Map.new(fallback, fn {key, default} ->
      {key, decode_one_prompt_meta(Map.get(meta, key), default, source)}
    end)
  end

  defp decode_prompt_meta(_other, data, source, opts), do: prompt_meta(data, source, opts)

  defp decode_one_prompt_meta(nil, default, _source), do: default

  defp decode_one_prompt_meta(meta, default, source) when is_map(meta) do
    %{
      etag: meta["etag"] || default.etag,
      last_modified: meta["last_modified"] || default.last_modified,
      source: source,
      fetched_at: parse_iso8601(meta["fetched_at"]) || default.fetched_at,
      stale_since: parse_iso8601(meta["stale_since"])
    }
  end

  defp decode_one_prompt_meta(_other, default, _source), do: default

  defp decode_prompt_docs(nil, _base, _env_slug), do: nil

  defp decode_prompt_docs(docs, base, env_slug) when is_map(docs) do
    docs
    |> Enum.reduce(%{}, &decode_prompt_doc(&1, &2, base, env_slug))
    |> case do
      docs when map_size(docs) == 0 -> nil
      docs -> docs
    end
  end

  defp decode_prompt_docs(_other, _base, _env_slug), do: nil

  defp decode_prompt_doc({key, raw}, acc, base, env_slug) do
    case PromptDocument.decode(raw) do
      {:ok, data, _warnings} -> put_scoped_prompt_doc(acc, key, data, base, env_slug)
      {:error, _reason} -> acc
    end
  end

  defp put_scoped_prompt_doc(acc, key, data, base, env_slug) do
    if valid_prompt_document_scope?(key, data, base, env_slug) do
      Map.put(acc, key, data)
    else
      acc
    end
  end

  defp valid_prompt_document_scope?(key, data, base, env_slug) do
    expected_environment = env_slug || base.environment

    data.environment == expected_environment and
      data.project == base.project and
      Map.has_key?(data.prompts, key) and
      Map.has_key?(data.deployments, key)
  end

  defp stringify_json(%{} = map) do
    Map.new(map, fn {key, value} -> {stringify_json_key(key), stringify_json(value)} end)
  end

  defp stringify_json(list) when is_list(list), do: Enum.map(list, &stringify_json/1)
  defp stringify_json(nil), do: nil
  defp stringify_json(value) when is_boolean(value), do: value
  defp stringify_json(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_json(value), do: value

  defp stringify_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_json_key(key), do: to_string(key)

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
