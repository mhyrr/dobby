defmodule DobbyWeb.AdminLiveTest do
  @moduledoc """
  The page a maintainer opens, against the real house.

  Three questions, and they are not the household's questions: what has this
  house been doing, what is it going to do, and is it actually there. The thread
  and the cards are for people living in the house; this is for whoever has to
  work out why the heat did not come on.
  """

  use Dobby.RigCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Dobby.Activity
  alias Dobby.ActivityEvents
  alias Dobby.SchedulerAgent
  alias Dobby.Schedules

  @endpoint DobbyWeb.Endpoint

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 66, target: 70)})

    %{conn: build_conn()}
  end

  describe "health" do
    test "says whether each part of the house is actually there", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".panel .row .name", "Dobby")
      assert has_element?(view, ".panel .row .name", "Scheduler")
      assert has_element?(view, ".panel .row .name", "Home Assistant")

      # The registry id, because these rows are about processes and the same
      # words appear on /house about devices. They can honestly disagree.
      assert has_element?(view, ".panel .row .val", "thermostat:main")
      assert has_element?(view, ".panel .rows .row .flap[data-st=acting]", "Awake")
    end

    test "a part that is not running says so", %{conn: conn} do
      Dobby.Jido.stop_agent(Dobby.DobbyAgent.id())

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".panel .rows .row .flap[data-st=silent]", "Quiet")
      assert has_element?(view, ".plate .flap[data-st=silent]", "Quiet")
    end

    # "That can run", not "enabled": `unregistered` measures the schedules that
    # are enabled *and* still able to reach their device, so the wider claim
    # reads as a flat contradiction of a HELD row two lines below it.
    test "empty says so rather than showing nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".panel .note", "Every schedule that can run has a timer")
    end

    # The most useful row on the page: a schedule accepted at authoring time
    # and then rejected by the timer looks, from every other angle, exactly
    # like one that works.
    test "names the enabled schedules that have no timer", %{conn: conn} do
      create!(label: "weeknight heat")
      SchedulerAgent.clear()

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".panel .note .wrong", "weeknight heat")
      assert has_element?(view, ".panel .note .wrong", "no timer")
    end
  end

  describe "the schedule form" do
    test "writes a row, registers its timer, and attributes it", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/admin")

      view
      |> form("form.new-sched",
        schedule: %{
          "label" => "morning warmup",
          "cron" => "30 6 * * *",
          "target" => @thermostat,
          "action" => "set_temperature",
          "args" => %{"temperature_f" => "68"}
        }
      )
      |> render_submit()

      assert [schedule] = Schedules.list_schedules()
      assert schedule.label == "morning warmup"
      assert schedule.args == %{"temperature_f" => 68.0}
      assert schedule.created_via == :admin
      assert schedule.created_by == "greg"

      # A row nobody set a timer for is a row, not a schedule.
      assert SchedulerAgent.unregistered() == []
      assert has_element?(view, ".sched .name", "morning warmup")
      assert has_element?(view, ".sched .flap[data-st=expected]", "Ready")
    end

    # The argument fields come from the target action's own schema, so the form
    # can only offer what the row will accept.
    test "offers the arguments the chosen action actually takes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, "input[name='schedule[args][temperature_f]'][type=number]")
      assert has_element?(view, "select[name='schedule[target]'] option[value='#{@thermostat}']")

      # A read-only device is left out rather than offered and then refused.
      refute has_element?(view, "select[name='schedule[target]'] option[value='wifi:kitchen_tv']")
    end

    test "says why a row was refused, in the words the refusal used", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> form("form.new-sched",
          schedule: %{
            "label" => "nonsense",
            "cron" => "not a cron",
            "target" => @thermostat,
            "action" => "set_temperature",
            "args" => %{"temperature_f" => "68"}
          }
        )
        |> render_submit()

      assert Schedules.list_schedules() == []
      assert html =~ "cron"
      assert has_element?(view, ".new-sched .why")
    end
  end

  describe "changing a schedule" do
    test "pausing cancels the timer and takes the word off the board", %{conn: conn} do
      schedule = create!(label: "weeknight heat")
      {:ok, view, _html} = live(conn, "/admin")

      view |> element(".sched .acts button", "pause") |> render_click()

      refute Schedules.fetch(schedule.id) |> elem(1) |> Map.fetch!(:enabled)

      # No flap at all: none of the eight words means "somebody switched this
      # off", and bending one to fit would put a word on the board that means
      # two things. The row goes quiet and the button says resume.
      assert has_element?(view, ".sched.paused")
      refute has_element?(view, ".sched .flap")
      assert has_element?(view, ".sched .acts button", "resume")
    end

    test "deleting offers the row back for a moment", %{conn: conn} do
      create!(label: "weeknight heat")
      {:ok, view, _html} = live(conn, "/admin")

      view |> element(".sched .acts button", "delete") |> render_click()

      assert Schedules.list_schedules() == []
      assert has_element?(view, ".admin .undo", "weeknight heat")

      # The same bargain the cards make, and for the same reason: a confirm
      # dialog would be the other answer, and this surface has decided against
      # training people to dismiss them.
      view |> element(".admin .undo button") |> render_click()

      assert [restored] = Schedules.list_schedules()
      assert restored.label == "weeknight heat"
      assert restored.args == %{"temperature_f" => 70.0}

      # And it is a schedule again, not just a row: the timer is rebuilt from
      # the rows at every write.
      assert SchedulerAgent.unregistered() == []
      refute has_element?(view, ".admin .undo")
    end
  end

  describe "the feed" do
    test "is the full record, including what the thread leaves out", %{conn: conn} do
      {:ok, _entry} =
        Activity.record(%{
          kind: "device_changed",
          device: "wifi:office_printer",
          action: "state_changed",
          result: %{"online" => false}
        })

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".feed .entry .kind", "device_changed")
      assert has_element?(view, ".feed .entry .what", "wifi:office_printer")
    end

    test "takes new entries as they land, newest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      {:ok, entry} =
        Activity.record(%{kind: "control", actor: "greg, card", device: @thermostat})

      ActivityEvents.recorded(entry)

      assert eventually(fn -> has_element?(view, ".feed .entry .who", "greg, card") end)
      assert view |> element(".feed .entry:first-child .kind") |> render() =~ "control"
    end
  end

  describe "getting there" do
    test "the only way in is from the house", %{conn: conn} do
      {:ok, thread, _html} = live(conn, "/")

      # Admin is laptop-shaped and rarely visited, so it does not earn header
      # space on the surface a phone opens first.
      refute has_element?(thread, "a[href='/admin']")

      {:ok, house, _html} = live(conn, "/house")
      assert has_element?(house, "a.to-admin", "Admin")
    end
  end

  # The page as a fresh box serves it, and as a box whose house has been
  # emptied under schedules that were written against it.
  describe "panels with nothing in them" do
    # The one panel that used to answer a heading with a void, while the two
    # above it both said something.
    test "the feed says it has recorded nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".feed .note", "Nothing recorded yet")
    end

    test "the feed stops saying so at the first entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      {:ok, entry} =
        Activity.record(%{kind: "control", device: @thermostat, action: "set_temperature"})

      ActivityEvents.recorded(entry)

      assert eventually(fn -> has_element?(view, ".entry .what", "set_temperature") end)
      refute has_element?(view, ".feed .note")
    end

    # Two empty selects and an Add that could only ever be refused.
    test "a house with nothing schedulable is not offered the form", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = live(conn, "/admin")

      refute has_element?(view, "form.new-sched")
      assert has_element?(view, ".panel .note", "Nothing in this house can be scheduled")

      # One line, and the stronger of the two: a house with nothing schedulable
      # obviously has nothing scheduled.
      refute has_element?(view, ".panel .note", "Nothing is scheduled")
    end

    # The sentence used to end on a colon and stop, which reads as truncated to
    # a person and tells the model even less.
    test "an unknown device names what the house does have, or that it has none",
         %{conn: conn} do
      create!(label: "weeknight heat")
      boot_house!([])

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".sched .why", "this house has no devices")
      refute has_element?(view, ".sched .why", "this house has:")
    end

    # An action on an existing schedule can fail, and its reason used to land
    # under the new-schedule form's last field, where it reads as a rejection
    # of what somebody is still typing.
    test "a failed action says so beside the schedules, not inside the form", %{conn: conn} do
      schedule = create!(label: "weeknight heat")
      boot_house!([])

      {:ok, view, _html} = live(conn, "/admin")

      view |> element("button[phx-value-id='#{schedule.id}']", "pause") |> render_click()

      assert has_element?(view, ".panel > .why", "unknown device")
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp create!(overrides) do
    attrs =
      %{
        label: "weeknight heat",
        cron: "0 20 * * 1-5",
        timezone: Dobby.Home.manifest().timezone,
        target: @thermostat,
        action: "set_temperature",
        args: %{"temperature_f" => 70},
        created_by: "greg",
        created_via: :conversation
      }
      |> Map.merge(Map.new(overrides))

    {:ok, schedule} = Schedules.create_schedule(attrs)
    schedule
  end

  defp named(conn, name) do
    post(conn, "/speaker", %{"name" => name, "return_to" => "/admin"})
  end
end
