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
  alias Dobby.Health
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

    # The row used to say AWAKE for a client that was up and reconnecting,
    # which is a process being there rather than a house answering. It reads
    # the same fact the topology panel does, so the two cannot disagree.
    test "a client that is up and not connected is not awake" do
      assert %{word: "Awake", state: :acting} = home_assistant_row()

      Fake.set_connection(:reconnecting)

      assert %{word: "Quiet", state: :silent} = home_assistant_row()
    end
  end

  # A live diagram of the house's mind: what commands what, what is running,
  # and what it currently says. Not the OTP tree — that is a flat fan by
  # design, and it says nothing about who commands whom.
  describe "the topology" do
    test "draws a node for every device in the manifest", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, "section.panel.topology h2", "Topology")

      for id <- ["thermostat:main", "light:living_room", "vacuum:robo", "wifi:kitchen_tv"] do
        assert has_element?(view, ".tier.devices .topo-node[data-part='#{id}']")
      end

      # The two directors and the one client every device speaks through.
      assert has_element?(view, ".tier.directors .topo-node[data-part='dobby']")
      assert has_element?(view, ".tier.directors .topo-node[data-part='scheduler']")
      assert has_element?(view, ".tier.house .topo-node[data-part='home_assistant']")
    end

    # Which is the whole of §1.1 said in two words, on the page rather than in
    # a document nobody on a laptop at 11pm is going to open.
    test "says which half of itself is probabilistic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".topo-node[data-part='dobby'] .note", "Probabilistic")
      assert has_element?(view, ".topo-node[data-part='scheduler'] .note", "Deterministic")
    end

    # Configuration, never process introspection: the roster's tools, the
    # schedule rows, and the manifest's entity bindings.
    test "wires the directors to what they can actually command", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".wire[data-from='dobby'][data-to='#{@thermostat}']")
      assert has_element?(view, ".wire[data-from='#{@thermostat}'][data-to='home_assistant']")

      # Nothing is scheduled, so the scheduler commands nothing. A wire drawn
      # anyway would claim a path that cannot fire.
      refute has_element?(view, ".wire[data-from='scheduler']")
    end

    test "the scheduler's wire appears with the schedule that draws it", %{conn: conn} do
      create!(label: "weeknight heat")

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".wire[data-from='scheduler'][data-to='#{@thermostat}']")

      view |> element(".sched .acts button", "pause") |> render_click()

      # A paused schedule has no timer, and the drawing says so the way the
      # row beneath it does — by not claiming otherwise.
      refute has_element?(view, ".wire[data-from='scheduler'][data-to='#{@thermostat}']")
    end

    test "a device node says what the device says", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      node = ".topo-node[data-part='#{@thermostat}']"

      # The seed is 66 heading for 70, and WARMING is what the card on /house
      # says about that — the node reads through the same function on purpose.
      assert has_element?(view, "#{node} .flap[data-st=acting]", "Warming")
      assert has_element?(view, "#{node} .val", "70°")
    end

    test "the scheduler node carries the timer count and the missing ones", %{conn: conn} do
      create!(label: "weeknight heat")

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".topo-node[data-part='scheduler'] .note", "1 timer")
      refute has_element?(view, ".topo-node[data-part='scheduler'] .note.wrong")

      # The most useful fact on the page, on the node it is about: a row
      # accepted at authoring time and then rejected by the timer.
      SchedulerAgent.clear()
      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".topo-node[data-part='scheduler'] .note.wrong", "1 without a timer")
    end

    # Liveness by monitor, not by asking: a `:DOWN` flips the node, and a
    # re-lookup catches the supervisor putting the agent back. A restart is
    # visibly a restart.
    @tag :capture_log
    test "a device agent that dies reads down, and comes back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      node = ".topo-node[data-part='#{@thermostat}']"
      assert has_element?(view, "#{node} .flap[data-st=acting]", "Warming")

      Process.exit(Dobby.Jido.whereis(@thermostat), :kill)

      assert eventually(fn -> has_element?(view, "#{node} .flap[data-st=silent]", "Quiet") end)

      # And back — knowing nothing, because a restarted agent came back with
      # the state it was built with and Home Assistant has not spoken since.
      assert eventually(fn -> has_element?(view, "#{node} .flap", "Not known") end)
      assert is_pid(Dobby.Jido.whereis(@thermostat))
    end

    test "Dobby's node goes quiet with Dobby", %{conn: conn} do
      Dobby.Jido.stop_agent(Dobby.DobbyAgent.id())

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".topo-node[data-part='dobby'] .flap[data-st=silent]", "Quiet")
    end

    # The connection is a fact about the world, not about the process, and it
    # arrives as a transition rather than being asked for — the client spends
    # its bad minutes blocked in a connect, which is exactly when a synchronous
    # status call would be waited on.
    test "a lost connection to Home Assistant reaches the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      house = ".topo-node[data-part='home_assistant']"
      assert has_element?(view, "#{house} .flap[data-st=acting]", "Awake")

      Fake.set_connection(:reconnecting)

      assert eventually(fn -> has_element?(view, "#{house} .flap[data-st=silent]", "Quiet") end)
      assert has_element?(view, "#{house} .note", "Trying again")

      Fake.set_connection(:connected)

      assert eventually(fn -> has_element?(view, "#{house} .flap[data-st=acting]", "Awake") end)
      refute has_element?(view, "#{house} .note", "Trying again")
    end

    # State once at mount and PubSub after it. The event carries the snapshot,
    # so the node is updated from what arrived rather than by asking the agent
    # that just told us.
    test "takes device state from the topic, not from the agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      node = ".topo-node[data-part='#{@thermostat}']"
      assert has_element?(view, "#{node} .val", "70°")

      Fake.inject_state_changed(@entity, thermostat_entity(current: 66, target: 64))

      assert eventually(fn -> has_element?(view, "#{node} .val", "64°") end)
    end

    test "a house with nothing in it says so", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = live(conn, "/admin")

      assert has_element?(view, ".topo .note", "No devices")
      refute has_element?(view, ".tier.devices")
      refute has_element?(view, ".wire")
    end

    # Step two: the feed, said on the drawing. Each recorded entry lights the
    # wire it names, and it can only light a wire the drawing already has —
    # the map from entry to edge is the map the wires were drawn from.
    test "traffic lights the wire it travelled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      refute has_element?(view, ".wire.pulse")

      # A state change reaches the feed through the watcher, and pulses the
      # device's own line to the house.
      Fake.inject_state_changed(@entity, thermostat_entity(current: 67, target: 70))

      house_wire = ".wire[data-from='#{@thermostat}'][data-to='home_assistant']"
      assert eventually(fn -> has_element?(view, "#{house_wire}.pulse") end)

      # A tool call is Dobby's doing, and pulses the command wire instead.
      {:ok, _entry} =
        Activity.record(%{
          kind: "tool_call",
          actor: "dobby",
          device: @thermostat,
          action: "thermostat_get_status"
        })

      command_wire = ".wire[data-from='dobby'][data-to='#{@thermostat}']"
      assert eventually(fn -> has_element?(view, "#{command_wire}.pulse") end)
    end

    # People are deliberately not on this drawing, so what a person said
    # cannot light anything.
    test "a request pulses no wire", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      {:ok, _entry} = Activity.record(%{kind: "request", actor: "greg", action: "ask"})

      assert eventually(fn -> has_element?(view, ".feed .entry .kind", "request") end)
      refute has_element?(view, ".wire.pulse")
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

      # The kind is stored with an underscore and read as a label — see
      # `AdminLive.kind/1` and The Identifier Rule.
      assert has_element?(view, ".feed .entry .kind", "device changed")
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

  # The one part of the responsive work that lives in markup rather than in the
  # stylesheet, and the coupling is easy to break by copying another route's
  # header: admin is the only page with two columns of content, so it is the
  # only page whose nameplate centres on the wider measure. Without the class
  # the name floats in the middle of the panels beneath it.
  test "admin's header is the wide one", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")

    assert has_element?(view, "header.board.board-admin")

    {:ok, thread, _html} = live(conn, "/")
    refute has_element?(thread, ".board-admin")
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

  defp home_assistant_row do
    Enum.find(Health.rows(), &(&1.name == "Home Assistant"))
  end
end
