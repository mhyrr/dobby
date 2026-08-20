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
  The name a home file calls this device type (TK-018).

  A household writes `type: thermostat`, never an Elixir module name. Declared
  by the module rather than listed centrally so that a new device type brings
  its own word with it; `Dobby.HomeConfig.Types` only says which modules are on
  offer.
  """
  @callback config_type() :: String.t()

  @doc """
  The `settings` this device type accepts in a home file, declared.

  A `NimbleOptions` schema, and the `:doc` on each key is written for whoever
  is editing the file rather than for whoever is reading the code. Two readers,
  one declaration: `Dobby.HomeConfig` validates against it, naming the field
  when a value is wrong, and /house renders a form from it — which is the seam
  that makes a new device type cost one module instead of a form as well.

  `[]` is a complete answer, and three of the four types give it: a device whose
  behaviour is entirely discovered from Home Assistant has nothing for a
  household to narrow.
  """
  @callback config_schema() :: keyword()

  @doc """
  Validates the manifest entry for one instance of this device type.

  Called during `Dobby.Home` bootstrap, before any agent starts. Return an
  error naming the offending field — the message reaches the operator as a
  startup failure.

  This is where a rule that spans two fields lives, the kind a declared schema
  cannot state: `config_schema/0` says a minimum is a number, and this says a
  minimum above the maximum is not a house.
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

  @doc """
  The device's public state, read from live agent state.

  The same map `Dobby.DeviceEvents.emit/2` carries — what cards render and what
  the model is told the house looks like. It exists as a callback because a
  surface that has just been opened needs the current state, and
  `dobby.device.state_changed` only fires on *change*: a page loaded at three in
  the afternoon would otherwise show an empty house until something moved.

  Reading `DobbyAgent`'s world model instead would answer the same question and
  would be wrong — it would make the cards depend on the language layer, which
  is the one thing the deterministic path is supposed to stand apart from.
  """
  @callback snapshot(state :: map()) :: map()

  @doc """
  Whether a change to this attribute is something somebody *did* (design §10.3).

  The thread records interventions and the cards record everything, but Home
  Assistant does not report intent — it reports that an attribute changed. The
  discriminator is *which* attribute: a setpoint is commanded, connectivity is
  observed. Somebody turning the dial in the hallway belongs in the thread; an
  endpoint flapping at 3am belongs on a card and in the log.

  That is per-device knowledge, which is why it lives here rather than in a
  central list the way a switch statement would want. `Thermostat` answers true
  for `:target_temperature_f` and false for the room's temperature;
  `WifiEndpoint` answers false for everything it has.
  """
  @callback intervention?(attribute :: atom()) :: boolean()

  @doc """
  What differs between two states, and which of it actually *moved*.

  Two answers because the house asks two questions of the same event.

  `changed` is everything that differs, and it is what the log records.

  `moved` is the subset that went from one known value to another. A value
  arriving where there was none is the house learning what it has, not
  something that happened in it: a thermostat reporting for the first time
  after a restart did not get set to 68 by anybody, and a thread that said so
  would announce the boot sequence to the kitchen every time the box came up.

  This is why `available` defaults to `nil` rather than `false` on both device
  types. `false` would have made every first report look like a device coming
  back from the dead.
  """
  @spec changes(map(), map(), [atom()]) :: %{changed: [atom()], moved: [atom()]}
  def changes(previous, next, keys) do
    changed = Enum.filter(keys, &(Map.get(previous, &1) != Map.get(next, &1)))

    %{changed: changed, moved: Enum.reject(changed, &is_nil(Map.get(previous, &1)))}
  end

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

  @doc """
  Sends a command to a device agent and reads back what it decided.

  The other half of the write protocol `command_outcome/2` documents, and the
  reason it is a function rather than three copies: the model's tool, a card
  someone tapped, and a schedule at eight o'clock all reach a device this way,
  and "the thermostat refused" has to mean the same thing whichever asked.

  The `ref` is minted here because it is a property of the call and not of the
  caller — nobody should be able to read back a decision that belongs to
  somebody else's command.
  """
  @spec command(pid(), String.t(), map()) :: outcome() | {:error, String.t()}
  def command(pid, signal_type, args) when is_pid(pid) and is_binary(signal_type) do
    ref = Jido.Util.generate_id()
    signal = Jido.Signal.new!(signal_type, Map.put(args, :ref, ref))

    case Jido.AgentServer.call(pid, signal) do
      {:ok, agent} -> command_outcome(agent.state, ref)
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
