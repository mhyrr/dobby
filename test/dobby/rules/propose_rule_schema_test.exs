defmodule Dobby.Rules.ProposeRuleSchemaTest do
  @moduledoc """
  What the tool tells the model, and what the tool does with the answer.

  The rig is here because the entry is only observable where it lands: the
  tool builds it and hands it to `Dobby.Rules.propose/2`, and the proposal it
  returns is the contract the household agrees to. Asserting on a map the test
  built itself would prove nothing about the arithmetic the model is forbidden
  to do.
  """
  use Dobby.RigCase, async: false

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
    for value <- ["68", "68 degrees", true, %{}] do
      assert {:error, _} = ProposeRule.validate_params(Map.put(@params, :number_value, value))
    end

    # A blank is absent, not wrong: the missing value is named later by run/2.
    for value <- [nil, [], ""] do
      assert {:ok, validated} =
               ProposeRule.validate_params(Map.put(@params, :number_value, value))

      refute Map.has_key?(validated, :number_value)
    end
  end

  test "boolean and state predicates keep their slot and do not acquire a numeric threshold" do
    cases = [
      {%{device: "contact:patio", attribute: "open"}, %{boolean_value: false}},
      {%{device: "contact:patio", attribute: "open"}, %{boolean_value: true}},
      {%{device: "vacuum:robo", attribute: "activity"}, %{state_value: "cleaning"}}
    ]

    for {observable, predicate} <- cases do
      params = @params |> Map.merge(observable) |> Map.merge(predicate)
      assert {:ok, validated} = ProposeRule.validate_params(params)
      refute Map.has_key?(validated, :number_value)
      assert Map.take(validated, Map.keys(predicate)) == predicate
    end
  end

  test "the exported schema asks for the spoken duration and nothing computed" do
    schema = Jido.Action.Schema.to_json_schema(ProposeRule.schema())
    properties = schema["properties"]

    # Three fields the file carries that the model is never asked for: two are
    # constants for an absence rule, and the third is arithmetic.
    for computed <- ~w(duration_seconds event_kind action) do
      refute Map.has_key?(properties, computed), computed
    end

    assert properties["duration"]["type"] == "integer"
    assert properties["duration_unit"]["enum"] == ~w(seconds minutes hours days)
    assert "duration" in schema["required"]
    assert "duration_unit" in schema["required"]
    refute "source" in schema["required"]
  end

  describe "the entry a proposal carries" do
    setup do
      writable_house!()
      :ok
    end

    test "spells the duration the household said and multiplies it in code" do
      assert {:ok, entry} = propose(%{number_value: 68, duration: 20, duration_unit: "minutes"})
      assert entry["duration_seconds"] == 1200
      refute Map.has_key?(entry, "duration")
      refute Map.has_key?(entry, "duration_unit")

      for {unit, seconds} <- [{"seconds", 20}, {"hours", 72_000}, {"days", 1_728_000}] do
        assert {:ok, entry} = propose(%{number_value: 68, duration: 20, duration_unit: unit})
        assert entry["duration_seconds"] == seconds
      end
    end

    test "writes an absence rule's fixed event fields without asking the model for them" do
      assert {:ok, entry} =
               propose(%{kind: "absence", number_value: 70, duration: 6, duration_unit: "hours"})

      assert entry["event_kind"] == "device_changed"
      assert entry["action"] == "state_changed"

      assert {:ok, state} = propose(%{number_value: 68, duration: 1, duration_unit: "minutes"})
      refute Map.has_key?(state, "event_kind")
      refute Map.has_key?(state, "action")
    end
  end

  defp propose(overrides) do
    case Jido.Exec.run(ProposeRule, Map.merge(@params, overrides)) do
      {:ok, %{rule: entry}} -> {:ok, entry}
      other -> other
    end
  end

  test "three filled value slots resolve to the one the observable declares" do
    # The model fills all three: 60 for the number, false for the boolean,
    # "" for the word. The thermostat's current_temperature_f is a number.
    params = %{
      device: "thermostat:main",
      attribute: "current_temperature_f",
      number_value: 60,
      boolean_value: false,
      state_value: "",
      unit: "",
      source: "",
      window_start: "",
      window_end: "",
      window_days: []
    }

    assert {:ok, cleaned} = Dobby.Tools.ProposeRule.on_before_validate_params(params)

    assert cleaned == %{
             device: "thermostat:main",
             attribute: "current_temperature_f",
             number_value: 60.0
           }

    # An enum observable keeps the word and drops the filled number and boolean.
    assert {:ok, %{state_value: "unlocked"} = lock} =
             Dobby.Tools.ProposeRule.on_before_validate_params(%{
               device: "lock:front",
               attribute: "lock_state",
               number_value: 0,
               boolean_value: false,
               state_value: "unlocked"
             })

    refute Map.has_key?(lock, :number_value)
    refute Map.has_key?(lock, :boolean_value)

    # An unknown device drops nothing, so the later check can name the fault.
    assert {:ok, unknown} =
             Dobby.Tools.ProposeRule.on_before_validate_params(%{
               device: "nothing:here",
               attribute: "x",
               number_value: 1.0,
               boolean_value: true
             })

    assert Map.has_key?(unknown, :boolean_value)
  end

  test "a unit offered for a reading that takes none is dropped, not refused" do
    # The model sent "°F" beside the thermostat's current temperature, a plain
    # number; the refusal cost a retry on every threshold rule (eval, 2026-09-06).
    params = %{
      device: "thermostat:main",
      attribute: "current_temperature_f",
      number_value: 60,
      unit: "°F"
    }

    assert {:ok, cleaned} = Dobby.Tools.ProposeRule.on_before_validate_params(params)
    refute Map.has_key?(cleaned, :unit)

    humidity = %{device: "monitor:office", attribute: "humidity", number_value: 60, unit: "%"}
    assert {:ok, %{unit: "%"}} = Dobby.Tools.ProposeRule.on_before_validate_params(humidity)
  end
end
