defmodule Dobby.DeviceAgents.WifiEndpoint.SyncState do
  @moduledoc """
  Translates an inbound HA `state_changed` into endpoint agent state.

  HA's binary sensors speak `"on"` / `"off"`, and a Ping sensor's `"on"` means
  the address answered. Anything else — `"unavailable"`, `"unknown"`, a sensor
  that has not reported yet — is `nil` rather than `false`, because "we cannot
  tell" and "it is offline" are different answers and Dobby should not round
  one into the other.
  """

  use Jido.Action,
    name: "wifi_endpoint_sync_state",
    description: "Applies a Home Assistant state change to endpoint agent state",
    schema: [
      entity_id: [type: :string, required: true],
      state: [type: {:or, [:string, nil]}, default: nil],
      # String keys — see Thermostat.SyncState: bare `:map` means atom keys,
      # which real HA's JSON attributes are not.
      attributes: [type: {:map, :string, :any}, default: %{}]
    ]

  alias Dobby.DeviceEvents

  @impl true
  def run(params, context) do
    previous = context.state
    online = parse_online(params.state)

    next = %{
      available: params.state not in [nil, "unavailable", "unknown"],
      online: online,
      last_changed_at: changed_at(previous, online)
    }

    if meaningful_change?(previous, next) do
      {:ok, next, [DeviceEvents.emit(previous.dobby_id, snapshot(previous, next))]}
    else
      {:ok, next}
    end
  end

  @doc """
  The device's public state, read from live agent state.

  `Dobby.DeviceAgent.snapshot/1` for this device type: a surface that has just
  opened needs the house as it is now, and state-change events only describe
  changes.
  """
  @spec snapshot(map()) :: map()
  def snapshot(state), do: snapshot(state, state)

  @doc """
  The device's public state — what cards render and the model is told.
  """
  @spec snapshot(map(), map()) :: map()
  def snapshot(previous, next) do
    %{
      id: previous.dobby_id,
      name: previous.name,
      type: :wifi_endpoint,
      available: next.available,
      online: next.online,
      last_changed_at: next.last_changed_at
    }
  end

  defp parse_online("on"), do: true
  defp parse_online("off"), do: false
  defp parse_online(_other), do: nil

  # Stamped only when reachability actually flips, so "offline since" means
  # what it says rather than "when HA last mentioned it".
  defp changed_at(previous, online) do
    if previous.online == online, do: previous.last_changed_at, else: DateTime.utc_now()
  end

  defp meaningful_change?(previous, next) do
    Enum.any?([:available, :online], fn key ->
      Map.get(previous, key) != Map.get(next, key)
    end)
  end
end
