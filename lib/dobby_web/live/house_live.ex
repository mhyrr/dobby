defmodule DobbyWeb.HouseLive do
  @moduledoc """
  Every device, as cards (design §10.1, §10.5).

  The first draft folded these into the thread page. Wrong for the real case —
  any house worth its salt has a lot of devices, and a strip of them wedged
  above a conversation stops working at about six. So devices got their own
  page and their own space, and the thread kept a band of two or three.

  ## No model is involved here, on purpose

  A control on this page reaches its device through `Dobby.Controls`, which
  reaches it by exactly the path the model's tool does. That makes this the
  deterministic surface: what the house does when the model is down, and the
  fastest way to change something when saying a sentence is more work than
  moving a dial. TK-001 calls it first-class rather than a fallback, and this
  is what that means in practice — no `ask`, no tokens, no waiting.

  What a control does *not* do is write the thread itself. `Dobby.Controls`
  does that, once, for everybody — the same rule the thread page follows, and
  for the same reason: three browsers watching would otherwise write three
  lines.
  """

  use DobbyWeb, :live_view

  import DobbyWeb.Board
  import DobbyWeb.HouseLive.Card

  alias Dobby.Controls
  alias Dobby.DeviceEvents
  alias Dobby.Home

  # Long enough to notice you did the wrong thing, short enough that the offer
  # is gone before it stops meaning the last thing you did.
  @undo_window 8_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DeviceEvents.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "The house")
     |> assign(:listening, listening?())
     |> assign(:undo, %{})
     |> assign(:held, %{})
     |> assign(:snapshots, snapshots())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="board">
      <.plate
        speaker={@speaker}
        listening={@listening}
        section="Devices"
        return_to={~p"/house"}
      />
    </header>

    <main class="cards">
      <.card
        :for={snapshot <- @snapshots}
        snapshot={snapshot}
        undo={@undo[snapshot.id]}
        held={@held[snapshot.id]}
      />
      <p :if={@snapshots == []} class="empty">No devices are configured.</p>

      <%!-- The way in to /admin, and the only one. It is laptop-shaped and
            rarely visited, so it does not earn permanent header space on the
            surface a phone opens first. --%>
      <.link navigate={~p"/admin"} class="to-admin">Admin</.link>
    </main>
    """
  end

  # -- what a person does ----------------------------------------------------

  @impl true
  def handle_event("set", %{"device" => device, "temperature_f" => temperature}, socket) do
    with {value, _rest} <- Float.parse(to_string(temperature)) do
      {:noreply, commit(socket, device, value)}
    else
      # A range input cannot send this. Ignoring it is right anyway: the card
      # is a control, not a form, and there is nothing to tell anybody.
      :error -> {:noreply, socket}
    end
  end

  # Going back does not offer a way back. One step, not a stack: a button
  # labelled "undo" that undoes an undo is a redo wearing the wrong word, and
  # the pair of them would sit there swapping the thermostat between two
  # numbers with nothing on the card saying which one you are on.
  def handle_event("undo", %{"device" => device}, socket) do
    case socket.assigns.undo[device] do
      %{to: temperature} ->
        {:noreply, socket |> commit(device, temperature) |> clear_undo(device)}

      nil ->
        {:noreply, socket}
    end
  end

  # The undo is offered against the setpoint as it was *before* the release,
  # read from the snapshot this page is already holding rather than remembered
  # separately — so a way back is only offered when there is one to go back to.
  #
  # Undoing writes its own line. That is two lines in the thread for one
  # mistake, and it is the honest count: the house went to 85 and then it went
  # back to 70, and both of those happened.
  defp commit(socket, device, temperature) do
    previous = Enum.find(socket.assigns.snapshots, &(&1.id == device))
    via = via(socket.assigns.speaker)

    case Controls.set_temperature(device, temperature, via: via) do
      {:ok, _result} ->
        socket
        |> clear_held(device)
        |> offer_undo(device, previous)

      {:held, reason} ->
        socket |> clear_undo(device) |> put_held(device, reason)

      {:error, reason} ->
        socket |> clear_undo(device) |> put_held(device, reason)
    end
  end

  defp via(nil), do: "card"
  defp via(speaker), do: "#{speaker.name}, card"

  defp offer_undo(socket, device, %{target_temperature_f: previous})
       when is_number(previous) do
    token = make_ref()
    Process.send_after(self(), {:undo_expired, device, token}, @undo_window)

    assign(socket, :undo, Map.put(socket.assigns.undo, device, %{to: previous, token: token}))
  end

  # Nothing to go back to: this thermostat had no setpoint before now.
  defp offer_undo(socket, device, _previous), do: clear_undo(socket, device)

  defp clear_undo(socket, device),
    do: assign(socket, :undo, Map.delete(socket.assigns.undo, device))

  defp put_held(socket, device, reason),
    do: assign(socket, :held, Map.put(socket.assigns.held, device, reason))

  defp clear_held(socket, device),
    do: assign(socket, :held, Map.delete(socket.assigns.held, device))

  # -- what the house does ---------------------------------------------------

  # The whole house is re-read rather than the one card patched. That is N
  # calls into N agents per event per browser, which at household scale is
  # microseconds — and it is the version that stays right when the manifest
  # changes under a page somebody left open.
  @impl true
  def handle_info(%Jido.Signal{type: "dobby.device.state_changed"}, socket) do
    {:noreply, socket |> assign(:snapshots, snapshots()) |> assign(:listening, listening?())}
  end

  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  # The token is not ceremony: two releases inside the window arm two timers,
  # and without it the first one to go off would take away the offer the second
  # one made.
  def handle_info({:undo_expired, device, token}, socket) do
    case socket.assigns.undo[device] do
      %{token: ^token} -> {:noreply, clear_undo(socket, device)}
      _superseded -> {:noreply, socket}
    end
  end

  # -- the house -------------------------------------------------------------

  # In manifest order, not most-recently-changed. The band is a watch list and
  # reorders itself; this is the whole house, and a page whose cards moved
  # under a finger would be worse than one that did not.
  defp snapshots do
    manifest_order = Enum.map(Home.devices(), & &1.id)
    by_id = Home.snapshots()

    Enum.map(manifest_order, &Map.fetch!(by_id, &1))
  rescue
    # No manifest yet, or the house is restarting. An empty page is honest and
    # the first state change fills it in.
    ArgumentError -> []
  end

  defp listening?, do: is_pid(Dobby.Jido.whereis(Dobby.DobbyAgent.id()))
end
