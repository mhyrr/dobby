defmodule Dobby.DeviceAgents.Vacuum do
  @moduledoc """
  A robot vacuum, as Dobby understands one (design §4.2, §7).

  Deterministic and signal-driven, like `Thermostat` and `Light`: it owns
  interpretation of its HA entity and the translation of semantic actions —
  start cleaning, go home — into HA service calls. It does not own a
  credential, a connection, or a vendor: Roomba's MQTT handshake is Home
  Assistant's problem, and this module knows only what a *vacuum* means.

  Deliberately small: status, start, dock. Rooms, zones, fan speeds, and
  quiet-hours policy wait for real use to earn them.
  """

  use Jido.Agent,
    name: "vacuum",
    description: "Reports vacuum state, starts a clean, and sends it home",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Vacuum.SyncState},
      {"vacuum.start_cleaning", Dobby.DeviceAgents.Vacuum.StartCleaning},
      {"vacuum.dock", Dobby.DeviceAgents.Vacuum.Dock}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: :boolean, default: false],
      activity: [type: {:or, [:atom, nil]}, default: nil],
      battery_percent: [type: {:or, [:integer, nil]}, default: nil],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def validate_device(%Device{bindings: bindings, settings: settings}) do
    with :ok <- require_binding(bindings, :vacuum) do
      if is_map(settings),
        do: :ok,
        else: {:error, "settings must be a map, got #{inspect(settings)}"}
    end
  end

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.VacuumGetStatus,
      Dobby.Tools.VacuumStart,
      Dobby.Tools.VacuumDock
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:vacuum]

  @impl Dobby.DeviceAgent
  def scheduled_actions do
    %{
      start_cleaning: {"vacuum.start_cleaning", Dobby.DeviceAgents.Vacuum.StartCleaning},
      dock: {"vacuum.dock", Dobby.DeviceAgents.Vacuum.Dock}
    }
  end

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Vacuum.SyncState

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device) do
    %{
      dobby_id: device.id,
      name: device.name,
      entity_id: Map.fetch!(device.bindings, :vacuum),
      settings: device.settings
    }
  end

  defp require_binding(bindings, key) when is_map(bindings) do
    case Map.fetch(bindings, key) do
      {:ok, entity_id} when is_binary(entity_id) ->
        :ok

      {:ok, other} ->
        {:error, "bindings.#{key} must be an entity id string, got #{inspect(other)}"}

      :error ->
        {:error, "missing required binding #{inspect(key)}"}
    end
  end

  defp require_binding(other, _key),
    do: {:error, "bindings must be a map, got #{inspect(other)}"}
end
