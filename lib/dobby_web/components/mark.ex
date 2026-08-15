defmodule DobbyWeb.Mark do
  @moduledoc """
  Dobby, drawn (surface design §16).

  Greg's line drawing: a round head, two swept ears, closed smiling eyes. The
  original is kept at `priv/static/images/elf.svg`; the paths below are it,
  and this component is what renders.

  Painted in ink rather than filled in white — stroke in `currentColor`, fill
  in the ground behind it — so it reads as something drawn onto the enamel
  rather than a sticker laid on top of it. The supplied white fill and black
  stroke read as a sticker on a dark board, and the hairline stroke greyed out
  at any size the board actually uses.

  ## Where it goes, and why it is not beside every reply

  §16 said the mark sits beside every reply at ~26px. Rendered at that size
  this drawing collapses: the eyes, nose and mouth merge into a smear and the
  ears turn to fuzz. It needs about 40px to stay a face. The ears alone were
  the fallback and they are worse — without the head they read as leaves.

  So the mark moved to the plate, at 44px, and that turns out to be the better
  job for it anyway. A mark beside a finished reply is a byline: it says who
  said this, and it should not move. A mark in the header is Dobby *now* — and
  now is the only thing a tilt can describe.

  ## The tilt

  Attending, he leans in. Fifteen degrees, which is enough to read at 44px and
  small enough not to look like a fall. It is the one state this drawing shows
  by itself; everything else on the board is a word, because that is the whole
  argument of the surface.
  """

  use Phoenix.Component

  @doc """
  Dobby's likeness.

  `attending?` tilts him toward the conversation. `ground` is the colour behind
  him — the drawing is open line work and the head has to be filled with
  whatever it is sitting on, or the ears show through the face.
  """
  attr :size, :integer, default: 44
  attr :attending?, :boolean, default: true
  attr :ground, :string, default: "var(--board-raised)"
  attr :class, :string, default: nil

  def mark(assigns) do
    ~H"""
    <svg
      class={["mark", @attending? && "attending", @class]}
      width={@size}
      height={@size}
      viewBox="0 0 1000 1000"
      role="img"
      aria-label="Dobby"
    >
      <g
        fill="none"
        stroke="currentColor"
        stroke-width="26"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <%!-- Ears first: the head is drawn over where they attach. --%>
        <g id="dobby-ear">
          <path fill={@ground} d="M 340 430 C 245 408, 120 376, 55 368 C 58 486, 150 645, 355 725" />
          <path d="M 128 424 C 188 476, 248 572, 298 660" />
        </g>
        <use href="#dobby-ear" transform="translate(1000 0) scale(-1 1)" />
        <ellipse cx="500" cy="520" rx="235" ry="290" fill={@ground} />
        <path d="M 372 537 Q 410 509, 448 537" />
        <path d="M 552 537 Q 590 509, 628 537" />
        <path d="M 376 599 Q 410 633, 444 599" />
        <path d="M 556 599 Q 590 633, 624 599" />
        <path d="M 483 660 Q 500 676, 517 660" />
        <path d="M 433 707 Q 500 749, 567 707" />
      </g>
    </svg>
    """
  end
end
