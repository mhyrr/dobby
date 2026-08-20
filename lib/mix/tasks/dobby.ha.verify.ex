defmodule Mix.Tasks.Dobby.Ha.Verify do
  @shortdoc "Proves the configured home against its real Home Assistant"

  @moduledoc """
  Boots the application against whatever home the environment selects and
  reports what actually happened — the development-integration layer of the
  test story (design §12), the one `mix test` deliberately does not cover.

      DOBBY_HOME_MANIFEST=config/homes/local.yaml \\
      DOBBY_HA_URL=http://localhost:8123 DOBBY_HA_TOKEN=... \\
      mix dobby.ha.verify

  Prints every device's snapshot once Home Assistant's initial state sync has
  landed. A device showing `available: true` with readings proves the whole
  inbound path: connection, authentication, subscription, routing, and state
  interpretation.

  With `--round-trip`, also drives a thermostat through a real setpoint
  change and back: deterministic action → `HACall` → service call → HA moves
  the entity → `state_changed` comes back → agent state agrees — then the
  original setpoint is restored the same way. The nudge is one degree inside
  household policy, and it is a real change to whatever the entity is bound
  to, for as long as confirmation takes.

  `--round-trip` alone targets the first thermostat in the manifest — keep a
  virtual one first, so the default nudge never lands on a furnace. Name a
  device to aim deliberately:

      mix dobby.ha.verify --round-trip thermostat:house
  """

  use Mix.Task

  alias Dobby.DeviceAgents.Thermostat

  @sync_timeout 10_000
  # Generous because it has to hold for cloud-polled devices: a TCC
  # thermostat confirms on Honeywell's schedule, not ours.
  @round_trip_timeout 120_000

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    devices = Dobby.Home.devices()
    manifest = Dobby.Home.manifest()

    Mix.shell().info("home #{inspect(manifest.id)} with #{length(devices)} device(s)\n")

    synced? = await(fn -> Enum.all?(snapshots(), &Map.get(&1, :available)) end, @sync_timeout)

    Enum.each(snapshots(), &Mix.shell().info(inspect(&1, pretty: true)))

    unless synced? do
      Mix.raise("""
      not every device heard from Home Assistant within #{@sync_timeout}ms.
      Devices still unavailable never got their entity's state — check the
      entity IDs in the manifest against Developer Tools → States, and the
      client logs above for connection errors.
      """)
    end

    Mix.shell().info("\ninitial state sync: ok")

    # Whatever follows --round-trip is a device id unless it is another flag.
    # Nothing forces a manifest to prefix its thermostats with `thermostat:`,
    # so an id we do not recognise must reach round_trip/1 and be refused
    # there by name — never silently fall through to the first thermostat.
    case Enum.drop_while(args, &(&1 != "--round-trip")) do
      ["--round-trip", "--" <> _flag | _rest_args] -> round_trip(nil)
      ["--round-trip", device_id | _rest_args] -> round_trip(device_id)
      ["--round-trip"] -> round_trip(nil)
      [] -> :ok
    end
  end

  defp round_trip(device_id) do
    device =
      case device_id do
        nil -> Enum.find(Dobby.Home.devices(), &(&1.agent_module == Thermostat))
        id -> Enum.find(Dobby.Home.devices(), &(&1.id == id))
      end

    unless device && device.agent_module == Thermostat do
      Mix.raise(
        "--round-trip needs a thermostat in the manifest" <>
          if(device_id, do: "; #{inspect(device_id)} is not one", else: "")
      )
    end

    pid = Dobby.Jido.whereis(device.id)
    {:ok, server_state} = Jido.AgentServer.state(pid)
    agent_state = server_state.agent.state
    {min, max} = Thermostat.accepted_range(agent_state)

    Mix.shell().info("""

    discovered capabilities: #{inspect(agent_state.capabilities)}
    household policy:        #{inspect(agent_state.settings)}
    accepted range:          #{inspect(min)}–#{inspect(max)}
    """)

    %{target_temperature_f: current} = snapshot(device.id)

    unless is_number(current) do
      Mix.raise("#{device.id} has no target setpoint to nudge yet")
    end

    # Down one degree unless policy floors us there — and always back where
    # it was: the proof is the loop, not the change, and nobody's afternoon
    # should be a degree different because a verify ran.
    nudged = if min != nil and current - 1 < min, do: current + 1.0, else: current - 1.0

    Mix.shell().info("\nround trip: #{device.id} setpoint #{inspect(current)} → #{nudged} → back")

    # The nudge is a real change to a real house, so the restore is owed on
    # the failure path too — a cloud-polled thermostat that never confirms is
    # exactly when the setpoint would otherwise be left a degree off. The
    # nudge's failure is the one worth reporting; the restore's own trouble
    # gets a warning and the operator's attention.
    try do
      set_and_confirm(device, pid, nudged)
    rescue
      error ->
        restore(device, pid, current * 1.0)
        reraise error, __STACKTRACE__
    end

    set_and_confirm(device, pid, current * 1.0)

    Mix.shell().info("round trip: ok — setpoint restored to #{inspect(current)}")
  end

  defp restore(device, pid, target) do
    Mix.shell().info("  putting #{device.id} back to #{target} ...")
    set_and_confirm(device, pid, target)
  rescue
    _error ->
      Mix.shell().error("""
      could not put #{device.id} back to #{target}. Set it by hand — the
      verify left the setpoint where the nudge put it.
      """)
  end

  defp set_and_confirm(device, pid, target) do
    ref = Jido.Util.generate_id()

    signal =
      Jido.Signal.new!("thermostat.set_temperature", %{temperature_f: target, ref: ref})

    {:ok, agent} = Jido.AgentServer.call(pid, signal)

    case Dobby.DeviceAgent.command_outcome(agent.state, ref) do
      :accepted -> Mix.shell().info("  accepted #{target}; waiting for the house to confirm ...")
      {:rejected, reason} -> Mix.raise("thermostat rejected the setpoint: #{reason}")
      :unknown -> Mix.raise("could not confirm the command")
    end

    started = System.monotonic_time(:millisecond)

    if await(fn -> snapshot(device.id).target_temperature_f == target end, @round_trip_timeout) do
      elapsed = System.monotonic_time(:millisecond) - started
      Mix.shell().info("  confirmed at #{target} after #{elapsed}ms")
    else
      Mix.raise("""
      HA accepted the call but the confirming state change never arrived.
      Agent state still shows #{inspect(snapshot(device.id).target_temperature_f)}.
      """)
    end
  end

  defp snapshots, do: Dobby.Home.snapshots() |> Map.values()
  defp snapshot(id), do: Dobby.Home.snapshots() |> Map.fetch!(id)

  defp await(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(100) && do_await(fun, deadline)
    end
  end
end
