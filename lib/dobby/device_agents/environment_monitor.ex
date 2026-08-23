defmodule Dobby.DeviceAgents.EnvironmentMonitor do
  @moduledoc """
  A group of environmental readings from one Home Assistant device.

  Temperature, humidity, air quality, carbon dioxide, particulate matter,
  volatile compounds, and illuminance belong in one household object when HA
  says they share a device. The monitor is read-only.
  """

  use Jido.Agent,
    name: "environment_monitor",
    description: "Reports environmental readings from one household monitor",
    signal_routes: [{"ha.state_changed", Dobby.DeviceAgents.EnvironmentMonitor.SyncState}],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      bindings: [type: :map, required: true],
      available: [type: {:or, [:boolean, nil]}, default: nil],
      readings: [type: :map, default: %{}],
      units: [type: :map, default: %{}],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device
  alias Dobby.HomeAssistant.Entity

  @classes %{
    "temperature" => :temperature,
    "humidity" => :humidity,
    "carbon_dioxide" => :carbon_dioxide,
    "aqi" => :air_quality,
    "pm25" => :pm25,
    "volatile_organic_compounds" => :volatile_organic_compounds,
    "volatile_organic_compounds_parts" => :volatile_organic_compounds,
    "illuminance" => :illuminance
  }

  @impl Dobby.DeviceAgent
  def config_type, do: "environment_monitor"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity),
    do: Entity.domain(entity) == "sensor" and Map.has_key?(@classes, entity.device_class)

  @impl Dobby.DeviceAgent
  def discovery_bindings(_anchor, related) do
    bindings =
      related
      |> Enum.filter(&matches_entity?/1)
      |> Enum.reduce(%{}, fn entity, acc ->
        Map.put_new(acc, Map.fetch!(@classes, entity.device_class), entity.entity_id)
      end)

    if map_size(bindings) > 0, do: {:ok, bindings}, else: :ignore
  end

  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{} = device) do
    with :ok <- Dobby.DeviceAgents.Validation.device(device, [], subscribed_bindings()) do
      if map_size(device.bindings) > 0,
        do: :ok,
        else: {:error, "environment_monitor needs at least one reading binding"}
    end
  end

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.EnvironmentMonitorGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings,
    do: [
      :temperature,
      :humidity,
      :carbon_dioxide,
      :air_quality,
      :pm25,
      :volatile_organic_compounds,
      :illuminance
    ]

  @impl Dobby.DeviceAgent
  def scheduled_actions, do: %{}

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.EnvironmentMonitor.SyncState

  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device), do: Dobby.DeviceAgent.initial_state(device)
end
