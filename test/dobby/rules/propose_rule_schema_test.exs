defmodule Dobby.Rules.ProposeRuleSchemaTest do
  use ExUnit.Case, async: true

  alias Dobby.Tools.ProposeRule

  @params %{
    id: "cold-room",
    name: "Cold room",
    device: "thermostat:main",
    kind: "state",
    attribute: "current_temperature_f",
    operator: "lt",
    duration: 1,
    duration_unit: "minutes"
  }

  test "JSON numbers export as numbers and validate as integers or floats" do
    schema = Jido.Action.Schema.to_json_schema(ProposeRule.schema())
    assert schema["properties"]["number_value"]["type"] == "number"

    for value <- [68, 68.5, 0, -10, -10.5] do
      assert {:ok, validated} =
               ProposeRule.validate_params(Map.put(@params, :number_value, value))

      assert validated.number_value == value
      assert is_float(validated.number_value)
    end
  end

  test "non-numeric thresholds are rejected before the action runs" do
    for value <- ["68", "68 degrees", true, nil, %{}, []] do
      assert {:error, _} = ProposeRule.validate_params(Map.put(@params, :number_value, value))
    end
  end

  test "boolean and state predicates do not acquire a numeric threshold" do
    for predicate <- [%{boolean_value: false}, %{boolean_value: true}, %{state_value: "cleaning"}] do
      assert {:ok, validated} = ProposeRule.validate_params(Map.merge(@params, predicate))
      refute Map.has_key?(validated, :number_value)
      assert Map.take(validated, Map.keys(predicate)) == predicate
    end
  end
end
