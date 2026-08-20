defmodule DobbyWeb.ThreadLive.Message do
  @moduledoc """
  One line of the thread (design §10.2, §10.3).

  Three shapes share this module because they share a grid: what somebody
  said, what Dobby answered, and what the house did. Every one of them is
  attributed the same way and positioned the same way.

  **Nothing is aligned by author.** The thread is a shared household record,
  and positioning a message by who is holding the phone means two people
  reading the same conversation see two different documents. Speaker becomes a
  fixed column when there is width for one; on a phone it is an inline line
  above the words. Neither moves depending on who is looking.

  **Language is the material.** What a person said is set at board scale, not
  at 14px in grey. The record-keeping around it is what gets small.
  """

  use Phoenix.Component

  import DobbyWeb.Flap

  alias Dobby.Conversation.Message
  alias DobbyWeb.Markdown

  @doc """
  A transcript row.
  """
  attr :message, Message, required: true
  attr :id, :string, default: nil

  # Two shapes of system line, told apart by whether the meta carries a state
  # word. An intervention reads as a board row — device, word, value, and who
  # did it. A failure is a sentence, because "Dobby couldn't answer that" is
  # not a reading of anything.
  def message(%{message: %Message{role: :system}} = assigns) do
    assigns = assign(assigns, :intervention, intervention(assigns.message))

    ~H"""
    <div class="sys" id={@id}>
      <span class="dev">{@message.text}</span>
      <.flap :if={@intervention} state={@intervention.state}>{@intervention.word}</.flap>
      <span :if={@intervention && @intervention.value} class="val">{@intervention.value}</span>
      <span :if={detail(@message)} class="via">— {detail(@message)}</span>
      <span :if={@intervention && @intervention.reason} class="why">
        {@intervention.reason}
      </span>
    </div>
    """
  end

  def message(assigns) do
    assigns =
      assigns
      |> assign(:steps, steps(assigns.message))
      |> assign(:duration, duration(assigns.message))

    ~H"""
    <div class={["msg", @message.role == :assistant && "dobby"]} id={@id}>
      <div class="attr">
        <span class="sp">{speaker_name(@message)}</span>
        <span class="t">{at(@message)}</span>
      </div>
      <p class="said">{Markdown.strip(@message.text)}</p>
      <.done_steps :if={@steps != []} steps={@steps} duration={@duration} />
    </div>
    """
  end

  @doc """
  A reply being composed, with its steps as they happen.

  Steps are the board showing its work. They are labels rather than sentences
  and they are written in device language, so they never read as Dobby
  narrating his own process — which the soul bans in his voice and which this
  would otherwise smuggle back in as a feature.

  Before the first step there is nothing to show, and measured against a real
  model that is not a flicker: an actuating request runs 1.0s before its first
  tool call and 2.1s before its first word, so this row is on the board saying
  nothing for most of every turn. It used to say it with an ellipsis in the
  timestamp slot — three faint dots where a time goes, which reads as a clock
  that failed rather than as a board at work. Every other blank here says what
  it is in the record voice, and this is the one a household sees most.
  """
  attr :pending, :map, required: true

  def pending(assigns) do
    ~H"""
    <div class="msg dobby" id={"pending-" <> @pending.request_id}>
      <div class="attr">
        <span class="sp">Dobby</span>
      </div>
      <p :if={@pending.text != ""} class="said">{Markdown.strip(@pending.text)}</p>
      <p :if={waiting?(@pending)} class="note">{waiting(@pending.request_id)}</p>
      <div :if={@pending.steps != []} class="steps">
        <div :for={step <- @pending.steps} class={["step", "step-#{step.state}"]}>
          <span class="tick" aria-hidden="true"></span>
          {step.label}
          <span :if={step.state == :held && step.detail} class="why">— {step.detail}</span>
        </div>
      </div>
    </div>
    """
  end

  # The board, waiting for a word to be set on it.
  #
  # The instrument's own voice and never Dobby's — the condensed face only ever
  # speaks about the board (`DESIGN.md`, The Instrument Voice Rule). That is the
  # constraint that holds: whatever these say, the board is saying it about
  # itself, and Dobby's own words never appear in this face.
  #
  # The register is Greg's, pinned in the direction round on 2026-08-14: fun,
  # hearted, magical. This list was flat and mechanical first, on the strength
  # of a "no wizarding diction" Don't that turned out to be an agent's write-up
  # of that pin rather than the pin itself. Greg reopened it, so the world is
  # allowed to be a little magical about its own workings here.
  #
  # It is still a *magical instrument* and not a wizard: these describe the
  # board doing something, never Dobby having a thought. The distinction is not
  # pedantry — the one line the anti-references actually draw is against reading
  # as a franchise, and a product named Dobby is one costume away from it.
  #
  # Eight, and every one of them says something. It was ten, with "No word yet"
  # and "Nothing has landed yet" kept as flat anchors on the theory that a set
  # this visible wants somewhere plain to rest. It does not — those two are the
  # old mechanical list surviving inside the new one, and a line that says
  # nothing is what this whole row was replacing. Greg cut both.
  #
  # Length carries no meaning here and the list is open, unlike the eight state
  # words. Adding or cutting one is editing this list; nothing else reads it.
  @waiting [
    "Conjuring.",
    "Casting about.",
    "Summoning a word.",
    "Divining.",
    "Riffling.",
    "Something is coming through.",
    "The cards are turning.",
    "Turning it over."
  ]

  # Only until the board has something truer to say. The first step replaces
  # this in the same place, so nothing reflows when it lands.
  defp waiting?(%{text: "", steps: []}), do: true
  defp waiting?(_pending), do: false

  # Keyed on the request and not on chance: every browser watching the same
  # turn is reading the same document (`DESIGN.md`, The Shared Document Rule),
  # and a kitchen tablet and a phone showing two different lines for one
  # question would be the first place that stopped being true.
  defp waiting(request_id) do
    Enum.at(@waiting, :erlang.phash2(request_id, length(@waiting)))
  end

  # After the reply lands the steps collapse to one row, because a finished
  # turn is read for its answer. They stay reachable rather than being thrown
  # away: the record of what Dobby actually did is the thing that makes the
  # answer trustworthy a week later.
  attr :steps, :list, required: true
  attr :duration, :string, default: nil

  defp done_steps(assigns) do
    ~H"""
    <details class="collapsed">
      <summary>
        <svg viewBox="0 0 8 8" fill="none" aria-hidden="true">
          <path d="M2 1l4 3-4 3" stroke="currentColor" stroke-width="1.2" stroke-linecap="square" />
        </svg>
        {length(@steps)} {if length(@steps) == 1, do: "step", else: "steps"}
        <span :if={@duration}>· {@duration}</span>
      </summary>
      <div class="steps">
        <div :for={step <- @steps} class={["step", "step-#{step.state}"]}>
          <span class="tick" aria-hidden="true"></span>
          {step.label}
          <span :if={step.state == :held && step.detail} class="why">— {step.detail}</span>
        </div>
      </div>
    </details>
    """
  end

  @doc """
  What a message's steps were, whether it is live or read back from the row.

  `meta` comes back from Postgres with string keys, and a renderer that
  handled only one of the two shapes would work all session and break on
  reload — which is the worst time to find out.
  """
  @spec steps(Message.t()) :: [map()]
  def steps(%Message{meta: %{"steps" => steps}}) when is_list(steps) do
    Enum.map(steps, fn step ->
      %{
        label: step["label"],
        state: state(step["state"]),
        detail: step["detail"]
      }
    end)
  end

  def steps(%Message{}), do: []

  defp state("held"), do: :held
  defp state("running"), do: :running
  defp state(_other), do: :done

  defp duration(%Message{meta: %{"duration_ms" => ms}}) when is_integer(ms) and ms > 0 do
    :erlang.float_to_binary(ms / 1000, decimals: 1) <> " s"
  end

  defp duration(%Message{}), do: nil

  # `via` is who or what did it — the half of a system line a person cares
  # about. A failure's raw reason is deliberately not rendered: it lives in
  # `meta` for the admin, and the sentence is the message.
  defp detail(%Message{meta: %{"via" => via}}) when is_binary(via), do: via
  defp detail(%Message{}), do: nil

  # `Dobby.Interventions` writes the word; this only reads it back. The state
  # arrives as a string because it has been through Postgres, and a renderer
  # that handled only the atom would work all session and break on reload.
  defp intervention(%Message{meta: %{"word" => word} = meta}) when is_binary(word) do
    %{
      word: word,
      state: flap_state(meta["state"]),
      value: meta["value"],
      reason: meta["reason"]
    }
  end

  defp intervention(%Message{}), do: nil

  defp flap_state("refused"), do: :refused
  defp flap_state(_set), do: :set

  @doc """
  Who said it.
  """
  @spec speaker_name(Message.t()) :: String.t()
  def speaker_name(%Message{role: :assistant}), do: "Dobby"
  def speaker_name(%Message{speaker: %{name: name}}), do: name
  def speaker_name(%Message{}), do: "the house"

  # The household's own clock, not the reader's: two people in the same
  # kitchen reading the same line must not see two different times.
  defp at(%Message{inserted_at: nil}), do: nil

  defp at(%Message{inserted_at: inserted_at}) do
    inserted_at
    |> Dobby.Home.local()
    |> Calendar.strftime("%-I:%M %p")
  end
end
