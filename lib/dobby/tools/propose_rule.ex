defmodule Dobby.Tools.ProposeRule do
  @moduledoc """
  Interpretation ends at a proposal. The returned deterministic description
  is what the household agrees to; no timer starts here. Duration conversion
  belongs to code, so the model copies 'twenty minutes' as 20 and minutes.
  """
  use Jido.Action,
    name: "propose_rule",
    description:
      "Propose an observation-only standing rule. First read list_rules for observables. Show the returned description and wait for agreement in a later message; proposing starts no watch. For absence, use device_changed/state_changed plus the desired observed predicate. Never convert a request to act into a notice.",
    schema: [
      id: [type: :string, required: true, doc: "Stable lowercase rule slug, e.g. garage-open."],
      name: [type: :string, required: true, doc: "Short household name."],
      source: [
        type: :string,
        doc:
          "The household's original words, copied exactly. Conversation supplies this automatically."
      ],
      device: [type: :string, required: true, doc: "Exact device id from the roster."],
      kind: [type: {:in, ["state", "absence"]}, required: true],
      attribute: [type: :string, required: true, doc: "Observable name from list_rules."],
      operator: [type: {:in, ["eq", "ne", "gt", "gte", "lt", "lte"]}, required: true],
      number_value: [
        type: :float,
        doc: "Numeric threshold. Supply exactly one of number_value, boolean_value, state_value."
      ],
      boolean_value: [type: :boolean, doc: "True or false for a boolean observable."],
      state_value: [type: :string, doc: "State word from the observable vocabulary."],
      duration: [type: :integer, doc: "Duration number as spoken; code converts the unit."],
      duration_unit: [
        type: {:in, ["seconds", "minutes", "hours", "days"]},
        doc: "Unit as spoken, paired with duration."
      ],
      duration_seconds: [
        type: :integer,
        doc:
          "Alternative only for durations stated in seconds. Do not calculate this from another unit."
      ],
      unit: [type: :string, doc: "Exact reported environmental measurement unit, when required."],
      event_kind: [type: :string, doc: "For absence only: device_changed."],
      action: [type: :string, doc: "For absence only: state_changed."],
      window_start: [
        type: :string,
        doc: "Optional local HH:MM; pair with window_end. Ask what bedtime means."
      ],
      window_end: [
        type: :string,
        doc: "Exclusive local HH:MM end. Earlier than start means overnight."
      ],
      window_days: [
        type: {:list, :integer},
        doc: "Optional weekdays 1..7, Monday 1; requires start/end. Omit for every day."
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "writing down a standing rule"

  # NimbleOptions has no :number type. :float exports the JSON number schema;
  # normalize JSON integers before validation without adding an absent value.
  @impl true
  def on_before_validate_params(%{number_value: value} = params) when is_integer(value),
    do: {:ok, %{params | number_value: value * 1.0}}

  def on_before_validate_params(params), do: {:ok, params}

  @impl true
  def run(params, context) do
    with {:ok, seconds} <- duration(params),
         {:ok, value} <- value(params),
         {:ok, window} <- window(params) do
      source = context[:utterance_text] || params[:source]

      entry =
        params
        |> Map.drop([
          :duration,
          :duration_unit,
          :number_value,
          :boolean_value,
          :state_value,
          :window_start,
          :window_end,
          :window_days
        ])
        |> Map.put(:value, value)
        |> Map.put(:duration_seconds, seconds)
        |> Map.put(:source, source)
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      entry = if window, do: Map.put(entry, "window", window), else: entry

      case Dobby.Rules.propose(entry,
             actor: context[:speaker] || "the household",
             request_id: context[:request_id]
           ) do
        {:ok, proposal} -> {:ok, Dobby.Rules.describe_proposal(proposal)}
        error -> error
      end
    end
  end

  defp value(params) do
    case Map.take(params, [:number_value, :boolean_value, :state_value]) |> Map.values() do
      [value] -> {:ok, value}
      _ -> {:error, "supply exactly one of number_value, boolean_value, state_value"}
    end
  end

  defp window(params) do
    case Map.take(params, [:window_start, :window_end, :window_days]) do
      empty when map_size(empty) == 0 ->
        {:ok, nil}

      %{window_start: first, window_end: last} = window ->
        {:ok,
         %{
           "start" => first,
           "end" => last,
           "days" => Map.get(window, :window_days, Enum.to_list(1..7))
         }}

      _ ->
        {:error, "a watch window needs both start and end times"}
    end
  end

  defp duration(%{duration: number, duration_unit: unit} = params)
       when is_integer(number) and number >= 0 do
    if Map.has_key?(params, :duration_seconds) do
      {:error, "supply duration and its unit, or duration_seconds, not both"}
    else
      factor = %{"seconds" => 1, "minutes" => 60, "hours" => 3600, "days" => 86400}
      {:ok, number * Map.fetch!(factor, unit)}
    end
  end

  defp duration(%{duration_seconds: seconds} = params) when is_integer(seconds) do
    if Map.has_key?(params, :duration) or Map.has_key?(params, :duration_unit),
      do: {:error, "supply one duration"},
      else: {:ok, seconds}
  end

  defp duration(_), do: {:error, "state the duration and its unit"}
end
