defmodule Dobby.History do
  @moduledoc """
  The household's past, limited to what Dobby actually recorded (TK-027).

  Removed devices remain queryable: identity in the record must not depend on
  today's manifest. Filters are exact strings, never SQL or inferred aliases.
  Counts cover all matching rows, independent of the evidence cap. They count
  records, not physical actions: one command may have both a command row and
  an observed state row. Kind filters let the caller count one kind of evidence.

  This log has no observation coverage intervals or initial state records.
  Consequently it cannot measure time spent heating, cleaning, or offline.
  Duration returns unknown rather than adding the API's duration_ms fields,
  which measure calls, not device operation. HA recorder is a separate design.
  """

  alias Dobby.{Activity, Home}
  alias Dobby.History.TimeWindow

  @kinds ~w(request tool_call control device_changed schedule_fired command_refused command_never_arrived rule_breached rule_resolved rule_acknowledged rule_saved rule_confirmed rule_paused rule_resumed rule_deleted)
  @keys ~w(device action actor kind kinds period weekday since until mode limit)
  @modes ~w(events count latest duration)

  def kinds, do: @kinds
  def modes, do: @modes

  def query(params, opts \\ [])

  def query(params, opts) when is_map(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    with :ok <- validate(params),
         {:ok, window} <-
           TimeWindow.resolve(
             params,
             Keyword.get_lazy(opts, :timezone, fn -> Home.manifest().timezone end),
             Keyword.get(opts, :now, DateTime.utc_now())
           ) do
      filters = Map.take(params, ~w(device action actor kind kinds))
      mode = params["mode"] || "events"
      limit = if mode == "latest", do: 1, else: params["limit"] || 50
      result = Activity.history(filters, window, limit)

      {:ok,
       Map.merge(result, %{
         source: "dobby_activity",
         mode: mode,
         window: Map.new(window, fn {key, value} -> {key, encode_time(value)} end),
         entries: Enum.map(result.entries, &describe/1),
         duration_seconds: nil,
         coverage:
           "Recorded events only; gaps and downtime are unknown. No row is not proof that nothing happened. Continuous device duration cannot be measured from this log.",
         count_unit: "activity records, not unique physical actions"
       })}
    end
  end

  def query(_, _), do: {:error, "History filters must be an object."}

  defp validate(params) do
    cond do
      Enum.any?(Map.keys(params), &(&1 not in @keys)) ->
        {:error, "Unknown history filter."}

      (params["mode"] || "events") not in @modes ->
        {:error, "mode must be events, count, latest, or duration."}

      not is_integer(params["limit"] || 50) or (params["limit"] || 50) not in 1..100 ->
        {:error, "limit must be an integer from 1 through 100."}

      params["kind"] != nil and params["kinds"] != nil ->
        {:error, "Use kind or kinds, not both."}

      params["kind"] != nil and params["kind"] not in @kinds ->
        {:error, "Unknown activity kind; use #{Enum.join(@kinds, ", ")}."}

      params["kinds"] != nil and
          (not is_list(params["kinds"]) or params["kinds"] == [] or
             Enum.any?(params["kinds"], &(&1 not in @kinds))) ->
        {:error, "kinds must be a nonempty list of known activity kinds."}

      Enum.any?(~w(device action actor), fn key ->
        params[key] != nil and (not is_binary(params[key]) or String.trim(params[key]) == "")
      end) ->
        {:error, "device, action, and actor must be nonempty strings."}

      params["weekday"] != nil and params["period"] != "weekday" ->
        {:error, "weekday requires period weekday."}

      true ->
        :ok
    end
  end

  defp describe(entry) do
    %{
      id: entry.id,
      at: DateTime.to_iso8601(entry.inserted_at),
      kind: entry.kind,
      actor: entry.actor,
      device: entry.device,
      action: entry.action,
      args: entry.args,
      result: entry.result,
      request_id: entry.request_id,
      evidence: evidence(entry.kind)
    }
  end

  defp evidence("device_changed"), do: "observed state change reported by Home Assistant"

  defp evidence("command_never_arrived"),
    do: "command was not observed arriving before its deadline; physical outcome unknown"

  defp evidence("command_refused"), do: "Home Assistant refused the command"

  defp evidence(kind) when kind in ~w(tool_call control schedule_fired),
    do:
      "recorded call or command; inspect result for acceptance or refusal, not proof of physical outcome"

  defp evidence(_), do: "recorded event"
  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_time(value), do: value
end
