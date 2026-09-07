defmodule Dobby.HistoryTest do
  use Dobby.DataCase, async: true
  alias Dobby.{Activity, History, Repo}
  @now ~U[2026-09-04 16:00:00Z]
  @opts [timezone: "America/New_York", now: @now]

  test "exact filters, removed devices, attribution, and half-open boundaries" do
    first =
      record("control", ~U[2026-09-04 04:00:00Z], %{
        device: "light:removed",
        actor: "greg",
        action: "turn_on"
      })

    record("control", ~U[2026-09-04 03:59:59Z], %{
      device: "light:removed",
      actor: "greg",
      action: "turn_on"
    })

    record("control", @now, %{device: "light:removed", actor: "greg", action: "turn_on"})

    record("control", ~U[2026-09-04 05:00:00Z], %{
      device: "light:removed",
      actor: "maya",
      action: "turn_on"
    })

    record("device_changed", ~U[2026-09-04 05:00:00Z], %{
      device: "light:removed",
      action: "state_changed",
      result: %{"on" => true},
      args: %{"changed" => ["on"]}
    })

    assert {:ok, result} =
             History.query(
               %{device: "light:removed", actor: "greg", action: "turn_on", kind: "control"},
               @opts
             )

    assert result.count == 1
    assert [entry] = result.entries
    assert entry.id == first.id
    assert entry.actor == "greg"
    assert entry.evidence =~ "not proof of physical outcome"
  end

  test "count spans capped rows and latest does not silently mean today" do
    for second <- 1..105 do
      record("command_never_arrived", DateTime.add(@now, -second), %{
        device: "light:kitchen",
        request_id: "request-#{second}"
      })
    end

    assert {:ok, result} =
             History.query(%{kind: "command_never_arrived", mode: "count", limit: 2}, @opts)

    assert result.count == 105
    assert result.returned == 2
    assert result.truncated
    assert [newest, older] = result.entries
    assert newest.request_id == "request-1"
    assert older.request_id == "request-2"

    old = record("device_changed", ~U[2026-08-01 12:00:00Z], %{device: "wifi:retired"})

    assert {:ok, %{entries: [%{id: id}]}} =
             History.query(%{device: "wifi:retired", mode: "latest"}, @opts)

    assert id == old.id
  end

  test "failed confirmations are countable together without including accepted commands" do
    record("command_refused", DateTime.add(@now, -3), %{
      device: "light:one",
      result: %{"reason" => "HA refused"}
    })

    record("command_never_arrived", DateTime.add(@now, -2), %{device: "light:two"})

    record("tool_call", DateTime.add(@now, -1), %{
      device: "light:two",
      result: %{"status" => "accepted"}
    })

    assert {:ok, result} =
             History.query(%{kinds: ["command_refused", "command_never_arrived"]}, @opts)

    assert result.count == 2
    assert Enum.map(result.entries, & &1.device) == ["light:two", "light:one"]
    assert hd(result.entries).evidence =~ "unknown"
  end

  test "duration_ms is call latency, never the time a device ran" do
    record("control", DateTime.add(@now, -10), %{
      device: "vacuum:main",
      action: "start",
      duration_ms: 120,
      result: %{"status" => "accepted"}
    })

    assert {:ok, result} = History.query(%{device: "vacuum:main", mode: "duration"}, @opts)
    assert result.duration_seconds == nil
    assert result.coverage =~ "cannot be measured"
    assert {:ok, empty} = History.query(%{device: "vacuum:unknown"}, @opts)
    assert empty.count == 0
    assert empty.coverage =~ "not proof"
  end

  test "invalid filters fail before they can broaden the query" do
    for params <- [
          %{kind: "invented"},
          %{kinds: []},
          %{kinds: "control"},
          %{kind: "control", kinds: ["control"]},
          %{limit: 101},
          %{limit: 0},
          %{limit: "2"},
          %{mode: "sql"},
          %{device: ""},
          %{actor: 1},
          %{where: "true"},
          %{weekday: 1}
        ] do
      assert {:error, _} = History.query(params, @opts)
    end
  end

  defp record(kind, at, attrs) do
    {:ok, entry} = Activity.record(Map.put(attrs, :kind, kind))
    # Activity.record is the production writer; the clock is fixed only after
    # recording so boundary cases can be tested without a process clock mock.
    # Ecto requires declared microsecond precision even for whole-second instants.
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}
    entry |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end
end
