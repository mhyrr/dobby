defmodule DobbyWeb.HouseLive.Card do
  @moduledoc """
  A card is a board row that grew a control (`DESIGN.md`).

  Same three columns, same vocabulary, same flap. What a card adds is the room
  underneath the row: a second reading the band has no space for, and — for
  a device that can be commanded — a way to command it.

  ## The controls are the device's, not the card's

  What a card offers is whatever the device's own module declares in
  `Dobby.DeviceAgent.controls/1`, drawn by kind: a fader for a number between
  two ends the device reported, a choice row for a word the device advertised.
  The card dispatches on the *kind of control* and never on the type of
  device. The first version dispatched on `snapshot.type`, drew a fader for
  the thermostat and nothing for anybody else, and when five writable
  appliance types arrived not one of them could be touched — the direct
  control path, which is first-class rather than a fallback, had one device
  on it (TK-069).

  ## The fader

  The one place in this house where a fat finger actuates something. Given
  kids, it commits **on release** rather than on every drag tick, and offers an
  undo for a few seconds afterwards rather than a confirm dialog. Dialogs train
  people to dismiss dialogs, and a household that has learned to dismiss them
  is worse off than one that never had them.

  A control is drawn only when the device has told us what it will accept —
  the type decides that, because the knowledge is the type's. A fader that
  lets you reach 85° in a house capped at 76 is a control that exists to be
  refused, and a thermostat that has not reported yet has not told us
  anything — which is a different fact from a thermostat that said no, and
  the board has a different word for each.

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

  alias Dobby.DeviceAgent
  alias Dobby.HomeConfig.Types

  @doc """
  One device.
  """
  attr :snapshot, :map, required: true
  attr :undo, :map, default: nil, doc: "the value to go back to, if there is a way back"
  attr :held, :string, default: nil, doc: "why the device said no, if it did"
  attr :editable, :boolean, default: false, doc: "whether this house can be written at all"
  attr :editing, :boolean, default: false, doc: "whether this card's form is open"
  attr :removing, :map, default: nil, doc: "the question and its cost, when a removal was asked"
  attr :trouble, :string, default: nil, doc: "why the last removal was refused"
  slot :inner_block, doc: "the form, when this is the card being edited"

  def card(assigns) do
    assigns = assign(assigns, :controls, controls(assigns.snapshot))

    ~H"""
    <article class="card" id={"card-" <> @snapshot.id}>
      <.reading snapshot={@snapshot} />
      <div :if={detail(@snapshot)} class="detail">{detail(@snapshot)}</div>
      <%= for control <- @controls do %>
        <.fader :if={control.kind == :fader} snapshot={@snapshot} control={control} />
        <.choice :if={control.kind == :choice} snapshot={@snapshot} control={control} />
      <% end %>
      <.aftermath snapshot={@snapshot} undo={@undo} held={@held} />
      <.editing {assigns} />
    </article>
    """
  end

  @doc """
  The controls a device offers right now, asked of its own type.

  The type is found by the word the snapshot carries rather than by the
  manifest, so a snapshot answers for itself and a card never has to know
  which house it is on.
  """
  @spec controls(map()) :: [DeviceAgent.control()]
  def controls(%{type: type} = snapshot) when is_atom(type) do
    case Types.fetch(Atom.to_string(type)) do
      {:ok, module} -> DeviceAgent.controls(module, snapshot)
      :error -> []
    end
  end

  def controls(_snapshot), do: []

  @doc """
  A control's value as the undo line says it: `70°` for a fader, `eco` for a
  choice.
  """
  @spec word(DeviceAgent.control(), term()) :: String.t()
  def word(%{kind: :fader, unit: unit}, value) when is_number(value),
    do: "#{round(value)}#{unit}"

  def word(_control, true), do: "on"
  def word(_control, false), do: "off"
  def word(_control, value), do: value |> to_string() |> String.replace("_", " ")

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
  #
  # Keyed on the attribute it moves rather than on the device, so a card can
  # hold more than one; the ends and the unit are the control's own.
  attr :snapshot, :map, required: true
  attr :control, :map, required: true

  defp fader(assigns) do
    assigns =
      assigns
      |> assign(:min, round(assigns.control.min))
      |> assign(:max, round(assigns.control.max))
      |> assign(:value, at(assigns.snapshot, assigns.control))

    ~H"""
    <div class="fader">
      <div class="asking" data-pending aria-hidden="true"></div>
      <input
        type="range"
        id={"set-" <> @snapshot.id <> "-" <> Atom.to_string(@control.field)}
        name={Atom.to_string(@control.arg)}
        min={@min}
        max={@max}
        step={@control.step}
        value={@value}
        style={"--at: #{travelled(@value, @min, @max)}%"}
        data-device={@snapshot.id}
        data-action={@control.action}
        data-unit={@control.unit}
        aria-label={"Set the #{@snapshot.name}"}
        phx-hook=".Fader"
      />
      <div class="ends">
        <span>{@min}{@control.unit}</span>
        <span>{@max}{@control.unit}</span>
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

            asking.textContent = this.el.value + this.el.dataset.unit
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
              action: this.el.dataset.action,
              value: this.el.value
            })
          })
        }
      }
    </script>
    """
  end

  # A row of the words the device advertised, the one it holds now written in
  # the record voice and the rest drawn as the quiet verbs `edit` and `undo`
  # are. Not a dropdown and not a dialog: a dropdown hides the other words and
  # a dialog trains people to dismiss dialogs. Tapping a word commits it and
  # offers the way back, the same as a release does.
  #
  # The current word is not a button. It is where the device is, and the one
  # thing this board never does is offer to set something to what it already
  # says — a control that changes nothing is a control that exists to lie.
  # A row with nothing left to offer — a lock that is locked, whose one word
  # is the one it holds — is not drawn at all: the reading already says it,
  # and the second line is meant to be a different fact.
  attr :snapshot, :map, required: true
  attr :control, :map, required: true

  defp choice(assigns) do
    now = assigns.snapshot[assigns.control.field]

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(:offering, Enum.any?(assigns.control.options, &(&1 != now)))

    ~H"""
    <div
      :if={@offering}
      class="choice"
      id={"choose-" <> @snapshot.id <> "-" <> Atom.to_string(@control.field)}
      role="group"
      aria-label={"#{@control[:label] || @control.field} of the #{@snapshot.name}"}
    >
      <span :if={@control[:label]} class="of">{@control.label}</span>
      <%= for option <- @control.options do %>
        <span :if={option == @now} class="now" aria-current="true">{word(@control, option)}</span>
        <button
          :if={option != @now}
          type="button"
          phx-click="set"
          phx-value-device={@snapshot.id}
          phx-value-action={@control.action}
          phx-value-value={to_string(option)}
        >
          {word(@control, option)}
        </button>
      <% end %>
    </div>
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
      <span>back to {@undo.word}</span>
    </div>

    <div :if={@held} class="held">
      <.flap state={:refused}>Held</.flap>
      <span class="why">{@held}</span>
    </div>
    """
  end

  # Where the slug sits: the attribute the control moves, held inside the
  # ends. A browser clamps a range input's value to its ends anyway; doing it
  # here keeps the server-rendered brass right in the first paint.
  defp at(snapshot, control) do
    case snapshot[control.field] do
      value when is_number(value) ->
        value |> round() |> max(round(control.min)) |> min(round(control.max))

      _absent ->
        round(control.min)
    end
  end

  # How far along the groove the slug sits, as a percentage. Rendered by the
  # server so the brass is right in the first paint rather than snapping into
  # place when the hook mounts; the hook takes over during a drag.
  defp travelled(value, min, max), do: Float.round((value - min) / (max - min) * 100, 1)

  # The second number is a different fact. The row carries the setpoint,
  # because the setpoint is the thing somebody asked for; the card has room
  # for the other number, which is not the same one said twice.
  defp detail(%{current_temperature_f: current}) when is_number(current),
    do: "Room #{round(current)}°"

  # Only when the flip was actually watched. `last_changed_at` is left unset on
  # a device's first report, so this cannot put the boot time on a printer that
  # has been off since Tuesday.
  defp detail(%{last_changed_at: %DateTime{} = at}) do
    "Since " <> (at |> Dobby.Home.local() |> Calendar.strftime("%-I:%M %p"))
  end

  defp detail(_snapshot), do: nil
end
