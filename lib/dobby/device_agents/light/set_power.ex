defmodule Dobby.DeviceAgents.Light.SetPower do
  @moduledoc """
  Decides whether the light may be switched, and if so describes the HA call.

  No side effect here, exactly as with the thermostat's `SetTemperature`:
  validate, then return a `Dobby.Directive.HACall` for the runtime. Agent
  state does not change on acceptance — the light going on arrives later as
  an inbound state change, or does not.
  """

  use Jido.Action,
    name: "light_set_power",
    description: "Validates switching a light and emits the Home Assistant call",
    schema: [
      on: [type: :boolean, required: true, doc: "Whether to turn the light on."],
      ref: [type: :string, required: true]
    ]

  alias Dobby.Directive.HACall

  @impl true
  def run(%{on: on, ref: ref}, context) do
    state = context.state

    if state.available do
      {:ok, %{last_command: %{ref: ref, action: :set_power, result: :accepted, on: on}},
       [
         %HACall{
           domain: "light",
           service: if(on, do: "turn_on", else: "turn_off"),
           entity_id: state.entity_id,
           data: %{}
         }
       ]}
    else
      {:ok,
       %{
         last_command: %{
           ref: ref,
           action: :set_power,
           result: {:rejected, "#{state.name} is unavailable"}
         }
       }}
    end
  end
end
