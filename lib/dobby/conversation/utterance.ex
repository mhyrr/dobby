defmodule Dobby.Utterance do
  @moduledoc """
  What someone said, and who said it (design §1).

  Utterances arrive as an envelope rather than a bare string from the first
  build, so that adding voice later changes how an utterance *enters* and not
  what handles it. `speaker` is for personalization and attribution and never
  for permissions — the Wi-Fi password is the trust boundary.
  """

  @enforce_keys [:speaker, :text]
  defstruct [:speaker, :text, channel: :web]

  @type t :: %__MODULE__{speaker: String.t(), text: String.t(), channel: :web | :voice}

  @doc """
  Builds an utterance.
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(speaker, text, opts \\ []) do
    %__MODULE__{speaker: speaker, text: text, channel: Keyword.get(opts, :channel, :web)}
  end

  @doc """
  Renders the utterance as the user message the model sees.

  The speaker prefix rides on the message itself rather than on per-turn
  context, because it has to survive into conversation history: the model
  attributes across interleaved speakers by reading back over the transcript
  (design §6.4).

  This function is the single definition of that string. Tests script the
  model against the same call, so changing the format cannot silently
  desynchronize the replay tier from production.
  """
  @spec to_message(t()) :: String.t()
  def to_message(%__MODULE__{speaker: speaker, text: text}), do: "[#{speaker}] #{text}"

  @doc """
  Whether a message string is one `to_message/1` wrote: a household utterance,
  as opposed to a user-role message something else put in the conversation.

  The request transformer draws a request's boundary at the last household
  utterance, and jido_ai appends its own user-role message when the model
  repeats a tool call; the prefix is the one thing that tells them apart, and
  it is this module's format, so this module answers.
  """
  @spec message?(String.t()) :: boolean()
  def message?(text) when is_binary(text), do: Regex.match?(~r/\A\[[^\]]+\] /, text)
  def message?(_other), do: false
end
