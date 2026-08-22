defmodule Dobby.Home do
  @moduledoc """
  The bootstrap (design §4.1).

  Loads the manifest, refuses to start if the house is described wrongly,
  brings up one agent per device, and tells the HA client which entity belongs
  to whom. After that it mostly gets out of the way: lookups are served from
  `:persistent_term`, because every tool call makes one and a GenServer round
  trip for immutable configuration would be a tax with no payer.

  Configuration errors take the application down naming the exact device and
  field. Silently skipping a thermostat because of a typo would make the house
  unusually philosophical about heating.
  """

  use GenServer

  alias Dobby.Home.{Device, Manifest}

  @term_key {__MODULE__, :manifest}

  # Tools that belong to the house rather than to any device. A schedule is
  # about the household's intentions, so these are offered whatever is plugged
  # in — a house with nothing schedulable refuses at authoring time, naming
  # what it does have, which is a better answer than a missing tool.
  #
  # The config three are here for the sharper version of the same reason: they
  # are how a house gets its *first* device, so a house that has none must
  # still offer them or there is no way in but a text editor (TK-010).
  @house_tools [
    Dobby.Tools.CreateSchedule,
    Dobby.Tools.ListSchedules,
    Dobby.Tools.SetScheduleEnabled,
    Dobby.Tools.DeleteSchedule,
    Dobby.Tools.DiscoverEntities,
    Dobby.Tools.ProposeDevice,
    Dobby.Tools.ConfirmDevice
  ]

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    config =
      Keyword.get_lazy(opts, :manifest, fn -> Application.get_env(:dobby, __MODULE__, []) end)

    manifest = Manifest.load!(config)

    Process.flag(:trap_exit, true)
    :persistent_term.put(@term_key, manifest)

    with :ok <- start_device_agents(manifest),
         :ok <- start_dobby_agent() do
      # Routing before the scheduler, so that the initial state HA sends on
      # subscribe lands on agents that exist — and reaches DobbyAgent's world
      # model, which means Dobby knows what the house looks like before anyone
      # says anything.
      Dobby.HomeAssistant.configure_routing(Manifest.routing_table(manifest))

      # Timers last. A schedule resolves a device and dispatches to its agent,
      # so everything it can reach has to be running first — and a firing in
      # the first milliseconds of boot should find a house that has heard from
      # Home Assistant, not one that has not.
      with :ok <- start_scheduler_agent() do
        {:ok, %{manifest: manifest}}
      end
    end
  end

  @impl GenServer
  def terminate(_reason, %{manifest: manifest}) do
    # Device agents live under the Jido instance's dynamic supervisor, not
    # under this process, so they outlive it unless we say otherwise. Leaving
    # them running would make a restart fail on registry IDs already taken —
    # and a restarted Home should give you the house as configured, not the
    # house as it was.
    # Timers down first, and deliberately: a cron job is owned by the scheduler
    # and would die with it anyway, but it dies exiting `{:owner_down,
    # :shutdown}`, which OTP reports as a crash. Cancelling first keeps that
    # report meaning something.
    Dobby.SchedulerAgent.clear()
    Dobby.Jido.stop_agent(Dobby.SchedulerAgent.id())

    Enum.each(manifest.devices, &Dobby.Jido.stop_agent(&1.id))
    Dobby.Jido.stop_agent(Dobby.DobbyAgent.id())
    :persistent_term.erase(@term_key)
    :ok
  end

  def terminate(_reason, _state) do
    :persistent_term.erase(@term_key)
    :ok
  end

  @doc """
  Takes the house down, and waits for it to actually be down.

  `terminate_child` returns when this process is gone, but the agents it stopped
  bring down plugin children of their own — Jido AI gives every agent a
  Task.Supervisor. Coming back up before those have exited collides on
  registered names, which surfaces as `:already_registered` and then a request
  that never completes. Wait for the processes, not for the call.

  Proven in the rig, where every scenario reboots the house between tests, and
  in lib rather than in test support because production does the same thing for
  the same reason: `Dobby.HomeConfig.Writer` applies a changed house by
  restarting this.
  """
  @spec stop() :: :ok
  def stop do
    refs =
      Dobby.Jido.list_agents()
      |> Enum.map(fn {_id, pid} -> Process.monitor(pid) end)

    :ok = Supervisor.terminate_child(Dobby.Supervisor, __MODULE__)
    Enum.each(refs, &await_down/1)

    :ok
  end

  @doc """
  Reboots the house from whatever configuration is currently applied.

  What changing the house has always meant (design §2.4: edit and restart) — the
  only difference now is that a person can do it without a shell. The cards
  honestly blink NOT KNOWN while the agents come back, and Home Assistant's
  initial-state sync heals them.
  """
  @spec restart() :: {:ok, pid()} | {:error, term()}
  def restart do
    stop()

    case Supervisor.restart_child(Dobby.Supervisor, __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> raise "timed out waiting for the house's agents to shut down"
    end
  end

  # -- reads -----------------------------------------------------------------

  @doc """
  The loaded manifest.
  """
  @spec manifest() :: Manifest.t()
  def manifest, do: :persistent_term.get(@term_key)

  @doc """
  Looks up a device by its stable Dobby ID.
  """
  @spec fetch_device(String.t()) :: {:ok, Device.t()} | :error
  def fetch_device(id), do: Manifest.fetch_device(manifest(), id)

  @doc """
  Every device the house currently manages.
  """
  @spec devices() :: [Device.t()]
  def devices, do: manifest().devices

  @doc """
  A UTC timestamp on the household's own clock.

  The thread is a shared record, so it is stamped in the house's time rather
  than each reader's — two people in the same kitchen must not see the same
  message at two different times, and doctrine already tells Dobby to speak in
  the household's local clock.
  """
  @spec local(DateTime.t()) :: DateTime.t()
  def local(%DateTime{} = at) do
    case DateTime.shift_zone(at, manifest().timezone, Dobby.Schedules.Cron.time_zone_database()) do
      {:ok, local} -> local
      {:error, _reason} -> at
    end
  rescue
    # No manifest means no house, and a page that is already rendering should
    # show a slightly wrong clock rather than a stack trace.
    ArgumentError -> at
  end

  @doc """
  The current public state of every managed device, keyed by device ID.

  What a surface reads when it opens. `dobby.device.state_changed` keeps it
  current after that, but it only fires on change — a board opened in the
  middle of a quiet afternoon has to get the house from somewhere, and this is
  where.

  A device whose agent is not running answers from its manifest entry, which
  reads as a device that exists and has told us nothing. That is the truth in
  that situation, and it is better than a hole in the board.
  """
  @spec snapshots() :: %{String.t() => map()}
  def snapshots do
    Map.new(devices(), fn device -> {device.id, snapshot(device)} end)
  end

  defp snapshot(%Device{agent_module: module} = device) do
    case Dobby.Jido.whereis(device.id) do
      pid when is_pid(pid) ->
        {:ok, server_state} = Jido.AgentServer.state(pid)
        module.snapshot(server_state.agent.state)

      nil ->
        # Through `new/1` rather than `initial_state/1` directly, so the schema
        # defaults are applied. A raw manifest projection is missing every
        # observable field, and a snapshot built from it would raise rather
        # than say "nothing known yet".
        module.new(id: device.id, state: module.initial_state(device)).state
        |> module.snapshot()
    end
  end

  @doc """
  The tool modules this house's devices advertise to the model.

  Derived from the configured agent modules, so adding a device type to the
  manifest adds its tools with no central list to edit. Passed per request
  rather than declared on the agent: `Jido.AI.Agent` resolves its `tools:`
  option at compile time and rejects function calls there, so a manifest-derived
  set can only be applied at ask time.
  """
  @spec tools() :: [module()]
  def tools do
    device_tools =
      devices()
      |> Enum.flat_map(& &1.agent_module.tools())
      |> Enum.uniq()

    device_tools ++ @house_tools
  end

  @doc """
  Every tool module any house could ever be offered, whatever this one has.

  `tools/0` is one house's set; this is the closure it is drawn from — the
  tools of every registered device type plus the house's own. The MCP surface
  declares this at compile time and narrows to `tools/0` per connection, the
  same shape `Dobby.DobbyAgent` takes for the same macro-shaped reason: a
  declaration cannot read the manifest, so the compile-time set is the library
  and the running house narrows it.
  """
  @spec library() :: [module()]
  def library do
    device_tools = Enum.flat_map(Dobby.HomeConfig.Types.modules(), & &1.tools())

    Enum.uniq(device_tools ++ @house_tools)
  end

  @doc """
  The roster the model is shown each turn: what exists, what to call it, and
  the ID to use when acting on it.
  """
  @spec roster() :: [map()]
  def roster do
    Enum.map(devices(), fn device ->
      %{
        id: device.id,
        name: device.name,
        aliases: device.aliases,
        # Not shown to the model as such — it is what the renderer asks for the
        # device's schedulable actions, which is the one thing about a device
        # the model needs that the manifest does not state directly.
        agent_module: device.agent_module
      }
    end)
  end

  @doc """
  Resolves a device ID the model supplied, refusing anything off the roster.

  This is the closed-by-construction guarantee at runtime: the model can name
  only devices this house actually has, and only ones of the expected type.
  """
  @spec resolve(String.t(), module()) :: {:ok, Device.t(), pid()} | {:error, String.t()}
  def resolve(device_id, expected_module) do
    with {:ok, device} <- fetch_device_or_error(device_id),
         :ok <- expect_module(device, expected_module) do
      case Dobby.Jido.whereis(device_id) do
        pid when is_pid(pid) -> {:ok, device, pid}
        nil -> {:error, "#{device.name} is not running"}
      end
    end
  end

  defp fetch_device_or_error(device_id) do
    case fetch_device(device_id) do
      {:ok, device} ->
        {:ok, device}

      :error ->
        {:error, "unknown device #{inspect(device_id)}; #{roll_call(devices())}"}
    end
  end

  # A house with nothing in it used to end this sentence on a colon and stop,
  # which reads as truncated to a person and tells the model even less than
  # saying so. Both audiences are real: the same string reaches the admin page
  # and the model's create_schedule refusal.
  defp roll_call([]), do: "this house has no devices"
  defp roll_call(devices), do: "this house has: " <> Enum.map_join(devices, ", ", & &1.id)

  defp expect_module(%Device{agent_module: module}, module), do: :ok

  defp expect_module(%Device{} = device, expected) do
    {:error,
     "#{device.name} is not a #{friendly(expected)}; it is a #{friendly(device.agent_module)}"}
  end

  defp friendly(module) do
    module |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ")
  end

  # -- startup ---------------------------------------------------------------

  defp start_device_agents(%Manifest{devices: devices}) do
    Enum.reduce_while(devices, :ok, fn device, :ok ->
      agent =
        device.agent_module.new(id: device.id, state: device.agent_module.initial_state(device))

      # `agent_module:` is not redundant. Agents built by `use Jido.Agent` are
      # all `%Jido.Agent{}` structs carrying their module in a field, so a
      # pre-built struct alone leaves AgentServer resolving routes against
      # Jido.Agent itself.
      case Dobby.Jido.start_agent(agent, id: device.id, agent_module: device.agent_module) do
        {:ok, pid} ->
          await_ready(pid)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:stop, "could not start device #{inspect(device.id)}: #{inspect(reason)}"}}
      end
    end)
  end

  # The conversation window is handed over at construction rather than pushed
  # in afterwards, because `Jido.AI.Reasoning.ReAct.Strategy` reads
  # `agent.state[:context]` when it initializes and there is no signal for
  # replacing it later. Design §10.8; the seam is documented in
  # `Dobby.Conversation.Rehydrate`.
  defp start_dobby_agent do
    agent =
      Dobby.DobbyAgent.new(
        id: Dobby.DobbyAgent.id(),
        state: %{context: Dobby.Conversation.Rehydrate.context()}
      )

    case Dobby.Jido.start_agent(agent, id: Dobby.DobbyAgent.id(), agent_module: Dobby.DobbyAgent) do
      {:ok, pid} ->
        await_ready(pid)
        install_soul(pid)

      {:error, reason} ->
        {:stop, "could not start DobbyAgent: #{inspect(reason)}"}
    end
  end

  # Schedules are rows, and the timers for them are a projection rebuilt at
  # every boot (design §9). Nothing about a schedule survives in a process, so
  # a restart cannot leave a stale timer behind or lose a live one.
  defp start_scheduler_agent do
    agent = Dobby.SchedulerAgent.new(id: Dobby.SchedulerAgent.id())

    case Dobby.Jido.start_agent(agent,
           id: Dobby.SchedulerAgent.id(),
           agent_module: Dobby.SchedulerAgent
         ) do
      {:ok, pid} ->
        await_ready(pid)
        Dobby.SchedulerAgent.sync()

      {:error, reason} ->
        {:stop, "could not start SchedulerAgent: #{inspect(reason)}"}
    end
  end

  # The agent compiles in doctrine alone; who Dobby *is* arrives here, read
  # from `config/soul.md` on the box (design §2.4 — edit and restart, never
  # rebuild). Sent synchronously so the prompt is in place before anyone can
  # get a reply written without it.
  defp install_soul(pid) do
    signal =
      Jido.Signal.new!("ai.react.set_system_prompt", %{system_prompt: Dobby.Soul.system_prompt()})

    case Jido.AgentServer.call(pid, signal) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:stop, "could not install Dobby's soul: #{inspect(reason)}"}
    end
  end

  # `start_agent/2` returns as soon as the process is alive, but AgentServer
  # builds its signal routes in a `handle_continue`. Without this barrier the
  # first device events raced DobbyAgent's routing table and landed as "no
  # route for signal" — so whether Dobby knew the house at boot depended on
  # scheduling. A synchronous call queues behind the continue, which is all
  # the ordering we need.
  defp await_ready(pid) do
    {:ok, _state} = Jido.AgentServer.state(pid)
    :ok
  end
end
