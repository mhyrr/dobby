defmodule Dobby.Conversation.Rehydrate do
  @moduledoc """
  Rebuilds `DobbyAgent`'s conversation window from the transcript (design §10.8).

  Jido AI's ReAct strategy accumulates turns in `Jido.AI.Context` for the life
  of the process and nothing more — restart the node and Dobby has forgotten
  the morning. The transcript is the durable half, so at boot the recent window
  is read back and handed to the agent at construction.

  ## The seam

  `Jido.AI.Context` is a supported entry point rather than a workaround:
  `Jido.AI.Reasoning.ReAct.Strategy.initial_context/2` reads `agent.state[:context]`
  and coerces it, raising a specific error for the retired `:thread` key. So
  rehydration is `DobbyAgent.new(id: ..., state: %{context: context})` and needs
  no custom action, no signal, and no exposure to the deep-merge behaviour that
  bit `SchedulerAgent`.

  A context supplied with `system_prompt: nil` inherits the compile-time
  doctrine, and `Dobby.Home` then installs soul-plus-doctrine over it exactly
  as it does today. The boot order is unchanged.

  ## What goes back in, and what does not

  Only what people said and what Dobby said. **System lines stay out.**

  That is deliberate and it is a doctrine question, not a tidiness one. Device
  state reaches the model through the `<house>` block, which is rebuilt from
  the live world model on every turn (§6.3). Replaying "thermostat set to 70"
  from three hours ago into the conversation would give the model a second,
  older source of truth for precisely the thing it is forbidden to guess about.
  One source, and it is the live one.

  ## The speaker prefix

  Rehydrated user messages are rendered through `Dobby.Utterance.to_message/1`,
  the single definition of that format. Rebuilding the string here would mean
  history after a restart looked subtly different from history before it, and
  the model attributes across interleaved speakers by reading that prefix.
  """

  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Utterance
  alias Jido.AI.Context

  require Logger

  # The house's standing window (`Dobby.Conversation.window/0`), applied here at
  # boot. It used to be the *only* bound in the system, which is what `TK-007`
  # was: it capped what Dobby remembered on the way up and nothing capped what
  # he sent afterwards. `Dobby.DobbyAgent.RequestTransformer` holds the other
  # end now, and both read the same number.

  @doc """
  Builds a `Jido.AI.Context` from the recent transcript.

  Returns an empty context when there is nothing to remember, which is the
  ordinary case on a fresh database and must not be an error.
  """
  @spec context(keyword()) :: Context.t()
  def context(opts \\ []) do
    build(Keyword.get(opts, :window, Conversation.window()))
  rescue
    # Broad on purpose, and this is the one place it is warranted. This runs
    # inside `Dobby.Home.init/1`, so anything raised here is the difference
    # between a house that has forgotten this morning and no house at all. The
    # first is a bad morning; the second is a cold building.
    error ->
      Logger.warning("could not rehydrate the conversation: #{Exception.message(error)}")
      Context.new()
  end

  defp build(window) do
    messages =
      window
      |> fetch_window()
      |> Enum.map(&to_entry/1)
      |> Enum.reject(&is_nil/1)

    Context.append_messages(Context.new(), messages)
  end

  # The role filter lives in SQL, not here. Fetching a superset and discarding
  # system lines afterwards means a busy hour of card taps eats the window and
  # Dobby forgets the conversation around them — which a test caught, having
  # been written to.
  defp fetch_window(window), do: Conversation.recent_dialogue(window)

  defp to_entry(%Message{role: :user, speaker: %{name: name}, text: text}) do
    %{role: :user, content: Utterance.to_message(Utterance.new(name, text))}
  end

  # A user message with no speaker cannot happen — the changeset requires one —
  # but reading it back is not the place to find out, and a thread that fails
  # to load is worse than one missing a line.
  defp to_entry(%Message{role: :user}), do: nil

  defp to_entry(%Message{role: :assistant, text: text}) do
    %{role: :assistant, content: text}
  end

  defp to_entry(%Message{}), do: nil
end
