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

  use Phoenix.Component

  import DobbyWeb.Flap

  @doc """
  The board header.
  """
  attr :snapshots, :list, required: true, doc: "device snapshots, most recently changed first"
  attr :speaker, :map, default: nil
  attr :listening, :boolean, default: true
  attr :limit, :integer, default: 3

  def board(assigns) do
    rows =
      assigns.snapshots
      |> Enum.take(assigns.limit)
      |> Enum.map(&%{name: &1.name, reading: read(&1)})

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <header class="board">
      <.eyes />
      <div class="plate">
        <h1>The House</h1>
        <div class="who">
          <span :if={@speaker}>{@speaker.name}</span>
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
  Dobby's eyes, behind the header (surface design §16.1).

  Round and protruding with the sclera showing all round, a hard limbal ring
  and a catchlight, cropped by the top edge. Ambient — a tick underneath
  everything, never a foreground element, and never a status indicator: the
  board's words are what tell you the state.

  Subtlety comes from **color, not opacity**. Set bright and faded to 16% these
  collapsed into grey donuts, because low opacity compresses every hue toward
  the background at once. Drawn at full opacity in colors chosen close to the
  ground, the structure survives.
  """
  def eyes(assigns) do
    ~H"""
    <svg class="eyes" viewBox="0 0 128 54" aria-hidden="true">
      <ellipse class="sclera" cx="38" cy="27" rx="21" ry="22" />
      <ellipse class="sclera" cx="90" cy="27" rx="21" ry="22" />
      <circle class="iris" cx="41" cy="28" r="11.5" />
      <circle class="iris" cx="87" cy="28" r="11.5" />
      <circle class="limbal" cx="41" cy="28" r="11.5" />
      <circle class="limbal" cx="87" cy="28" r="11.5" />
      <circle class="pupil" cx="41" cy="28" r="5.4" />
      <circle class="pupil" cx="87" cy="28" r="5.4" />
      <circle class="spark" cx="36.5" cy="23" r="2.6" />
      <circle class="spark" cx="82.5" cy="23" r="2.6" />
      <g class="lids">
        <path class="lid" d="M8 -14h112v40H8z" />
        <path class="limbal" d="M18 26c8 7 38 7 46 0M64 26c8 7 38 7 46 0" />
      </g>
    </svg>
    """
  end
end
