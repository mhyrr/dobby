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

  ## The house is also edited here (TK-018 layer D)

  No /config page: a device is edited where it lives, which is its card. The
  forms are built from the type — see `DobbyWeb.HouseLive.Editor` — and every
  write goes through `Dobby.HomeConfig.Writer`, which is the only process that
  writes the file.

  Applying a changed house restarts `Dobby.Home`, so the cards go back to
  NOT KNOWN for as long as it takes Home Assistant to say what the house looks
  like. That is the truth of the moment and the page is not going to dress it
  up: the agents were rebuilt from the manifest and have been told nothing yet.
  The initial state sync heals it, usually inside a frame.

  ## A house Dobby cannot write offers nothing

  The writer refuses `.exs` homes, which the development rig is one of. On such
  a house there are no buttons at all and one line saying why — rather than
  controls that exist to be refused, which is the same argument the fader makes
  about a thermostat that has not reported.
  """

  use DobbyWeb, :live_view

  import DobbyWeb.Board
  import DobbyWeb.HouseLive.Card
  import DobbyWeb.HouseLive.Editor, only: [editor: 1]

  alias Dobby.ConfigEvents
  alias Dobby.Controls
  alias Dobby.DeviceEvents
  alias Dobby.Home
  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Writer
  alias DobbyWeb.HouseLive.Editor

  # Long enough to notice you did the wrong thing, short enough that the offer
  # is gone before it stops meaning the last thing you did.
  @undo_window 8_000

  # Everything that changes the house. A house Dobby cannot write never draws
  # any of them, and a crafted event is not an affordance — see the last
  # `handle_event/3` clause.
  @edits ~w(edit add cancel form save remove remove_confirm)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DeviceEvents.subscribe()
      ConfigEvents.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "The House")
     |> assign(:listening, listening?())
     |> assign(:undo, %{})
     |> assign(:held, %{})
     |> assign(:editing, nil)
     |> assign(:form, nil)
     |> assign(:error, nil)
     |> assign(:removing, nil)
     |> assign(:trouble, %{})
     |> put_config(config())
     |> assign(:snapshots, snapshots())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="board">
      <.plate
        speaker={@speaker}
        listening={@listening}
        here={:house}
        return_to={~p"/house"}
      />
    </header>

    <main class="cards">
      <.card
        :for={snapshot <- @snapshots}
        snapshot={snapshot}
        undo={@undo[snapshot.id]}
        held={@held[snapshot.id]}
        editable={@editable and describes?(@config, snapshot.id)}
        editing={@editing == snapshot.id}
        removing={removal_note(@config, @removing, snapshot.id)}
        trouble={@trouble[snapshot.id]}
      >
        <.editor
          :if={@editing == snapshot.id}
          form={@form}
          module={Editor.module(@form)}
          error={@error}
        />
      </.card>

      <%!-- The record voice, not Barlow: the board saying what it has is the
            board speaking about itself, and the one person who ever sees a
            house with nothing in it is the one who describes it — so the line
            says where a house comes from rather than only that there isn't
            one. It names the file this boot actually read, since that is the
            one a person can go and open. --%>
      <%!-- One line and the strongest true one, which is why an empty house
            that cannot be written says both things here rather than taking the
            read-only sentence below as well. --%>
      <p :if={@snapshots == [] and not @editable} class="note">
        No devices. The house is described in <span class="file arg">{path(@config)}</span>
        on the box, which Dobby reads and does not write.
      </p>

      <p :if={@snapshots == [] and @editable} class="note">
        No devices yet. Whatever you add here is written to <span class="file arg">{path(@config)}</span>.
      </p>

      <div :if={@editable and @editing != :new} class="acts">
        <button type="button" phx-click="add">add a device</button>
      </div>

      <.editor
        :if={@editing == :new}
        form={@form}
        module={Editor.module(@form)}
        new={true}
        error={@error}
      />

      <%!-- One sentence, and it says why rather than only that. A house that
            wants an editable surface is a YAML house — the writer will not
            round-trip a file with logic in it — and the line names the file so
            that whoever reads it knows which one to move. --%>
      <p :if={not @editable and @snapshots != []} class="note">
        Devices are read only here: this house is <span class="file arg">{path(@config)}</span>, and Dobby writes YAML.
      </p>

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

  # The form opens on the *file's* entry and not on the card's snapshot: a
  # snapshot is what Home Assistant said, and what is being edited is what this
  # household wrote down.
  def handle_event("edit", %{"device" => id}, %{assigns: %{editable: true}} = socket) do
    case entry(socket.assigns.config, id) do
      nil -> {:noreply, socket}
      entry -> {:noreply, open(socket, id, Editor.params(entry))}
    end
  end

  def handle_event("add", _params, %{assigns: %{editable: true}} = socket) do
    {:noreply, open(socket, :new, Editor.blank())}
  end

  # One word for both the form and the confirm line, because they are one
  # question: nothing is open, and nothing is being asked.
  def handle_event("cancel", _params, %{assigns: %{editable: true}} = socket) do
    {:noreply, closed(socket)}
  end

  # Changing the type changes what a device has, so the entity and settings
  # fields are re-read rather than carried over — the same rule the admin's
  # schedule form follows about an action's arguments, for the same reason: a
  # value typed for one shape has no meaning in another.
  def handle_event("form", %{"device" => params}, %{assigns: %{editable: true}} = socket) do
    {:noreply, assign(socket, :form, normalize(params, socket.assigns.form))}
  end

  # Two refusals can reach here and they are different sizes. The form's own —
  # a device with no name, a setting that is not a number — never leaves this
  # process; the writer's is the house refusing to hold together, and it has
  # already left the file where it was. Both land under the last field, which
  # is where what somebody just typed is.
  def handle_event("save", %{"device" => params}, %{assigns: %{editable: true}} = socket) do
    form = normalize(params, socket.assigns.form)
    editing = socket.assigns.editing
    previous = if editing == :new, do: %{}, else: entry(socket.assigns.config, editing) || %{}

    with {:ok, entry} <- Editor.entry(form, previous),
         {:ok, applied} <- write(socket, {:put, editing, entry}) do
      {:noreply, socket |> closed() |> put_config(applied.config) |> reload()}
    else
      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:error, reason)}
    end
  end

  # Asked, not blocked. A schedule aimed at a device that leaves becomes an
  # enabled row with no timer, which admin's health note and the schedule's own
  # badge already say out loud — so the confirm line says it here too, in the
  # one moment somebody can still decide otherwise.
  def handle_event("remove", %{"device" => id}, %{assigns: %{editable: true}} = socket) do
    {:noreply, socket |> closed() |> assign(:removing, id)}
  end

  def handle_event("remove_confirm", %{"device" => id}, %{assigns: %{editable: true}} = socket) do
    case write(socket, {:remove, id}) do
      {:ok, applied} ->
        {:noreply, socket |> closed() |> put_config(applied.config) |> reload()}

      # The device is still here, so its reason goes on its own card.
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:removing, nil)
         |> assign(:trouble, Map.put(socket.assigns.trouble, id, reason))}
    end
  end

  # A house Dobby cannot write drew none of the above. There is nothing to say
  # to an event that was never offered, and nothing to change.
  def handle_event(event, _params, socket) when event in @edits, do: {:noreply, socket}

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

  # -- what a person changes -------------------------------------------------

  defp open(socket, editing, form) do
    socket
    |> assign(:editing, editing)
    |> assign(:form, form)
    |> assign(:error, nil)
    |> assign(:removing, nil)
  end

  defp closed(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
    |> assign(:error, nil)
    |> assign(:removing, nil)
  end

  defp write(socket, operation) do
    expected = socket.assigns.config

    Writer.update(Writer.server(), fn current ->
      with {:ok, devices} <- update_devices(current, expected, operation) do
        {:ok, %{current | house: Keyword.put(current.house, :devices, devices)}}
      end
    end)
  end

  defp update_devices(current, _expected, {:put, :new, entry}),
    do: {:ok, config_devices(current) ++ [entry]}

  defp update_devices(current, expected, {:put, id, replacement}) do
    if entry(current, id) == entry(expected, id) and entry(current, id) != nil do
      {:ok, devices(current, id, replacement)}
    else
      changed_device(id)
    end
  end

  defp update_devices(current, expected, {:remove, id}) do
    if entry(current, id) == entry(expected, id) and entry(current, id) != nil do
      {:ok, Enum.reject(config_devices(current), &(&1.id == id))}
    else
      changed_device(id)
    end
  end

  defp changed_device(id),
    do: {:error, "#{id} changed while this form was open; review it and try again"}

  defp devices(config, id, entry) do
    Enum.map(config_devices(config), fn existing ->
      if existing.id == id, do: entry, else: existing
    end)
  end

  # Everything the new house has to say about itself is re-read: the agents are
  # new processes that have been told nothing, so the cards go back to NOT KNOWN
  # until Home Assistant speaks. That is the truth of this moment and it heals
  # itself.
  defp reload(socket) do
    socket
    |> assign(:snapshots, snapshots())
    |> assign(:trouble, %{})
    |> assign(:undo, %{})
    |> assign(:held, %{})
    |> assign(:listening, listening?())
  end

  defp normalize(params, previous) do
    previous = previous || Editor.blank()
    type = params["type"] || previous["type"]
    same_type? = type == previous["type"]

    %{
      "id" => params["id"] || previous["id"] || "",
      "type" => type,
      "name" => params["name"] || "",
      "aliases" => params["aliases"] || "",
      "hands_only" => params["hands_only"] || previous["hands_only"] || "false",
      "bindings" => if(same_type?, do: params["bindings"] || %{}, else: %{}),
      "settings" => if(same_type?, do: params["settings"] || %{}, else: %{})
    }
  end

  # -- what the house does ---------------------------------------------------

  # The whole house is re-read rather than the one card patched. That is N
  # calls into N agents per event per browser, which at household scale is
  # microseconds — and it is the version that stays right when the manifest
  # changes under a page somebody left open.
  @impl true
  def handle_info(%Jido.Signal{type: "dobby.device.state_changed"}, socket) do
    {:noreply, socket |> assign(:snapshots, snapshots()) |> assign(:listening, listening?())}
  end

  def handle_info(%Jido.Signal{type: "dobby.device.command_status_changed"}, socket) do
    {:noreply, assign(socket, :snapshots, snapshots())}
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

  # Somebody else's browser, or the household thread, changed the house. The
  # page renders from the applied configuration and this is how it stays that —
  # there is no file watcher in v1 and none is needed, because everything Dobby
  # itself writes is announced the moment it takes effect.
  def handle_info({:applied, applied}, socket) do
    {:noreply, socket |> put_config(applied.config) |> reload() |> reopen()}
  end

  # A form open on a device that has just left the house is a form about
  # nothing. One that is still described stays open with what was typed in it:
  # somebody else's save is not a reason to lose a sentence half written.
  defp reopen(%{assigns: %{editing: editing}} = socket)
       when is_binary(editing) do
    if entry(socket.assigns.config, editing), do: socket, else: closed(socket)
  end

  defp reopen(socket), do: socket

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

  # -- the file --------------------------------------------------------------

  # Read once here and kept current on `dobby:config` — the same shape every
  # live surface in this application takes, and the reason the pages need no
  # file watcher.
  defp config do
    Writer.current(Writer.server())
  catch
    # The writer is restarting, or this is a boot that never had a house. Read
    # only is the honest answer either way: nothing is going to be written
    # through a process that is not there.
    :exit, _reason -> nil
  end

  # `Writer.writable?/1` and not a local format match: the rule of who may be
  # written lives in one module, and /admin asks it the same way.
  defp put_config(socket, config) do
    socket
    |> assign(:config, config)
    |> assign(:editable, match?(%HomeConfig{}, config) and Writer.writable?(config))
  end

  defp config_devices(%HomeConfig{house: house}), do: Keyword.get(house, :devices, [])
  defp config_devices(nil), do: []

  defp entry(config, id), do: Enum.find(config_devices(config), &(&1.id == id))

  # A card whose device the file does not describe gets no edit affordance. It
  # is a real state — the running house came from somewhere this page cannot
  # write back to — and offering a form that would create rather than change
  # would be worse than offering nothing.
  defp describes?(config, id), do: entry(config, id) != nil

  defp path(%HomeConfig{path: path}), do: path
  defp path(nil), do: "the home file"

  # The one thing removal costs that nothing else on this page does. Said as a
  # count and not as a warning: the schedules stay, they stay enabled, and they
  # will have nothing to fire — which is what admin's health note is already
  # measuring and what the schedule's own row will say.
  defp removal_note(_config, asked_about, id) when asked_about != id, do: nil

  defp removal_note(config, _asked_about, id) do
    name =
      case entry(config, id) do
        %{name: name} -> name
        nil -> id
      end

    %{question: "Remove #{name}?", cost: cost(aimed_at(id))}
  end

  defp cost(0), do: nil

  defp cost(1), do: "One enabled schedule aims at it. It stays, with no timer, and admin says so."

  defp cost(count) do
    "#{count} enabled schedules aim at it. They stay, with no timer, and admin says so."
  end

  defp aimed_at(id) do
    Enum.count(Dobby.Schedules.enabled(), &(&1.target == id))
  end
end
