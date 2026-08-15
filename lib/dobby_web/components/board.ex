defmodule DobbyWeb.Board do
  @moduledoc """
  The header band, in two pieces (surface design §2, §3).

  The **plate** is the board's nameplate — where it is, who is speaking, and
  whether anything is listening. Every route wears it, which is why it lives
  here rather than under `thread_live/`: `/house` and `/admin` are the same
  instrument seen from a different side, not different applications.

  The **band** is the thread page's compact house — two or three flap rows, not
  the card set. It exists because "what's the thermostat at" should be answered
  before anyone asks, which is the cheapest possible improvement to a product
  whose alternative costs six hundred input tokens and a second of waiting.
  Tapping it opens `/house`, where the same rows have controls on them.

  There is no navigation bar. The plate is the way back and the band is the way
  in, which is the whole of it: a shell of links around this would be a second
  visual language arguing with the first.
  """

  use DobbyWeb, :html

  import DobbyWeb.Flap
  import DobbyWeb.Mark

  @doc """
  The board's nameplate.

  `section` says where you are and turns the name into the way back. On the
  thread it is absent, because you are already home.
  """
  attr :speaker, :map, default: nil
  attr :listening, :boolean, default: true
  attr :section, :string, default: nil
  attr :return_to, :string, default: "/"

  def plate(assigns) do
    ~H"""
    <div class="plate">
      <h1>
        <span :if={!@section}>The House</span>
        <.link :if={@section} navigate={~p"/"}>The House</.link>
        <span :if={@section} class="sep" aria-hidden="true">·</span>
        <span :if={@section} class="section">{@section}</span>
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
    <.link navigate={~p"/house"} class="rows" aria-label="Every device in the house">
      <div :for={row <- @rows} class="row">
        <span class="name">{row.name}</span>
        <span class="val">{row.reading.value}</span>
        <.flap state={row.reading.state}>{row.reading.word}</.flap>
      </div>
    </.link>
    """
  end
end
