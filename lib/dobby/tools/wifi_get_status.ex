defmodule Dobby.Tools.WifiGetStatus do
  @moduledoc """
  Tool: check whether a network endpoint is reachable.

  Answered from device-agent state with no Home Assistant round trip, same as
  the thermostat read. "Which endpoints are offline?" therefore costs the model
  one tool call per endpoint and costs the network nothing.
  """

  use Jido.Action,
    name: "wifi_get_status",
    description: """
    Check whether a network endpoint is currently reachable. Returns online, \
    offline, or unknown — unknown means Dobby cannot tell, which is not the \
    same as offline.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. wifi:kitchen_tv"
      ]
    ]

  alias Dobby.DeviceAgents.WifiEndpoint

  @impl true
  def run(%{device: device_id}, _context) do
    with {:ok, _device, pid} <- Dobby.Home.resolve(device_id, WifiEndpoint),
         {:ok, server_state} <- Jido.AgentServer.state(pid) do
      {:ok, status(server_state.agent.state)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp status(state) do
    %{
      device: state.dobby_id,
      name: state.name,
      available: state.available,
      reachability: reachability(state),
      last_changed_at: state.last_changed_at
    }
  end

  defp reachability(%{online: true}), do: :online
  defp reachability(%{online: false}), do: :offline
  defp reachability(_state), do: :unknown
end
