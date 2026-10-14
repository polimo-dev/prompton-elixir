defmodule Mix.Tasks.Prompton.ExportTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias Mix.Tasks.Prompton.Export
  alias PromptOnSDK.Snapshot.Store

  setup do
    Application.put_env(:prompton_sdk, :client, PromptOnSDK.FakeClient)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "assembles prompt list details into a schema v1 bundle with local hash sidecar" do
    out = tmp_path("priv/prompton/prompts.production.json")
    list = prompt_list([{"support_reply", "chat"}, {"route", "decision"}])

    FakeClient.set(:fetch_prompts, fn nil, [receive_timeout: 15_000] ->
      {:ok,
       %{status: 200, body: Jason.encode!(list), etag: ~s("index"), last_modified: "ignored"}}
    end)

    FakeClient.set(:fetch_prompt, fn key, nil, [receive_timeout: 15_000] ->
      {:ok, %{status: 200, body: detail(key)}}
    end)

    Export.run([
      "--out",
      out,
      "--base-url",
      "http://prompton.test/api/v1",
      "--api-key",
      "ptn_production_k"
    ])

    body = File.read!(out)
    bundle = Jason.decode!(body)
    assert bundle["schema_version"] == 1
    assert Map.keys(bundle["prompts"]) == ["route", "support_reply"]
    assert bundle["prompt_versions"]["support_reply@2"]["prompt"] == "support_reply"
    assert bundle["models"]["openrouter:openai/gpt-4o-mini"]

    meta = Jason.decode!(File.read!(out <> ".meta.json"))
    expected_etag = "sha256-" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    assert meta["etag"] == expected_etag
    assert meta["etag"] != ~s("index")
    assert meta["last_modified"] == nil
    assert meta["environment"] == "production"
    assert meta["source"] == "assembled-local"
    assert {:ok, _, _} = DateTime.from_iso8601(meta["exported_at"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "wrote #{out}"

    assert {:ok, entry} = Store.load_file(out, :bundle, "production")
    assert entry.etag == expected_etag
  end

  test "empty prompt list exports a valid empty schema v1 bundle" do
    out = tmp_path("empty.json")

    FakeClient.set(:fetch_prompts, fn nil, _opts ->
      {:ok, %{status: 200, body: prompt_list([]), etag: "unused", last_modified: nil}}
    end)

    Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])

    assert Jason.decode!(File.read!(out)) == %{
             "schema_version" => 1,
             "project" => "helpdesk",
             "environment" => "production",
             "prompts" => %{},
             "deployments" => %{},
             "prompt_versions" => %{},
             "models" => %{}
           }
  end

  test "uses PTN_* env vars and app config when flags are absent" do
    out = tmp_path("snap.json")
    System.put_env("PTN_BASE_URL", "http://env.test/api/v1")
    System.put_env("PTN_API_KEY", "ptn_staging_k")

    on_exit(fn ->
      System.delete_env("PTN_BASE_URL")
      System.delete_env("PTN_API_KEY")
    end)

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: prompt_list([{"support_reply", "chat"}])}}
    end)

    FakeClient.set(:fetch_prompt, fn key, _, _ -> {:ok, %{status: 200, body: detail(key)}} end)

    Export.run(["--out", out])
    assert File.exists?(out)
    assert {:ok, _, _} = PromptOnSDK.PromptDocument.decode_json(File.read!(out))
  end

  test "failure leaves the existing file untouched and raises" do
    out = tmp_path("snap.json")
    File.write!(out, "old")
    FakeClient.set(:fetch_prompts, fn _, _ -> {:ok, %{status: 500, body: "boom"}} end)

    assert_raise Mix.Error, ~r/existing file left untouched/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
    refute File.exists?(out <> ".meta.json")

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: "{bad", etag: nil, last_modified: nil}}
    end)

    assert_raise Mix.Error, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
  end

  test "invalid list and detail mismatches fail before writing" do
    out = tmp_path("bad.json")
    File.write!(out, "old")

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok,
       %{status: 200, body: prompt_list([{"support_reply", "chat"}, {"support_reply", "chat"}])}}
    end)

    assert_raise Mix.Error, ~r/duplicate_key/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: prompt_list([{"support_reply", "chat"}])}}
    end)

    FakeClient.set(:fetch_prompt, fn key, _, _ ->
      {:ok, %{status: 200, body: put_in(detail(key), ["environment"], "staging")}}
    end)

    assert_raise Mix.Error, ~r/environment_mismatch/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
  end

  test "model metadata collisions across details fail export" do
    out = tmp_path("collision.json")
    list = prompt_list([{"support_reply", "chat"}, {"other_reply", "chat"}])

    FakeClient.set(:fetch_prompts, fn _, _ -> {:ok, %{status: 200, body: list}} end)

    FakeClient.set(:fetch_prompt, fn
      "support_reply", _, _ ->
        {:ok, %{status: 200, body: detail("support_reply")}}

      "other_reply", _, _ ->
        body =
          "other_reply"
          |> detail()
          |> put_in(["model", "display_name"], "Conflicting display name")

        {:ok, %{status: 200, body: body}}
    end)

    assert_raise Mix.Error, ~r/resource_collision/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end
  end

  test "list scope and malformed detail responses fail without writing" do
    out = tmp_path("scope.json")
    File.write!(out, "old")

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: Map.delete(prompt_list([]), "project")}}
    end)

    assert_raise Mix.Error, ~r/missing_scope/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: put_in(prompt_list([]), ["environment"], "staging")}}
    end)

    assert_raise Mix.Error, ~r/environment_mismatch/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    FakeClient.set(:fetch_prompts, fn _, _ ->
      {:ok, %{status: 200, body: prompt_list([{"support_reply", "chat"}])}}
    end)

    FakeClient.set(:fetch_prompt, fn _key, _, _ -> {:ok, %{status: 200, body: []}} end)

    assert_raise Mix.Error, ~r/invalid_body/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    FakeClient.set(:fetch_prompt, fn _key, _, _ ->
      {:ok, %{status: 200, body: Map.drop(detail("support_reply"), ["prompt"])}}
    end)

    assert_raise Mix.Error, ~r/prompt is required/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
  end

  test "missing base_url/api_key raises" do
    assert_raise Mix.Error, ~r/base_url and api_key are required/, fn ->
      Export.run(["--out", tmp_path("x.json")])
    end
  end

  defp prompt_list(items) do
    %{
      "schema_version" => 1,
      "project" => "helpdesk",
      "environment" => "production",
      "prompts" => Enum.map(items, fn {key, kind} -> %{"key" => key, "kind" => kind} end)
    }
  end

  defp detail("route") do
    base_detail("route", "decision", 1, %{
      "kind" => "decision",
      "engine" => "liquid",
      "decision" => %{"state" => %{"message" => "{{ input }}"}, "questions" => %{}}
    })
  end

  defp detail(key) do
    base_detail(key, "chat", 2, %{
      "kind" => "chat",
      "engine" => "liquid",
      "messages" => [%{"role" => "user", "content" => "{{ question }}"}]
    })
  end

  defp base_detail(key, kind, number, prompt_version) do
    %{
      "schema_version" => 1,
      "project" => "helpdesk",
      "environment" => "production",
      "prompt" => %{"key" => key, "kind" => kind, "variables" => []},
      "deployment" => %{
        "revision" => "v2026.09.30-1",
        "provider" => "openrouter",
        "model" => "openai/gpt-4o-mini",
        "prompt_version" => number
      },
      "prompt_version" => Map.merge(%{"prompt" => key, "number" => number}, prompt_version),
      "model" => %{
        "provider" => "openrouter",
        "model" => "openai/gpt-4o-mini",
        "display_name" => "GPT-4o mini"
      }
    }
  end
end
