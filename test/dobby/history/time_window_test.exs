defmodule Dobby.History.TimeWindowTest do
  use ExUnit.Case, async: true
  alias Dobby.History.TimeWindow
  @zone "America/New_York"
  @friday ~U[2026-09-04 16:30:00Z]

  test "today uses house midnight and clips at now" do
    assert {:ok, window} = TimeWindow.resolve(%{}, @zone, @friday)
    assert DateTime.to_unix(window.since) == DateTime.to_unix(~U[2026-09-04 04:00:00Z])
    assert DateTime.compare(window.until, @friday) == :eq
  end

  test "weeks start Monday and weekdays are the most recent occurrence" do
    assert {:ok, week} = TimeWindow.resolve(%{period: "this_week"}, @zone, @friday)
    assert DateTime.to_date(week.since) == ~D[2026-08-31]
    assert {:ok, previous} = TimeWindow.resolve(%{period: "last_week"}, @zone, @friday)
    assert DateTime.to_date(previous.since) == ~D[2026-08-24]
    assert DateTime.to_date(previous.until) == ~D[2026-08-31]
    assert {:ok, tuesday} = TimeWindow.resolve(%{period: "weekday", weekday: 2}, @zone, @friday)
    assert DateTime.to_date(tuesday.since) == ~D[2026-09-01]
    assert {:ok, saturday} = TimeWindow.resolve(%{period: "weekday", weekday: 6}, @zone, @friday)
    assert DateTime.to_date(saturday.since) == ~D[2026-08-29]
  end

  test "calendar days are 23 or 25 hours across DST, not fixed seconds" do
    assert {:ok, spring} =
             TimeWindow.resolve(%{period: "yesterday"}, @zone, ~U[2026-03-09 16:00:00Z])

    assert DateTime.diff(spring.until, spring.since) == 23 * 3600

    assert {:ok, autumn} =
             TimeWindow.resolve(%{period: "yesterday"}, @zone, ~U[2026-11-02 16:00:00Z])

    assert DateTime.diff(autumn.until, autumn.since) == 25 * 3600
  end

  test "last night has explicit boundaries and never includes the future" do
    assert {:ok, night} = TimeWindow.resolve(%{period: "last_night"}, @zone, @friday)
    assert {DateTime.to_date(night.since), night.since.hour} == {~D[2026-09-03], 18}
    assert {DateTime.to_date(night.until), night.until.hour} == {~D[2026-09-04], 6}

    assert {:ok, early} =
             TimeWindow.resolve(%{period: "last_night"}, @zone, ~U[2026-09-04 07:00:00Z])

    assert early.until.hour == 3
  end

  test "explicit instants keep their offsets and exclude reversed or mixed windows" do
    params = %{since: "2026-11-01T01:30:00-04:00", until: "2026-11-01T01:30:00-05:00"}
    assert {:ok, window} = TimeWindow.resolve(params, @zone, @friday)
    assert DateTime.diff(window.until, window.since) == 3600
    assert {:error, _} = TimeWindow.resolve(%{since: "2026-11-01T01:30:00"}, @zone, @friday)
    assert {:error, _} = TimeWindow.resolve(%{since: "2027-01-01T00:00:00Z"}, @zone, @friday)
    assert {:error, _} = TimeWindow.resolve(Map.put(params, :period, "today"), @zone, @friday)
    assert {:error, _} = TimeWindow.resolve(%{period: "bedtime"}, @zone, @friday)
    assert {:error, _} = TimeWindow.resolve(%{period: "weekday", weekday: 0}, @zone, @friday)
  end

  test "latest has an unbounded past only when no window was supplied" do
    assert {:ok, %{since: nil}} = TimeWindow.resolve(%{mode: "latest"}, @zone, @friday)

    assert {:ok, %{since: %DateTime{}}} =
             TimeWindow.resolve(%{mode: "latest", period: "today"}, @zone, @friday)
  end
end
