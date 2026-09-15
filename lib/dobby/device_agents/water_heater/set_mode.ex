defmodule Dobby.DeviceAgents.WaterHeater.SetMode do
  @moduledoc "Mode names come from HA's operation list, never a guessed enum."
  use Jido.Action,
    name: "water_heater_set_mode",
    description: "Sets an advertised water heater mode",
    schema: [mode: [type: :string, required: true], ref: [type: :string, required: true]]

  alias Dobby.DeviceAgents.WaterHeater.Command

  @impl true
  def run(%{mode: mode, ref: ref}, %{state: state}) do
    with :ok <- Command.authorize(state, :supports_mode),
         true <- mode in (state.capabilities[:modes] || []) do
      Command.accept(state, ref, :set_mode, %{mode: mode}, "set_operation_mode", %{
        operation_mode: mode
      })
    else
      false ->
        Command.reject(ref, :set_mode, "mode must be one of the water heater's advertised modes")

      {:error, reason} ->
        Command.reject(ref, :set_mode, reason)
    end
  end
end
