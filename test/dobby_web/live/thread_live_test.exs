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

      assert eventually(fn -> has_element?(view, ".row .flap[data-st=silent]", "Quiet") end)

      # Most-recently-changed leads the band, which is the rule for deciding
      # which two or three devices are worth standing watch over.
      assert view |> element(".rows .row:first-child .name") |> render() =~ "kitchen TV"
    end
  end

  describe "the set line" do
    test "asks who is there before it takes anything down", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "input#composer[name=name][aria-label='Your name']")

      view |> element("form.set-line") |> render_submit(%{"name" => "greg"})

      assert has_element?(view, "input#composer[name=text]")
      assert has_element?(view, ".plate .who", "greg")
      assert Conversation.get_speaker_by_name("greg")
    end

    test "a name that already exists is the same person", %{conn: conn} do
      {:ok, existing} = Conversation.name_speaker("Greg")
      {:ok, view, _html} = live(conn, "/")

      view |> element("form.set-line") |> render_submit(%{"name" => "greg"})

      assert has_element?(view, ".plate .who", "Greg")
      assert length(Conversation.list_speakers()) == 1
      assert Conversation.get_speaker_by_name("greg").id == existing.id
    end

    test "a sentence typed as a name is refused out loud", %{conn: conn} do
      # Observed in the wild: the placeholder question vanished under the
      # typing, and a whole request went in as a name. The guard already
      # refused it — this pins the refusal being said, not swallowed.
      sentence = "Hey Dobby, can you set the thermostat to seventy three?"
      {:ok, view, _html} = live(conn, "/")

      view |> element("form.set-line") |> render_submit(%{"name" => sentence})

      assert has_element?(view, ".set-note", "reads like a message")
      assert has_element?(view, "input#composer[name=name]")
      refute Conversation.get_speaker_by_name(sentence)

      # The note clears the moment a real name lands.
      view |> element("form.set-line") |> render_submit(%{"name" => "greg"})
      refute has_element?(view, ".set-note")
      assert has_element?(view, "input#composer[name=text]")
    end

    test "the identity question stays visible while an answer is typed", %{conn: conn} do
      # It lives beside the input, not inside it, because a placeholder is
      # erased by the first letter of the answer.
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".set-ask", "who's this?")

      view |> element("form.set-line") |> render_submit(%{"name" => "greg"})

      refute has_element?(view, ".set-ask")
    end
  end

  describe "a turn" do
    test "puts what somebody said in the thread, then says it could not answer",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element("form.set-line") |> render_submit(%{"name" => "greg"})

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
