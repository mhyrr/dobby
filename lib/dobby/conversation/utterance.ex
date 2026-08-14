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
end
