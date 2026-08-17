defmodule Mix.Tasks.Dobby.Ha.Verify do
  @shortdoc "Proves the configured home against its real Home Assistant"

  @moduledoc """
  Boots the application against whatever home the environment selects and
  reports what actually happened — the development-integration layer of the
  test story (design §12), the one `mix test` deliberately does not cover.

      DOBBY_HOME_MANIFEST=config/homes/local.exs DOBBY_HA_TOKEN=... \\
      mix dobby.ha.verify

  Prints every device's snapshot once Home Assistant's initial state sync has
  landed. A device showing `available: true` with readings proves the whole
  inbound path: connection, authentication, subscription, routing, and state
  interpretation.

  With `--round-trip`, also drives the first thermostat through a real
  setpoint change: deterministic action → `HACall` → service call → HA moves
  the entity → `state_changed` comes back → agent state agrees. The nudge is
  one degree inside household policy, and it is a real change to the running
  instance.
  """

  use Mix.Task

  alias Dobby.DeviceAgents.Thermostat

  @sync_timeout 10_000
  @round_trip_timeout 10_000

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

    if "--round-trip" in args, do: round_trip()
  end

  defp round_trip do
    device =
      Enum.find(Dobby.Home.devices(), &(&1.agent_module == Thermostat)) ||
        Mix.raise("--round-trip needs a thermostat in the manifest")

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
    target = if current == 72, do: 71.0, else: 72.0

    Mix.shell().info("\nround trip: #{device.id} setpoint #{inspect(current)} → #{target}")

    ref = Jido.Util.generate_id()

    signal =
      Jido.Signal.new!("thermostat.set_temperature", %{temperature_f: target, ref: ref})

    {:ok, agent} = Jido.AgentServer.call(pid, signal)

    case Dobby.DeviceAgent.command_outcome(agent.state, ref) do
      :accepted -> Mix.shell().info("thermostat accepted; waiting for Home Assistant ...")
      {:rejected, reason} -> Mix.raise("thermostat rejected the setpoint: #{reason}")
      :unknown -> Mix.raise("could not confirm the command")
    end

    if await(fn -> snapshot(device.id).target_temperature_f == target end, @round_trip_timeout) do
      Mix.shell().info("round trip: ok — HA reported #{target}, agent state agrees")
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
