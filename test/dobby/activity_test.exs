defmodule Dobby.ActivityTest do
  @moduledoc """
  The full record (design §10.6).
  """

  use Dobby.DataCase, async: true

  alias Dobby.Activity

  test "records an entry" do
    assert {:ok, entry} =
             Activity.record(%{
               kind: "tool_call",
               actor: "greg",
               device: "thermostat:main",
               action: "set_temperature",
               args: %{"temperature_f" => 70.0},
               result: %{"status" => "accepted"},
               duration_ms: 12,
               request_id: "req_1"
             })

    assert entry.kind == "tool_call"
    assert entry.args == %{"temperature_f" => 70.0}
  end

  test "requires a kind and nothing else" do
    assert {:ok, _} = Activity.record(%{kind: "state_changed"})
    assert {:error, changeset} = Activity.record(%{actor: "greg"})
    assert %{kind: _} = errors_on(changeset)
  end

  test "refuses a negative duration" do
    assert {:error, changeset} = Activity.record(%{kind: "tool_call", duration_ms: -1})
    assert %{duration_ms: _} = errors_on(changeset)
  end

  test "recent/1 is newest first — it is read as a feed" do
    {:ok, _} = Activity.record(%{kind: "first"})
    {:ok, _} = Activity.record(%{kind: "second"})

    assert ["second", "first"] = Enum.map(Activity.recent(), & &1.kind)
  end

  test "for_request/1 is oldest first — within one request it is a story" do
    {:ok, _} = Activity.record(%{kind: "request", request_id: "req_1"})
    {:ok, _} = Activity.record(%{kind: "tool_call", request_id: "req_1"})
    {:ok, _} = Activity.record(%{kind: "elsewhere", request_id: "req_2"})

    assert ["request", "tool_call"] = Enum.map(Activity.for_request("req_1"), & &1.kind)
  end

  test "for_device/2 is the question TK-004 will ask" do
    {:ok, _} = Activity.record(%{kind: "schedule_fired", device: "thermostat:main"})
    {:ok, _} = Activity.record(%{kind: "schedule_fired", device: "thermostat:main"})
    {:ok, _} = Activity.record(%{kind: "schedule_fired", device: "wifi:kitchen_tv"})

    assert length(Activity.for_device("thermostat:main")) == 2
  end
end
