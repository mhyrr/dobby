defmodule DobbyWeb.HouseLive.Card do
  @moduledoc """
  A card is a board row that grew a control (`DESIGN.md`).

  Same three columns, same vocabulary, same flap. What a card adds is the room
  underneath the row: a second reading the band has no space for, and — for the
  one device type that can be commanded — a way to command it.

  ## The setpoint control

  The one place in this house where a fat finger actuates something. Given
  kids, it commits **on release** rather than on every drag tick, and offers an
  undo for a few seconds afterwards rather than a confirm dialog. Dialogs train
  people to dismiss dialogs, and a household that has learned to dismiss them
  is worse off than one that never had them.

  The control is drawn only when the device has told us what it will accept.
  A fader that lets you reach 85° in a house capped at 76 is a control that
  exists to be refused, and a thermostat that has not reported yet has not told
  us anything — which is a different fact from a thermostat that said no, and
  the board has a different word for each.

  The dispatch on `snapshot.type` is deliberate and mirrors
  `DobbyWeb.Flap.read/1`: what a device *looks like* is per-device knowledge,
  and a type that reaches here without a clause gets the row alone, which is
  true of anything.

  ## Editing is the fifth part of a card (TK-018)

  Devices are edited where they live, and a device lives on its card. So the
  card grew one more line — `edit` and `remove`, in the same quiet lettering
  the undo uses — and the form opens underneath the row it is about rather than
  on a page of its own or in a dialog.

  None of it is drawn on a house Dobby cannot write. The affordance and the
  reason it is missing are one decision, taken once, in `DobbyWeb.HouseLive`.
  """

  use DobbyWeb, :html

  import DobbyWeb.Flap

  @doc """
  One device.
  """
  attr :snapshot, :map, required: true
  attr :undo, :map, default: nil, doc: "the setpoint to go back to, if there is a way back"
  attr :held, :string, default: nil, doc: "why the device said no, if it did"
  attr :editable, :boolean, default: false, doc: "whether this house can be written at all"
  attr :editing, :boolean, default: false, doc: "whether this card's form is open"
  attr :removing, :map, default: nil, doc: "the question and its cost, when a removal was asked"
  attr :trouble, :string, default: nil, doc: "why the last removal was refused"
  slot :inner_block, doc: "the form, when this is the card being edited"

  def card(%{snapshot: %{type: :thermostat}} = assigns) do
    ~H"""
    <article class="card" id={"card-" <> @snapshot.id}>
      <.reading snapshot={@snapshot} />
      <div :if={room(@snapshot)} class="detail">Room {room(@snapshot)}</div>
      <.fader :if={settable?(@snapshot)} snapshot={@snapshot} />
      <.aftermath snapshot={@snapshot} undo={@undo} held={@held} />
      <.editing {assigns} />
    </article>
    """
  end

  def card(assigns) do
    ~H"""
    <article class="card" id={"card-" <> @snapshot.id}>
      <.reading snapshot={@snapshot} />
      <div :if={since(@snapshot)} class="detail">Since {since(@snapshot)}</div>
      <.editing {assigns} />
    </article>
    """
  end

  # What can be done to the device rather than with it. Removal asks first —
  # not as a dialog, which this surface has already decided against, but as the
  # line the button turns into, carrying what the removal would do to anything
  # aiming at this device.
  attr :snapshot, :map, required: true
  attr :editable, :boolean, default: false
  attr :editing, :boolean, default: false
  attr :removing, :map, default: nil
  attr :trouble, :string, default: nil
  slot :inner_block

  defp editing(assigns) do
    ~H"""
    <div :if={@editable and not @editing and is_nil(@removing)} class="acts">
      <button type="button" phx-click="edit" phx-value-device={@snapshot.id}>edit</button>
      <button type="button" class="takes" phx-click="remove" phx-value-device={@snapshot.id}>
        remove
      </button>
    </div>

    <%!-- The question is a board line and its cost is a sentence, which is why
          they are two: a clause about schedules shouted in condensed capitals
          is the record voice used for something it is not for. --%>
    <p :if={@removing} class="note confirm">{@removing.question}</p>
    <p :if={@removing && @removing.cost} class="hint">{@removing.cost}</p>

    <div :if={@removing} class="acts">
      <button
        type="button"
        class="takes"
        phx-click="remove_confirm"
        phx-value-device={@snapshot.id}
      >
        remove
      </button>
      <button type="button" class="back" phx-click="cancel">keep it</button>
    </div>

    <%!-- A refusal about the device this card is about belongs on this card,
          the same way a held setpoint does. --%>
    <div :if={@trouble} class="why">{@trouble}</div>

    {render_slot(@inner_block)}
    """
  end

  attr :snapshot, :map, required: true

  defp reading(assigns) do
    assigns = assign(assigns, :read, read(assigns.snapshot))

    ~H"""
    <div class="row">
      <span class="name">{@snapshot.name}</span>
      <span class="val">{@read.value}</span>
      <.flap state={@read.state}>{@read.word}</.flap>
    </div>
    """
  end

  # A fader rather than a stepper, and rather than a dial: a dial is the
  # category default this whole surface is a refusal of, and a stepper turns
  # "make it warmer" into six taps. The pending readout is written by the hook
  # while a finger is down, so the number under the thumb is the number that
  # will be sent — and nothing is sent until the finger comes up.
  attr :snapshot, :map, required: true

  defp fader(assigns) do
    ~H"""
    <div class="fader">
      <div class="asking" data-pending aria-hidden="true"></div>
      <input
        type="range"
        id={"set-" <> @snapshot.id}
        name="temperature_f"
        min={round(@snapshot.min_temperature_f)}
        max={round(@snapshot.max_temperature_f)}
        step="1"
        value={round(@snapshot.target_temperature_f)}
        style={"--at: #{travelled(@snapshot)}%"}
        data-device={@snapshot.id}
        aria-label={"Set the #{@snapshot.name}"}
        phx-hook=".Fader"
      />
      <div class="ends">
        <span>{round(@snapshot.min_temperature_f)}°</span>
        <span>{round(@snapshot.max_temperature_f)}°</span>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Fader">
      export default {
        mounted() {
          const asking = this.el.parentElement.querySelector("[data-pending]")

          // `input` fires all the way through a drag; `change` fires when the
          // finger comes up. So the number rides the thumb locally and the
          // card answers instantly, and only the release reaches the house.
          //
          // It is deliberately not the card's own reading. That number is a
          // value somebody commanded, and showing a value nobody has commanded
          // yet in its place would be the board claiming a state it was never
          // set to — which is the one thing this surface exists to refuse. It
          // appears while a finger is down and goes away when the board takes
          // over.
          this.el.addEventListener("input", () => {
            const min = Number(this.el.min), max = Number(this.el.max)
            const at = (Number(this.el.value) - min) / (max - min)

            asking.textContent = this.el.value + "°"
            // A fraction and not a percentage of the width: the label sits on
            // the slug, and a range input slides the slug's centre across a
            // track shortened by one slug. CSS does that arithmetic, because
            // the slug's width is a token there and a literal here.
            asking.style.setProperty("--f", at)
            asking.classList.add("live")

            // The brass in the groove follows the slug, so how far it has been
            // pushed reads even while a finger is on it.
            this.el.style.setProperty("--at", (at * 100) + "%")
          })

          this.el.addEventListener("change", () => {
            asking.classList.remove("live")

            this.pushEvent("set", {
              device: this.el.dataset.device,
              temperature_f: this.el.value
            })
          })
        }
      }
    </script>
    """
  end

  # What happened after the last release: a way back for a few seconds, or the
  # reason the device said no.
  #
  # The refusal stays until the next attempt rather than expiring with the undo
  # window. An undo is an offer and goes stale; a refusal is an answer to a
  # question somebody just asked, and taking it off the card after eight
  # seconds would mean the person who looked away missed it.
  attr :snapshot, :map, required: true
  attr :undo, :map, default: nil
  attr :held, :string, default: nil

  defp aftermath(assigns) do
    ~H"""
    <div :if={@undo} class="undo">
      <button type="button" phx-click="undo" phx-value-device={@snapshot.id}>undo</button>
      <span>back to {round(@undo.to)}°</span>
    </div>

    <div :if={@held} class="held">
      <.flap state={:refused}>Held</.flap>
      <span class="why">{@held}</span>
    </div>
    """
  end

  # How far along the groove the slug sits, as a percentage. Rendered by the
  # server so the brass is right in the first paint rather than snapping into
  # place when the hook mounts; the hook takes over during a drag.
  defp travelled(snapshot) do
    span = snapshot.max_temperature_f - snapshot.min_temperature_f

    ((snapshot.target_temperature_f - snapshot.min_temperature_f) / span * 100)
    |> Float.round(1)
  end

  @doc """
  Whether this device has told us enough to offer a control.
  """
  @spec settable?(map()) :: boolean()
  def settable?(%{type: :thermostat} = snapshot) do
    snapshot.available == true and
      is_number(snapshot.target_temperature_f) and
      is_number(snapshot[:min_temperature_f]) and
      is_number(snapshot[:max_temperature_f]) and
      snapshot.min_temperature_f < snapshot.max_temperature_f
  end

  def settable?(_snapshot), do: false

  # The band shows the setpoint, because the setpoint is the thing somebody
  # asked for. The card has room for the other number, which is a different
  # fact and not the same one said twice.
  defp room(%{current_temperature_f: current}) when is_number(current), do: "#{round(current)}°"
  defp room(_snapshot), do: nil

  # Only when the flip was actually watched. `last_changed_at` is left unset on
  # a device's first report, so this cannot put the boot time on a printer that
  # has been off since Tuesday.
  defp since(%{last_changed_at: %DateTime{} = at}) do
    at |> Dobby.Home.local() |> Calendar.strftime("%-I:%M %p")
  end

  defp since(_snapshot), do: nil
end
