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
  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Writer
  alias Dobby.SchedulerAgent
  alias Dobby.Schedules

  @endpoint DobbyWeb.Endpoint

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @lock "lock:front"

  setup do
    seed_house(%{@entity => thermostat_entity(current: 66, target: 70)})

    %{conn: build_conn()}
  end

  describe "health" do
    test "says whether each part of the house is actually there", %{conn: conn} do
      {:ok, view, _html} = open(conn, :health)

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

      {:ok, view, _html} = open(conn, :health)

      assert has_element?(view, ".panel .rows .row .flap[data-st=silent]", "Quiet")
      assert has_element?(view, ".plate .flap[data-st=silent]", "Quiet")
    end

    # "That can run", not "enabled": `unregistered` measures the schedules that
    # are enabled *and* still able to reach their device, so the wider claim
    # reads as a flat contradiction of a HELD row two lines below it.
    test "empty says so rather than showing nothing", %{conn: conn} do
      {:ok, view, _html} = open(conn, :health)

      assert has_element?(view, ".panel .note", "Every schedule that can run has a timer")
    end

    # The most useful row on the page: a schedule accepted at authoring time
    # and then rejected by the timer looks, from every other angle, exactly
    # like one that works.
    test "names the enabled schedules that have no timer", %{conn: conn} do
      create!(label: "weeknight heat")
      SchedulerAgent.clear()

      {:ok, view, _html} = open(conn, :health)

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
      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".rail a.on", "Topology")

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
      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".topo-node[data-part='dobby'] .note", "Probabilistic")
      assert has_element?(view, ".topo-node[data-part='scheduler'] .note", "Deterministic")
    end

    # Configuration, never process introspection: the roster's tools, the
    # schedule rows, and the manifest's entity bindings.
    test "wires the directors to what they can actually command", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".wire[data-from='dobby'][data-to='#{@thermostat}']")
      assert has_element?(view, ".wire[data-from='#{@thermostat}'][data-to='home_assistant']")

      # Nothing is scheduled, so the scheduler commands nothing. A wire drawn
      # anyway would claim a path that cannot fire.
      refute has_element?(view, ".wire[data-from='scheduler']")
    end

    test "the scheduler's wire appears with the schedule that draws it", %{conn: conn} do
      create!(label: "weeknight heat")

      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".wire[data-from='scheduler'][data-to='#{@thermostat}']")

      view |> element(".rail a", "Schedules") |> render_click()
      view |> element(".sched .acts button", "pause") |> render_click()
      view |> element(".rail a", "Topology") |> render_click()

      # A paused schedule has no timer, and the drawing says so the way the
      # row beneath it does — by not claiming otherwise.
      refute has_element?(view, ".wire[data-from='scheduler'][data-to='#{@thermostat}']")
    end

    test "a device node says what the device says", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

      node = ".topo-node[data-part='#{@thermostat}']"

      # The seed is 66 heading for 70, and WARMING is what the card on /house
      # says about that — the node reads through the same function on purpose.
      assert has_element?(view, "#{node} .flap[data-st=acting]", "Warming")
      assert has_element?(view, "#{node} .val", "70°")
    end

    test "the scheduler node carries the timer count and the missing ones", %{conn: conn} do
      create!(label: "weeknight heat")

      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".topo-node[data-part='scheduler'] .note", "1 timer")
      refute has_element?(view, ".topo-node[data-part='scheduler'] .note.wrong")

      # The most useful fact on the page, on the node it is about: a row
      # accepted at authoring time and then rejected by the timer.
      SchedulerAgent.clear()
      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(
               view,
               ".topo-node[data-part='scheduler'] .note.wrong",
               "1 without a timer"
             )
    end

    # Liveness by monitor, not by asking: a `:DOWN` flips the node, and a
    # re-lookup catches the supervisor putting the agent back. A restart is
    # visibly a restart.
    @tag :capture_log
    test "a device agent that dies reads down, and comes back", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

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

      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".topo-node[data-part='dobby'] .flap[data-st=silent]", "Quiet")
    end

    # The connection is a fact about the world, not about the process, and it
    # arrives as a transition rather than being asked for — a client that has
    # died cannot answer a status call, and that is the moment the panel most
    # needs to be right.
    test "a lost connection to Home Assistant reaches the panel", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

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
      {:ok, view, _html} = open(conn, :topology)

      node = ".topo-node[data-part='#{@thermostat}']"
      assert has_element?(view, "#{node} .val", "70°")

      Fake.inject_state_changed(@entity, thermostat_entity(current: 66, target: 64))

      assert eventually(fn -> has_element?(view, "#{node} .val", "64°") end)
    end

    test "a house with nothing in it says so", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = open(conn, :topology)

      assert has_element?(view, ".topo .note", "No devices")
      refute has_element?(view, ".tier.devices")
      refute has_element?(view, ".wire")
    end

    # Step two: the feed, said on the drawing. Each recorded entry lights the
    # wire it names, and it can only light a wire the drawing already has —
    # the map from entry to edge is the map the wires were drawn from.
    test "traffic lights the wire it travelled", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

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

      # A command Home Assistant never answered is still an answer about that
      # wire, so it lights the same device-to-house line an accepted call
      # went out on.
      lock_wire = ".wire[data-from='#{@lock}'][data-to='home_assistant']"
      refute has_element?(view, "#{lock_wire}.pulse")

      {:ok, _entry} =
        Activity.record(%{
          kind: "command_never_arrived",
          device: @lock,
          action: "lock.secure",
          result: %{"timeout_ms" => 1_000}
        })

      assert eventually(fn -> has_element?(view, "#{lock_wire}.pulse") end)
    end

    # People are deliberately not on this drawing, so what a person said
    # cannot light anything.
    test "a request pulses no wire", %{conn: conn} do
      {:ok, view, _html} = open(conn, :topology)

      {:ok, entry} = Activity.record(%{kind: "request", actor: "greg", action: "ask"})

      # The feed used to be the proof this had been handled, and the feed is a
      # different section now. The same entry, sent straight to the view: a
      # message put in the mailbox here is ahead of the render that follows it,
      # which a broadcast on its own does not promise.
      send(view.pid, {:recorded, entry})
      render(view)

      refute has_element?(view, ".wire.pulse")
    end
  end

  describe "the schedule form" do
    test "writes a row, registers its timer, and attributes it", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/admin?section=schedules")

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
      {:ok, view, _html} = open(conn, :schedules)

      assert has_element?(view, "input[name='schedule[args][temperature_f]'][type=number]")
      assert has_element?(view, "select[name='schedule[target]'] option[value='#{@thermostat}']")

      # A read-only device is left out rather than offered and then refused.
      refute has_element?(view, "select[name='schedule[target]'] option[value='wifi:kitchen_tv']")
    end

    test "says why a row was refused, in the words the refusal used", %{conn: conn} do
      {:ok, view, _html} = open(conn, :schedules)

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
      {:ok, view, _html} = open(conn, :schedules)

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
      {:ok, view, _html} = open(conn, :schedules)

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

  # The box rather than the house: the model behind the `:capable` alias, the
  # port, whether Dobby answers on the household network. Every field on it is
  # drawn from the section's own schema, so a knob added there grows a field
  # here and nowhere else.
  describe "the system panel" do
    test "has a field for every knob the schema declares, and no others", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      assert has_element?(view, ".rail a.on", "System")

      for {key, _spec} <- HomeConfig.System.schema() do
        assert has_element?(view, ".system .field .arg", Atom.to_string(key))
      end

      # And nothing else: a field on this panel that is not in the schema would
      # be a hand-built form growing back.
      assert settings(view) == length(HomeConfig.System.schema())
    end

    # The rig boots from `config/homes/rig.exs`, the writer will not write
    # Elixir, and that is the ordinary case on a developer's machine rather than
    # an edge. So the panel says why, and names the file the settings do live in.
    test "an Elixir house is read-only, and says so in one sentence", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      # No form at all, rather than one that could only ever be refused — the
      # call this page already makes about a house with nothing schedulable.
      refute has_element?(view, "form#system")
      refute has_element?(view, ".system input")

      assert has_element?(view, ".system .note", "does not write")
      assert has_element?(view, ".system .note .file", "config/homes/rig.exs")
    end

    # A knob the file does not mention is a knob at Dobby's own default, and
    # that is a reading. Deliberately not `NOT SET`, which in capitals would be
    # a ninth word on a board with eight — one letter from `NOT KNOWN`, which
    # means something else.
    test "a knob the file does not mention reads as a default", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      assert has_element?(view, ".system .field .reading.unset", "default")

      # A boolean always has a value, so it never reads that way.
      assert has_element?(view, ".system .field .reading", "no")
    end

    # The schema's `:doc` was written for whoever edits the file by hand. It has
    # a second reader now, which is the whole of "a new knob costs a schema
    # entry and nothing else".
    test "explains each knob in the schema's own words", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      assert has_element?(view, ".system .field .ask", "capable")

      # And without the Markdown it was written in: a backtick painted on this
      # board is a stray mark.
      refute view |> element(".system") |> render() =~ "`"
    end

    test "says so rather than showing nothing when there is no writer", %{conn: conn} do
      Application.put_env(:dobby, :home_config_writer, :no_writer_here)
      on_exit(fn -> Application.delete_env(:dobby, :home_config_writer) end)

      {:ok, view, _html} = open(conn, :system)

      assert has_element?(view, ".system .note", "has not been read")
      refute has_element?(view, ".system .setting")
    end
  end

  # The other half, and the one a household actually has: a YAML house is an
  # editable house. The writer under this panel holds a file of the test's own,
  # so what lands on disk can be read back and read back from.
  describe "the system panel, on a house Dobby can write" do
    setup :editable_house

    test "offers a box for every knob, typed by the schema", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      assert has_element?(view, "form#system")
      assert has_element?(view, "input[name='system[model]'][type=text]")
      assert has_element?(view, "input[name='system[port]'][type=number]")
      assert has_element?(view, "input[name='system[hostname]'][type=text]")

      # Two words rather than a checkbox: a tick is an icon, and this board says
      # things in words.
      assert has_element?(view, "select[name='system[lan]'] option[value=true]", "yes")
      refute has_element?(view, ".system input[type=checkbox]")

      # A closed set of words is offered as those words, with a blank for the
      # default: the board offers what the file accepts instead of refusing
      # what was typed.
      assert has_element?(view, "select[name='system[reasoning]'] option[value='']", "default")
      assert has_element?(view, "select[name='system[reasoning]'] option[value=low]", "low")
      assert has_element?(view, "select[name='system[routing]'] option[value=latency]", "latency")
    end

    # How the model answers is read on every request, like the alias, so it is
    # the other setting a save can honestly say is in effect now.
    test "how the model answers takes effect now, from the panel", %{conn: conn} do
      previous = Application.get_env(:dobby, :llm_opts)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:dobby, :llm_opts, previous),
          else: Application.delete_env(:dobby, :llm_opts)
      end)

      with_env("DOBBY_MODEL", nil)

      {:ok, view, _html} = open(conn, :system)

      view
      |> form("form#system", system: %{"reasoning" => "low", "routing" => "latency"})
      |> render_submit()

      assert has_element?(view, ".field .effect", "In effect now")
      refute has_element?(view, ".field .effect.waiting")

      assert Application.get_env(:dobby, :llm_opts) ==
               [reasoning_effort: :low, openrouter_provider: %{sort: "latency"}]
    end

    # The other half of the same honesty, and the door the boot check does not
    # close: boot refuses a house whose settings the model in force cannot be
    # sent, and boot was hours ago (TK-037). So the save does not take, and the
    # field says what outranked it — an export in a shell is the one place the
    # person editing this panel will not think to look.
    test "a setting the model in force cannot take does not take, and the field says why", %{
      conn: conn
    } do
      previous = Application.get_env(:dobby, :llm_opts)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:dobby, :llm_opts, previous),
          else: Application.delete_env(:dobby, :llm_opts)
      end)

      with_env("DOBBY_MODEL", "openai:gpt-5.6-luna")
      Application.put_env(:dobby, :llm_opts, reasoning_effort: :low)

      {:ok, view, _html} = open(conn, :system)

      view |> form("form#system", system: %{"routing" => "latency"}) |> render_submit()

      assert has_element?(view, ".field .effect.waiting")
      refute has_element?(view, ".field .effect", "In effect now")

      said = view |> element(".system") |> render()
      assert said =~ "routing: latency"
      assert said =~ "openai:gpt-5.6-luna"
      assert said =~ "exported as DOBBY_MODEL"

      assert Application.get_env(:dobby, :llm_opts) == [reasoning_effort: :low]
    end

    # The `:capable` alias is the one setting read at the moment it is used,
    # which is exactly why design §2.1 made the agent name an alias.
    test "a change that took effect says so on the field it took effect on", %{conn: conn} do
      previous = Application.get_env(:jido_ai, :model_aliases)
      on_exit(fn -> Application.put_env(:jido_ai, :model_aliases, previous) end)
      with_env("DOBBY_MODEL", nil)

      {:ok, view, _html} = open(conn, :system)

      view |> form("form#system", system: %{"model" => "openai:gpt-5.6-luna"}) |> render_submit()

      assert has_element?(view, ".field .effect", "In effect now")
      refute has_element?(view, ".field .effect.waiting")

      assert Application.get_env(:jido_ai, :model_aliases) == %{capable: "openai:gpt-5.6-luna"}
    end

    # And the honest half: a port belongs to a socket opened at boot, and no
    # amount of writing the file moves it. The panel says which, per field,
    # rather than one line underneath claiming the whole save worked.
    test "a change that cannot take effect yet says it is waiting", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      view
      |> form("form#system", system: %{"port" => "4100", "lan" => "true"})
      |> render_submit()

      assert has_element?(view, ".field .effect.waiting", "Waiting for a restart")

      # Two fields waiting, and each says so where it is — the port and the LAN
      # binding are two settings, not one save.
      assert view |> element(".system") |> render() =~
               ~r/Waiting for a restart.*Waiting for a restart/s

      # The socket is where it was: a written port is a written port.
      assert DobbyWeb.Endpoint.config(:http)[:port] == 4002
    end

    test "what it writes is what the file says, and what the panel then shows", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = open(conn, :system)

      view |> form("form#system", system: %{"hostname" => "greg.local"}) |> render_submit()

      assert {:ok, written} = HomeConfig.load(path)
      assert written.system.hostname == "greg.local"

      assert has_element?(view, "input[name='system[hostname]'][value='greg.local']")
    end

    # An empty box is not a value: a field somebody cleared is a field the file
    # should stop mentioning, so the built-in default comes back rather than an
    # empty string being written down as though somebody had chosen one.
    test "a box somebody emptied stops being mentioned in the file", %{conn: conn, path: path} do
      {:ok, view, _html} = open(conn, :system)

      view |> form("form#system", system: %{"hostname" => "greg.local"}) |> render_submit()
      view |> form("form#system", system: %{"hostname" => ""}) |> render_submit()

      assert {:ok, written} = HomeConfig.load(path)
      assert written.system.hostname == nil
      refute File.read!(path) =~ "hostname"
    end

    # The refusal is the schema's own, naming the field. Nothing on the surface
    # writes a second message for the same mistake.
    test "a value the schema refuses is refused by name, and the file keeps what it had", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = open(conn, :system)
      original = File.read!(path)

      view |> form("form#system", system: %{"port" => "the kitchen one"}) |> render_submit()

      assert has_element?(view, ".fields .why", "port")
      assert File.read!(path) == original

      # And what was typed stays where it was, beside the reason it was refused.
      assert has_element?(view, "input[name='system[port]'][value='the kitchen one']")
    end

    test "a hostname that could become shell syntax is refused", %{conn: conn, path: path} do
      {:ok, view, _html} = open(conn, :system)
      original = File.read!(path)

      view
      |> form("form#system", system: %{"hostname" => "dobby.local'; touch /tmp/nope; '"})
      |> render_submit()

      assert has_element?(view, ".fields .why", "system.hostname")
      assert File.read!(path) == original
    end

    # Always current with the applied configuration, which is what buys v1 out
    # of needing a file watcher: an open page follows a change made anywhere.
    test "follows a change made somewhere other than this browser", %{conn: conn, writer: writer} do
      {:ok, view, _html} = open(conn, :system)

      config = Writer.current(writer)
      system = struct!(config.system, hostname: "elsewhere.local")
      {:ok, _applied} = Writer.save(writer, %{config | system: system})

      assert eventually(fn ->
               has_element?(view, "input[name='system[hostname]'][value='elsewhere.local']")
             end)

      assert has_element?(view, ".field .effect.waiting")
    end
  end

  describe "the tokens panel" do
    # The whole life of a key, in one pass: minted with a label, the plaintext
    # on screen exactly once beside the sentence saying so, listed by label,
    # refused a twin, revoked. Deliberately no undo test — there is no undo,
    # because the plaintext is exactly what Dobby does not keep.
    test "mints with a label, shows the plaintext once, and revokes", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      # Empty says what it means rather than showing nothing.
      assert has_element?(view, ".tokens .note", "No tokens")

      html =
        view
        |> form("#new-token", %{"token" => %{"label" => "the kitchen laptop"}})
        |> render_submit()

      # The plaintext is on screen, the sentence says it will not come back —
      # and it is a real key: the digest Dobby kept verifies it.
      assert html =~ "it will not be shown again"

      assert [_whole, plaintext] =
               Regex.run(~r|<span class="arg">([A-Za-z0-9_-]{43})</span>|, html)

      assert Dobby.MCP.verify(plaintext) == {:ok, "the kitchen laptop"}

      assert has_element?(view, ".tokens .row .name", "the kitchen laptop")

      # Leaving the system room is the revisit boundary promised beside the
      # plaintext. Coming back can list the label but cannot reveal the key.
      view |> element(".rail a", "Activity") |> render_click()
      assert_patched(view, "/admin?section=activity")
      view |> element(".rail a", "System") |> render_click()
      assert_patched(view, "/admin?section=system")
      refute render(view) =~ plaintext

      # A label names exactly one key, and the refusal is the row's own words.
      view
      |> form("#new-token", %{"token" => %{"label" => "the kitchen laptop"}})
      |> render_submit()

      assert has_element?(view, ".tokens .why", "already a token")
      refute render(view) =~ plaintext

      [token] = Dobby.MCP.list()

      view
      |> element(~s{.tokens button[phx-value-id="#{token.id}"]}, "revoke")
      |> render_click()

      refute has_element?(view, ".tokens .row .name", "the kitchen laptop")
      assert has_element?(view, ".tokens .note", "No tokens")
      assert Dobby.MCP.list() == []
      assert Dobby.MCP.verify(plaintext) == :error
    end

    test "refuses an overlong label and a malformed revoke id", %{conn: conn} do
      {:ok, view, _html} = open(conn, :system)

      view
      |> form("#new-token", %{"token" => %{"label" => String.duplicate("a", 121)}})
      |> render_submit()

      assert has_element?(view, ".tokens .why", "at most 120")
      assert Dobby.MCP.list() == []

      render_click(view, "revoke", %{"id" => "not-an-id"})

      assert has_element?(view, ".tokens .why", "not a token id")
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

      {:ok, view, _html} = open(conn, :activity)

      # The kind is stored with an underscore and read as a label — see
      # `AdminLive.kind/1` and The Identifier Rule.
      assert has_element?(view, ".feed .entry .kind", "device changed")
      assert has_element?(view, ".feed .entry .what", "wifi:office_printer")
    end

    test "takes new entries as they land, newest first", %{conn: conn} do
      {:ok, view, _html} = open(conn, :activity)

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
      {:ok, view, _html} = open(conn, :activity)

      assert has_element?(view, ".feed .note", "Nothing recorded yet")
    end

    test "the feed stops saying so at the first entry", %{conn: conn} do
      {:ok, view, _html} = open(conn, :activity)

      {:ok, entry} =
        Activity.record(%{kind: "control", device: @thermostat, action: "set_temperature"})

      ActivityEvents.recorded(entry)

      assert eventually(fn -> has_element?(view, ".entry .what", "set_temperature") end)
      refute has_element?(view, ".feed .note")
    end

    # Two empty selects and an Add that could only ever be refused.
    test "a house with nothing schedulable is not offered the form", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = open(conn, :schedules)

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

      {:ok, view, _html} = open(conn, :schedules)

      assert has_element?(view, ".sched .why", "this house has no devices")
      refute has_element?(view, ".sched .why", "this house has:")
    end

    # An action on an existing schedule can fail, and its reason used to land
    # under the new-schedule form's last field, where it reads as a rejection
    # of what somebody is still typing.
    test "a failed action says so beside the schedules, not inside the form", %{conn: conn} do
      schedule = create!(label: "weeknight heat")
      boot_house!([])

      {:ok, view, _html} = open(conn, :schedules)

      view |> element("button[phx-value-id='#{schedule.id}']", "pause") |> render_click()

      assert has_element?(view, ".panel > .why", "unknown device")
    end
  end

  # ── the rail ──────────────────────────────────────────────────────────────
  #
  # Five sections and one at a time. What this replaces is a page whose two
  # columns shared a scroll container, so a hundred entries of log dragged the
  # three panels you came to change off the top of the screen.
  describe "the rail" do
    test "opens on the map, and every section is one link away", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      # No section named, so the map — the thing the other four are asked
      # about.
      assert has_element?(view, ".rail a.on", "Topology")
      assert has_element?(view, ".panel.topology")

      for section <- ~w(topology health schedules system activity) do
        assert has_element?(view, ".rail a[href='/admin?section=#{section}']")
      end
    end

    test "one section shows at a time", %{conn: conn} do
      {:ok, view, _html} = open(conn, :schedules)

      assert has_element?(view, "form#new-schedule")
      refute has_element?(view, ".panel.topology")
      refute has_element?(view, "#activity")
    end

    # The address carries it, not an assign — a LiveView that loses its socket
    # remounts on the URL it is on, so a page left open on the feed comes back
    # to the feed rather than to the map.
    test "the section is in the address", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")

      view |> element(".rail a", "Activity") |> render_click()

      assert_patched(view, "/admin?section=activity")
      assert has_element?(view, ".rail a.on", "Activity")
      assert has_element?(view, "#activity")
    end

    # A word nobody serves is the map, because that is the honest default for
    # a page whose other four sections are questions asked about it.
    test "a section nobody has is the map", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin?section=nonsense")

      assert has_element?(view, ".rail a.on", "Topology")
    end

    # The rail carries every section name now, so a panel repeating its own
    # would be the same heading printed twice on one screen.
    test "no panel repeats the name the rail gave it", %{conn: conn} do
      for section <- ~w(topology health schedules system activity) do
        {:ok, _view, html} = live(conn, "/admin?section=#{section}")

        refute html =~ "<h2>"
      end
    end
  end

  # The feed is in the DOM only while its own section is showing, so an entry
  # arriving behind another section has nowhere to land. The section re-reads
  # on the way in rather than a hundred rows being held open for nobody.
  describe "the feed behind another section" do
    test "an entry recorded elsewhere is there when the feed is opened", %{conn: conn} do
      {:ok, view, _html} = open(conn, :health)

      {:ok, entry} =
        Activity.record(%{kind: "control", device: @thermostat, action: "set_temperature"})

      ActivityEvents.recorded(entry)

      view |> element(".rail a", "Activity") |> render_click()

      assert has_element?(view, ".entry .what", "set_temperature")
    end
  end

  # `delete` and `pause` sit in one row, a finger apart, and were drawn
  # identically. The gap under a coarse pointer keeps a tap from landing on the
  # wrong one; this keeps the eye from reading them as the same offer.
  describe "what a verb looks like" do
    test "deleting a schedule is drawn as taking something away", %{conn: conn} do
      create!(label: "weeknight heat")

      {:ok, view, _html} = open(conn, :schedules)

      assert has_element?(view, ".sched .acts button.takes", "delete")
      refute has_element?(view, ".sched .acts button.takes", "pause")
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Which section this test is about. The page shows one at a time, so a test
  # that does not say lands on the map and finds nothing it came for.
  defp open(conn, section), do: live(conn, "/admin?section=#{section}")

  # A house Dobby can write, which the rig's Elixir home is not. The writer is
  # the test's own, pointed at a file in a temporary directory, and the panel
  # reaches it the way the application's own writer is reached — by name, which
  # is what `Writer.server/0` exists to answer.
  #
  # The house in it is a valid one and it is never changed here: the system
  # section is what this panel edits, and a save that leaves the house alone
  # does not restart the house.
  @editable_house """
  house:
    id: rig
    name: Rig Home
    timezone: America/New_York
    home_assistant:
      url: http://fake.invalid:8123
      token: env:DOBBY_ADMIN_LIVE_TEST_HA_TOKEN
    devices: []
  """

  defp settings(view) do
    view
    |> element(".system")
    |> render()
    |> then(&Regex.scan(~r/class="field"/, &1))
    |> length()
  end

  defp editable_house(_context) do
    previous_token = System.get_env("DOBBY_ADMIN_LIVE_TEST_HA_TOKEN")
    System.put_env("DOBBY_ADMIN_LIVE_TEST_HA_TOKEN", "fake")

    on_exit(fn ->
      if previous_token do
        System.put_env("DOBBY_ADMIN_LIVE_TEST_HA_TOKEN", previous_token)
      else
        System.delete_env("DOBBY_ADMIN_LIVE_TEST_HA_TOKEN")
      end
    end)

    path = Path.join(System.tmp_dir!(), "admin-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, @editable_house)

    name = :"admin_writer_#{System.unique_integer([:positive])}"
    writer = start_supervised!({Writer, path: path, name: name})

    Application.put_env(:dobby, :home_config_writer, name)

    on_exit(fn ->
      Application.delete_env(:dobby, :home_config_writer)
      File.rm(path)
    end)

    %{path: path, writer: writer, conn: build_conn()}
  end

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
