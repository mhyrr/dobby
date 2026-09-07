defmodule Dobby.Tools.ProposeRule do
  @moduledoc """
  Interpretation ends at a proposal. The returned deterministic description
  is what the household agrees to; no timer starts here. Duration conversion
  belongs to code, so the model copies 'twenty minutes' as 20 and minutes.

  The schema says what each field is and nothing about when to call. The
  doctrine in `Dobby.DobbyAgent` says when, once: a rule repeated here rides
  on every request and can drift from the one that counts. Two fields the
  file carries are set here rather than asked for — an absence rule's event
  kind and action are constants today, and a model copying two fixed strings
  is two more ways to get a rule wrong.
  """
  use Jido.Action,
    name: "propose_rule",
    description:
      "Propose one observation-only standing rule on one device. Returns the exact description the household must agree to; nothing is watched until confirm_rule.",
    schema: [
      id: [type: :string, required: true, doc: "Lowercase slug, e.g. garage-open."],
      name: [type: :string, required: true, doc: "Short household name."],
      device: [type: :string, required: true, doc: "Device id from the roster."],
      kind: [
        type: {:in, ["state", "absence"]},
        required: true,
        doc:
          "state: the condition holds for the duration. absence: no change into the condition is recorded for the duration."
      ],
      attribute: [
        type: :string,
        required: true,
        doc: "Observable name, exactly as the house block's watches line or list_rules gives it."
      ],
      operator: [type: {:in, ["eq", "ne", "gt", "gte", "lt", "lte"]}, required: true],
      number_value: [
        type: :float,
        doc: "Threshold for a number observable. Give exactly one of the three value fields."
      ],
      boolean_value: [type: :boolean, doc: "Value for a boolean observable."],
      state_value: [type: :string, doc: "Word from an enum observable's vocabulary."],
      duration: [
        type: :integer,
        required: true,
        doc: "Duration as spoken, e.g. 20; 0 for the moment it happens."
      ],
      duration_unit: [type: {:in, ["seconds", "minutes", "hours", "days"]}, required: true],
      unit: [
        type: :string,
        doc:
          "Reported unit of an environmental reading, as the device's state shows it reporting."
      ],
      source: [
        type: :string,
        doc: "The household's words. Filled from the conversation when omitted."
      ],
      window_start: [type: :string, doc: "Local HH:MM; pair with window_end."],
      window_end: [
        type: :string,
        doc: "Local HH:MM, exclusive. Earlier than window_start means overnight."
      ],
      window_days: [
        type: {:list, :integer},
        doc: "Weekdays 1 (Monday) to 7 (Sunday); omit for every day."
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "writing down a standing rule"

  @seconds %{"seconds" => 1, "minutes" => 60, "hours" => 3600, "days" => 86_400}
  @absence_event %{"event_kind" => "device_changed", "action" => "state_changed"}

  # NimbleOptions has no :number type. :float exports the JSON number schema;
  # normalize JSON integers before validation without adding an absent value.
  @impl true
  def on_before_validate_params(params) do
    params =
      params |> Dobby.Tools.without_blanks() |> Map.take(Keyword.keys(schema())) |> one_value()

    case params do
      %{number_value: value} when is_integer(value) ->
        {:ok, %{params | number_value: value * 1.0}}

      _ ->
        {:ok, params}
    end
  end

  # Three typed slots, and a model that fills all three — `false` and `0` for
  # the two it did not mean — and a unit ("°F") for a thermostat reading that
  # takes none. The device's declared observable says which slot carries the
  # value and whether a unit applies; the rest is filler and goes. When the
  # device or observable is unknown nothing is dropped, and the later checks
  # name the fault.
  defp one_value(%{device: device, attribute: attribute} = params) do
    with {:ok, %{agent_module: module}} <- Dobby.Home.fetch_device(device),
         {_key, type} <-
           Enum.find(module.observables(), fn {key, _} -> Atom.to_string(key) == attribute end) do
      keep =
        case type do
          :boolean -> :boolean_value
          {:enum, _} -> :state_value
          _ -> :number_value
        end

      params = Map.drop(params, [:number_value, :boolean_value, :state_value] -- [keep])
      if match?({:reading, _}, type), do: params, else: Map.delete(params, :unit)
    else
      _ -> params
    end
  end

  defp one_value(params), do: params

  @impl true
  def run(params, context) do
    with {:ok, value} <- value(params),
         {:ok, window} <- window(params) do
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
        |> Map.put(
          :duration_seconds,
          params.duration * Map.fetch!(@seconds, params.duration_unit)
        )
        |> Map.put(:source, context[:utterance_text] || params[:source])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      entry = if window, do: Map.put(entry, "window", window), else: entry
      entry = if params.kind == "absence", do: Map.merge(entry, @absence_event), else: entry

      case Dobby.Rules.propose(entry,
             actor: context[:speaker] || "the household",
             request_id: context[:request_id]
           ) do
        {:ok, proposal} -> {:ok, proposal |> Dobby.Rules.describe_proposal() |> replacing()}
        error -> error
      end
    end
  end

  # A proposal whose id a standing rule already holds is an edit: confirming
  # it replaces that rule and its watch. The proposal machinery has always
  # allowed that and said nothing, so the household agreed to the new rule
  # alone and lost the old one unannounced. The result now names what would
  # be replaced, and the doctrine says to tell the household before asking.
  defp replacing(%{rule: %{"id" => id}} = described) do
    case Enum.find(Dobby.Rules.list(), &(&1.id == id)) do
      nil ->
        described

      standing ->
        Map.put(described, :replaces, %{
          id: standing.id,
          name: standing.name,
          description: standing.description,
          note: "Confirming this proposal replaces that rule and its watch."
        })
    end
  end

  defp replacing(described), do: described

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
end
