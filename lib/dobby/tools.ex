defmodule Dobby.Tools do
  @moduledoc """
  How a tool call reads on the board (design §10.7).

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

  @doc """
  Coerces a model-supplied number toward the integer the schema declares.

  `:integer` renders as `"integer"` in the JSON schema, which is the truth;
  this is for models that send `"60"` or `60.0` anyway, because we have
  watched them do it. A value that will not read as a number passes through
  unchanged, so NimbleOptions still names the field in its refusal.
  """
  @spec to_percent(term()) :: term()
  def to_percent(value) when is_integer(value), do: value
  def to_percent(value) when is_float(value), do: round(value)

  def to_percent(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> value
    end
  end

  def to_percent(value), do: value

  @doc """
  Drops the fields a model filled in only because the schema named them.

  Some models send every property a schema lists — `""` for a string they
  have no use for, `[]` for a list, `null` for the rest — and each one then
  reads as a value the validators must refuse. The refusal is retryable, the
  model sends the same shape again, and the turn times out. The eval tier
  watched gpt-5.6-luna do exactly that on 2026-09-06, on every history call.
  Absence spelled as blank is transport, not intent, so it goes before
  validation, and validation keeps refusing what is actually wrong.
  """
  @spec without_blanks(map()) :: map()
  def without_blanks(params) when is_map(params),
    do: Map.reject(params, fn {_key, value} -> blank?(value) end)

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp module(tool_name) do
    Enum.find(Dobby.Home.tools(), fn tool -> tool.name() == tool_name end)
  end

  defp humanize(tool_name), do: String.replace(tool_name, "_", " ")
end
