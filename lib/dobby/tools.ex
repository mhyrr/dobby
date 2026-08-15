defmodule Dobby.Tools do
  @moduledoc """
  How a tool call reads on the board (design §5.3).

  While Dobby works, the thread shows named steps — "setting the main
  thermostat", not `thermostat_set_temperature`. Two rules make that safe.

  **Steps are written in device language, not tool language.** A person reads
  the name of the thing in their house, not the name of a function in ours.

  **Steps are labels, not sentences.** They are the board showing its work,
  which is the whole thesis of the surface; they are never Dobby narrating
  ("let me just check the thermostat…"), because the soul bans process
  narration in Dobby's voice and a step phrased as speech would break that
  while looking like a feature.

  The label belongs to the tool because the verb does: only
  `create_schedule` knows it is writing something down. The device half comes
  from the roster, so a tool never has to carry a device's display name.
  """

  @doc """
  How this call reads as a step, given the arguments the model supplied.

  Arguments arrive with string keys — they are the model's JSON, not ours.
  """
  @callback label(arguments :: map()) :: String.t()

  @doc """
  The step label for a tool call, by tool name.

  Falls back to a humanized tool name for anything this house does not
  advertise. That is not defensive filler: the manifest can change under a
  running request, and a step that reads slightly generically is a better
  outcome than a crash inside somebody's turn.
  """
  @spec label(String.t(), map()) :: String.t()
  def label(tool_name, arguments) when is_binary(tool_name) and is_map(arguments) do
    case module(tool_name) do
      nil -> humanize(tool_name)
      module -> module.label(arguments)
    end
  end

  @doc """
  The device a tool call names, as a person would say it.

  Falls back to the raw id, which is what a model naming a device this house
  does not have deserves to be shown.
  """
  @spec device_name(map()) :: String.t()
  def device_name(%{"device" => id}) when is_binary(id) do
    case Dobby.Home.fetch_device(id) do
      {:ok, device} -> device.name
      :error -> id
    end
  end

  def device_name(_arguments), do: "a device"

  defp module(tool_name) do
    Enum.find(Dobby.Home.tools(), fn tool -> tool.name() == tool_name end)
  end

  defp humanize(tool_name), do: String.replace(tool_name, "_", " ")
end
