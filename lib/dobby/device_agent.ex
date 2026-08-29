defmodule Dobby.DeviceAgent do
  @moduledoc """
  The extension contract for a reusable device-agent module (design §4.2).

  A module implementing this behaviour is the *behavior* half of a device —
  `Thermostat`, `WifiEndpoint`. The *instance* half is a `Dobby.Home.Device`
  entry in the manifest. Adding a new kind of device to Dobby means writing
  one of these plus its actions; no central switch statement changes.

  The shared command protocol also carries the trusted caller. That is where
  `hands_only` binds language without binding cards. A prompt rule or a check
  copied into every tool was rejected because MCP and delayed schedules would
  acquire separate policy paths, and one forgotten path would become a bypass.
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
  Whether an unbound Home Assistant entity looks like one of these (TK-010).

  The removable half of the double-entry problem. Home Assistant already knows
  that `climate.dining_room` is a climate entity; nobody should have to retype
  that as a device type. What HA cannot supply — the id this house will use
  forever, the words the household actually says, the policy bounds — stays the
  household's to state, which is why this only ever *suggests*.

  Declared per type rather than as a domain table somewhere central, for the
  reason `config_type/0` is: a new device agent should bring its own discovery
  with it. It also lets a type be narrower than its domain — `wifi_endpoint`
  wants the `binary_sensor` entities that report connectivity and none of the
  motion sensors, and only `WifiEndpoint` knows that.
  """
  @callback matches_entity?(Dobby.HomeAssistant.Entity.t()) :: boolean()

  @doc """
  The bindings one discovery anchor claims from its HA device group.

  Most types bind one entity. They can omit this callback and discovery maps
  the anchor to their sole subscribed binding. Compound types implement it to
  select several related entities, or return `:ignore` when the group is not
  the semantic device they represent.
  """
  @callback discovery_bindings(
              anchor :: Dobby.HomeAssistant.Entity.t(),
              related :: [Dobby.HomeAssistant.Entity.t()]
            ) :: {:ok, %{atom() => String.t()}} | :ignore

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
  Whether a public snapshot is the echo of one accepted command.

  Home Assistant does not attach Dobby's correlation reference when it reports
  state. The device type therefore owns the match: a lock accepts `:locking`
  or `:locked`, a thermostat compares the reported setpoint, and a vacuum
  accepts `:returning` as the first answer to a dock command. Keeping that
  knowledge here avoids a central table that would have to learn every device
  type's state vocabulary.

  Read-only device types can omit this callback. Their answer is always false.
  """
  @callback command_arrived?(command :: map(), snapshot :: map()) :: boolean()

  @doc """
  How long this device type may take to echo an accepted command.

  A timeout is type knowledge, not a house-file preference: a lock and a shade
  have different physical response times in every house. Types can override
  the generous default when their Home Assistant contract is tighter.
  """
  @callback confirmation_timeout() :: pos_integer()

  @optional_callbacks discovery_bindings: 2, command_arrived?: 2, confirmation_timeout: 0

  @default_confirmation_timeout 30_000

  @doc """
  Resolves a type's discovery bindings, including the single-entity default.

  The default is intentionally unavailable to a multi-binding type. Such a
  type must state how its HA entities fit together rather than letting their
  order choose.
  """
  @spec discovery_bindings(module(), Dobby.HomeAssistant.Entity.t(), [
          Dobby.HomeAssistant.Entity.t()
        ]) :: {:ok, %{atom() => String.t()}} | :ignore
  def discovery_bindings(module, anchor, related) do
    if function_exported?(module, :discovery_bindings, 2) do
      module.discovery_bindings(anchor, related)
    else
      case module.subscribed_bindings() do
        [binding] -> {:ok, %{binding => anchor.entity_id}}
        _several -> :ignore
      end
    end
  end

  @doc """
  Asks the device type whether a snapshot answers an accepted command.

  The false default is for sensor-only types. A write-capable type implements
  the callback beside the state vocabulary it is comparing.
  """
  @spec command_arrived?(module(), map(), map()) :: boolean()
  def command_arrived?(module, command, snapshot) do
    if function_exported?(module, :command_arrived?, 2),
      do: module.command_arrived?(command, snapshot),
      else: false
  end

  @doc "Returns the type's confirmation deadline in milliseconds."
  @spec confirmation_timeout(module()) :: pos_integer()
  def confirmation_timeout(module) do
    if function_exported?(module, :confirmation_timeout, 0),
      do: module.confirmation_timeout(),
      else: @default_confirmation_timeout
  end

  @doc """
  Checks whether one trusted caller may command a device.

  Schedule authoring asks this before it writes a delayed command. The write
  protocol asks it again at fire time. Keeping both answers here prevents the
  stored path and the immediate path from acquiring different meanings for
  `hands_only`.
  """
  @spec authorize_command(Device.t(), channel()) :: :ok | {:rejected, String.t()}
  def authorize_command(%Device{}, via) when via in [:card, :admin], do: :ok

  def authorize_command(%Device{} = device, via) when via in [:conversation, :mcp] do
    if Map.get(device, :hands_only, false) do
      {:rejected,
       "#{device.name} is hands only; the language layer may read it but may not command it"}
    else
      :ok
    end
  end

  @doc """
  The identity a device agent starts with, which is the same for every type.

  Every type answers `initial_state/1` with these four keys and differs only in
  which binding carries its entity — a light's is `:light`, a thermostat's is
  `:climate`. Written once here so that a fifth thing an agent knows about
  itself is one edit rather than one per type, and so that the library cannot
  drift into several slightly different ideas of what a device is.

  `Map.fetch!/2` rather than `Map.get/2` on purpose. `validate_device/1` has
  already run by the time `Dobby.Home` builds a state, so a device arriving
  here without its binding is a bug in bootstrap and should say so loudly
  rather than start an agent pointed at `nil`.
  """
  @spec initial_state(Device.t(), atom()) :: map()
  def initial_state(%Device{} = device, binding) when is_atom(binding) do
    device
    |> initial_state()
    |> Map.put(:entity_id, Map.fetch!(device.bindings, binding))
  end

  @doc """
  The shared identity for a compound device agent.

  A single-entity type uses `initial_state/2`. A compound type keeps the
  complete binding map and decides which incoming entity moved in its sync
  action.
  """
  @spec initial_state(Device.t()) :: map()
  def initial_state(%Device{} = device) do
    %{
      dobby_id: device.id,
      name: device.name,
      bindings: device.bindings,
      settings: device.settings
    }
  end

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

  @typedoc "The trusted surface that originated a device command."
  @type channel :: :conversation | :mcp | :card | :admin

  @type caller :: %{
          required(:via) => channel(),
          optional(:request_id) => String.t()
        }

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
  reason it is a function rather than three copies: the model's tool, MCP, a
  card, and a schedule all reach a device this way. The caller is trusted
  request framing, never a model argument. That lets `hands_only` bind the
  language layer here without weakening the direct path or relying on a
  prompt or on each tool remembering the rule.

  The `ref` is minted here because it is a property of the call and not of the
  caller — nobody should be able to read back a decision that belongs to
  somebody else's command.
  """
  @spec command(pid(), String.t(), map(), caller()) :: outcome() | {:error, String.t()}
  def command(pid, signal_type, args, %{via: via} = caller)
      when is_pid(pid) and is_binary(signal_type) and is_map(args) do
    with {:ok, server_state} <- Jido.AgentServer.state(pid),
         :ok <- authorize(server_state.agent.state, via),
         ref = Jido.Util.generate_id(),
         signal = command_signal(signal_type, args, ref, caller),
         {:ok, agent} <- Jido.AgentServer.call(pid, signal) do
      command_outcome(agent.state, ref)
    else
      {:rejected, _reason} = refusal -> refusal
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def command(_pid, _signal_type, _args, caller),
    do: {:error, "unknown command caller #{inspect(caller)}"}

  defp authorize(%{dobby_id: id}, via)
       when via in [:conversation, :mcp, :card, :admin] do
    case Dobby.Home.fetch_device(id) do
      {:ok, %Device{} = device} ->
        authorize_command(device, via)

      :error ->
        {:error, "unknown device #{inspect(id)}"}
    end
  end

  defp authorize(_agent_state, via), do: {:error, "unknown command caller #{inspect(via)}"}

  defp command_signal(signal_type, args, ref, caller) do
    extensions =
      caller
      |> Map.take([:via, :request_id])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Jido.Signal.new!(signal_type, Map.put(args, :ref, ref), %{extensions: extensions})
  end
end
