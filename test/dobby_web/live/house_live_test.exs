defmodule DobbyWeb.HouseLiveTest do
  @moduledoc """
  The cards, against the real house.

  The deterministic surface end to end: a control reaches a device agent, the
  agent decides, Home Assistant moves, and the state comes back around the
  physical confirm loop — with no model anywhere in it. That is what makes
  these tests possible at all in a tier where the model is unreachable by
  configuration, and it is the same property that makes the page the fallback
  when the model is down.
  """

  use Dobby.RigCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Writer
  alias Dobby.Schedules
  alias Dobby.ThreadEvents

  @endpoint DobbyWeb.Endpoint

  @thermostat "thermostat:main"
  @light "light:living_room"
  @entity "climate.main_floor"
  @tv "binary_sensor.kitchen_tv"

  # A house a machine can write, which the rig itself is not. Two devices on
  # purpose: one type that declares settings and one that declares none, so the
  # form is shown to be the type's rather than a form written for a thermostat.
  @editable """
  house:
    id: rig
    name: Rig Home
    timezone: America/New_York
    home_assistant:
      url: http://fake.invalid:8123
      token: env:DOBBY_HOUSE_LIVE_TEST_HA_TOKEN
    devices:
      - id: thermostat:main
        type: thermostat
        name: main thermostat
        bindings:
          climate: climate.main_floor
        settings:
          min_temperature_f: 60
          max_temperature_f: 76
      - id: light:living_room
        type: light
        name: living room light
        bindings:
          light: light.living_room
  """

  setup do
    seed_house(%{
      @entity => thermostat_entity(current: 66, target: 70),
      @tv => %{state: "on", attributes: %{}}
    })

    %{conn: build_conn()}
  end

  describe "the cards" do
    test "are board rows that grew a control", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      assert has_element?(view, "#card-thermostat\\:main .name", "main thermostat")
      assert has_element?(view, "#card-thermostat\\:main .val", "70°")
      assert has_element?(view, "#card-thermostat\\:main .flap[data-st=acting]", "Warming")

      # The other number. The band has no room for it and it is a different
      # fact, not the same one said twice.
      assert has_element?(view, "#card-thermostat\\:main .detail", "Room 66°")

      # One card per device, read-only ones included.
      assert has_element?(view, "#card-wifi\\:kitchen_tv .flap[data-st=acting]", "Awake")
    end

    test "offer a setpoint only inside what the device will accept", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      # The rig's household policy caps at 76 and the hardware reports 50-90.
      # A control that let you reach 85 would exist to be refused.
      assert has_element?(view, "#set-thermostat\\:main[min='60'][max='76'][value='70']")

      # A read-only device grows nothing.
      refute has_element?(view, "#set-wifi\\:kitchen_tv")
    end

    test "a device that has not reported has nothing to offer", %{conn: conn} do
      boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])

      {:ok, view, _html} = live(conn, "/house")

      # NOT KNOWN, not QUIET: nobody has told us, which is a different fact
      # from a device that stopped answering.
      assert has_element?(view, "#card-thermostat\\:main .flap[data-st=silent]", "Not known")
      refute has_element?(view, "#set-thermostat\\:main")
    end

    test "follow the house as it changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      Fake.inject_state_changed(@tv, %{state: "off", attributes: %{}})

      assert eventually(fn ->
               has_element?(view, "#card-wifi\\:kitchen_tv .flap[data-st=silent]", "Quiet")
             end)
    end
  end

  describe "turning the dial" do
    test "actuates the house and says who did it", %{conn: conn} do
      ThreadEvents.subscribe()
      {:ok, view, _html} = live(named(conn, "greg"), "/house")

      release(view, @thermostat, "72")

      assert_receive {:ha_call, %HACall{entity_id: @entity, data: %{temperature: 72.0}}}, 2_000

      assert_receive {:system_line, %{text: "main thermostat", meta: meta}}
      assert meta["via"] == "greg, card"
      assert meta["value"] == "72°"
    end

    # No model anywhere in the path — which is the whole reason this surface is
    # first-class rather than a fallback (TK-001).
    test "spends no tokens doing it", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/house")
      Trace.reset()

      release(view, @thermostat, "72")

      assert_receive {:ha_call, %HACall{}}, 2_000
      assert Trace.llm_calls() == []
      assert Trace.tool_calls() == []
    end

    test "offers a way back for a moment afterwards", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/house")

      release(view, @thermostat, "72")

      assert has_element?(view, "#card-thermostat\\:main .undo", "back to 70°")

      # And going back is a command like any other, so it announces itself the
      # same way. Two lines in the thread for one mistake is the honest count.
      ThreadEvents.subscribe()
      view |> element("#card-thermostat\\:main .undo button") |> render_click()

      assert_receive {:system_line, %{meta: %{"value" => "70°", "via" => "greg, card"}}}
      refute has_element?(view, "#card-thermostat\\:main .undo")
    end

    test "a refusal stays on the card, with the reason beside it", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/house")

      # The fader cannot reach this; a crafted event can, and the card must
      # still tell the truth rather than assume its own control was obeyed.
      release(view, @thermostat, "85")

      assert has_element?(view, "#card-thermostat\\:main .held .flap[data-st=refused]", "Held")
      assert has_element?(view, "#card-thermostat\\:main .held .why", "maximum")

      # Refused means refused: nothing reached Home Assistant, and there is no
      # way back to offer because nothing moved.
      assert Fake.trace() == []
      refute has_element?(view, "#card-thermostat\\:main .undo")
    end

    # Identity personalizes and never permits (§10.4).
    test "works from a browser nobody has named", %{conn: conn} do
      ThreadEvents.subscribe()
      {:ok, view, _html} = live(conn, "/house")

      release(view, @thermostat, "72")

      assert_receive {:system_line, %{meta: %{"via" => "card"}}}
    end
  end

  describe "a house with nothing in it" do
    # The record voice, not Barlow. The board saying what it has is the board
    # speaking about itself, and the only person who ever opens an unconfigured
    # house is the one who configures it — so the line says where a house comes
    # from rather than only that there isn't one.
    test "says so in the board's own voice, and where a house comes from", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = live(conn, "/house")

      assert has_element?(view, ".cards .note", "No devices")
      # The file this boot actually read, since that is the one to go and open.
      assert has_element?(view, ".cards .note .file", "config/homes/rig.exs")
      refute has_element?(view, ".card")

      # One line, and the strongest true one: an empty house Dobby cannot write
      # says both things here rather than taking the read-only note as well.
      assert has_element?(view, ".cards .note", "reads and does not write")
      refute has_element?(view, ".cards .note", "Dobby writes YAML")
    end

    test "still offers the way in to admin", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = live(conn, "/house")

      assert has_element?(view, "a.to-admin")
    end
  end

  describe "getting about" do
    test "the band on the thread opens the house", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view |> element("a.rows") |> render() =~ "main thermostat"

      assert {:ok, house, _html} =
               view |> element("a.rows") |> render_click() |> follow_redirect(conn, "/house")

      assert has_element?(house, ".plate .section", "The House")
    end

    test "the nameplate is the way back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      assert {:ok, _thread, html} =
               view |> element(".plate h1 a") |> render_click() |> follow_redirect(conn, "/")

      assert html =~ "say something" or html =~ "who&#39;s this?"
    end

    # The nameplate names the instrument and the section names the room, and
    # the two must stay different words. They were one — `The House` was the
    # plate on every route *and* the name of `/house` — and the header lied in
    # both directions: the thread announced "The House" over a band of rows
    # that led somewhere else called the house, and `/house` offered "The
    # House" as the way off it. Nothing in the markup stops that collapsing
    # back, so this is what stops it.
    test "the thread's nameplate does not claim to be the house", %{conn: conn} do
      {:ok, thread, _html} = live(conn, "/")

      assert has_element?(thread, ".plate h1", "Dobby")
      refute has_element?(thread, ".plate .section")

      heading = thread |> element(".plate h1") |> render()
      refute heading =~ "The House"

      # And the band is a link *to* the house rather than a claim to be it.
      assert has_element?(thread, "a.rows[href='/house']")
    end
  end

  describe "the thread" do
    test "renders an intervention as a board row, not a sentence", %{conn: conn} do
      {:ok, _message} =
        Dobby.Interventions.record(%{
          device: @thermostat,
          name: "main thermostat",
          value: "70°",
          action: "set_temperature",
          via: "greg, card"
        })

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".sys .dev", "main thermostat")
      assert has_element?(view, ".sys .flap[data-st=set]", "Set")
      assert has_element?(view, ".sys .val", "70°")
      assert has_element?(view, ".sys .via", "greg, card")
    end

    test "renders a refusal quietly, with its reason", %{conn: conn} do
      {:ok, _message} =
        Dobby.Interventions.held(%{
          device: @thermostat,
          name: "main thermostat",
          action: "set_temperature",
          reason: "85° is above the main thermostat's maximum of 76°",
          via: ~s(schedule "far too warm")
        })

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".sys .flap[data-st=refused]", "Held")
      assert has_element?(view, ".sys .why", "maximum")
    end

    # A system line closes the pending row only when it *is* the end of the
    # turn. A schedule going off mid-request would otherwise take Dobby's
    # half-written reply off the board while he was still writing it.
    test "a line from elsewhere does not close a turn in flight", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      ThreadEvents.turn_started("req-9")
      ThreadEvents.delta("req-9", 1, "Setting it now")
      assert eventually(fn -> has_element?(view, "#pending-req-9") end)

      {:ok, message} =
        Dobby.Interventions.record(%{
          device: @thermostat,
          name: "main thermostat",
          value: "68°",
          via: ~s(schedule "weeknight heat")
        })

      ThreadEvents.system_line(message)

      assert eventually(fn -> has_element?(view, ".sys .via", "weeknight heat") end)
      assert has_element?(view, "#pending-req-9")
    end
  end

  describe "a house Dobby cannot write" do
    # The rig is an `.exs` home and the writer refuses those, so /house is
    # read only here — which is the state the whole suite runs in unless a
    # scenario goes to the trouble of pointing a writer at a YAML file.
    test "offers nothing to edit, and says why in one line", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      refute has_element?(view, "#card-thermostat\\:main .acts")
      refute has_element?(view, "form.device-form")
      refute has_element?(view, ".cards .acts button")

      assert has_element?(view, ".cards .note", "Dobby writes YAML")
      assert has_element?(view, ".cards .note .file", "config/homes/rig.exs")
    end

    test "and an event nobody was offered changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      render_click(view, "remove_confirm", %{"device" => @thermostat})

      assert @thermostat in Enum.map(Dobby.Home.devices(), & &1.id)
      assert has_element?(view, "#card-thermostat\\:main")
    end
  end

  describe "the form on a card" do
    setup [:editable_house]

    test "is built from the type rather than written for it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      # The scaffolding every entry has, filled in from the file rather than
      # from the card: a snapshot is what Home Assistant said, and what is
      # being edited is what this household wrote down.
      assert has_element?(view, "input[name='device[name]'][value='main thermostat']")
      assert has_element?(view, "#device-hands-only[name='device[hands_only]']")

      # The entity field is the type's own binding key, and the settings are
      # its declared schema — including the sentence `config_schema/0` writes
      # for whoever is editing the file.
      assert has_element?(
               view,
               "input[name='device[bindings][climate]'][value='climate.main_floor']"
             )

      assert has_element?(view, "input[name='device[settings][min_temperature_f]'][value='60']")
      assert has_element?(view, ".device-form .ask", "coolest this household")

      # A type that declares no settings gets no settings fields, and nobody
      # wrote a light form to make that true.
      view |> element("#card-light\\:living_room .acts button", "edit") |> render_click()

      assert has_element?(view, "input[name='device[bindings][light]']")
      refute has_element?(view, "input[name='device[settings][min_temperature_f]']")
    end

    test "writes the hands-only choice into the shared device entry", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      view
      |> form(".device-form",
        device: %{
          "name" => "main thermostat",
          "aliases" => "",
          "hands_only" => "true",
          "bindings" => %{"climate" => @entity},
          "settings" => %{"min_temperature_f" => "60", "max_temperature_f" => "76"}
        }
      )
      |> render_submit()

      assert {:ok, reread} = HomeConfig.load(path)
      assert [thermostat, _light] = reread.house[:devices]
      assert thermostat.hands_only
    end

    # The id is what a schedule stores and the type is where its actions come
    # from. Both are shown as the identifiers they are; changing what a device
    # *is* is a removal and an addition, and reads like one.
    test "shows the id and the type without offering to change them", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      assert has_element?(view, ".device-form .note .arg", "thermostat:main")
      assert has_element?(view, ".device-form .note .arg", "thermostat")
      refute has_element?(view, "input[name='device[id]']")
      refute has_element?(view, "select[name='device[type]']")
    end

    test "writes the file, restarts the house, and heals", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      view
      |> form(".device-form",
        device: %{
          "name" => "hall thermostat",
          "aliases" => "downstairs, the dial",
          "bindings" => %{"climate" => @entity},
          "settings" => %{"min_temperature_f" => "62", "max_temperature_f" => "76"}
        }
      )
      |> render_submit()

      # The file first, because it is the record. Aliases arrive as the list
      # they are and the setting as the number it is — the browser sent both
      # as text.
      assert {:ok, reread} = HomeConfig.load(path)

      assert [%{name: "hall thermostat", aliases: ["downstairs", "the dial"]} = entry, _light] =
               reread.house[:devices]

      assert entry.settings.min_temperature_f == 62

      # And the running house is the house that was written.
      assert "hall thermostat" in Enum.map(Dobby.Home.devices(), & &1.name)
      assert has_element?(view, "#card-thermostat\\:main .name", "hall thermostat")

      # The agents were rebuilt and have been told nothing, so the card is
      # honestly blank until Home Assistant speaks — and then it heals.
      assert eventually(fn -> has_element?(view, "#card-thermostat\\:main .val", "70°") end)
    end

    test "a refusal keeps what was typed and leaves the file alone", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")
      original = File.read!(path)

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      # A minimum above the maximum is the rule a declared schema cannot state,
      # and the thermostat is the one that states it.
      view
      |> form(".device-form",
        device: %{
          "name" => "main thermostat",
          "aliases" => "",
          "bindings" => %{"climate" => @entity},
          "settings" => %{"min_temperature_f" => "80", "max_temperature_f" => "76"}
        }
      )
      |> render_submit()

      assert has_element?(view, ".device-form .why", "exceeds max_temperature_f")
      assert has_element?(view, "input[name='device[settings][min_temperature_f]'][value='80']")
      assert File.read!(path) == original
    end

    # The schema is the validator, and it names the field. Nothing here knows
    # that a thermostat's minimum is a number.
    test "a setting that is not what the schema declared is named", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "edit") |> render_click()

      view
      |> form(".device-form",
        device: %{
          "name" => "main thermostat",
          "aliases" => "",
          "bindings" => %{"climate" => @entity},
          "settings" => %{"min_temperature_f" => "quite warm", "max_temperature_f" => "76"}
        }
      )
      |> render_submit()

      assert has_element?(view, ".device-form .why", "min_temperature_f")
    end
  end

  describe "adding a device" do
    setup [:editable_house]

    test "is the same form with a type to choose", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element(".cards .acts button", "add a device") |> render_click()

      assert has_element?(view, "select[name='device[type]'] option[value=thermostat]")
      assert has_element?(view, "select[name='device[type]'] option[value=wifi_endpoint]")

      view
      |> form(".device-form",
        device: %{
          "id" => "thermostat:attic",
          "type" => "thermostat",
          "name" => "attic thermostat",
          "aliases" => "",
          "bindings" => %{"climate" => "climate.attic"},
          "settings" => %{"min_temperature_f" => "", "max_temperature_f" => ""}
        }
      )
      |> render_submit()

      assert {:ok, reread} = HomeConfig.load(path)

      assert Enum.map(reread.house[:devices], & &1.id) == [
               @thermostat,
               @light,
               "thermostat:attic"
             ]

      # A setting nobody narrowed is left out of the file rather than written
      # as an empty one.
      assert %{settings: settings} = List.last(reread.house[:devices])
      assert settings == %{}

      assert has_element?(view, "#card-thermostat\\:attic .name", "attic thermostat")
      assert is_pid(Dobby.Jido.whereis("thermostat:attic"))
    end

    # The device type has the last word about its own entry, and the form does
    # not repeat it in different words: a blank entity field is left out, and
    # what comes back is the thermostat's own sentence.
    test "a device its type will not accept is not written", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")
      original = File.read!(path)

      view |> element(".cards .acts button", "add a device") |> render_click()

      view
      |> form(".device-form",
        device: %{
          "id" => "thermostat:attic",
          "type" => "thermostat",
          "name" => "attic thermostat",
          "aliases" => "",
          "bindings" => %{"climate" => ""},
          "settings" => %{"min_temperature_f" => "", "max_temperature_f" => ""}
        }
      )
      |> render_submit()

      assert has_element?(view, ".device-form .why", "missing required binding :climate")
      assert File.read!(path) == original
      refute has_element?(view, "#card-thermostat\\:attic")
    end
  end

  describe "removing a device" do
    setup [:editable_house]

    test "asks first, and says what a schedule aimed at it loses", %{conn: conn, path: path} do
      {:ok, _schedule} = weeknight_heat()
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-thermostat\\:main .acts button", "remove") |> render_click()

      # The question is a board line; what it would cost is a sentence.
      assert has_element?(view, "#card-thermostat\\:main .confirm", "Remove main thermostat?")

      assert has_element?(
               view,
               "#card-thermostat\\:main .hint",
               "One enabled schedule aims at it"
             )

      view |> element("#card-thermostat\\:main .acts button", "remove") |> render_click()

      refute has_element?(view, "#card-thermostat\\:main")
      assert {:ok, reread} = HomeConfig.load(path)
      assert Enum.map(reread.house[:devices], & &1.id) == [@light]

      # And it did exactly what the line said it would: the row is still there,
      # still enabled, and no longer able to reach anything. Admin says so.
      assert [schedule] = Schedules.list_schedules()
      assert schedule.enabled
      assert Schedules.describe(schedule).status != "active"
    end

    test "says nothing about schedules when nothing aims at it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("#card-light\\:living_room .acts button", "remove") |> render_click()

      assert has_element?(view, "#card-light\\:living_room .confirm", "Remove living room light?")
      refute has_element?(view, "#card-light\\:living_room .hint")
    end

    test "keeping it changes nothing", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, "/house")
      original = File.read!(path)

      view |> element("#card-thermostat\\:main .acts button", "remove") |> render_click()
      view |> element("#card-thermostat\\:main .acts button", "keep it") |> render_click()

      assert has_element?(view, "#card-thermostat\\:main .acts button", "edit")
      refute has_element?(view, "#card-thermostat\\:main .confirm")
      assert File.read!(path) == original
    end
  end

  describe "staying current" do
    setup [:editable_house]

    # No file watcher in v1 and none needed: everything Dobby writes is
    # announced on `dobby:config` the moment it takes effect, and this page
    # renders from the applied configuration.
    test "a house somebody else changed reaches an open page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      config = Writer.current()
      devices = Keyword.fetch!(config.house, :devices)

      attic = %{
        id: "thermostat:attic",
        name: "attic thermostat",
        aliases: [],
        agent_module: Dobby.DeviceAgents.Thermostat,
        bindings: %{climate: "climate.attic"},
        settings: %{}
      }

      {:ok, _applied} =
        Writer.save(%{config | house: Keyword.put(config.house, :devices, devices ++ [attic])})

      assert eventually(fn -> has_element?(view, "#card-thermostat\\:attic") end)
    end
  end

  # Eight verbs shared one drawing, so `remove` was the same object as `edit`
  # and, at the confirm, the same object as the way out of it. The tier is a
  # class rather than a guess from the word, and a button copied from its
  # neighbour loses it silently — which is what this holds.
  describe "what a verb looks like" do
    setup [:editable_house]

    test "taking something away is drawn as taking something away", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      assert has_element?(view, ".card .acts button.takes", "remove")
      refute has_element?(view, ".card .acts button.takes", "edit")

      view |> element("button[phx-value-device='thermostat:main']", "remove") |> render_click()

      # The one moment somebody can still decide otherwise, and the two answers
      # to it were the same object.
      assert has_element?(view, ".acts button.takes", "remove")
      assert has_element?(view, ".acts button.back", "keep it")
    end

    test "the way out of a form is not drawn like the way in", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      view |> element("button", "add a device") |> render_click()

      assert has_element?(view, ".device-form button.back", "cancel")
      refute has_element?(view, ".device-form button.back", "save")
    end
  end

  # -- helpers ---------------------------------------------------------------

  # What the fader's hook pushes when a finger comes up — never on a drag tick.
  defp release(view, device, temperature) do
    render_hook(view, "set", %{"device" => device, "temperature_f" => temperature})
  end

  defp named(conn, name) do
    post(conn, "/speaker", %{"name" => name, "return_to" => "/house"})
  end

  # A house Dobby can write, which is the other half of this page. The file is
  # real, in a temporary directory, and the running house is booted from it —
  # so the file on disk and the house on the board are the same house, which is
  # what a boot means.
  defp editable_house(_context) do
    previous_token = System.get_env("DOBBY_HOUSE_LIVE_TEST_HA_TOKEN")
    System.put_env("DOBBY_HOUSE_LIVE_TEST_HA_TOKEN", "fake")

    on_exit(fn ->
      if previous_token do
        System.put_env("DOBBY_HOUSE_LIVE_TEST_HA_TOKEN", previous_token)
      else
        System.delete_env("DOBBY_HOUSE_LIVE_TEST_HA_TOKEN")
      end
    end)

    path = Path.join(System.tmp_dir!(), "house-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, @editable)
    on_exit(fn -> File.rm(path) end)

    config = on_the_fake(HomeConfig.load!(path))

    Application.put_env(:dobby, Dobby.Home, HomeConfig.manifest(config))
    Fake.reset()
    {:ok, _pid} = Dobby.Home.restart()

    Fake.subscribe()
    Dobby.DeviceEvents.subscribe()

    swap_writer!(config)
    seed_house(%{@entity => thermostat_entity(current: 66, target: 70)})

    %{conn: build_conn(), path: path}
  end

  # The application's own writer is pointed at the rig, which it will not
  # write. This one takes its name for as long as the scenario runs, because
  # the page reaches the writer the way everything else does — by its name.
  defp swap_writer!(config) do
    :ok = Supervisor.terminate_child(Dobby.Supervisor, Writer)
    {:ok, writer} = Writer.start_link(config: config)

    on_exit(fn ->
      reference = Process.monitor(writer)
      if Process.alive?(writer), do: GenServer.stop(writer)

      receive do
        {:DOWN, ^reference, :process, _pid, _reason} -> :ok
      after
        5_000 -> :ok
      end

      {:ok, _pid} = Supervisor.restart_child(Dobby.Supervisor, Writer)
    end)
  end

  # The rig speaks to the fake and a YAML house never says so — that is the
  # point of it. So the client is swapped in the loaded struct, and the file
  # that lands on disk stays the shareable one either way.
  defp on_the_fake(%HomeConfig{house: house} = config) do
    home_assistant =
      house
      |> Keyword.fetch!(:home_assistant)
      |> Keyword.put(:client, Dobby.HomeAssistant.Fake)

    %{config | house: Keyword.put(house, :home_assistant, home_assistant)}
  end

  defp weeknight_heat do
    Schedules.create_schedule(%{
      label: "weeknight heat",
      cron: "0 20 * * 1-5",
      timezone: "America/New_York",
      target: @thermostat,
      action: "set_temperature",
      args: %{"temperature_f" => 68},
      created_by: "greg",
      created_via: :admin
    })
  end
end
