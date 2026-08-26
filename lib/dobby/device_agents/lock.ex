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

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute == :lock_state

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :lock)
end
