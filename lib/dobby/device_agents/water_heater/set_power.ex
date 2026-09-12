defmodule Dobby.DeviceAgents.WaterHeater.SetPower do
  @moduledoc "Power requires HA's ON_OFF flag; operation modes alone do not authorize it."
  use Jido.Action,
    name: "water_heater_set_power",
    description: "Sets water heater power",
    schema: [
      power: [type: {:in, [:on, :off]}, required: true],
      ref: [type: :string, required: true]
    ]

  alias Dobby.DeviceAgents.WaterHeater.Command

  @impl true
  def run(%{power: power, ref: ref}, %{state: state}) do
    case Command.authorize(state, :supports_power) do
      :ok -> Command.accept(state, ref, :set_power, %{power: power}, "turn_#{power}", %{})
      {:error, reason} -> Command.reject(ref, :set_power, reason)
    end
  end
end
