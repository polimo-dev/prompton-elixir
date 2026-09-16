defmodule PromptOnSDK.LiveFixtureIntegrationTest do
  @moduledoc """
  Real PromptOn fixture-server integration.

  Skips unless `PTN_API_KEY` is set. With a key, it talks to
  `PTN_HOST` (default `http://localhost:4000`) under `/api/v1`.
  """

  use ExUnit.Case, async: false

  alias PromptOnSDK.{Client, Config, Prompt, Result}
  alias PromptOnSDK.Snapshot.Store

  @moduletag :live_fixture

  unless System.get_env("PTN_API_KEY") do
    @moduletag skip:
                 "set PTN_API_KEY to run live fixture integration against PTN_HOST (default http://localhost:4000)"
  end

  setup do
    for {key, _} <- Application.get_all_env(:prompton_sdk) do
      Application.delete_env(:prompton_sdk, key)
    end

    Config.erase()
    Store.erase()

    on_exit(fn ->
      Config.erase()
      Store.erase()

      for {key, _} <- Application.get_all_env(:prompton_sdk) do
        Application.delete_env(:prompton_sdk, key)
      end
    end)

    opts = live_opts()
    start_supervised!({PromptOnSDK, opts})
    assert :ok = PromptOnSDK.refresh_prompt_document()

    %{config: Config.load(opts)}
  end

  test "GET /prompts drives default prompt/messages/text and remote template errors", %{
    config: config
  } do
    assert {:ok, %Prompt{} = prompt} = PromptOnSDK.prompt("greeting")

    assert prompt.source == :remote
    assert prompt.template == "default"
    assert prompt.template_names == ["default"]

    assert {:ok,
            [
              %{role: "system", content: system},
              %{role: "user", content: user}
            ]} =
             PromptOnSDK.messages(prompt, %{name: "Ada", language: "ko"})

    assert system =~ "friendly greeter"
    assert user == "Say hello to Ada."

    assert {:ok, text_prompt} = PromptOnSDK.prompt("summarize")
    assert {:ok, text} = PromptOnSDK.text(text_prompt, %{items: ["alpha", "beta"]})
    assert text =~ "- alpha"
    assert text =~ "- beta"

    assert PromptOnSDK.prompt("does_not_exist") == {:error, :unknown_prompt}

    assert PromptOnSDK.prompt("greeting", template: "does_not_exist") ==
             {:error, :unknown_template}

    assert {:ok, %{status: 200, body: remote}} =
             post_prompt(config, "greeting", %{
               "variables" => %{"name" => "Ada", "language" => "ko"}
             })

    assert remote["key"] == "greeting"
    assert remote["source"] == "remote"
    assert get_in(remote, ["messages", Access.at(0), "content"]) =~ "friendly greeter"
    assert get_in(remote, ["messages", Access.at(1), "content"]) == "Say hello to Ada."
    assert remote["template"] == "default"
    assert is_binary(remote["prompt_version"]["id"])

    assert {:ok, %{status: status, body: body}} =
             post_prompt(config, "does_not_exist", %{"variables" => %{}})

    assert status in [404, 422]
    assert get_in(body, ["error", "code"]) == "not_found"
    assert get_in(body, ["error", "details", "key"]) == "does_not_exist"

    assert {:ok, %{status: status, body: body}} =
             post_prompt(config, "greeting", %{
               "template" => "does_not_exist",
               "variables" => %{"name" => "아다"}
             })

    assert status in [404, 422]
    assert get_in(body, ["error", "details", "reason"]) == "unknown_template"
    assert get_in(body, ["error", "details", "key"]) == "greeting"
    assert get_in(body, ["error", "details", "template_names"]) == ["default"]
  end

  test "POST /logs accepts the first live fixture log and reports duplicate resend", %{
    config: config
  } do
    assert {:ok, %Prompt{} = prompt} = PromptOnSDK.prompt("greeting")

    log = %{
      "id" => PromptOnSDK.log_id(),
      "prompt_key" => prompt.key,
      "kind" => "chat",
      "model" => prompt.model,
      "provider" => to_string(prompt.provider || :other),
      "status" => "ok",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "deployment_id" => prompt.deployment.id,
      "deployment_revision" => prompt.deployment.revision,
      "template" => prompt.template,
      "prompt_version_id" => prompt.prompt_version && prompt.prompt_version.id,
      "model_id" => prompt.model_id,
      "source" => "remote",
      "output" => %{"content" => "live fixture integration"},
      "finish_reason" => "stop",
      "stop_kind" => "stop",
      "latency_ms" => 1,
      "usage" => %{"cost_source" => "unknown"},
      "sdk" => %{"name" => "prompton_sdk", "version" => PromptOnSDK.version()}
    }

    assert {:ok, %{status: 202, body: first}} = Client.Req.post_logs(config, [log])
    assert first["accepted"] == 1
    assert first["duplicates"] == 0
    assert first["rejected"] == []

    assert {:ok, %{status: 202, body: second}} = Client.Req.post_logs(config, [log])
    assert second["accepted"] == 0
    assert second["duplicates"] == 1
    assert second["rejected"] == []
  end

  test "messages/2 feeds the next track/3 log evidence once" do
    assert {:ok, default_template} = PromptOnSDK.prompt("greeting")

    assert {:ok, msgs} = PromptOnSDK.messages(default_template, %{name: "Ada", language: "ko"})

    result = %Result{
      content: "ok",
      usage: %{input_tokens: 1, output_tokens: 1},
      cost_source: :unknown
    }

    assert {:ok, ^result} =
             PromptOnSDK.track(
               default_template,
               %{id: PromptOnSDK.log_id(), input_messages: msgs},
               fn ->
                 {:ok, result}
               end
             )

    assert {:ok, 0} = PromptOnSDK.Buffer.flush(10_000)
  end

  defp live_opts do
    [
      mode: :live,
      api_key: System.fetch_env!("PTN_API_KEY"),
      base_url: base_url(),
      environment: System.get_env("PTN_ENVIRONMENT", "production"),
      disk_cache: nil,
      bundle: nil,
      poll_interval: 60_000,
      log: [flush_interval: 50, flush_size: 1, flush_bytes: 1_000_000, max_buffer: 100],
      http: [receive_timeout: 10_000]
    ]
  end

  defp base_url do
    host =
      System.get_env("PTN_HOST", "http://localhost:4000")
      |> String.trim_trailing("/")

    if String.ends_with?(host, "/api/v1") do
      host
    else
      host <> "/api/v1"
    end
  end

  defp post_prompt(config, key, body) do
    config
    |> Client.Req.base()
    |> Req.post(
      url: "/prompts/#{key}/render",
      params: [environment: config.environment],
      json: body
    )
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
