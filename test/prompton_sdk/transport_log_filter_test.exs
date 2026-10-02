defmodule PromptOnSDK.TransportLogFilterTest do
  use PromptOnSDK.RuntimeCase, async: false

  import PromptOnSDK.Test, only: [assert_logged: 1]

  @closed "%Req.TransportError{reason: :closed}"
  @message "failed to send request: #{@closed}"

  setup do
    Application.put_env(:prompton_sdk, :mode, :test)
    PromptOnSDK.Test.put_prompt_document(Fixtures.snapshot())
    on_exit(&PromptOnSDK.Test.clear/0)
    {:ok, prompt: elem(PromptOnSDK.prompt("diary_generation"), 1)}
  end

  test "track suppresses closed transport logs while preserving the result and telemetry", %{
    prompt: prompt
  } do
    attach_telemetry([[:prompton, :log, :start], [:prompton, :log, :stop]])
    result = {:error, %{kind: :transport, message: @message}}

    assert PromptOnSDK.track(prompt, %{id: "closed"}, fn -> result end) == result
    refute_receive {:prompton_log, _}, 10
    assert_receive {:telemetry, [:prompton, :log, :start], _, %{id: "closed"}}

    assert_receive {:telemetry, [:prompton, :log, :stop], _,
                    %{id: "closed", status: :error, error_kind: "transport"}}

    assert {:ok, %{content: "retried"}} =
             PromptOnSDK.track(prompt, %{id: "retry"}, fn -> {:ok, %{content: "retried"}} end)

    assert_logged(%{"id" => "retry", "status" => "ok", "output" => %{"content" => "retried"}})
  end

  test "manual logs suppress both atom and string keys and the inspected Req error" do
    assert :ok =
             PromptOnSDK.log(%{
               status: :error,
               error: %{kind: :transport, message: @message}
             })

    assert :ok =
             PromptOnSDK.log(%{
               "status" => "error",
               "error" => %{"kind" => "transport", "message" => @closed}
             })

    refute_receive {:prompton_log, _}, 10
  end

  test "other transport failures and unrelated messages remain visible", %{prompt: prompt} do
    for message <- [
          "failed to send request: %Req.TransportError{reason: :timeout}",
          "failed to send request: %Req.TransportError{reason: :econnrefused}",
          "socket closed",
          "failed to send request: #{@closed} followed by an application failure"
        ] do
      result = {:error, %{kind: :transport, message: message}}
      assert PromptOnSDK.track(prompt, %{}, fn -> result end) == result
      assert_logged(%{"status" => "error", "error" => %{"message" => ^message}})
    end
  end

  test "the same text does not suppress successful logs or other error kinds" do
    for {status, kind} <- [
          {:ok, :transport},
          {:error, :parse},
          {:error, :http_5xx},
          {:error, :app}
        ] do
      assert :ok = PromptOnSDK.log(%{status: status, error: %{kind: kind, message: @message}})
      assert_logged(%{"error" => %{"message" => @message}})
    end
  end

  test "filtering happens before redaction" do
    Application.put_env(:prompton_sdk, :log,
      redact: fn gen ->
        Map.put(gen, "error", %{"kind" => "transport", "message" => "redacted"})
      end
    )

    assert :ok = PromptOnSDK.log(%{status: :error, error: %{kind: :transport, message: @message}})
    refute_receive {:prompton_log, _}, 10
  end

  test "closed error completion events are suppressed in test, live async, and live sync modes" do
    for message <- [@closed, @message, "failed to call LLM: #{@message}"] do
      event = completion("closed", :error, message)
      assert :ok = PromptOnSDK.log_events(event)
      refute_receive {:prompton_events, _}, 10
    end

    Application.put_env(:prompton_sdk, :mode, :live)
    Application.put_env(:prompton_sdk, :client, FakeClient)
    event = completion("closed", :error, "failed to call LLM: #{@message}")

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert :ok = PromptOnSDK.log_events(event)

             assert {:ok, %{body: %{"events" => %{"accepted" => 0, "rejected" => []}}}} =
                      PromptOnSDK.log_events(event, sync: true)
           end) == ""

    assert FakeClient.calls(:post_events) == []
  end

  test "mixed completion events preserve unrelated events, order, IDs, and sync acknowledgement" do
    closed = completion("closed", :error, "failed to call LLM: #{@message}")
    success = completion("ok", :ok, @message)

    timeout =
      completion(
        "timeout",
        :error,
        "failed to send request: %Req.TransportError{reason: :timeout}"
      )

    tool = %{closed | event_id: "tool", event_kind: :tool_attempt}
    suffix = completion("suffix", :error, @message <> " followed by an application failure")
    events = [success, closed, timeout, tool, suffix]

    assert :ok = PromptOnSDK.log_events(events)
    assert_receive {:prompton_events, kept}
    assert Enum.map(kept, & &1["event_id"]) == ["ok", "timeout", "tool", "suffix"]

    Application.put_env(:prompton_sdk, :mode, :live)
    Application.put_env(:prompton_sdk, :client, FakeClient)
    response = %{status: 202, body: %{"events" => %{"accepted" => 4}}, headers: %{}}
    FakeClient.set(:post_events, fn _ -> {:ok, response} end)

    assert {:ok, ^response} = PromptOnSDK.log_events(events, sync: true)
    assert [{:post_events, sent}] = FakeClient.calls(:post_events)
    assert Enum.map(sent, & &1["event_id"]) == ["ok", "timeout", "tool", "suffix"]
  end

  test "closed completion events still require valid event fields" do
    event = completion("closed", :error, @message) |> Map.delete(:trace_id)
    assert {:error, {:invalid_event, 1, :trace_id_required}} = PromptOnSDK.log_events(event)
    assert {:error, :empty_events} = PromptOnSDK.log_events([])
  end

  test "live buffer sends the successful retry without sending the closed failure", %{
    prompt: prompt
  } do
    Application.delete_env(:prompton_sdk, :mode)
    FakeClient.notify(self())
    FakeClient.set(:post_logs, fn items -> ok_202(length(items)) end)
    start_sdk(log: [flush_size: 100, flush_interval: 60_000])

    error = {:error, %{kind: :transport, message: @message}}
    assert PromptOnSDK.track(prompt, %{id: "closed"}, fn -> error end) == error

    assert :ok =
             PromptOnSDK.log(%{
               id: "manual-closed",
               status: :error,
               error: %{kind: :transport, message: @closed}
             })

    PromptOnSDK.track(prompt, %{id: "success"}, fn -> {:ok, %{content: "ok"}} end)
    assert {:ok, 0} = PromptOnSDK.Buffer.flush()
    assert_receive {:fake_client, :post_logs, [[%{"id" => "success", "status" => "ok"}]]}
    assert length(FakeClient.calls(:post_logs)) == 1
  end

  defp completion(id, status, output) do
    %{
      event_id: id,
      trace_id: "trace",
      event_kind: :completion,
      status: status,
      completion_output: output
    }
  end
end
