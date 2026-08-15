defmodule DobbyWeb.ThreadLive.Board do
  @moduledoc """
  The header band: the house, in a few flap rows (surface design §3).

  Not the card set. It is the two or three devices worth standing watch over,
  always visible above the conversation, and tapping it opens `/house`. It
  exists because "what's the thermostat at" should be answered before anyone
  asks — the cheapest possible improvement to a product whose alternative
  costs six hundred input tokens and a second of waiting.

  Most-recently-changed decides which devices earn the band. A house with
  twenty devices may want a better rule; this one is right for a house with
  four, and it is right for the case that matters — the thing that just
  changed is the thing somebody is watching.
  """

  use DobbyWeb, :html

  import DobbyWeb.Flap
  import DobbyWeb.Mark

  @doc """
  The board header.
  """
  attr :snapshots, :list, required: true, doc: "device snapshots, most recently changed first"
  attr :speaker, :map, default: nil
  attr :listening, :boolean, default: true
  attr :limit, :integer, default: 3
  attr :return_to, :string, default: "/"

  def board(assigns) do
    rows =
      assigns.snapshots
      |> Enum.take(assigns.limit)
      |> Enum.map(&%{name: &1.name, reading: read(&1)})

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <header class="board">
      <div class="plate">
        <h1>The House</h1>
        <div class="who">
          <.speaking_as :if={@speaker} speaker={@speaker} return_to={@return_to} />
          <.mark attending?={@listening} />
          <.flap state={if @listening, do: :acting, else: :silent}>
            {if @listening, do: "Listening", else: "Quiet"}
          </.flap>
        </div>
      </div>

      <div class="rows">
        <div :for={row <- @rows} class="row">
          <span class="name">{row.name}</span>
          <span class="val">{row.reading.value}</span>
          <.flap state={row.reading.state}>{row.reading.word}</.flap>
        </div>
      </div>
    </header>
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
end
