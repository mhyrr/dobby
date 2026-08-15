defmodule Dobby.RigCase do
  @moduledoc """
  Case template for tests that run the whole application against FakeHA.

  Not `async`. The rig *is* the real application — one Jido registry, one set
  of device agents at fixed IDs, one fake Home Assistant. Scenarios take turns,
  and each gets the house restarted underneath it so nothing carries over.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Dobby.HomeAssistant.Fake

  using do
    quote do
      import Dobby.RigCase

      alias Dobby.Directive.HACall
      alias Dobby.HomeAssistant.Fake
      alias Dobby.Trace
    end
  end

  setup do
    default_manifest = Application.get_env(:dobby, Dobby.Home, [])

    # `on_exit` runs last-registered-first, and the order below is the reason
    # these three are separate callbacks rather than one. The house comes down
    # before the database connection it borrows, because `SchedulerAgent` reads
    # rows on any tick and a timer outliving its sandbox owner is a stray query
    # against a checked-in connection.
    on_exit(fn ->
      # A scenario that swapped houses must not leave the next one living in it.
      Application.put_env(:dobby, Dobby.Home, default_manifest)
    end)

    # Shared: the house is started by the application supervisor, so the
    # processes that query are not descendants of the test.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Dobby.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    on_exit(&stop_home!/0)
    on_exit(&drain_turns!/0)

    Fake.reset()
    restart_home!()

    Fake.subscribe()
    Dobby.DeviceEvents.subscribe()
    Dobby.ScheduleEvents.subscribe()
    Dobby.Trace.start!()

    :ok
  end

  @doc """
  Reboots the house from a different manifest.

  Scenarios that need a differently-shaped home — two thermostats, a device
  that isn't there — get one by restarting the real bootstrap against new
  configuration, which is what changing the house does in production too
  (design §2.4: edit and restart). It is not a way to reach around
  `Dobby.Home` and place agents by hand.
  """
  @spec boot_house!([map()]) :: :ok
  def boot_house!(devices) do
    Application.put_env(:dobby, Dobby.Home, rig_manifest(devices))
    Fake.reset()
    restart_home!()

    Fake.subscribe()
    Dobby.DeviceEvents.subscribe()

    :ok
  end

  @doc """
  A manifest shaped like `config/homes/rig.exs`, with the given devices.
  """
  @spec rig_manifest([map()]) :: keyword()
  def rig_manifest(devices) do
    [
      id: "rig",
      name: "Rig Home",
      timezone: "America/New_York",
      home_assistant: [client: Dobby.HomeAssistant.Fake, url: "http://fake.invalid:8123"],
      networks: [%{id: :home_wifi, name: "Rig", ssid: "rig"}],
      devices: devices
    ]
  end

  @doc """
  A thermostat manifest entry.
  """
  @spec thermostat_device(String.t(), String.t(), keyword()) :: map()
  def thermostat_device(id, name, opts \\ []) do
    %{
      id: id,
      name: name,
      aliases: Keyword.get(opts, :aliases, []),
      agent_module: Dobby.DeviceAgents.Thermostat,
      bindings: %{climate: Keyword.get(opts, :entity, "climate.#{String.replace(id, ":", "_")}")},
      settings: Keyword.get(opts, :settings, %{min_temperature_f: 60, max_temperature_f: 76})
    }
  end

  @doc """
  Seeds Home Assistant's view of the world and lets the house come up on it.

  This is the production boot sequence, not a shortcut into agent state: HA
  holds entity state, the client fans it out on subscribe, and device agents
  learn what they are from the resulting events. Blocks until every seeded
  device has reported, so a test never races its own setup.
  """
  @spec seed_house(%{String.t() => map()}) :: :ok
  def seed_house(entities) do
    Enum.each(entities, fn {entity_id, entity} -> Fake.put_entity(entity_id, entity) end)

    :ok = Fake.configure_routing(Dobby.Home.Manifest.routing_table(Dobby.Home.manifest()))

    Enum.each(entities, fn _ ->
      assert_receive %Jido.Signal{type: "dobby.device.state_changed"}, 2_000
    end)

    :ok
  end

  @doc """
  A thermostat entity as Home Assistant would report one.

  The envelope attributes are the point: `min_temp` and `max_temp` are what
  capability discovery reads, and they are the hardware's word, not ours.
  """
  @spec thermostat_entity(keyword()) :: map()
  def thermostat_entity(opts \\ []) do
    %{
      state: Keyword.get(opts, :hvac_mode, "heat"),
      attributes: %{
        current_temperature: Keyword.get(opts, :current, 68),
        temperature: Keyword.get(opts, :target, 68),
        min_temp: Keyword.get(opts, :min_temp, 50),
        max_temp: Keyword.get(opts, :max_temp, 90),
        target_temp_step: 1,
        hvac_modes: ["off", "heat"]
      }
    }
  end

  @doc """
  Retries `fun` until it returns a truthy value, or fails.

  For genuinely eventual properties only. `dobby.device.state_changed` fans
  out to its two consumers through `Task.Supervisor.async_stream`, so the
  thread can have an event before DobbyAgent's world model does. That is a
  property of the design (§7), not a defect — but it means a synchronous read
  of the world model right after a device change is a race, and asserting it
  eventually is the honest form.
  """
  @spec eventually((-> result), pos_integer()) :: result when result: term()
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _falsy ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition never became true within the timeout")
        else
          Process.sleep(10)
          do_eventually(fun, deadline)
        end
    end
  end

  @doc """
  Reads a device agent's current state.
  """
  @spec agent_state(String.t()) :: map()
  def agent_state(dobby_id) do
    pid = Dobby.Jido.whereis(dobby_id)
    {:ok, server_state} = Jido.AgentServer.state(pid)
    server_state.agent.state
  end

  # `terminate_child` returns when Dobby.Home is gone, but the agents it
  # stopped bring down plugin children of their own — Jido AI gives every
  # agent a Task.Supervisor. Restarting before those have actually exited
  # collides on registered names, which surfaces as `:already_registered` and
  # then a request that never completes. Wait for the processes, not the call.
  defp restart_home! do
    stop_home!()
    {:ok, _pid} = Supervisor.restart_child(Dobby.Supervisor, Dobby.Home)
    :ok
  end

  @doc false
  # `Dobby.Conversation.Turn` runs one task per request under the application's
  # own Task.Supervisor, so a turn is not a descendant of the house and does not
  # die with it. A test that returns while a task is still writing leaves a
  # query in flight against a connection the sandbox is about to check back in —
  # the same class of stray-query race the house teardown order exists for, and
  # the reason this runs before either of them.
  #
  # Registered last, so it runs first: `on_exit` is last-registered-first.
  def drain_turns! do
    Dobby.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(&await_turn_down/1)
  catch
    # No supervisor means no turns to wait for, which is most of the suite.
    :exit, _reason -> :ok
  end

  defp await_turn_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> raise "a turn was still running when its test ended"
    end
  end

  @doc false
  def stop_home! do
    pids = Enum.map(Dobby.Jido.list_agents(), fn {_id, pid} -> pid end)
    refs = Enum.map(pids, &Process.monitor/1)

    :ok = Supervisor.terminate_child(Dobby.Supervisor, Dobby.Home)
    Enum.each(refs, &await_down/1)

    :ok
  end

  defp await_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> raise "timed out waiting for a rig agent to shut down"
    end
  end
end
