defmodule DobbyWeb.Markdown do
  @moduledoc """
  Takes the markdown out of Dobby's replies (surface design §5.4).

  Models emit `**bold**` whether or not anybody asked. The soul tells this one
  not to, and this strips it anyway, because that belt-and-braces pair is
  cheaper than either half alone: a soul line cannot be relied on — models
  drift, and the eval tier catches formatting only sometimes — and a renderer
  cannot stop the model spending tokens on asterisks.

  Deliberately **not** a markdown renderer. Adding `mdex` to draw bold inside a
  two-sentence reply about a thermostat is a fence larger than the loss, and a
  full renderer on model output is a much larger surface than a few regexes.
  """

  # Order matters: the double forms have to go before the single ones, or
  # `**warm**` loses one asterisk from each end and keeps the other.
  @rules [
    {~r/\*\*(.+?)\*\*/s, "\\1"},
    {~r/__(.+?)__/s, "\\1"},
    {~r/(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])/, "\\1"},
    # A bare underscore is only emphasis between word boundaries. Without the
    # guard this would eat the middle of `thermostat_set_temperature`, which is
    # exactly the kind of string that shows up in a house's conversation.
    {~r/(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])/, "\\1"},
    {~r/`([^`\n]+)`/, "\\1"},
    {~r/^#+\s+/m, ""}
  ]

  @doc """
  The reply as a person should read it.
  """
  @spec strip(String.t() | nil) :: String.t()
  def strip(nil), do: ""

  def strip(text) when is_binary(text) do
    Enum.reduce(@rules, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end
end
