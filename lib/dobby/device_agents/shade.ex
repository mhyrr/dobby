defmodule Dobby.DeviceAgents.Shade do
  @moduledoc """
  A blind, shade, curtain, shutter, or awning.

  This type accepts both directions because it controls privacy and light, not
  access. Door, gate, garage, and window covers use AccessCover, whose surface
  omits open.
  """

  use Jido.Agent,
    name: "shade",
    description: "Reports and controls a household shade",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Shade.SyncState},
      {"shade.move", Dobby.DeviceAgents.Shade.Move},
      {"shade.set_position", Dobby.DeviceAgents.Shade.SetPosition}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      shade_state: [type: {:or, [:atom, nil]}, default: nil],
      position: [type: {:or, [:integer, nil]}, default: nil],
      supports_position: [type: {:or, [:boolean, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @impl Dobby.DeviceAgent
  def config_type, do: "shade"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity) do
    Entity.domain(entity) == "cover" and
      entity.device_class in ["awning", "blind", "curtain", "shade", "shutter"]
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device),
    do: Dobby.DeviceAgents.Validation.device(device, [:cover])

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.ShadeGetStatus,
      Dobby.Tools.ShadeOpen,
      Dobby.Tools.ShadeClose,
      Dobby.Tools.ShadeSetPosition
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:cover]

  @impl Dobby.DeviceAgent
  def scheduled_actions,
    do: %{
      move: {"shade.move", Dobby.DeviceAgents.Shade.Move},
      set_position: {"shade.set_position", Dobby.DeviceAgents.Shade.SetPosition}
    }

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Shade.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(attribute), do: attribute in [:shade_state, :position]

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device, :cover)
end
