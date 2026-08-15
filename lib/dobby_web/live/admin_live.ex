defmodule DobbyWeb.AdminLive do
  @moduledoc """
  What the house has been doing, what it is going to do, and whether it is
  there at all (surface design §9).

  Laptop-shaped and open to the house, like everything else here — LAN-only,
  flat trust, the Wi-Fi password is the boundary. There is no admin *role*,
  because there is no role system; this page is a different question, not a
  different permission.

  Three sections and the order is deliberate. Health first because it is three
  lines and it changes what the other two mean. Schedules next because they are
  the only thing on this page you can change. The feed last because it is the
  long one, and because you scroll to a log rather than being handed it.

  ## The feed is the full record

  Everything: requests, tool calls, controls somebody touched, schedules
  firing, and an endpoint flapping at 3am. The thread's interventions are a
  subset of this (design §10.1) — the thread is a document a household reads
  and this is the log behind it, which is why the endpoint at 3am reaches here
  and stops.
  """

  use DobbyWeb, :live_view

  import DobbyWeb.Board
  import DobbyWeb.Flap

  alias Dobby.Activity
  alias Dobby.ActivityEvents
  alias Dobby.Health
  alias Dobby.Home
  alias Dobby.ScheduleEvents
  alias Dobby.Schedules

  @feed 100
  @undo_window 8_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ActivityEvents.subscribe()
      ScheduleEvents.subscribe()
    end

    devices = Schedules.schedulable_devices()

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:listening, listening?())
     |> assign(:error, nil)
     |> assign(:deleted, nil)
     |> assign(:devices, devices)
     |> assign(:form, blank_form(devices))
     |> load_arguments()
     |> load_health()
     |> load_schedules()
     |> stream(:activity, Activity.recent(@feed))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="board">
      <.plate speaker={@speaker} listening={@listening} section="Admin" return_to={~p"/admin"} />
    </header>

    <main class="admin">
      <section class="panel">
        <h2>Health</h2>

        <div class="rows">
          <div :for={row <- @health} class="row">
            <span class="name">{row.name}</span>
            <span class="val">{row.detail}</span>
            <.flap state={row.state}>{row.word}</.flap>
          </div>
        </div>

        <%!-- The most useful row on the page: a schedule accepted at authoring
              time and then rejected by the timer looks, from every other
              angle, exactly like one that works. Empty is the healthy
              answer, and empty says so rather than showing nothing. --%>
        <div class="note">
          <span :if={@unregistered == []}>Every enabled schedule has a timer.</span>
          <span :if={@unregistered != []} class="wrong">
            {length(@unregistered)} enabled {if length(@unregistered) == 1,
              do: "schedule has",
              else: "schedules have"} no timer: {Enum.map_join(@unregistered, ", ", & &1.label)}
          </span>
        </div>
      </section>

      <section class="panel">
        <h2>Schedules</h2>

        <p :if={@schedules == []} class="note">Nothing is scheduled.</p>

        <div :for={schedule <- @schedules} class={["sched", !schedule.enabled && "paused"]}>
          <div class="row">
            <span class="name">{schedule.label}</span>
            <span class="val">{schedule.cron}</span>
            <.flap :if={schedule.enabled} state={status_state(schedule)}>
              {status_word(schedule)}
            </.flap>
          </div>
          <div class="detail">
            {schedule.device} · {schedule.action}{args(schedule)}
            <span :if={schedule.next_fire}>· next {fires_at(schedule)}</span>
          </div>
          <div :if={schedule.enabled && blocked(schedule)} class="why">{blocked(schedule)}</div>
          <div class="acts">
            <button type="button" phx-click="toggle" phx-value-id={schedule.id}>
              {if schedule.enabled, do: "pause", else: "resume"}
            </button>
            <button type="button" phx-click="delete" phx-value-id={schedule.id}>delete</button>
          </div>
        </div>

        <div :if={@deleted} class="undo">
          <button type="button" phx-click="restore">undo</button>
          <span>put back "{@deleted.label}"</span>
        </div>

        <.schedule_form form={@form} devices={@devices} arguments={@arguments} error={@error} />
      </section>

      <section class="panel feed">
        <h2>Activity</h2>

        <div id="activity" phx-update="stream">
          <div :for={{dom_id, entry} <- @streams.activity} id={dom_id} class="entry">
            <span class="t">{at(entry)}</span>
            <span class="kind">{entry.kind}</span>
            <span class="what">{what(entry)}</span>
            <span class="who">{entry.actor}</span>
            <span class="took">{took(entry)}</span>
          </div>
        </div>
      </section>
    </main>
    """
  end

  # A form over `Dobby.Schedules` and nothing more. The argument fields come
  # from the target action's own schema, so the form can only offer what the
  # row will accept — and a new device type brings its own fields rather than
  # needing a form written for it.
  attr :form, :map, required: true
  attr :devices, :list, required: true
  attr :arguments, :list, required: true
  attr :error, :string, default: nil

  defp schedule_form(assigns) do
    ~H"""
    <form id="new-schedule" class="new-sched" phx-change="form" phx-submit="create">
      <label>
        <span>Label</span>
        <input type="text" name="schedule[label]" value={@form["label"]} autocomplete="off" />
      </label>

      <label>
        <span>Cron</span>
        <input
          type="text"
          name="schedule[cron]"
          value={@form["cron"]}
          autocomplete="off"
          placeholder="0 20 * * 1-5"
        />
      </label>

      <label>
        <span>Device</span>
        <select name="schedule[target]">
          <option :for={device <- @devices} value={device.id} selected={device.id == @form["target"]}>
            {device.name}
          </option>
        </select>
      </label>

      <label>
        <span>Action</span>
        <select name="schedule[action]">
          <option
            :for={action <- actions(@devices, @form["target"])}
            value={action}
            selected={action == @form["action"]}
          >
            {action}
          </option>
        </select>
      </label>

      <label :for={argument <- @arguments}>
        <span>{argument.name}</span>
        <input
          type={input_type(argument.type)}
          step={if input_type(argument.type) == "number", do: "any"}
          name={"schedule[args][" <> argument.name <> "]"}
          value={@form["args"][argument.name]}
          autocomplete="off"
        />
      </label>

      <div :if={@error} class="why">{@error}</div>

      <button type="submit">Add</button>
    </form>
    """
  end

  # -- what a person does ----------------------------------------------------

  # Changing the device changes what can be scheduled on it, so the action and
  # its arguments are re-read rather than carried over. A form that kept
  # `set_temperature` selected after switching to a device that cannot do it
  # would be offering something the row will refuse.
  @impl true
  def handle_event("form", %{"schedule" => params}, socket) do
    form = normalize(params, socket.assigns.form, socket.assigns.devices)

    {:noreply, socket |> assign(:form, form) |> load_arguments()}
  end

  def handle_event("create", %{"schedule" => params}, socket) do
    form = normalize(params, socket.assigns.form, socket.assigns.devices)

    attrs = %{
      label: form["label"],
      cron: form["cron"],
      timezone: timezone(),
      target: form["target"],
      action: form["action"],
      args: form["args"],
      created_by: created_by(socket.assigns.speaker),
      created_via: :admin
    }

    case Schedules.create_schedule(attrs) do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> assign(:form, blank_form(socket.assigns.devices))
         |> assign(:error, nil)
         |> load_arguments()
         |> load_schedules()
         |> load_health()}

      {:error, changeset} ->
        {:noreply,
         socket |> assign(:form, form) |> assign(:error, Schedules.error_message(changeset))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with {:ok, schedule} <- Schedules.fetch(id),
         {:ok, _updated} <- Schedules.set_enabled(id, not schedule.enabled) do
      {:noreply, socket |> load_schedules() |> load_health() |> assign(:error, nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, :error, describe(reason))}
    end
  end

  # Deleted, then offered back for a few seconds — the same bargain the cards
  # make, and for the same reason. A confirm dialog would be the other answer
  # and this surface has already decided against training people to dismiss
  # them. The row comes back with a new id, which nothing references: a
  # schedule's timer is rebuilt from the rows at every write.
  def handle_event("delete", %{"id" => id}, socket) do
    case Schedules.delete_schedule(id) do
      {:ok, schedule} ->
        token = make_ref()
        Process.send_after(self(), {:undo_expired, token}, @undo_window)

        {:noreply,
         socket
         |> assign(:deleted, %{schedule: schedule, label: schedule.label, token: token})
         |> assign(:error, nil)
         |> load_schedules()
         |> load_health()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, describe(reason))}
    end
  end

  def handle_event("restore", _params, socket) do
    case socket.assigns.deleted do
      %{schedule: schedule} ->
        case Schedules.create_schedule(Map.from_struct(schedule)) do
          {:ok, _restored} ->
            {:noreply, socket |> assign(:deleted, nil) |> load_schedules() |> load_health()}

          # The device it aimed at may have left the manifest in the meantime,
          # which is a real answer and not a failure to undo.
          {:error, changeset} ->
            {:noreply,
             socket |> assign(:deleted, nil) |> assign(:error, Schedules.error_message(changeset))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # -- what the house does ---------------------------------------------------

  @impl true
  def handle_info({:recorded, entry}, socket) do
    {:noreply, stream_insert(socket, :activity, entry, at: 0, limit: @feed)}
  end

  # A firing changes what `next_fire` and `status` say, and both are computed
  # at read time — so the panel is re-read rather than patched.
  def handle_info(%Jido.Signal{type: "dobby.schedule.fired"}, socket) do
    {:noreply, socket |> load_schedules() |> load_health()}
  end

  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  def handle_info({:undo_expired, token}, socket) do
    case socket.assigns.deleted do
      %{token: ^token} -> {:noreply, assign(socket, :deleted, nil)}
      _superseded -> {:noreply, socket}
    end
  end

  # -- reads -----------------------------------------------------------------

  defp load_health(socket) do
    socket
    |> assign(:health, Health.rows())
    |> assign(:unregistered, Health.unregistered())
  end

  defp load_schedules(socket) do
    now = DateTime.utc_now()

    assign(socket, :schedules, Enum.map(Schedules.list_schedules(), &Schedules.describe(&1, now)))
  end

  defp load_arguments(socket) do
    %{"target" => target, "action" => action} = socket.assigns.form

    arguments =
      case Schedules.action_arguments(target || "", action || "") do
        {:ok, arguments} -> arguments
        {:error, _nothing_schedulable} -> []
      end

    assign(socket, :arguments, arguments)
  end

  # -- the form --------------------------------------------------------------

  # Resolved rather than empty, because the two selects are never empty on the
  # page: a form whose stored target was nil while the browser was showing the
  # first device would submit a schedule for nothing, and would clear the
  # arguments on the first keystroke because the action had "changed".
  defp blank_form(devices) do
    target = default_target(devices)

    %{
      "label" => "",
      "cron" => "",
      "target" => target,
      "action" => default_action(devices, target),
      "args" => %{}
    }
  end

  # The device drives the action and the action drives the arguments, so
  # changing one upstream clears what depended on it — a temperature typed for
  # a thermostat must not follow you to a device that does not take one.
  defp normalize(params, previous, devices) do
    target = params["target"] || previous["target"] || default_target(devices)

    action =
      if target == previous["target"],
        do: params["action"] || previous["action"],
        else: default_action(devices, target)

    args = if action == previous["action"], do: params["args"] || %{}, else: %{}

    %{
      "label" => params["label"] || "",
      "cron" => params["cron"] || "",
      "target" => target,
      "action" => action,
      "args" => args
    }
  end

  defp actions(devices, target) do
    case Enum.find(devices, &(&1.id == target)) do
      %{actions: actions} -> actions
      nil -> devices |> List.first(%{actions: []}) |> Map.fetch!(:actions)
    end
  end

  defp default_target(devices), do: devices |> List.first(%{}) |> Map.get(:id)

  defp default_action(devices, target), do: devices |> actions(target) |> List.first()

  defp input_type(type) do
    if numeric?(type), do: "number", else: "text"
  end

  defp numeric?({:or, types}), do: Enum.any?(types, &numeric?/1)
  defp numeric?(type), do: type in [:integer, :float, :number, :pos_integer, :non_neg_integer]

  defp timezone do
    Home.manifest().timezone
  rescue
    # No manifest and therefore no household clock. UTC is wrong and saying so
    # through a rejected cron is better than guessing a zone.
    ArgumentError -> "Etc/UTC"
  end

  defp created_by(nil), do: "admin"
  defp created_by(speaker), do: speaker.name

  # -- rendering -------------------------------------------------------------

  # READY, in plain lettering, because a schedule waiting for its time is not a
  # state the house is *in* — that is exactly what Expected Cream is for.
  #
  # HELD for one that can no longer reach its device: nothing declined it, but
  # the shape is the same and so is the treatment — it will not run, there is a
  # reason, and the reason goes on its own line beneath.
  #
  # A paused schedule gets **no flap at all**, and that is the deliberate part.
  # None of the eight words means "somebody switched this off": QUIET is an
  # endpoint that stopped answering and HELD is a device declining. Bending one
  # of them to fit would put a word on the board that means two things, and a
  # ninth word is a design decision rather than a CSS change. The row going
  # quiet and its button saying "resume" says it without a word.
  defp status_word(%{status: "active"}), do: "Ready"
  defp status_word(_blocked), do: "Held"

  defp status_state(%{status: "active"}), do: :expected
  defp status_state(_blocked), do: :refused

  defp blocked(%{status: "active"}), do: nil
  defp blocked(%{status: status}), do: status

  defp args(%{args: args}) when map_size(args) > 0 do
    " " <> Enum.map_join(args, ", ", fn {key, value} -> "#{key} #{value}" end)
  end

  defp args(_schedule), do: ""

  defp fires_at(%{next_fire: iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at |> Home.local() |> Calendar.strftime("%a %-I:%M %p")
      _unparseable -> iso
    end
  end

  defp fires_at(_schedule), do: nil

  # The household's own clock, the same as the thread's: two people reading the
  # same record must not see two different times.
  defp at(entry) do
    entry.inserted_at |> Home.local() |> Calendar.strftime("%-I:%M:%S %p")
  end

  defp what(%{device: nil, action: action}), do: action
  defp what(%{device: device, action: nil}), do: device
  defp what(%{device: device, action: action}), do: "#{device} · #{action}"

  defp took(%{duration_ms: ms}) when is_integer(ms) and ms > 0 do
    :erlang.float_to_binary(ms / 1000, decimals: 1) <> " s"
  end

  defp took(_entry), do: nil

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%Ecto.Changeset{} = changeset), do: Schedules.error_message(changeset)
  defp describe(reason), do: inspect(reason)

  defp listening?, do: is_pid(Dobby.Jido.whereis(Dobby.DobbyAgent.id()))
end
