defmodule DobbyWeb.AdminLive do
  @moduledoc """
  What the house has been doing, what it is going to do, and whether it is
  there at all (design §10.6).

  Laptop-shaped and open to the house, like everything else here — LAN-only,
  flat trust, the Wi-Fi password is the boundary. There is no admin *role*,
  because there is no role system; this page is a different question, not a
  different permission.

  Four sections and the order is deliberate. Health first because it is three
  lines and it changes what the other two mean. Schedules next because they are
  the thing on this page changed most often. The system panel under them,
  because a model alias or a port is changed once and then left alone, and
  because it is about the box rather than the house the three around it
  describe. The feed last because it is the long one, and because you scroll to
  a log rather than being handed it.

  Above all three, the topology (TK-016): the diagram is not one of the
  maintainer's three questions, it is the map they are asked about, and it is
  the one thing here that has to be looked at before it can be read.

  ## The topology's reads are the load-bearing part

  Nothing on this page asks a running agent anything on a timer.
  `Jido.AgentServer.state/1` is a synchronous call that queues in the agent's
  mailbox, and for `DobbyAgent` that is behind an in-flight ReAct turn — the
  same queuing `Dobby.Home.await_ready/1` uses deliberately as a boot barrier.
  A polling panel would inherit the model's latency and give every open browser
  a place in that queue.

  So: state once, at mount, through `Dobby.Home.snapshots/0`, which answers
  from the manifest for anything that is not running. Liveness by
  `Process.monitor` on each agent's pid, since `Dobby.Jido.whereis/1` is an ETS
  read and a `:DOWN` costs nothing until it happens. Currency from
  `dobby:devices` and `dobby:home_assistant`. The only timer in the file is the
  re-lookup after a `:DOWN`, which is how the supervisor's restart is noticed —
  a Registry read, never an agent call.

  ## The feed is the full record

  Everything: requests, tool calls, controls somebody touched, schedules
  firing, and an endpoint flapping at 3am. The thread's interventions are a
  subset of this (design §10.3) — the thread is a document a household reads
  and this is the log behind it, which is why the endpoint at 3am reaches here
  and stops.
  """

  use DobbyWeb, :live_view

  # The panel only; the rest of that module is what this one calls it by name.
  import DobbyWeb.AdminLive.SystemPanel, only: [system: 1]
  import DobbyWeb.AdminLive.TokensPanel, only: [tokens: 1]
  import DobbyWeb.AdminLive.Topology
  import DobbyWeb.Board
  import DobbyWeb.Flap
  import DobbyWeb.Fields

  alias Dobby.Activity
  alias Dobby.ActivityEvents
  alias Dobby.ConfigEvents
  alias Dobby.DeviceEvents
  alias Dobby.Health
  alias Dobby.Home
  alias Dobby.HomeAssistant.Connection
  alias Dobby.HomeConfig.Applied
  alias Dobby.ScheduleEvents
  alias Dobby.SchedulerAgent
  alias Dobby.Schedules
  alias Dobby.Topology
  alias DobbyWeb.AdminLive.SystemPanel
  alias DobbyWeb.AdminLive.TokensPanel
  alias DobbyWeb.Fields

  @feed 100
  @undo_window 8_000

  # The five sections, in the order the rail reads them. Same names the panels
  # carried as headings, because the rail *is* those headings — the order is
  # still the argument it always was: the map first because it is what the
  # other four are asked about, then health because it changes what schedules
  # mean, then the thing changed most often, then the box, then the log you
  # scroll to rather than being handed.
  @sections [
    topology: "Topology",
    health: "Health",
    schedules: "Schedules",
    system: "System",
    activity: "Activity"
  ]

  # How long to wait before looking for an agent again after its `:DOWN`. The
  # supervisor is usually finished inside a millisecond; the doubling is for
  # the case it never will be, so a device that has left for good costs one
  # registry read every five seconds instead of one every fifth of one.
  @relook 200
  @relook_max 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ActivityEvents.subscribe()
      ScheduleEvents.subscribe()
      DeviceEvents.subscribe()
      Connection.subscribe()
      ConfigEvents.subscribe()
    end

    devices = Schedules.schedulable_devices()
    feed = Activity.recent(@feed)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:listening, listening?())
     |> assign(:error, nil)
     |> assign(:trouble, nil)
     |> assign(:deleted, nil)
     |> assign(:devices, devices)
     |> assign(:form, blank_form(devices))
     # A stream cannot be asked whether it is empty, and a heading with a void
     # under it is the one panel here that says nothing when it has nothing.
     |> assign(:blank_feed, feed == [])
     |> load_arguments()
     |> load_health()
     |> load_schedules()
     |> load_system()
     |> load_tokens()
     |> watch_house()
     |> stream(:activity, feed)}
  end

  # Which section, from the address rather than from a click. A LiveView that
  # loses its socket remounts on the URL it is on, so a page left open on the
  # feed comes back to the feed instead of to the map — which a click handler
  # holding this in an assign could not do.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, show(socket, section(params["section"]))}
  end

  defp sections, do: @sections

  defp section(name) do
    Enum.find_value(@sections, :topology, fn {key, _label} ->
      if Atom.to_string(key) == name, do: key
    end)
  end

  # The feed is in the DOM only while its own section is showing, so entries
  # arriving behind another section have nowhere to land. Re-reading on the way
  # in is the honest answer: a hundred rows held open behind four other
  # sections would be a stream kept current for nobody, and the read is one
  # query against a Postgres in the same box.
  defp show(socket, :activity) do
    feed = Activity.recent(@feed)

    socket
    |> assign(:section, :activity)
    |> assign(:blank_feed, feed == [])
    |> stream(:activity, feed, reset: true)
  end

  defp show(socket, section), do: assign(socket, :section, section)

  @impl true
  def render(assigns) do
    ~H"""
    <header class="board">
      <.plate speaker={@speaker} listening={@listening} section="Admin" return_to={~p"/admin"} />
    </header>

    <%!-- The five panel headings this page already had, rotated from a column
          into a row. The section you are reading stays brass and the rest go
          faint, which is how this board has always told a subject apart from
          its record-keeping — so nothing new is drawn here. That is what makes
          it the board's own index rather than the shell of links The No Nav
          Rule bans: navigation between *routes* is still the nameplate, the
          band and one quiet link, and this changes which part of one page is
          showing. --%>
    <div class="rail">
      <.link
        :for={{key, name} <- sections()}
        patch={~p"/admin?section=#{key}"}
        class={key == @section && "on"}
        aria-current={key == @section && "page"}
      >
        {name}
      </.link>
    </div>

    <%!-- One section at a time, and it is the only thing on this page that
          scrolls. The two columns before it shared one scroll container, so a
          hundred entries of log dragged health, schedules and system off the
          top — the panels you came to change were hostage to the length of the
          one you came to read. --%>
    <main class="admin">
      <%!-- The map. It is a section like the other four rather than a banner
            over them: at the span it can no longer divide N ways and stay
            readable, so it takes the page while it is being looked at. --%>
      <.topology
        :if={@section == :topology}
        topology={@topology}
        snapshots={@snapshots}
        live={@live}
        ha_status={@ha_status}
        changed_at={@changed_at}
        timers={@timers}
        unregistered={@unregistered}
        pulses={@pulses}
      />

      <section :if={@section == :health} class="panel">
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
        <%!-- "That can run", not "enabled": `unregistered` measures the
              schedules that are enabled *and* still able to reach their
              device, so the wider claim reads as a flat contradiction of a
              HELD row sitting two lines below it. --%>
        <div class="note">
          <span :if={@unregistered == []}>Every schedule that can run has a timer.</span>
          <span :if={@unregistered != []} class="wrong">
            {length(@unregistered)} enabled {if length(@unregistered) == 1,
              do: "schedule has",
              else: "schedules have"} no timer: {Enum.map_join(@unregistered, ", ", & &1.label)}
          </span>
        </div>
      </section>

      <section :if={@section == :schedules} class="panel">
        <%!-- One line, and it is the stronger of the two: a house with nothing
              schedulable obviously has nothing scheduled, and saying both
              stacks two negations where one is the answer. --%>
        <p :if={@schedules == [] && @devices != []} class="note">Nothing is scheduled.</p>

        <div :for={schedule <- @schedules} class={["sched", !schedule.enabled && "paused"]}>
          <div class="row">
            <span class="name">{schedule.label}</span>
            <span class="val">{schedule.cron}</span>
            <.flap :if={schedule.enabled} state={status_state(schedule)}>
              {status_word(schedule)}
            </.flap>
          </div>
          <%!-- The identifiers as identifiers, and the time as a time. --%>
          <div class="detail">
            <span class="arg">{schedule.device} · {schedule.action}{args(schedule)}</span>
            <span :if={schedule.next_fire}>· next {fires_at(schedule)}</span>
          </div>
          <div :if={schedule.enabled && blocked(schedule)} class="why">{blocked(schedule)}</div>
          <div class="acts">
            <button type="button" phx-click="toggle" phx-value-id={schedule.id}>
              {if schedule.enabled, do: "pause", else: "resume"}
            </button>
            <button type="button" class="takes" phx-click="delete" phx-value-id={schedule.id}>
              delete
            </button>
          </div>
        </div>

        <div :if={@deleted} class="undo">
          <button type="button" phx-click="restore">undo</button>
          <span>put back "{@deleted.label}"</span>
        </div>

        <%!-- Pausing, deleting or restoring an existing schedule can fail, and
              its reason belongs beside the schedules — not under the new
              schedule form's last field, where it reads as a rejection of
              what somebody is still typing. --%>
        <div :if={@trouble} class="why">{@trouble}</div>

        <%!-- A house with nothing schedulable used to get the form anyway: two
              empty selects and an `add` that could only be refused. The form
              is offered when there is something for it to act on. --%>
        <p :if={@devices == []} class="note">Nothing in this house can be scheduled.</p>

        <.schedule_form
          :if={@devices != []}
          form={@form}
          devices={@devices}
          arguments={@arguments}
          error={@error}
        />
      </section>

      <%!-- The box rather than the house: a model alias, a port, whether Dobby
            answers on the household network. Its own section because every
            field on it is the maintainer's, which is the one panel here where
            that is true of all of them. --%>
      <.system
        :if={@section == :system}
        config={@system_config}
        form={@system_form}
        effects={@effects}
        error={@system_error}
      />

      <%!-- Under the system fields, because it is the same subject — who and
            what may reach this box — and the same reader. The keys to the MCP
            door: minted here, labeled for the record, revocable here. --%>
      <.tokens
        :if={@section == :system}
        tokens={@tokens}
        minted={@minted}
        label={@token_label}
        error={@token_error}
      />

      <section :if={@section == :activity} class="panel feed">
        <p :if={@blank_feed} class="note">Nothing recorded yet.</p>

        <div id="activity" phx-update="stream">
          <div :for={{dom_id, entry} <- @streams.activity} id={dom_id} class="entry">
            <span class="t">{at(entry)}</span>
            <span class="kind">{kind(entry)}</span>
            <span class="what arg">{what(entry)}</span>
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
    assigns = assign(assigns, :registers, Fields.registers(assigns.arguments))

    ~H"""
    <form id="new-schedule" class="fields new-sched" phx-change="form" phx-submit="create">
      <.field ask="What to call this" key="label">
        <input type="text" name="schedule[label]" value={@form["label"]} autocomplete="off" />
      </.field>

      <%!-- The question is when, and the answer is cron. The placeholder does
            the teaching rather than a sentence about five fields — a specimen
            of the thing is shorter than a description of it, and this one is a
            weeknight at eight. --%>
      <.field ask="When it fires" key="cron">
        <input
          type="text"
          name="schedule[cron]"
          value={@form["cron"]}
          autocomplete="off"
          placeholder="0 20 * * 1-5"
        />
      </.field>

      <.field ask="What it acts on" key="target">
        <select name="schedule[target]">
          <option :for={device <- @devices} value={device.id} selected={device.id == @form["target"]}>
            {device.name}
          </option>
        </select>
      </.field>

      <.field ask="What it does" key="action">
        <select name="schedule[action]">
          <option
            :for={action <- actions(@devices, @form["target"])}
            value={action}
            selected={action == @form["action"]}
          >
            {action}
          </option>
        </select>
      </.field>

      <%!-- The action's own arguments, asking in the words its schema declares
            them in. Nobody wrote these labels: they are the same `:doc` the
            model is handed as the argument's description, so a question this
            form can ask is one the model was told too. --%>
      <.field :for={argument <- elem(@registers, 0)} ask={argument.ask} key={argument.name}>
        <.argument argument={argument} value={@form["args"][argument.name]} />
      </.field>

      <%!-- An argument whose schema declares no `:doc` has no question to ask,
            here or in the tool schema. It falls to the second register, which
            is where a person will see that it is missing. --%>
      <.named
        :if={elem(@registers, 1) != []}
        say="The action's schema says nothing about these, so neither does this form."
      />

      <.field :for={argument <- elem(@registers, 1)} key={argument.name}>
        <.argument argument={argument} value={@form["args"][argument.name]} />
      </.field>

      <div :if={@error} class="why">{@error}</div>

      <%!-- Lower case, like every other quiet control on this board. It is a
            verb, and capitals here mean a state, a name or a time. --%>
      <button type="submit">add</button>
    </form>
    """
  end

  # One argument's control, typed by the schema that declared it. A boolean is
  # two words in a select and never a tick — the same call the system panel
  # makes, which is now the same code.
  attr :argument, :map, required: true
  attr :value, :any, default: nil

  defp argument(assigns) do
    assigns = assign(assigns, :input, Fields.input_type(assigns.argument.type))

    ~H"""
    <select :if={@input == "select"} name={"schedule[args][" <> @argument.name <> "]"}>
      <option value="false" selected={to_string(@value) != "true"}>no</option>
      <option value="true" selected={to_string(@value) == "true"}>yes</option>
    </select>

    <input
      :if={@input != "select"}
      type={@input}
      step={if @input == "number", do: "any"}
      name={"schedule[args][" <> @argument.name <> "]"}
      value={@value}
      autocomplete="off"
    />
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
      {:noreply, socket |> load_schedules() |> load_health() |> assign(:trouble, nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, :trouble, describe(reason))}
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
         |> assign(:trouble, nil)
         |> load_schedules()
         |> load_health()}

      {:error, reason} ->
        {:noreply, assign(socket, :trouble, describe(reason))}
    end
  end

  # The system panel has no cascade — a port does not change what a model can
  # be — so this only remembers what is in the boxes, which is what keeps them
  # holding it across the feed streaming an entry in underneath.
  def handle_event("system", %{"system" => params}, socket) do
    {:noreply, assign(socket, :system_form, SystemPanel.entered(params))}
  end

  # Through the one writer, always. Its answer is applied here as well as on
  # `dobby:config`, so the browser that asked sees its own save land without
  # waiting for the announcement — and applying it twice says the same thing
  # twice, which is the point of the announcement being a fact rather than an
  # instruction.
  def handle_event("save", %{"system" => params}, socket) do
    case SystemPanel.save(socket.assigns.system_config, params) do
      {:ok, applied} ->
        {:noreply, socket |> assign(:system_error, nil) |> take_config(applied)}

      # The typing stays where it was, beside the reason it was refused.
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:system_form, SystemPanel.entered(params))
         |> assign(:system_error, reason)}
    end
  end

  def handle_event("token", %{"token" => %{"label" => label}}, socket) do
    {:noreply, assign(socket, :token_label, label)}
  end

  # The one moment the plaintext exists outside `Dobby.MCP`: minted, shown
  # beside its label, and held only in this assign — a refresh, a revisit or
  # the next mint and it is gone for good, which is what the sentence next to
  # it says. The label box clears because its job is done; a refused label
  # stays put beside the reason, like every other form here.
  def handle_event("mint", %{"token" => %{"label" => label}}, socket) do
    case Dobby.MCP.mint(label) do
      {:ok, plaintext, token} ->
        {:noreply,
         socket
         |> assign(:minted, %{label: token.label, token: plaintext})
         |> assign(:token_label, "")
         |> assign(:token_error, nil)
         |> assign(:tokens, TokensPanel.list())}

      {:error, reason} ->
        {:noreply, socket |> assign(:token_label, label) |> assign(:token_error, reason)}
    end
  end

  # No undo, deliberately, where a schedule gets one: a deleted schedule can
  # be put back because Dobby still knows everything about it, but a revoked
  # token's plaintext is exactly what Dobby does not keep. Putting the row
  # back would restore the label and not the key — an undo that looks like
  # one and isn't. Minting a fresh token is the honest path back in.
  def handle_event("revoke", %{"id" => id}, socket) do
    case Dobby.MCP.revoke(id) do
      {:ok, _token} ->
        {:noreply, socket |> assign(:token_error, nil) |> assign(:tokens, TokensPanel.list())}

      {:error, reason} ->
        {:noreply, assign(socket, :token_error, reason)}
    end
  end

  def handle_event("restore", _params, socket) do
    case socket.assigns.deleted do
      %{schedule: schedule} ->
        case Schedules.create_schedule(Map.from_struct(schedule)) do
          {:ok, _restored} ->
            {:noreply, socket |> assign(:deleted, nil) |> load_schedules() |> load_health()}

          # The device it aimed at may have left the manifest in the meantime,
          # which is a real answer and not a failure to undo. It belongs beside
          # the schedules: the row it is about is the one that just failed to
          # come back, and there is no row left to hang it on.
          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:deleted, nil)
             |> assign(:trouble, Schedules.error_message(changeset))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # -- what the house does ---------------------------------------------------

  # The pulse lands whatever section is showing — it is the topology's, and a
  # wire that only lit while somebody was watching the log would be a diagram
  # that lies about a quiet house. The row is the feed's, and waits for it.
  @impl true
  def handle_info({:recorded, entry}, socket) do
    {:noreply, socket |> pulse(entry) |> record(entry)}
  end

  # Only the newest pulse's own timer may darken its wire — an older timer
  # firing under fresh traffic would flicker a line that is honestly busy.
  def handle_info({:pulse_fade, wire, count}, socket) do
    case socket.assigns.pulses do
      %{^wire => ^count} ->
        {:noreply, assign(socket, :pulses, Map.delete(socket.assigns.pulses, wire))}

      _newer_pulse ->
        {:noreply, socket}
    end
  end

  # The file changed, by whatever path — this browser, another one, or the
  # household thread once it can. The panel is always current with the *applied*
  # configuration, which is what buys v1 out of needing a file watcher.
  #
  # Only the system half is taken. A changed house is a restarted house, and
  # what that means for the topology, the health rows and the schedules on this
  # page is `/house`'s question to answer when it can make one.
  def handle_info({:applied, %Applied{} = applied}, socket) do
    {:noreply, take_config(socket, applied)}
  end

  # A firing changes what `next_fire` and `status` say, and both are computed
  # at read time — so the panel is re-read rather than patched.
  def handle_info(%Jido.Signal{type: "dobby.schedule.fired"}, socket) do
    {:noreply, socket |> load_schedules() |> load_health()}
  end

  # The event carries the snapshot, so the node is updated from what arrived
  # rather than by asking the agent that just told us. The stamp follows the
  # log's own rule — `moved` and not `changed` — so "since" on a node means
  # what "device changed" means in the feed underneath it, and a device
  # reporting for the first time does not read as one that just moved.
  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: data}, socket) do
    {:noreply,
     socket
     |> put_snapshot(data[:device], data[:snapshot])
     |> stamp(data)
     |> assign(:listening, listening?())}
  end

  def handle_info(%Jido.Signal{}, socket), do: {:noreply, socket}

  # Re-read rather than taken from the message: a client that has *died* cannot
  # send anything, and the read covers that case as well as the one that just
  # arrived.
  def handle_info({:home_assistant, _status}, socket) do
    {:noreply, assign(socket, :ha_status, Connection.status())}
  end

  # An agent went down. The node says so immediately — a restart should be
  # visibly a restart — and a re-lookup goes on the clock to catch the
  # supervisor putting it back.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Map.pop(socket.assigns.watching, ref) do
      {nil, _watching} ->
        {:noreply, socket}

      {id, watching} ->
        {:noreply,
         socket
         |> assign(:watching, watching)
         |> put_live(id, false)
         |> look_again(id, @relook)}
    end
  end

  # The restarted agent is a new process and knows nothing: it came back with
  # the state it was built with, so its snapshot is dropped rather than
  # re-read. NOT KNOWN is what it has been told, and the first thing Home
  # Assistant says about the device fills it in.
  def handle_info({:look_for, id, delay}, socket) do
    case Dobby.Jido.whereis(id) do
      pid when is_pid(pid) ->
        {:noreply,
         socket
         |> monitor(id, pid)
         |> put_live(id, true)
         |> put_snapshot(id, nil)
         |> assign(:listening, listening?())}

      nil ->
        {:noreply, look_again(socket, id, min(delay * 2, @relook_max))}
    end
  end

  def handle_info({:undo_expired, token}, socket) do
    case socket.assigns.deleted do
      %{token: ^token} -> {:noreply, assign(socket, :deleted, nil)}
      _superseded -> {:noreply, socket}
    end
  end

  # -- reads -----------------------------------------------------------------

  # One read, because it is one fact seen from three sides: the health rows,
  # the scheduler node's badge and the scheduler's own wires all come out of
  # the schedule rows, so a write that changes any of them changes all three.
  defp load_health(socket) do
    socket
    |> assign(:health, Health.rows())
    |> assign(:unregistered, Health.unregistered())
    |> assign(:timers, SchedulerAgent.timers())
    |> assign(:ha_status, Connection.status())
    |> load_topology()
  end

  # Once, when the page opens. `dobby:config` keeps it current after that.
  defp load_system(socket) do
    config = SystemPanel.current()

    socket
    |> assign(:system_config, config)
    |> assign(:system_form, SystemPanel.values(config))
    |> assign(:system_error, nil)
    |> assign(:effects, %{})
  end

  # Once, when the page opens. The rows change only through this page's own
  # mint and revoke, which re-read as they go.
  defp load_tokens(socket) do
    socket
    |> assign(:tokens, TokensPanel.list())
    |> assign(:minted, nil)
    |> assign(:token_label, "")
    |> assign(:token_error, nil)
  end

  # The boxes are refilled from what was applied, including under a hand that
  # was typing: two browsers editing one knob is exactly the argument the single
  # writer exists to settle, and showing the value that won is the honest half
  # of settling it.
  defp take_config(socket, %Applied{} = applied) do
    socket
    |> assign(:system_config, applied.config)
    |> assign(:system_form, SystemPanel.values(applied.config))
    |> assign(:effects, SystemPanel.effects(socket.assigns.effects, applied))
  end

  # Nodes and edges only — configuration, and cheap enough to take again
  # whenever a schedule moves. Nothing here asks a running process anything.
  defp load_topology(socket), do: assign(socket, :topology, Topology.read())

  # Everything the diagram needs that is not configuration, taken once. The
  # snapshots are the only synchronous agent reads on this page, and
  # `Dobby.Home.snapshots/0` answers from the manifest for anything that is not
  # running rather than leaving a hole in the drawing.
  defp watch_house(socket) do
    socket
    |> assign(:snapshots, snapshots())
    |> assign(:changed_at, Activity.last_changes())
    |> assign(:live, %{})
    |> assign(:watching, %{})
    |> assign(:pulses, %{})
    |> assign(:pulse_count, 0)
    |> then(fn socket -> Enum.reduce(Topology.agent_ids(), socket, &watch(&2, &1)) end)
  end

  # A registry lookup and a monitor, and that is the whole liveness mechanism.
  # `Dobby.Jido.whereis/1` is an ETS read, so this costs nothing per agent and
  # nothing at all until something dies.
  defp watch(socket, id) do
    case Dobby.Jido.whereis(id) do
      pid when is_pid(pid) -> socket |> monitor(id, pid) |> put_live(id, true)
      nil -> socket |> put_live(id, false) |> look_again(id, @relook)
    end
  end

  # Only a connected browser is watching. A dead render monitors nothing and
  # arms no timer — it is thrown away as soon as the socket connects.
  defp monitor(socket, id, pid) do
    if connected?(socket) do
      ref = Process.monitor(pid)
      assign(socket, :watching, Map.put(socket.assigns.watching, ref, id))
    else
      socket
    end
  end

  defp look_again(socket, id, delay) do
    if connected?(socket), do: Process.send_after(self(), {:look_for, id, delay}, delay)
    socket
  end

  defp put_live(socket, id, alive?),
    do: assign(socket, :live, Map.put(socket.assigns.live, id, alive?))

  # The feed entry, said on the drawing (TK-016 step two): each recorded entry
  # names an edge, and the edge it names lights for a moment. Pure ornament on
  # a topic this page already subscribes to — the map of what the entry means
  # is the same one the wires were drawn from, so a pulse can only travel a
  # wire that exists.
  #
  # A `request` pulses nothing: it is a person speaking to Dobby, and people
  # are deliberately not on this drawing.
  @pulse_for %{
    "tool_call" => :command,
    "schedule_fired" => :command,
    "control" => :house,
    "device_changed" => :house
  }

  defp record(%{assigns: %{section: :activity}} = socket, entry) do
    socket
    |> assign(:blank_feed, false)
    |> stream_insert(:activity, entry, at: 0, limit: @feed)
  end

  defp record(socket, _entry), do: socket

  defp pulse(socket, %{kind: kind, device: device}) when is_binary(device) do
    case Map.get(@pulse_for, kind) do
      # The commanded wire's far end is the director the entry attributes it
      # to; the house wire always runs from the device to the client.
      :command -> light(socket, {director(kind), device})
      :house -> light(socket, {device, Topology.house_id()})
      nil -> socket
    end
  end

  defp pulse(socket, _entry), do: socket

  defp director("schedule_fired"), do: Dobby.SchedulerAgent.id()
  defp director(_tool_call), do: Dobby.DobbyAgent.id()

  # A busy wire stays lit rather than flickering: each pulse takes a fresh
  # count, and only the fade carrying the current count darkens the wire.
  @pulse_ms 700

  defp light(socket, wire) do
    count = socket.assigns.pulse_count + 1

    if connected?(socket), do: Process.send_after(self(), {:pulse_fade, wire, count}, @pulse_ms)

    socket
    |> assign(:pulse_count, count)
    |> assign(:pulses, Map.put(socket.assigns.pulses, wire, count))
  end

  defp put_snapshot(socket, nil, _snapshot), do: socket

  defp put_snapshot(socket, id, nil),
    do: assign(socket, :snapshots, Map.delete(socket.assigns.snapshots, id))

  defp put_snapshot(socket, id, snapshot),
    do: assign(socket, :snapshots, Map.put(socket.assigns.snapshots, id, snapshot))

  # `moved` and not `changed`, which is the rule the activity log is written by
  # — a device reporting a value for the first time is the house learning what
  # it has, not something that happened in it.
  defp stamp(socket, %{device: device, moved: [_something | _]}) when is_binary(device) do
    assign(socket, :changed_at, Map.put(socket.assigns.changed_at, device, DateTime.utc_now()))
  end

  defp stamp(socket, _data), do: socket

  defp snapshots do
    Home.snapshots()
  rescue
    # No manifest, or the house is restarting under a page somebody left open.
    ArgumentError -> %{}
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

    assign(socket, :arguments, Enum.map(arguments, &Map.put(&1, :ask, Fields.ask(&1[:doc]))))
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

  # The one column here that is neither an identifier nor a time: it names what
  # sort of record a row is, which is the board's own vocabulary about its own
  # log and therefore a label. The underscore is how the value is stored, not
  # what it means — and a shouted underscore is the audit test for The
  # Identifier Rule, which this column would otherwise fail while not being one.
  defp kind(%{kind: kind}), do: kind |> to_string() |> String.replace("_", " ")

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
