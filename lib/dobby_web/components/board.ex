defmodule DobbyWeb.Board do
  @moduledoc """
  The header band, in two pieces (design §10.1).

  The **plate** is the board's nameplate — whose instrument this is, where you
  are in it, who is speaking, and whether anything is listening. Every route
  wears it, which is why it lives here rather than under `thread_live/`:
  `/house` and `/admin` are the same instrument seen from a different side, not
  different applications.

  **The name on the plate is `Dobby`, and it names the instrument.** It used to
  be `The House`, and that one phrase was doing two jobs — the whole board on
  every route, and the device page at `/house` — so the thread's header
  announced "The House" above a band of rows that took you somewhere else
  called the house, and `/house` offered "The House" as the way *off* the house.
  Neither sentence was true. The instrument has a name and the room has a name,
  and now they are different words.

  The **band** is the thread page's compact house — two or three flap rows, not
  the card set. It exists because "what's the thermostat at" should be answered
  before anyone asks, which is the cheapest possible improvement to a product
  whose alternative costs six hundred input tokens and a second of waiting.
  Tapping it opens `/house`, where the same rows have controls on them.

  There is no navigation bar. The plate carries the way between the two rooms
  and the band is the wide, tappable way in to one of them, which is the whole
  of it: a shell of links around this would be a second visual language arguing
  with the first.
  """

  use DobbyWeb, :html

  import DobbyWeb.Flap
  import DobbyWeb.Mark

  @doc """
  The board's nameplate: two words, and one of them is where you are.

  `here` is the only thing a route passes, and the plate composes both words
  from it. Three routes spelling their own strings is how `The House` came to
  mean two different places at once, and a caller that cannot write the name
  cannot write it wrong.

  The reading is the same on every route: **the word in ink is the page you are
  on, and the word in brass is a page you can go to.** That rule already ran
  here — brass `Dobby` was the way back and the ink section was where you stood
  — and the thread was the one route with nothing in the second slot, so the
  only way in to the house was a band of rows with no name on it. Now the
  thread says `Dobby · The House` too, with the roles swapped: you are with
  Dobby, and the house is the other place.

  Admin keeps its own word, because it is not the other half of this pair — it
  is a third room, reached from the foot of `/house` (`DESIGN.md`, The No Nav
  Rule).
  """
  attr :speaker, :map, default: nil
  attr :listening, :boolean, default: true
  attr :here, :atom, values: [:thread, :house, :admin], required: true
  attr :return_to, :string, default: "/"

  def plate(assigns) do
    ~H"""
    <div class="plate">
      <h1>
        <span :if={@here == :thread} class="here">Dobby</span>
        <.link :if={@here != :thread} navigate={~p"/"}>Dobby</.link>

        <span class="sep" aria-hidden="true">·</span>

        <.link :if={@here == :thread} navigate={~p"/house"} class="section">The House</.link>
        <span :if={@here == :house} class="section here">The House</span>
        <span :if={@here == :admin} class="section here">Admin</span>
      </h1>

      <div class="who">
        <.speaking_as :if={@speaker} speaker={@speaker} return_to={@return_to} />
        <.mark attending?={@listening} />
        <.flap state={if @listening, do: :acting, else: :silent}>
          {if @listening, do: "Listening", else: "Quiet"}
        </.flap>
      </div>
    </div>
    """
  end

  @doc """
  Who this browser thinks it is, and how to stop being them.

  A real form and not a link: switching identity is a write, and the cookie it
  clears can only be cleared by a controller. It is also why "switch" is a
  small, quiet word rather than the name itself being tappable — a household
  tablet that changed who was speaking because somebody brushed the header
  would be worse than typing a name again.
  """
  attr :speaker, :map, required: true
  attr :return_to, :string, default: "/"

  def speaking_as(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/speaker/switch"} method="post" class="speaking-as">
      <input type="hidden" name="return_to" value={@return_to} />
      <span class="name">{@speaker.name}</span>
      <button type="submit">switch</button>
    </.form>
    """
  end

  @doc """
  The compact house, and the way to the rest of it.

  Most-recently-changed decides which devices earn the band. A house with
  twenty devices may want a better rule; this one is right for a house with
  four, and it is right for the case that matters — the thing that just
  changed is the thing somebody is watching.

  Tapping it opens `/house`, whose plate reads `Dobby · The House` — so the
  band is a few rows of a board the next page names.
  """
  attr :snapshots, :list, required: true, doc: "device snapshots, most recently changed first"
  attr :limit, :integer, default: 3

  def band(assigns) do
    rows =
      assigns.snapshots
      |> Enum.take(assigns.limit)
      |> Enum.map(&%{name: &1.name, reading: read(&1)})

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <%!-- A house with nothing in it has no band, rather than an empty one. A
          band with no rows still lays out as a link the width of the board —
          invisible, zero-high, and reachable by tab, which offers a keyboard
          the way in to a page that has nothing on it. --%>
    <.link
      :if={@rows != []}
      navigate={~p"/house"}
      class="rows"
      aria-label="The House — every device"
    >
      <div :for={row <- @rows} class="row">
        <span class="name">{row.name}</span>
        <span class="val">{row.reading.value}</span>
        <.flap state={row.reading.state}>{row.reading.word}</.flap>
      </div>
    </.link>
    """
  end

  @doc """
  A thread with nothing in it yet.

  Sits where the first line will land, and says two things at most: what the
  blank is, and — once the house has told us enough to promise it — one
  sentence of the kind that works here.

  **Dobby does not speak first.** Proactive behaviour is deferred (design §11),
  and a greeting in this space would take that decision quietly, on the surface
  where it is hardest to notice. So the label is the board's own voice and the
  specimen is a *household* utterance: the one voice on this page that is
  neither the instrument's nor his, and the only one that can honestly stand in
  a space where nothing has been said.

  The specimen is built from what a device has actually reported, never from
  copy — a board that suggested a sentence naming a device this house does not
  have would be inventing one, which is the first thing doctrine forbids.
  """
  attr :speaker, :map, default: nil
  attr :example, :string, default: nil

  def blank(assigns) do
    ~H"""
    <div class="blank">
      <%!-- Before a name, one fact, and it is the one that answers "why is it
            asking?" — not a rule, since a name never permits anything. --%>
      <p :if={!@speaker} class="note">Your name goes on what you change.</p>

      <p :if={@speaker} class="note">Nothing said yet.</p>
      <p :if={@speaker && @example} class="like note">
        Something like <span class="said">“{@example}”</span>
      </p>
    </div>
    """
  end
end
