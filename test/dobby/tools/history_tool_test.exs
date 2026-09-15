defmodule Dobby.HistoryToolTest do
  @moduledoc """
  The tool's closed vocabularies are literals, because the action macro needs
  them at compile time. That is the drift this file exists to catch: a kind
  added to `Dobby.History` and not to the tool is a record the model cannot
  ask for, and a kind in the tool alone is a filter the query would refuse
  after the model spent a call on it. `Dobby.Tools.History`'s moduledoc names
  this module as the one holding it.
  """
  use ExUnit.Case, async: true

  alias Dobby.History
  alias Dobby.History.TimeWindow

  defp properties, do: Dobby.Tools.History.to_tool().parameters_schema["properties"]

  test "every vocabulary the tool exports is the one the query enforces" do
    properties = properties()

    assert properties["kinds"]["items"]["enum"] == History.kinds()
    assert properties["period"]["enum"] == TimeWindow.periods()
    assert properties["mode"]["enum"] == History.modes()
  end

  test "the model is offered one way to name a kind, not two" do
    # `Dobby.History` still accepts a singular `kind` for callers that are not
    # the model. Exporting both would cost fifteen more words on every request
    # and hand the model a rule about which field to use.
    properties = properties()

    refute Map.has_key?(properties, "kind")
    assert Map.has_key?(properties, "kinds")
    assert properties["kinds"]["type"] == "array"
  end

  test "an unlisted kind is refused by the validator, not only undescribed" do
    assert {:error, _} = Dobby.Tools.History.validate_params(%{kinds: ["everything"]})
    assert {:error, _} = Dobby.Tools.History.validate_params(%{period: "bedtime"})
    assert {:error, _} = Dobby.Tools.History.validate_params(%{mode: "average"})
    assert {:ok, _} = Dobby.Tools.History.validate_params(%{kinds: ["rule_breached"]})
  end

  test "blank fields a model filled for nothing are absent, not refused" do
    # gpt-5.6-luna sends every property: "" for since/until/actor, and a
    # weekday beside a period that takes none. Each refusal was retryable and
    # the turn timed out (eval, 2026-09-06).
    params = %{
      device: "thermostat:main",
      actor: "",
      action: "",
      period: "today",
      since: "",
      until: "",
      weekday: 2,
      kinds: [],
      mode: "count"
    }

    assert {:ok, cleaned} = Dobby.Tools.History.on_before_validate_params(params)
    assert cleaned == %{device: "thermostat:main", period: "today", mode: "count"}

    # A speaker's name in actor is the same filler. The tool no longer has the
    # field, and a model that remembers it is not allowed to narrow the answer
    # through a key the validator would have let past.
    assert {:ok, only_schema} =
             Dobby.Tools.History.on_before_validate_params(%{
               device: "thermostat:main",
               actor: "greg",
               action: "set_temperature"
             })

    assert only_schema == %{device: "thermostat:main"}

    assert {:ok, kept} =
             Dobby.Tools.History.on_before_validate_params(%{period: "weekday", weekday: 2})

    assert kept.weekday == 2
  end

  test "action and actor are not fields the model is offered" do
    # action came back as a kind name or an invented verb; actor came back as
    # the speaker's own name on every call. Each matched no row, or only the
    # speaker's rows, and turned a real record into "nothing recorded"
    # (eval, 2026-09-06).
    props = Dobby.Tools.History.to_tool().parameters_schema["properties"]
    refute Map.has_key?(props, "action")
    refute Map.has_key?(props, "actor")

    assert Map.keys(props) |> Enum.sort() ==
             ~w(device kinds limit mode period since until weekday)
  end

  test "the slots a model fills beside the one it meant are dropped" do
    # A named date arrived with its instants and, beside them, the weekday
    # period that date falls on; "not both" then failed every device in turn.
    assert {:ok, dated} =
             Dobby.Tools.History.on_before_validate_params(%{
               since: "2026-09-01T00:00:00-04:00",
               until: "2026-09-02T00:00:00-04:00",
               period: "weekday",
               weekday: 2
             })

    assert dated == %{since: "2026-09-01T00:00:00-04:00", until: "2026-09-02T00:00:00-04:00"}

    # "When did it last happen" arrived as latest with period today beside it,
    # which searched today instead of all recorded history.
    assert {:ok, latest} =
             Dobby.Tools.History.on_before_validate_params(%{
               device: "vacuum:robo",
               mode: "latest",
               period: "today",
               weekday: 0
             })

    assert latest == %{device: "vacuum:robo", mode: "latest"}
  end
end
