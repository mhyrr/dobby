defmodule Dobby.DeviceAgents.WifiEndpoint do
  @moduledoc """
  A network endpoint Dobby can tell you the reachability of (design §7.2).

  Read-only, and deliberately narrow: this reports whether a *configured
  endpoint* answers, not whether a person is home. Presence inference needs a
  reliable `device_tracker` source and phones are poor ping targets because
  they sleep their radios, so it stays deferred.

  It is also the second device type in the library, which makes it the test of
  §4.2's extension contract: adding it should be one module, its actions, and
  manifest entries — no central switch statement, no change to `Dobby.Home`,
  `DobbyAgent`, or the HA client.
  """

  use Jido.Agent,
    name: "wifi_endpoint",
    description: "Reports whether a configured network endpoint is reachable",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.WifiEndpoint.SyncState}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      available: [type: :boolean, default: false],
      online: [type: {:or, [:boolean, nil]}, default: nil],
      last_changed_at: [type: {:or, [:any, nil]}, default: nil],
      settings: [type: :map, default: %{}]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def validate_device(%Device{bindings: bindings}) when is_map(bindings) do
    case Map.fetch(bindings, :connectivity) do
      {:ok, entity_id} when is_binary(entity_id) ->
        :ok

      {:ok, other} ->
        {:error, "bindings.connectivity must be an entity id string, got #{inspect(other)}"}

      :error ->
        {:error, "missing required binding :connectivity"}
    end
  end

  def validate_device(%Device{bindings: other}),
    do: {:error, "bindings must be a map, got #{inspect(other)}"}

  @impl Dobby.DeviceAgent
  def tools, do: [Dobby.Tools.WifiGetStatus]

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:connectivity]

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device) do
    %{
      dobby_id: device.id,
      name: device.name,
      entity_id: Map.fetch!(device.bindings, :connectivity),
      settings: device.settings
    }
  end
end
