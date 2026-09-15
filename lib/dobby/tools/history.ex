defmodule Dobby.Tools.History do
  @moduledoc """
  Past-tense questions share one deterministic query with the house's other
  callers. The language layer extracts filters and calendar words; the query
  owns dates, counts, and the limits of what its evidence can establish.

  The closed vocabularies — record kinds, calendar periods, modes — are typed
  enums here rather than prose, so the exporter tells the model the choices
  and the validator refuses the rest. The lists are literal because the
  action macro needs them so; `Dobby.HistoryToolTest` holds them to
  `Dobby.History`'s own. One way to say which kinds: `Dobby.History` accepts
  `kind` too, for callers that are not the model, but a second field with
  the same fifteen words would be paid for on every request and would give
  the model a rule about which to use.

  `action` and `actor` are not offered. The eval tier watched `action` filled
  with a kind name (`device_changed`, `control`) and an invented verb
  (`heating`), and `actor` filled with the speaker's own name on every call,
  so that "who set the thermostat?" was answered from the rows Greg wrote and
  nothing else. Each matches no row, or the wrong rows, and turns a real
  record into "nothing recorded". Device, kinds, and the period answer the
  household's questions; the rows carry their actor and action for the reply
  to read. `Dobby.History` still takes both, for callers that know the
  recorded vocabulary.
  """

  use Jido.Action,
    name: "history",
    description:
      "Read Dobby's own activity record for one device or the whole house: commands, observed state changes, refusals, and rule events, including devices since removed. Each row names its actor and action. Code resolves the period and counts the rows.",
    schema: [
      device: [type: :string, doc: "Device id, current or former. Omit for the whole house."],
      kinds: [
        type:
          {:list,
           {:in,
            [
              "request",
              "tool_call",
              "control",
              "device_changed",
              "schedule_fired",
              "command_refused",
              "command_never_arrived",
              "rule_breached",
              "rule_resolved",
              "rule_acknowledged",
              "rule_saved",
              "rule_confirmed",
              "rule_paused",
              "rule_resumed",
              "rule_deleted"
            ]}},
        doc:
          "Record kinds to include; all when omitted. request: somebody spoke to Dobby. tool_call: Dobby acted for them. control: a hand on a card or a form. device_changed: a state change Home Assistant reported. schedule_fired: a schedule ran. command_refused and command_never_arrived: a command's outcome. rule_*: standing rules and their notices."
      ],
      period: [
        type: {:in, ["today", "yesterday", "this_week", "last_week", "last_night", "weekday"]},
        doc: "Calendar period in house time; today when omitted. last_night is 18:00 to 06:00."
      ],
      weekday: [
        type: :integer,
        doc: "With period weekday: 1 Monday to 7 Sunday, the most recent one including today."
      ],
      since: [
        type: :string,
        doc:
          "Only when the household named a date: that date as YYYY-MM-DD, and the house applies its own clock. Not with period."
      ],
      until: [
        type: :string,
        doc:
          "Only beside since: the day after the last day asked about, as YYYY-MM-DD, exclusive. Now when omitted."
      ],
      mode: [
        type: {:in, ["events", "count", "latest", "duration"]},
        doc:
          "events: the matching rows. count: how many in the whole period. latest: the most recent row in all recorded history. duration: always unknown, since this record has no coverage intervals."
      ],
      limit: [
        type: :integer,
        doc: "Rows returned, 1 to 100, default 50. count covers the whole period regardless."
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "reading the house's record"

  # Only the schema's own fields reach the query: Jido's validator lets an
  # unknown key through, and `Dobby.History` would honour an `actor` a model
  # remembered from an older schema. Then the slots a model fills beside the
  # one it meant: a weekday means something only with period weekday; a
  # named date's instants are the household's own words and a period beside
  # them is filler; and latest searches all recorded history, so a period
  # beside it would quietly search today instead. The eval tier watched each
  # of these turn a real record into "nothing recorded".
  @impl true
  def on_before_validate_params(params) do
    params = params |> Dobby.Tools.without_blanks() |> Map.take(Keyword.keys(schema()))

    params =
      cond do
        Map.has_key?(params, :since) or Map.has_key?(params, :until) ->
          Map.drop(params, [:period, :weekday])

        params[:mode] == "latest" ->
          Map.drop(params, [:period, :weekday])

        params[:period] == "weekday" ->
          params

        true ->
          Map.delete(params, :weekday)
      end

    {:ok, params}
  end

  @impl true
  def run(params, _context) do
    with {:ok, params} <- dated(params),
         {:ok, result} <- Dobby.History.query(params) do
      {:ok, on_the_house_clock(result)}
    end
  end

  # A date the household named arrives as a date, and code makes the instant.
  # The record takes instants with offsets, and the doctrine used to ask the
  # model to attach the house clock's offset to any date it was given — which
  # is the model doing time-zone arithmetic, and it did it wrong: today's
  # offset on a January date is off by an hour at both ends in a house that
  # keeps daylight time. So `since` and `until` may be bare dates; each
  # becomes local midnight in the house's zone here, `until` exclusive, with
  # an ambiguous midnight taking its first reading and a missing one the
  # first instant after the gap. An instant with an offset still passes as it
  # was, for a caller that has one.
  defp dated(params) do
    Enum.reduce_while([:since, :until], {:ok, params}, fn edge, {:ok, params} ->
      case Map.fetch(params, edge) do
        {:ok, value} ->
          case midnight(value) do
            {:ok, instant} -> {:cont, {:ok, Map.put(params, edge, instant)}}
            :not_a_date -> {:cont, {:ok, params}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error ->
          {:cont, {:ok, params}}
      end
    end)
  end

  defp midnight(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        zone = Dobby.Home.manifest().timezone

        case DateTime.new(date, ~T[00:00:00], zone, Dobby.Schedules.Cron.time_zone_database()) do
          {:ok, at} -> {:ok, DateTime.to_iso8601(at)}
          {:ambiguous, first, _second} -> {:ok, DateTime.to_iso8601(first)}
          {:gap, _before, after_gap} -> {:ok, DateTime.to_iso8601(after_gap)}
          {:error, _reason} -> {:error, "#{value} is not a day the house's clock can place."}
        end

      {:error, _not_a_date} ->
        :not_a_date
    end
  end

  defp midnight(_other), do: :not_a_date

  # The record stamps rows in UTC and the model reads them beside a house
  # clock in the household's zone. Asked what happened last night, GLM 5.2 on
  # 2026-09-07 read a row at 03:10Z as "3:10 AM last night" for a door that
  # unlocked at 11:10 PM. Converting a zone is arithmetic, and the model never
  # does arithmetic: the rows and the window leave here in the house's own
  # offset, which is the clock the block shows. Transport, so it lives in the
  # tool and not in `Dobby.History`, whose record stays in UTC for every
  # other reader.
  defp on_the_house_clock(result) when is_map(result) do
    result
    |> Map.update(:entries, [], fn entries ->
      Enum.map(entries, &Map.update(&1, :at, nil, fn at -> on_the_house_clock(at) end))
    end)
    |> Map.update(:window, %{}, fn window ->
      Map.new(window, fn {edge, at} -> {edge, on_the_house_clock(at)} end)
    end)
  end

  # One string, converted the one way the house converts a timestamp for the
  # model: `Dobby.Home.local_iso8601/1`, which the world model renderer and
  # every device status tool already read through. What is the tool's own
  # knowledge is the shape — that the rows are a list and the window a pair of
  # edges — not what "on the house's clock" means.
  defp on_the_house_clock(iso) when is_binary(iso), do: Dobby.Home.local_iso8601(iso)

  defp on_the_house_clock(other), do: other
end
