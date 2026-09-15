defmodule Dobby.DeviceAgents.WaterHeater.SetAwayMode do
  @moduledoc "Away mode is a separate advertised capability, not an operation-mode guess."
  use Jido.Action,
    name: "water_heater_set_away_mode",
    description: "Sets water heater away mode",
    schema: [away_mode: [type: :boolean, required: true], ref: [type: :string, required: true]]

  alias Dobby.DeviceAgents.WaterHeater.Command

  @impl true
  def run(%{away_mode: away, ref: ref}, %{state: state}) do
    case Command.authorize(state, :supports_away_mode) do
      :ok ->
        Command.accept(state, ref, :set_away_mode, %{away_mode: away}, "set_away_mode", %{
          away_mode: away
        })

      {:error, reason} ->
        Command.reject(ref, :set_away_mode, reason)
    end
  end
end
