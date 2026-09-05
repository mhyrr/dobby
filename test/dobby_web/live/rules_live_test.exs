defmodule DobbyWeb.RulesLiveTest do
  use Dobby.RigCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Dobby.Rules

  @endpoint DobbyWeb.Endpoint
  @device "thermostat:main"
  @entity "climate.main_floor"

  setup do
    writable_house!()
    seed_house(%{@entity => thermostat_entity(current: 66, target: 70)})
    %{conn: build_conn()}
  end

  test "a household form installs a typed rule without a model", %{conn: conn} do
    {:ok, view, _} = live(conn, "/house")
    assert has_element?(view, "#rules-empty")
    view |> element("#rule-add") |> render_click()
    assert has_element?(view, "#rule-form")
    refute has_element?(view, "#rule-form textarea")

    view
    |> form("#rule-form", rule: %{name: "Warm room", value: "75", minutes: "20"})
    |> render_submit()

    [rule] = Rules.list()
    assert rule.rule["attribute"] == "current_temperature_f"
    assert rule.rule["value"] == 75.0
    assert rule.rule["duration_seconds"] == 1_200
    assert rule.rule["source"] == "House form: Warm room"
    assert has_element?(view, "#rules-#{rule.id} .rule-description", rule.description)
    refute has_element?(view, "#rule-form")
    refute_received {:ha_call, _}
  end

  test "absence and an overnight weekday window use the same typed condition", %{conn: conn} do
    {:ok, view, _} = live(conn, "/house")
    view |> element("#rule-add") |> render_click()
    view |> form("#rule-form", rule: %{kind: "absence", windowed: "true"}) |> render_change()

    view
    |> form("#rule-form",
      rule: %{
        name: "No heat change",
        value: "70",
        minutes: "30",
        start: "20:00",
        end: "07:00",
        days: "weekdays"
      }
    )
    |> render_submit()

    [rule] = Rules.list()
    assert rule.rule["kind"] == "absence"
    assert rule.rule["event_kind"] == "device_changed"
    assert rule.rule["action"] == "state_changed"
    assert rule.rule["attribute"] == "current_temperature_f"

    assert rule.rule["window"] == %{
             "start" => "20:00",
             "end" => "07:00",
             "days" => [1, 2, 3, 4, 5]
           }
  end

  test "changing the observable resets incompatible values and offers its declared choices", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/house")
    view |> element("#rule-add") |> render_click()
    view |> form("#rule-form", rule: %{value: "75"}) |> render_change()
    view |> form("#rule-form", rule: %{attribute: "hvac_mode"}) |> render_change()

    assert has_element?(view, "select#rule_value option[value=off][selected]")
    refute has_element?(view, "#rule_value option[value='75']")
    refute has_element?(view, "#rule_operator option[value=gt]")
    view |> form("#rule-form", rule: %{name: "Heat stays on", value: "heat"}) |> render_submit()

    assert [%{rule: %{"attribute" => "hvac_mode", "value" => "heat", "operator" => "eq"}}] =
             Rules.list()
  end

  test "a rejected form preserves what was typed and does not install a rule", %{conn: conn} do
    {:ok, view, _} = live(conn, "/house")
    view |> element("#rule-add") |> render_click()

    view
    |> form("#rule-form", rule: %{name: "Keep this name", value: "70", minutes: "-1"})
    |> render_submit()

    assert has_element?(view, "#rule-error")
    assert has_element?(view, "#rule_name[value='Keep this name']")
    assert Rules.list() == []
  end

  test "pause, resume, deletion and undo reach both browsers", %{conn: conn} do
    {:ok, _} = Rules.save(rule_entry())
    {:ok, first, _} = live(conn, "/house")
    {:ok, second, _} = live(build_conn(), "/house")

    first |> element("#rule-toggle-warm-room") |> render_click()
    assert [%{enabled: false}] = Rules.list()
    assert has_element?(second, "#rules-warm-room.paused")
    refute has_element?(second, "#rules-warm-room .flap")

    second |> element("#rule-toggle-warm-room") |> render_click()
    assert [%{enabled: true}] = Rules.list()
    first |> element("#rule-delete-warm-room.takes") |> render_click()
    assert Rules.list() == []
    assert has_element?(first, "#rule-undo")
    refute has_element?(second, "#rules-warm-room")

    first |> element("#rule-undo button") |> render_click()
    assert [%{id: "warm-room", enabled: true}] = Rules.list()
    assert has_element?(second, "#rules-warm-room")
    refute has_element?(first, "#rule-undo")
  end

  test "undo cannot overwrite a newer definition with the same id", %{conn: conn} do
    {:ok, _} = Rules.save(rule_entry())
    {:ok, view, _} = live(conn, "/house")
    view |> element("#rule-delete-warm-room") |> render_click()
    {:ok, _} = Rules.save(Map.put(rule_entry(), "name", "A different responsibility"))
    view |> element("#rule-undo button") |> render_click()

    assert [%{name: "A different responsibility"}] = Rules.list()
    assert has_element?(view, "#rule-error")
  end

  test "a standing notice can be acknowledged from either browser without pausing the rule", %{
    conn: conn
  } do
    {:ok, first, _} = live(conn, "/")
    {:ok, second, _} = live(build_conn(), "/")
    {:ok, _} = Rules.save(rule_entry() |> Map.put("value", 65) |> Map.put("duration_seconds", 0))
    Dobby.Rules.Watcher.check()

    assert has_element?(first, "#notice-ack-warm-room")
    assert has_element?(second, "#notice-ack-warm-room")
    refute has_element?(first, "#standing-notices .flap")
    first |> element("#notice-ack-warm-room") |> render_click()
    refute has_element?(second, "#notice-ack-warm-room")
    assert [%{enabled: true}] = Rules.list()
    assert Rules.notices() == []
  end

  defp rule_entry do
    %{
      "id" => "warm-room",
      "name" => "Warm room",
      "source" => "Tell me if the room stays above 75.",
      "device" => @device,
      "kind" => "state",
      "attribute" => "current_temperature_f",
      "operator" => "gt",
      "value" => 75,
      "duration_seconds" => 1_200,
      "enabled" => true
    }
  end
end
