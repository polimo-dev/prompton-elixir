defmodule PromptOnSDK.Supervisor do
  @moduledoc """
  SDK supervision tree (§7.2). The host app adds `{PromptOnSDK, opts}` as a child (after
  Repo/PubSub, before Oban/Endpoint).

      PromptOnSDK.Supervisor (rest_for_one)
        ├─ PromptOnSDK.Snapshot        # load/poll → :persistent_term
        ├─ PromptOnSDK.TaskSupervisor  # Buffer send tasks
        └─ PromptOnSDK.Buffer          # log batcher (shutdown 10s, drains in terminate)

  `rest_for_one`: if Snapshot dies, TaskSupervisor and Buffer are restarted too (guarantees the
  configuration is reloaded). Shutdown runs in reverse order, so TaskSupervisor stays alive while
  Buffer drains.

  `init/1` stores the result of `PromptOnSDK.Config.load/1` in `:persistent_term`, so `opts`
  override the app env.
  """

  use Supervisor

  alias PromptOnSDK.Config

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Config.load(opts)
    Config.put(config)

    children = [
      {PromptOnSDK.Snapshot, config},
      {Task.Supervisor, name: PromptOnSDK.TaskSupervisor},
      {PromptOnSDK.Buffer, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
