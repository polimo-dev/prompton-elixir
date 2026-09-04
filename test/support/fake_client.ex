defmodule PromptOnSDK.FakeClient do
  @moduledoc """
  A `PromptOnSDK.Client` implementation for tests: handlers are planted in an Agent, no Mox needed.

      start_supervised!(PromptOnSDK.FakeClient)
      PromptOnSDK.FakeClient.set(:fetch_snapshot, fn etag, _opts -> {:ok, %{status: 304}} end)
      PromptOnSDK.FakeClient.set(:post_generations, fn items ->
        {:ok, %{status: 202, body: %{}, headers: %{}}}
      end)
      PromptOnSDK.FakeClient.notify(self())   # receive {:fake_client, name, args} on every call

  Without a handler the result is `{:error, :no_handler}`. `calls/0` is the call history (oldest
  first).
  """

  @behaviour PromptOnSDK.Client

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{handlers: %{}, calls: [], notify: nil} end, name: __MODULE__)
  end

  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}

  def set(name, fun) when name in [:fetch_snapshot, :post_generations, :post_feedback] do
    Agent.update(__MODULE__, &put_in(&1, [:handlers, name], fun))
  end

  def notify(pid), do: Agent.update(__MODULE__, &%{&1 | notify: pid})

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def calls(name), do: calls() |> Enum.filter(&(elem(&1, 0) == name))

  def reset, do: Agent.update(__MODULE__, &%{&1 | handlers: %{}, calls: []})

  @impl true
  def fetch_snapshot(_config, etag, opts \\ []) do
    call(:fetch_snapshot, [etag, opts])
  end

  @impl true
  def post_generations(_config, items), do: call(:post_generations, [items])

  @impl true
  def post_feedback(_config, items), do: call(:post_feedback, [items])

  defp call(name, args) do
    state =
      Agent.get_and_update(__MODULE__, fn state ->
        {state, %{state | calls: [List.to_tuple([name | args]) | state.calls]}}
      end)

    if state.notify, do: send(state.notify, {:fake_client, name, args})

    case Map.get(state.handlers, name) do
      nil -> {:error, :no_handler}
      fun -> apply(fun, args)
    end
  end
end
