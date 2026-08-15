defmodule Dobby.Tools.ThermostatGetStatus do
  @moduledoc """
  Tool: read a thermostat.

  Answered straight from device-agent state, with no Home Assistant round
  trip, because the agent's state is kept current by the HA subscription
  (design §6.2). The `device` argument is checked against the roster, so the
  model cannot read a thermostat this house does not have.
  """

  use Jido.Action,
    name: "thermostat_get_status",
    description: """
    Read a thermostat's current temperature, target setpoint, and mode. \
    Use the device id from the roster.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. thermostat:main"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Thermostat

  @impl Dobby.Tools
  def label(arguments), do: "reading the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context) do
    with {:ok, _device, pid} <- Dobby.Home.resolve(device_id, Thermostat),
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
      current_temperature_f: state.current_temperature_f,
      target_temperature_f: state.target_temperature_f,
      hvac_mode: state.hvac_mode
    }
  end
end
