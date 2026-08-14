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
  @house_tools [
    Dobby.Tools.CreateSchedule,
    Dobby.Tools.ListSchedules,
    Dobby.Tools.SetScheduleEnabled,
    Dobby.Tools.DeleteSchedule
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
        known = devices() |> Enum.map(& &1.id) |> Enum.join(", ")
        {:error, "unknown device #{inspect(device_id)}; this house has: #{known}"}
    end
  end

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

  defp start_dobby_agent do
    agent = Dobby.DobbyAgent.new(id: Dobby.DobbyAgent.id())

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
