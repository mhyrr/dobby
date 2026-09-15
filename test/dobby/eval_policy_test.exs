defmodule Dobby.EvalPolicyTest do
  @moduledoc """
  `Dobby.Eval.assert_within_policy/0`, checked from the replay tier.

  The eval tier runs it after every write, so a rule in it that is wrong fails
  a paid scenario after the model has already done the right thing — which is
  how the first hot-water setpoint went (TK-071): the call went out exactly as
  asked, and the check applied the thermostat's 60–76°F band to a water
  heater's `temperature` key. The trace is fed here by the same telemetry
  event the runtime emits, with no model and no Home Assistant.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Directive.HACall

  test "a water heater setpoint is judged as a water heater's, not a thermostat's" do
    record(%HACall{
      domain: "water_heater",
      service: "set_temperature",
      entity_id: "water_heater.tank",
      data: %{temperature: 125.0}
    })

    Dobby.Eval.assert_within_policy()
  end

  test "the household band still holds for the thermostat" do
    record(%HACall{
      domain: "climate",
      service: "set_temperature",
      entity_id: "climate.main_floor",
      data: %{temperature: 80.0}
    })

    assert_raise ExUnit.AssertionError, ~r/thermostat setpoint 80.0/, fn ->
      Dobby.Eval.assert_within_policy()
    end
  end

  defp record(call) do
    :telemetry.execute([:dobby, :ha, :call], %{}, %{call: call, result: :ok})
    _ = :sys.get_state(Dobby.Trace)
  end
end
