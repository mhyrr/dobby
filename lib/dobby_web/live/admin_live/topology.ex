defmodule DobbyWeb.AdminLive.Topology do
  @moduledoc """
  The house's command hierarchy, drawn (TK-016, `DESIGN.md`).

  Three tiers and two bands of wire. The directors on top — Dobby, who is
  probabilistic, and the scheduler, which is a clock — then one node per device
  in the manifest, then the one client every device speaks to the house
  through. Read top to bottom it says the thing design §1.1 says in a
  paragraph: **probabilistic above, deterministic below**, and the two words
  under the two directors are where that is stated rather than implied.

  ## Plain nodes and SVG wires, and nothing else

  No graph library and no JS. A node is a board row that lost its middle
  column, using the same name, flap and vocabulary as every other row on this
  surface — a diagram in a second visual language would be a second product.

  The wires are one `<svg>` per band with a `0 0 100 10` viewBox and
  `preserveAspectRatio="none"`, so x is a percentage of whatever width the
  panel got and the arithmetic is the tier's own grid: node *i* of *n* sits at
  `(i + 0.5) / n`. That is the whole layout engine, and it is why nothing here
  has to measure anything in a browser. The strokes carry
  `vector-effect="non-scaling-stroke"`, without which that horizontal stretch
  would draw a hairline at one weight across the panel and another down it.

  Brass, never a state colour: a wire is structure, and structure is what brass
  marks on this board. The words on the flaps are the only saturation here,
  exactly as they are everywhere else.

  ## What the nodes say

  A device node says what the device says on `/house` — its own word, its own
  reading — *while its agent is running*. When the agent is not, the node says
  `QUIET`, which is what the health row beside it means by the same word: this
  is a fact about a process, and it may honestly disagree with what the device
  itself would say. A device whose agent has just come back says `NOT KNOWN`,
  because a restarted agent has been told nothing yet.
  """

  use DobbyWeb, :html

  import DobbyWeb.Flap

  alias Dobby.Home

  @doc """
  The panel.
  """
  attr :topology, :map, required: true, doc: "nodes and edges, from Dobby.Topology"
  attr :snapshots, :map, required: true, doc: "device id => snapshot, absent when unknown"
  attr :live, :map, required: true, doc: "registry id => whether that agent is running"
  attr :ha_status, :atom, required: true
  attr :changed_at, :map, default: %{}, doc: "device id => when it last moved"
  attr :timers, :integer, default: 0
  attr :unregistered, :list, default: []
  attr :pulses, :map, default: %{}, doc: "{from, to} => the traffic lighting that wire"

  def topology(assigns) do
    assigns =
      assigns
      |> assign(:devices, assigns.topology.devices)
      |> assign(:places, places(assigns.topology))
      |> assign(:dobby, director(assigns.topology, :dobby))
      |> assign(:scheduler, director(assigns.topology, :scheduler))

    ~H"""
    <section class="panel topology">
      <h2>Topology</h2>

      <div class="topo">
        <div class="tier directors">
          <.part
            part={@dobby}
            reading={dobby_reading(@live)}
            notes={[note("Probabilistic"), note(@dobby.detail, "arg")]}
          />
          <.part
            part={@scheduler}
            reading={agent_reading(@live, @scheduler.agent_id)}
            notes={[note("Deterministic"), note(timers(@timers)), note(badge(@unregistered), "wrong")]}
          />
        </div>

        <.wires
          :if={@devices != []}
          edges={@topology.edges}
          band={:command}
          places={@places}
          pulses={@pulses}
        />

        <%!-- A house with nothing in it has no middle tier, and says so in the
              record voice rather than leaving a gap between two wires. --%>
        <p :if={@devices == []} class="note">
          No devices. The house is described in <span class="file arg">home.yaml</span> on the box.
        </p>

        <div :if={@devices != []} class="tier devices" style={"--n: #{length(@devices)}"}>
          <.part
            :for={device <- @devices}
            part={device}
            reading={device_reading(@live, @snapshots, device)}
            notes={[note(since(@changed_at[device.id]))]}
          />
        </div>

        <.wires
          :if={@devices != []}
          edges={@topology.edges}
          band={:house}
          places={@places}
          pulses={@pulses}
        />

        <div class="tier house">
          <.part
            part={@topology.house}
            reading={house_reading(@ha_status)}
            notes={[note(@topology.house.detail, "arg"), note(trying(@ha_status))]}
          />
        </div>
      </div>
    </section>
    """
  end

  # A board row that lost its middle column: the name, then the word, then
  # whatever small true things the tier has room for underneath.
  attr :part, :map, required: true
  attr :reading, :map, required: true
  attr :notes, :list, default: []

  defp part(assigns) do
    assigns = assign(assigns, :notes, Enum.reject(assigns.notes, &is_nil/1))

    ~H"""
    <div class="topo-node" data-part={@part.id}>
      <span class="name">{@part.name}</span>
      <span class="read">
        <.flap state={@reading.state}>{@reading.word}</.flap>
        <span :if={@reading.value} class="val">{@reading.value}</span>
      </span>
      <span :for={note <- @notes} class={["note", note.class]}>{note.text}</span>
    </div>
    """
  end

  # One band of wire. The viewBox is a percentage grid stretched over the
  # panel's real width, so a line's ends are the two tiers' own column centres
  # and nothing has to be measured at runtime.
  attr :edges, :list, required: true
  attr :band, :atom, required: true
  attr :places, :map, required: true
  attr :pulses, :map, default: %{}

  defp wires(assigns) do
    assigns = assign(assigns, :lines, lines(assigns.edges, assigns.band, assigns.places))

    ~H"""
    <svg class="wires" viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true">
      <line
        :for={line <- @lines}
        class={["wire", Map.has_key?(@pulses, {line.from, line.to}) && "pulse"]}
        x1={line.x1}
        y1="0"
        x2={line.x2}
        y2="10"
        vector-effect="non-scaling-stroke"
        data-from={line.from}
        data-to={line.to}
      />
    </svg>
    """
  end

  # -- where everything sits -------------------------------------------------

  # Node *i* of *n* in a tier of equal columns sits at the centre of its own
  # column. Two directors land at 25 and 75, one client at 50, and the devices
  # divide the width between them — which is the same arithmetic the tier's
  # `repeat(var(--n), 1fr)` does, said once in each language.
  defp places(topology) do
    %{}
    |> place(topology.directors)
    |> place(topology.devices)
    |> place([topology.house])
  end

  defp place(places, nodes) do
    count = length(nodes)

    nodes
    |> Enum.with_index()
    |> Enum.reduce(places, fn {node, index}, places ->
      Map.put(places, node.id, Float.round((index + 0.5) / count * 100, 2))
    end)
  end

  defp lines(edges, band, places) do
    for %{band: ^band} = edge <- edges,
        x1 = places[edge.from],
        x2 = places[edge.to],
        x1 && x2 do
      %{from: edge.from, to: edge.to, x1: x1, x2: x2}
    end
  end

  # -- what each node reads --------------------------------------------------

  defp director(topology, kind), do: Enum.find(topology.directors, &(&1.kind == kind))

  # The plate's own two words, for the fact the plate reports: Dobby attending,
  # or not. Two places on one page saying the same thing must say it the same
  # way.
  defp dobby_reading(live) do
    if alive?(live, "dobby"),
      do: %{word: "Listening", state: :acting, value: nil},
      else: %{word: "Quiet", state: :silent, value: nil}
  end

  defp agent_reading(live, id) do
    if alive?(live, id),
      do: %{word: "Awake", state: :acting, value: nil},
      else: %{word: "Quiet", state: :silent, value: nil}
  end

  # Three cases and they are three different facts: the agent is not running,
  # which is what the health row means by QUIET; the agent is running and has
  # been told nothing, which is NOT KNOWN; or it knows, and then the node says
  # exactly what the card on `/house` says, through the same function.
  defp device_reading(live, snapshots, device) do
    cond do
      not alive?(live, device.agent_id) -> %{word: "Quiet", state: :silent, value: nil}
      is_nil(snapshots[device.id]) -> %{word: "Not known", state: :silent, value: nil}
      true -> read(snapshots[device.id])
    end
  end

  # The connection, not the process. A client that is up and reconnecting gets
  # QUIET and a note beneath it — none of the eight words means "trying again",
  # and widening one to cover it would put a word on this board that means two
  # things.
  defp house_reading(:connected), do: %{word: "Awake", state: :acting, value: nil}
  defp house_reading(_not_connected), do: %{word: "Quiet", state: :silent, value: nil}

  defp alive?(live, id), do: Map.get(live, id, false)

  # -- the small true things -------------------------------------------------

  defp note(text, class \\ nil)
  defp note(nil, _class), do: nil
  defp note(text, class), do: %{text: text, class: class}

  defp timers(1), do: "1 timer"
  defp timers(count), do: "#{count} timers"

  # The most useful fact on this page, on the node it is about rather than in a
  # table row: enabled schedules with no live timer. Declined rust, which is
  # the colour the health note already uses for this exact sentence.
  defp badge([]), do: nil
  defp badge(unregistered), do: "#{length(unregistered)} without a timer"

  defp trying(:reconnecting), do: "Trying again"
  defp trying(_status), do: nil

  defp since(%DateTime{} = at) do
    "Since " <> (at |> Home.local() |> Calendar.strftime("%-I:%M %p"))
  end

  defp since(_never), do: nil
end
