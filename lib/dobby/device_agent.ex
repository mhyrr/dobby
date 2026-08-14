defmodule Dobby.DeviceAgent do
  @moduledoc """
  The extension contract for a reusable device-agent module (design §4.2).

  A module implementing this behaviour is the *behavior* half of a device —
  `Thermostat`, `WifiEndpoint`. The *instance* half is a `Dobby.Home.Device`
  entry in the manifest. Adding a new kind of device to Dobby means writing
  one of these plus its actions; no central switch statement changes.
  """

  alias Dobby.Home.Device

  @doc """
  Validates the manifest entry for one instance of this device type.

  Called during `Dobby.Home` bootstrap, before any agent starts. Return an
  error naming the offending field — the message reaches the operator as a
  startup failure.
  """
  @callback validate_device(Device.t()) :: :ok | {:error, String.t()}

  @doc """
  The starting agent state for one instance, built from its manifest entry.

  Identity and configuration only. Everything observable — availability,
  readings, capabilities — starts empty and arrives from Home Assistant.
  """
  @callback initial_state(Device.t()) :: map()

  @doc """
  The tool modules this device type advertises to `DobbyAgent`.

  These become the model's only means of acting on this kind of device.
  """
  @callback tools() :: [module()]

  @doc """
  The HA entity bindings this device type subscribes to, as binding keys.

  `Dobby.Home` uses this to build the client's entity-to-agent routing table.
  """
  @callback subscribed_bindings() :: [atom()]

  @doc """
  The actions of this device type a schedule is allowed to fire (design §9).

  Keyed by the name a schedule row stores, valued by the signal type and the
  action module behind it. `%{}` is a complete answer — a read-only device has
  nothing to schedule, and a schedule aimed at one is refused at authoring
  time rather than at eight o'clock.

  This is deliberately narrower than `signal_routes`: an agent routes
  `ha.state_changed` too, and nobody should be able to schedule that. It is
  also the reason `Dobby.Schedules` needs no list of device types — validating
  a schedule and firing one both go through whatever the target's module says
  here, so a new device type brings its own schedulable surface with it.
  """
  @callback scheduled_actions() :: %{atom() => {signal_type :: String.t(), module()}}

  @typedoc "What a device agent decided about a command it was sent."
  @type outcome :: :accepted | {:rejected, String.t()} | :unknown

  @doc """
  Reads the outcome of a command out of a device agent's state.

  The write protocol every device agent shares: a caller sends a command
  carrying a `ref`, the agent records its decision in `last_command` under that
  ref, and the caller reads it back. Both callers are here — the model's tool
  and a schedule firing — and both must read it the same way, because "the
  thermostat refused" has to mean the same thing whether a person asked or a
  timer did.

  The `ref` is not ceremony. It is what stops a caller reporting a decision
  that belongs to somebody else's command; `:unknown` says the outcome could
  not be confirmed, which is different from, and much better than, guessing.
  """
  @spec command_outcome(map(), String.t()) :: outcome()
  def command_outcome(agent_state, ref) do
    case Map.get(agent_state, :last_command) do
      %{ref: ^ref, result: :accepted} -> :accepted
      %{ref: ^ref, result: {:rejected, reason}} -> {:rejected, reason}
      _other -> :unknown
    end
  end
end
