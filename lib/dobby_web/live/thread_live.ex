defmodule DobbyWeb.ThreadLive do
  @moduledoc """
  The household thread (design §10.1, §10.2, §10.7).

  One shared, persistent conversation with a board header above it and the
  composer as the board's set line at the foot. Everyone in the house reads
  the same document; nothing here is scoped to a viewer.

  ## This LiveView never writes the thread

  It renders and it collects one form. `Dobby.Conversation.Turn` persists the
  utterance, runs the request, and republishes everything to `dobby:thread`,
  and this subscribes like any other surface — including to the message it
  just caused. That is a deliberate round trip: a surface that optimistically
  rendered its own copy would be showing something the transcript might not
  have.

  It also cannot call `ask_stream/3` itself. The stream's enumerable blocks in
  `receive`, so a LiveView iterating one would stop handling messages for the
  length of the request.

  ## The speaker

  Assigned by `DobbyWeb.Plugs.Speaker` before this mounts, read from a signed
  cookie the browser has been carrying since somebody typed a name into the set
  line. When nobody has, the set line asks — and that one form leaves the
  socket for a controller, because a LiveView cannot set a cookie.
  """

  use DobbyWeb, :live_view

  import DobbyWeb.Board
  import DobbyWeb.ThreadLive.Message

  alias Dobby.Conversation
  alias Dobby.Conversation.Turn
  alias Dobby.DeviceEvents
  alias Dobby.Home
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  @history 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ThreadEvents.subscribe()
      DeviceEvents.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Dobby")
     |> assign(:pending, %{})
     |> assign(:listening, listening?())
     |> assign(:snapshots, snapshots())
     |> stream(:messages, Conversation.recent(@history))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="board">
      <.plate speaker={@speaker} listening={@listening} return_to={~p"/"} />
      <.band snapshots={@snapshots} />
    </header>

    <main class="thread" id="thread" phx-hook=".StickToBottom" phx-update="stream">
      <div :for={{dom_id, message} <- @streams.messages} id={dom_id}>
        <.message message={message} />
      </div>
    </main>

    <div class="thread-pending">
      <.pending :for={pending <- ordered(@pending)} pending={pending} />
    </div>

    <%!-- Two set lines, and only ever one of them on the page. Saying
          something is an event; naming yourself is a POST, because the cookie
          it writes can only be written by a controller. --%>
    <form :if={@speaker} class="set-line" phx-submit="say">
      <input
        type="text"
        id="composer"
        name="text"
        value=""
        autocomplete="off"
        placeholder="say something"
        aria-label="Say something to Dobby"
        phx-hook=".Composer"
        phx-mounted={JS.focus()}
      />
      <.send_arrow />
    </form>

    <.form :if={!@speaker} for={%{}} action={~p"/speaker"} method="post" class="set-line">
      <input type="hidden" name="return_to" value={~p"/"} />
      <input
        type="text"
        id="composer"
        name="name"
        value=""
        autocomplete="off"
        placeholder="who's this?"
        aria-label="Your name"
        phx-mounted={JS.focus()}
      />
      <.send_arrow />
    </.form>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
      export default {
        mounted() { this.stick() },
        updated() { this.stick() },
        stick() { this.el.scrollTop = this.el.scrollHeight }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Composer">
      export default {
        mounted() {
          // The server clears the line once it has the utterance, rather than
          // the client clearing it on submit: the input empties when the
          // thread has actually taken the words, not when the person let go.
          this.handleEvent("dobby:composer-clear", () => { this.el.value = "" })
        }
      }
    </script>
    """
  end

  defp send_arrow(assigns) do
    ~H"""
    <button type="submit" aria-label="Send">
      <svg viewBox="0 0 17 17" fill="none" aria-hidden="true">
        <path
          d="M2 8.5h12M9.5 4l4.5 4.5L9.5 13"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="square"
        />
      </svg>
    </button>
    """
  end

  # -- what a person does ----------------------------------------------------

  @impl true
  def handle_event("say", %{"text" => text}, socket) do
    with %{} = speaker <- socket.assigns.speaker,
         trimmed when trimmed != "" <- String.trim(text) do
      speaker.name
      |> Utterance.new(trimmed)
      |> Turn.say(speaker)
    end

    {:noreply, clear_composer(socket)}
  end

  defp clear_composer(socket), do: push_event(socket, "dobby:composer-clear", %{})

  # -- what the house does ---------------------------------------------------

  @impl true
  def handle_info({:said, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  # A system line closes the pending row only when it *is* the end of the turn.
  # Every other line — the thermostat going to 70, a schedule at eight o'clock —
  # can land in the middle of a request, and closing the pending row on those
  # would take Dobby's half-written reply off the board while he was still
  # writing it.
  def handle_info({:system_line, message}, socket) do
    socket = socket |> stream_insert(:messages, message) |> assign(:listening, listening?())

    if message.meta["kind"] == "request_failed" do
      {:noreply, close_pending(socket, message.request_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:replied, message}, socket) do
    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> close_pending(message.request_id)
     |> assign(:listening, listening?())}
  end

  def handle_info({:turn_started, request_id}, socket) do
    pending = %{
      request_id: request_id,
      started_at: System.monotonic_time(:millisecond),
      deltas: %{},
      text: "",
      steps: []
    }

    {:noreply, assign(socket, :pending, Map.put(socket.assigns.pending, request_id, pending))}
  end

  # Deltas are keyed and re-sorted by `seq` rather than appended in arrival
  # order. `seq` is allocated in the runner and is authoritative; arrival is
  # not, and a two-event swap has been seen in the rig. Appending as they land
  # would occasionally transpose two words of Dobby's reply — rare, invisible
  # to tests, and precisely the kind of thing that makes an honest board look
  # broken.
  def handle_info({:delta, request_id, seq, text}, socket) do
    {:noreply,
     update_pending(socket, request_id, fn pending ->
       deltas = Map.put(pending.deltas, seq, text)

       %{pending | deltas: deltas, text: deltas |> Enum.sort() |> Enum.map_join(&elem(&1, 1))}
     end)}
  end

  def handle_info({:step, request_id, step}, socket) do
    {:noreply,
     update_pending(socket, request_id, fn pending ->
       %{pending | steps: replace_step(pending.steps, step)}
     end)}
  end

  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: data}, socket) do
    {:noreply, assign(socket, :snapshots, promote(socket.assigns.snapshots, data.snapshot))}
  end

  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  # -- the pending turn ------------------------------------------------------

  defp update_pending(socket, request_id, fun) do
    case Map.fetch(socket.assigns.pending, request_id) do
      {:ok, pending} ->
        assign(socket, :pending, Map.put(socket.assigns.pending, request_id, fun.(pending)))

      # A delta for a turn this surface never saw start — it connected
      # mid-request. Dropping it is right: the finished reply is persisted and
      # arrives whole.
      :error ->
        socket
    end
  end

  defp close_pending(socket, nil), do: socket

  defp close_pending(socket, request_id) do
    assign(socket, :pending, Map.delete(socket.assigns.pending, request_id))
  end

  defp replace_step(steps, step) do
    case Enum.find_index(steps, &(&1.id == step.id)) do
      nil -> steps ++ [step]
      index -> List.replace_at(steps, index, step)
    end
  end

  defp ordered(pending) do
    pending |> Map.values() |> Enum.sort_by(& &1.started_at)
  end

  # -- the house -------------------------------------------------------------

  # Whether there is anything there to hear it. The board says LISTENING beside
  # Dobby's own face, so the one thing it must not do is say it when DobbyAgent
  # is not running — a house that claims to be attending while nothing is
  # answering is the exact failure this surface exists to refuse.
  defp listening?, do: is_pid(Dobby.Jido.whereis(Dobby.DobbyAgent.id()))

  defp snapshots do
    Home.snapshots() |> Map.values()
  rescue
    # No manifest yet, or the house is restarting. An empty band is honest and
    # the first state change fills it in.
    ArgumentError -> []
  end

  # Most-recently-changed first, which is the rule the band uses to decide
  # which two or three devices are worth standing watch over.
  defp promote(snapshots, snapshot) do
    [snapshot | Enum.reject(snapshots, &(&1.id == snapshot.id))]
  end
end
