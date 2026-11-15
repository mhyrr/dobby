defmodule Dobby.DeviceAgents.Lock do
  @moduledoc """
  A household lock with a deliberately one-way write surface (TK-014).

  Dobby can report and secure a lock. It does not expose unlock. The missing
  action is policy, not an integration gap.
  """

  use Jido.Agent,
    name: "lock",
    description: "Reports and secures a household lock",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Lock.SyncState},
      {"lock.secure", Dobby.DeviceAgents.Lock.Secure}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      lock_state: [type: {:or, [:atom, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  @impl Dobby.DeviceAgent
  def observables, do: %{lock_state: {:enum, [:locked, :unlocked, :locking, :unlocking, :jammed]}}

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "lock"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Entity.domain(entity) == "lock"

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:lock])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.LockGetStatus, Dobby.Tools.LockSecure]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:lock]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{secure: {"lock.secure", Dobby.DeviceAgents.Lock.Secure}}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Lock.SyncState

  # One word, because a lock has one safe direction. The row reads LOCKED in
  # the record voice when it is, and offers `locked` when it is not; unlock
  # stays absent from every surface, and this is the card-side proof of
  # `hands_only` — the same lock that refuses a sentence takes a hand.
  @impl Dobby.DeviceAgent
  def controls(%{available: true, lock_state: state}) when is_atom(state) and not is_nil(state) do
    [
      %{
        kind: :choice,
        action: :secure,
        arg: nil,
        field: :lock_state,
        options: [:locked],
        label: nil
      }
    ]
  end

  def controls(_snapshot), do: []

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute == :lock_state

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, action: :secure}, snapshot),
    do: snapshot.lock_state in [:locking, :locked]

  def command_arrived?(_command, _snapshot), do: false

  # No override: a lock takes the thirty-second default. One second was here
  # with no reason recorded, and it assumed an answer Home Assistant does not
  # give. HA core does not synthesise a `locking` state, so a Z-Wave, August
  # or Schlage lock says nothing until the bolt has thrown and the report has
  # come back, seconds later. Each of those tripped the deadline and wrote a
  # NOT KNOWN line that the late echo then could not take back.

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :lock)
end
