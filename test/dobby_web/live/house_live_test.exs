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

  alias Dobby.ThreadEvents

  @endpoint DobbyWeb.Endpoint

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @tv "binary_sensor.kitchen_tv"

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

    # Identity personalizes and never permits (§10.2).
    test "works from a browser nobody has named", %{conn: conn} do
      ThreadEvents.subscribe()
      {:ok, view, _html} = live(conn, "/house")

      release(view, @thermostat, "72")

      assert_receive {:system_line, %{meta: %{"via" => "card"}}}
    end
  end

  describe "getting about" do
    test "the band on the thread opens the house", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert view |> element("a.rows") |> render() =~ "main thermostat"

      assert {:ok, house, _html} =
               view |> element("a.rows") |> render_click() |> follow_redirect(conn, "/house")

      assert has_element?(house, ".plate .section", "Devices")
    end

    test "the nameplate is the way back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/house")

      assert {:ok, _thread, html} =
               view |> element(".plate h1 a") |> render_click() |> follow_redirect(conn, "/")

      assert html =~ "say something" or html =~ "who&#39;s this?"
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

  # -- helpers ---------------------------------------------------------------

  # What the fader's hook pushes when a finger comes up — never on a drag tick.
  defp release(view, device, temperature) do
    render_hook(view, "set", %{"device" => device, "temperature_f" => temperature})
  end

  defp named(conn, name) do
    post(conn, "/speaker", %{"name" => name, "return_to" => "/house"})
  end
end
