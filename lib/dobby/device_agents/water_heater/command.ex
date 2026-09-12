defmodule Dobby.DeviceAgents.WaterHeater.Command do
  @moduledoc "Shared acceptance and refusal shape for the water heater's advertised controls."
  alias Dobby.Directive.HACall

  def authorize(state, feature) do
    cond do
      state.available != true ->
        {:error, "#{state.name} is unavailable"}

      state.capabilities[feature] != true ->
        {:error, "#{state.name} does not advertise #{feature}"}

      true ->
        :ok
    end
  end

  def accept(state, ref, action, report, service, data) do
    {:ok, %{last_command: Map.merge(report, %{ref: ref, action: action, result: :accepted})},
     [%HACall{domain: "water_heater", service: service, entity_id: state.entity_id, data: data}]}
  end

  def reject(ref, action, reason),
    do: {:ok, %{last_command: %{ref: ref, action: action, result: {:rejected, reason}}}}
end
