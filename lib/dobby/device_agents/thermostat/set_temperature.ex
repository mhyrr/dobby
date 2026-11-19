defmodule Dobby.DeviceAgents.Thermostat.SetTemperature do
  @moduledoc """
  Decides whether a setpoint is allowed, and if so describes the HA call.

  This action performs no side effect. It validates against the intersection
  of the device's discovered envelope and household policy, then returns a
  `Dobby.Directive.HACall` for the runtime to execute. That separation is what
  makes the decision testable without a house.

  A rejected setpoint is an `:ok` return, not an error: the device agent
  successfully decided "no". The refusal is recorded in `last_command` so the
  tool that asked can report it back to the model as an observation.
  """

  use Jido.Action,
    name: "thermostat_set_temperature",
    description: "Validates a thermostat setpoint and emits the Home Assistant call",
    schema: [
      temperature_f: [
        type: {:or, [:integer, :float]},
        required: true,
        doc: "The temperature to set the thermostat to, in Fahrenheit."
      ],
      ref: [type: :string, required: true]
    ]

  alias Dobby.DeviceAgents.Thermostat
  alias Dobby.Directive.HACall

  @impl true
  def run(%{temperature_f: temperature, ref: ref}, context) do
    state = context.state

    case authorize(state, temperature) do
      :ok ->
        {:ok, %{last_command: accepted(ref, temperature, state.capabilities[:step_f])},
         [
           %HACall{
             domain: "climate",
             service: "set_temperature",
             entity_id: state.entity_id,
             data: %{temperature: temperature}
           }
         ]}

      {:error, reason} ->
        {:ok, %{last_command: rejected(ref, reason)}}
    end
  end

  defp authorize(state, temperature) do
    {min, max} = Thermostat.accepted_range(state)

    cond do
      state.available != true ->
        {:error, "#{state.name} is unavailable"}

      min != nil and temperature < min ->
        {:error, "#{temperature}° is below the #{state.name}'s minimum of #{min}°"}

      max != nil and temperature > max ->
        {:error, "#{temperature}° is above the #{state.name}'s maximum of #{max}°"}

      true ->
        :ok
    end
  end

  # The step rides on the command so its echo is judged by what the device
  # said it would do at the moment it accepted, not by whatever it reports
  # later (`Thermostat.echoes?/2`).
  defp accepted(ref, temperature, step) do
    %{
      ref: ref,
      action: :set_temperature,
      result: :accepted,
      temperature_f: temperature,
      step_f: step
    }
  end

  defp rejected(ref, reason) do
    %{ref: ref, action: :set_temperature, result: {:rejected, reason}}
  end
end
