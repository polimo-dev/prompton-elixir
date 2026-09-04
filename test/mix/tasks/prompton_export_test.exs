defmodule Mix.Tasks.Prompton.ExportTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias Mix.Tasks.Prompton.Export

  setup do
    Application.put_env(:prompton_sdk, :client, PromptOnSDK.FakeClient)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "writes the snapshot body and a sidecar with etag/last_modified/environment/exported_at" do
    out = tmp_path("priv/prompton/snapshot.json")
    body = Jason.encode!(Fixtures.snapshot())

    FakeClient.set(:fetch_snapshot, fn nil, [receive_timeout: 15_000] ->
      {:ok,
       %{
         status: 200,
         body: body,
         etag: ~s("sha256-x"),
         last_modified: "Mon, 18 Aug 2026 09:12:03 GMT"
       }}
    end)

    Export.run([
      "--out",
      out,
      "--base-url",
      "http://prompton.test/api/v1",
      "--api-key",
      "ptn_production_k"
    ])

    assert File.read!(out) == body
    meta = Jason.decode!(File.read!(out <> ".meta.json"))
    assert meta["etag"] == ~s("sha256-x")
    assert meta["last_modified"] == "Mon, 18 Aug 2026 09:12:03 GMT"
    assert meta["environment"] == "production"
    assert {:ok, _, _} = DateTime.from_iso8601(meta["exported_at"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "wrote #{out}"

    # Loadable directly as a bundle
    assert {:ok, entry} = Store.load_file(out, :bundle, "production")
    assert entry.etag == ~s("sha256-x")
  end

  test "uses PTN_* env vars and app config when flags are absent" do
    out = tmp_path("snap.json")
    System.put_env("PTN_BASE_URL", "http://env.test/api/v1")
    System.put_env("PTN_API_KEY", "ptn_staging_k")

    on_exit(fn ->
      System.delete_env("PTN_BASE_URL")
      System.delete_env("PTN_API_KEY")
    end)

    FakeClient.set(:fetch_snapshot, fn _, _ ->
      {:ok, %{status: 200, body: Fixtures.snapshot(), etag: "e", last_modified: nil}}
    end)

    Export.run(["--out", out])
    assert File.exists?(out)
    assert {:ok, _, _} = PromptOnSDK.SnapshotData.decode_json(File.read!(out))
  end

  test "failure leaves the existing file untouched and raises" do
    out = tmp_path("snap.json")
    File.write!(out, "old")
    FakeClient.set(:fetch_snapshot, fn _, _ -> {:ok, %{status: 500, body: "boom"}} end)

    assert_raise Mix.Error, ~r/existing file left untouched/, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
    refute File.exists?(out <> ".meta.json")

    FakeClient.set(:fetch_snapshot, fn _, _ ->
      {:ok, %{status: 200, body: "{bad", etag: nil, last_modified: nil}}
    end)

    assert_raise Mix.Error, fn ->
      Export.run(["--out", out, "--base-url", "http://x/api/v1", "--api-key", "ptn_production_k"])
    end

    assert File.read!(out) == "old"
  end

  test "missing base_url/api_key raises" do
    assert_raise Mix.Error, ~r/base_url and api_key are required/, fn ->
      Export.run(["--out", tmp_path("x.json")])
    end
  end
end
