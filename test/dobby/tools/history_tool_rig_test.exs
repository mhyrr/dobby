defmodule Dobby.HistoryToolRigTest do
  @moduledoc """
  The history tool through Jido's own execution pipeline, against real rows.
  Schema tests prove what the model is offered; this proves what it gets back.
  """
  use Dobby.RigCase, async: false
  alias Dobby.Activity

  test "a count through the tool sees the rows the record holds" do
    for kind <- ["command_refused", "command_never_arrived", "command_never_arrived"] do
      {:ok, _} =
        Activity.record(%{kind: kind, device: "thermostat:main", action: "set_temperature"})
    end

    params = %{
      device: "thermostat:main",
      actor: "",
      kinds: ["command_refused", "command_never_arrived"],
      period: "today",
      since: "",
      until: "",
      weekday: 0,
      mode: "count",
      limit: 50
    }

    assert {:ok, result} = Jido.Exec.run(Dobby.Tools.History, params, %{})
    assert result.count == 3, inspect(result)
  end

  # The record stamps rows in UTC. Asked what happened last night, GLM 5.2 on
  # 2026-09-07 read a row at 03:10Z as "3:10 AM last night" for a door that
  # unlocked at 11:10 PM in the house's zone. Converting a zone is
  # arithmetic, and the model never does arithmetic: the rows and the window
  # leave the tool in the house's own offset, the clock the block shows.
  test "rows and the window come back on the house's clock, not UTC" do
    {:ok, entry} = Activity.record(%{kind: "control", device: "lock:front", action: "lock"})

    assert {:ok, result} = Jido.Exec.run(Dobby.Tools.History, %{device: "lock:front"}, %{})
    assert [row] = result.entries

    # The rig house keeps America/New_York, and every instant carries its
    # offset rather than a Z.
    local = Dobby.Home.local(entry.inserted_at)
    assert row.at == DateTime.to_iso8601(local)
    assert String.ends_with?(row.at, "-04:00") or String.ends_with?(row.at, "-05:00")
    refute String.ends_with?(row.at, "Z")

    assert String.ends_with?(result.window.until, "-04:00") or
             String.ends_with?(result.window.until, "-05:00")

    # The period defaults to today, so the window opens at the house's own
    # midnight and says so with its offset.
    assert result.window.since =~ ~r/T00:00:00-0[45]:00\z/
  end

  # A date the household named arrives as a date, and code makes the instant.
  # The doctrine used to ask the model for an offset, and in a house that
  # keeps daylight time the model attached today's offset to a January date:
  # an hour off at both ends, the model doing time-zone arithmetic.
  test "a bare date is midnight on the house's clock, at both edges" do
    assert {:ok, result} =
             Jido.Exec.run(
               Dobby.Tools.History,
               %{since: "2026-01-05", until: "2026-01-06"},
               %{}
             )

    # January in America/New_York is -05:00, whatever today's offset is.
    assert result.window.since == "2026-01-05T00:00:00-05:00"
    assert result.window.until == "2026-01-06T00:00:00-05:00"
  end

  test "an instant with its own offset still passes as it was" do
    assert {:ok, result} =
             Jido.Exec.run(
               Dobby.Tools.History,
               %{since: "2026-01-05T06:00:00-05:00", until: "2026-01-05T09:00:00-05:00"},
               %{}
             )

    assert result.window.since == "2026-01-05T06:00:00-05:00"
    assert result.window.until == "2026-01-05T09:00:00-05:00"
  end
end
