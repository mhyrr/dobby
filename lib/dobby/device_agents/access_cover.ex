defmodule Dobby.DeviceAgents.AccessCover do
  @moduledoc """
  A garage door, gate, door, or window represented by HA's cover domain.

  Dobby can report and close the opening. It does not expose open. Ordinary
  blinds use the separate shade type because access control and light control
  should not share policy merely because Home Assistant gives them one domain.
  """

  use Jido.Agent,
    name: "access_cover",
    description: "Reports and closes a garage door, gate, door, or window",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.AccessCover.SyncState},
      {"access_cover.close", Dobby.DeviceAgents.AccessCover.Close}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      cover_state: [type: {:or, [:atom, nil]}, default: nil],
      position: [type: {:or, [:integer, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "access_cover"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity) do
    Entity.domain(entity) == "cover" and
      entity.device_class in ["door", "garage", "gate", "window"]
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:cover])

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.AccessCoverGetStatus, Dobby.Tools.AccessCoverClose]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:cover]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{close: {"access_cover.close", Dobby.DeviceAgents.AccessCover.Close}}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.AccessCover.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:cover_state, :position]

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, action: :close}, snapshot),
    do: snapshot.cover_state in [:closing, :closed]

  def command_arrived?(_command, _snapshot), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :cover)
end
