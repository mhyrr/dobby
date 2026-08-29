defmodule DobbyWeb.ThreadLiveTest do
  @moduledoc """
  The thread, against the real house.

  Two kinds of test live here and the split matters.

  The **surface contract** tests feed the LiveView exactly what
  `Dobby.ThreadEvents` promises — including deltas, which no scripted turn
  ever produces because the replay tier never enters the streaming path. Those
  are the tests that can catch a delta rendered in arrival order.

  The **end-to-end** tests type into the composer and let the real
  `Dobby.Conversation.Turn` run. The model is unreachable by configuration, so
  what they prove is the half that does not need one: that a person's words
  reach the thread, and that a request which cannot be answered says so
  instead of leaving them looking at nothing.
  """

  use Dobby.RigCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Dobby.Conversation
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  @endpoint DobbyWeb.Endpoint

  @entity "climate.main_floor"

  setup do
    seed_house(%{
      @entity => thermostat_entity(current: 66, target: 70),
      "binary_sensor.kitchen_tv" => %{state: "on", attributes: %{}}
    })

    %{conn: build_conn()}
  end

  # A browser that has already been named, the way a real one gets that way:
  # through the controller, so the signed cookie is the real thing rather than
  # a session seeded by hand.
  defp named(conn, name) do
    post(conn, "/speaker", %{"name" => name, "return_to" => "/"})
  end

  describe "the board" do
    test "shows the house before anyone asks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".row .name", "main thermostat")
      assert has_element?(view, ".row .val", "70°")

      # WARMING, not SET: Home Assistant says the room is below its setpoint,
      # so the device is acting. The board never infers this from the number
      # alone and never claims the room is warm.
      assert has_element?(view, ".row .flap[data-st=acting]", "Warming")
      assert has_element?(view, ".row .flap[data-st=acting]", "Awake")
    end

    test "says it is listening only while there is something to hear it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".plate .mark.attending")
      assert has_element?(view, ".plate .flap[data-st=acting]", "Listening")

      Dobby.Jido.stop_agent(Dobby.DobbyAgent.id())

      # Any thread event re-reads it. A board that claims to be attending while
      # nothing is running is the exact failure this surface exists to refuse —
      # and the mark stops leaning in, because the drawing carries the same
      # fact the word does.
      {:ok, message} = Conversation.append_system_line("the house restarted", %{})
      ThreadEvents.system_line(message)

      assert eventually(fn -> has_element?(view, ".plate .flap[data-st=silent]", "Quiet") end)
      refute has_element?(view, ".plate .mark.attending")
    end

    test "follows the house as it changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      Fake.inject_state_changed("binary_sensor.kitchen_tv", %{state: "off", attributes: %{}})

      # Most-recently-changed leads the band, which is the rule for deciding
      # which two or three devices are worth standing watch over. Waited on
      # directly: the band has other Quiet flaps (a light nobody seeded), so
      # "some Quiet exists" passes before this event has even landed.
      assert eventually(fn ->
               view |> element(".rows .row:first-child .name") |> render() =~ "kitchen TV"
             end)

      assert has_element?(view, ".rows .row:first-child .flap[data-st=silent]", "Quiet")
    end
  end

  describe "the set line" do
    test "asks who is there before it takes anything down", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # A POST and not an event: the cookie this writes can only be written by
      # a controller, which is the one round trip on this surface.
      assert has_element?(view, "form.set-line[action='/speaker'][method=post]")
      assert has_element?(view, "input#composer[name=name][aria-label='Your name']")
      refute has_element?(view, ".plate .speaking-as")
    end

    test "takes what somebody says once the browser knows who they are", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      assert has_element?(view, "input#composer[name=text]")
      assert has_element?(view, ".plate .speaking-as .name", "greg")
      refute has_element?(view, "input#composer[name=name]")
    end

    # The whole of the ticket, and the reason it was worth a round trip: the
    # name is kept by the browser, so the second visit is no better informed
    # than the first and no worse. Two independent mounts from one cookie jar,
    # because the failure Greg actually hit was a name that answered once —
    # good for the connection that set it, gone on the next page load.
    test "does not ask a browser that has already said who it is", %{conn: conn} do
      conn = named(conn, "greg")

      {:ok, first, _html} = live(conn, "/")
      {:ok, second, _html} = live(conn, "/")

      assert has_element?(first, ".plate .speaking-as .name", "greg")
      assert has_element?(second, ".plate .speaking-as .name", "greg")
      refute has_element?(second, "input#composer[name=name]")
    end

    test "offers a way to stop being that person", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      assert has_element?(view, ".plate .speaking-as[action='/speaker/switch']")
      assert has_element?(view, ".plate .speaking-as button", "switch")
    end

    # Households share tablets, so the switch is not decoration. Taking it
    # leaves the browser as nameless as it began — the set line asks again and
    # the plate stops claiming anybody.
    test "the switch puts the set line back to asking", %{conn: conn} do
      conn =
        conn |> named("greg") |> post("/speaker/switch", %{"return_to" => "/"})

      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, ".plate .speaking-as")
      assert has_element?(view, "input#composer[name=name][aria-label='Your name']")
    end

    # And the next name is the one that goes on what gets said. A switch that
    # left the previous speaker on the utterance would be worse than not
    # offering one, because the thread is the household's record of who asked.
    test "what is said after a switch carries the new name", %{conn: conn} do
      conn =
        conn
        |> named("greg")
        |> post("/speaker/switch", %{"return_to" => "/"})
        |> named("sam")

      {:ok, view, _html} = live(conn, "/")

      view |> element("form.set-line") |> render_submit(%{"text" => "is the printer on?"})

      assert eventually(fn -> has_element?(view, ".msg .attr .sp", "sam") end)
      refute has_element?(view, ".msg .attr .sp", "greg")
    end
  end

  # A fresh database on a real box, which is the state nobody had rendered:
  # a board with a house on it and nothing said into it yet.
  describe "a thread with nothing in it" do
    test "names its own blank rather than showing a void", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      assert has_element?(view, ".blank .note", "Nothing said yet")
    end

    # Proactive speech is deferred (design §11), so nothing here may read as
    # Dobby opening the conversation. The specimen is a *household* utterance:
    # the label is the board's voice and the sentence is a person's.
    test "shows one sentence of the kind that works, in a person's voice", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      assert has_element?(view, ".blank .like .said", "put the main thermostat to 70")

      # Inside the range the device itself reported — 60 to 76 in the rig — so
      # the board cannot suggest a sentence the house is going to refuse.
      refute has_element?(view, ".blank", "Dobby")
    end

    test "asks for a name before it offers anything to say", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".blank .note", "Your name goes on what you change")
      refute has_element?(view, ".blank .like")
    end

    # A house that has not reported has not told us what it takes, and a
    # specimen naming a value it might refuse would be the board promising
    # something on its behalf.
    test "promises nothing while the house is still silent", %{conn: conn} do
      boot_house!([thermostat_device("thermostat:main", "main thermostat", entity: @entity)])

      {:ok, view, _html} = live(named(conn, "greg"), "/")

      assert has_element?(view, ".blank .note", "Nothing said yet")
      refute has_element?(view, ".blank .like")
    end

    # A system line counts. A house that changed while nobody was talking has a
    # record, and a board still offering an example beneath it would be
    # describing an empty page it is no longer on.
    test "goes at the first line of any kind", %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      {:ok, message} = Conversation.append_system_line("the house restarted", %{})
      ThreadEvents.system_line(message)

      assert eventually(fn -> has_element?(view, ".sys .dev", "the house restarted") end)
      refute has_element?(view, ".blank")
    end

    test "is not there at all once the thread has something in it", %{conn: conn} do
      {:ok, speaker} = Conversation.name_speaker("greg")
      {:ok, _message} = Conversation.append_utterance(Utterance.new("greg", "hello"), speaker)

      {:ok, view, _html} = live(named(conn, "greg"), "/")

      refute has_element?(view, ".blank")
    end

    # A band with no rows still lays out as a link the width of the board:
    # invisible, zero-high, and reachable by tab.
    test "a house with no devices has no band to tap", %{conn: conn} do
      boot_house!([])

      {:ok, view, _html} = live(named(conn, "greg"), "/")

      refute has_element?(view, "a.rows")
    end
  end

  describe "a turn" do
    test "puts what somebody said in the thread, then says it could not answer",
         %{conn: conn} do
      {:ok, view, _html} = live(named(conn, "greg"), "/")

      view |> element("form.set-line") |> render_submit(%{"text" => "is the printer on?"})

      assert eventually(fn -> render(view) =~ "is the printer on?" end)

      # No model is reachable from the replay tier, so this request genuinely
      # fails — and the thread says so rather than showing an utterance
      # followed by silence.
      assert eventually(fn -> has_element?(view, ".sys") end, 10_000)
    end

    test "renders a reply as it streams, in seq order and not arrival order",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      ThreadEvents.turn_started("req-1")

      ThreadEvents.step("req-1", %{
        id: "t1",
        label: "setting the main thermostat",
        state: :running,
        detail: nil
      })

      # Deliberately out of order. `seq` is allocated in the runner and is
      # authoritative; arrival is not, and a swap has been observed in the rig.
      # Appended as they land, these read "Done main — thermostat".
      ThreadEvents.delta("req-1", 3, " main")
      ThreadEvents.delta("req-1", 5, " thermostat")
      ThreadEvents.delta("req-1", 1, "Done")
      ThreadEvents.delta("req-1", 4, "")
      ThreadEvents.delta("req-1", 2, " —")

      assert eventually(fn -> render(view) =~ "Done — main thermostat" end)
      assert has_element?(view, ".step", "setting the main thermostat")
    end

    test "the pending row gives way to the reply it was composing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      ThreadEvents.turn_started("req-2")
      ThreadEvents.delta("req-2", 1, "Set to 70.")

      assert eventually(fn -> has_element?(view, "#pending-req-2") end)

      {:ok, message} =
        Conversation.append_reply("Set to 70.",
          request_id: "req-2",
          meta: %{"steps" => [%{"label" => "setting the main thermostat", "state" => "done"}]}
        )

      ThreadEvents.replied(message)

      assert eventually(fn -> not has_element?(view, "#pending-req-2") end)
      assert render(view) =~ "Set to 70."

      # The work collapses to one row rather than being thrown away: what
      # Dobby actually did is what makes the answer trustworthy a week later.
      assert has_element?(view, "details.collapsed summary", "1 step")
    end

    test "accepts the internal turn-finished ordering barrier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      ThreadEvents.turn_finished("req-finished")
      _ = :sys.get_state(view.pid)

      assert has_element?(view, ".plate")
    end

    test "strips the markdown a model emits despite being asked not to", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      {:ok, message} = Conversation.append_reply("Set the **main thermostat** to `70`.")
      ThreadEvents.replied(message)

      assert eventually(fn -> render(view) =~ "Set the main thermostat to 70." end)
      refute render(view) =~ "**"
    end
  end

  describe "the shared document" do
    test "shows the transcript from before this browser was open", %{conn: conn} do
      {:ok, speaker} = Conversation.name_speaker("sam")

      {:ok, _} =
        Conversation.append_utterance(Utterance.new("sam", "is the printer on?"), speaker)

      {:ok, _} = Conversation.append_reply("It is — awake and answering.")

      {:ok, view, _html} = live(conn, "/")

      assert render(view) =~ "is the printer on?"
      assert render(view) =~ "It is — awake and answering."
      assert has_element?(view, ".msg .attr .sp", "sam")
      assert has_element?(view, ".msg.dobby .attr .sp", "Dobby")
    end

    test "every viewer sees the same message, whoever said it", %{conn: conn} do
      {:ok, one, _html} = live(conn, "/")
      {:ok, two, _html} = live(build_conn(), "/")

      {:ok, speaker} = Conversation.name_speaker("sam")

      {:ok, message} =
        Conversation.append_utterance(Utterance.new("sam", "put the heat on"), speaker)

      ThreadEvents.said(%{message | speaker: speaker})

      # The thread is a shared household record. Two people reading it must
      # not see two different documents, which is also why nothing here is
      # aligned by author.
      assert eventually(fn -> render(one) =~ "put the heat on" end)
      assert eventually(fn -> render(two) =~ "put the heat on" end)
    end
  end
end
