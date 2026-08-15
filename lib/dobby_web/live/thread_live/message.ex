defmodule DobbyWeb.ThreadLive.Message do
  @moduledoc """
  One line of the thread (surface design §5).

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

  alias Dobby.Conversation.Message
  alias DobbyWeb.Markdown

  @doc """
  A transcript row.
  """
  attr :message, Message, required: true
  attr :id, :string, default: nil

  def message(%{message: %Message{role: :system}} = assigns) do
    ~H"""
    <div class="sys" id={@id}>
      <span class="dev">{@message.text}</span>
      <span :if={detail(@message)} class="via">— {detail(@message)}</span>
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
  """
  attr :pending, :map, required: true

  def pending(assigns) do
    ~H"""
    <div class="msg dobby" id={"pending-" <> @pending.request_id}>
      <div class="attr">
        <span class="sp">Dobby</span>
        <span class="t">…</span>
      </div>
      <p :if={@pending.text != ""} class="said">{Markdown.strip(@pending.text)}</p>
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
