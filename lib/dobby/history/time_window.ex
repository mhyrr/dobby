defmodule Dobby.History.TimeWindow do
  @moduledoc """
  Calendar language resolved by the house clock, never by the model.

  Windows are half-open. Weeks start Monday; an unqualified weekday means its
  most recent occurrence, including today. Last night means yesterday at 18:00
  through today at 06:00, clipped to now. These meanings are returned with the
  evidence so a caller cannot silently substitute another interpretation.

  Explicit instants require offsets. Calendar boundaries use the same timezone
  database as schedules and refuse ambiguous or nonexistent local times.
  """

  alias Dobby.Schedules.Cron

  @periods ~w(today yesterday this_week last_week last_night weekday)

  def periods, do: @periods

  def resolve(params, timezone, now \\ DateTime.utc_now()) do
    with {:ok, local} <- DateTime.shift_zone(now, timezone, Cron.time_zone_database()),
         {:ok, window} <- window(params, timezone, local),
         :ok <- ordered(window) do
      {:ok, Map.merge(window, %{timezone: timezone, interval: "[since, until)"})}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "The house timezone cannot resolve this time."}
    end
  end

  defp window(params, zone, now) do
    period = get(params, :period)
    since = get(params, :since)
    until = get(params, :until)

    cond do
      period != nil and (since != nil or until != nil) ->
        {:error, "Use a calendar period or explicit instants, not both."}

      since != nil or until != nil ->
        with {:ok, first} <- instant(since),
             {:ok, last} <- instant(until || DateTime.to_iso8601(now)) do
          {:ok, %{since: first, until: last, period: "explicit"}}
        end

      period == nil and get(params, :mode) == "latest" ->
        {:ok, %{since: nil, until: now, period: "all_recorded_history"}}

      true ->
        calendar(period || "today", get(params, :weekday), zone, now)
    end
  end

  defp calendar(period, weekday, zone, now) do
    today = DateTime.to_date(now)
    monday = Date.add(today, 1 - Date.day_of_week(today))

    dates =
      case period do
        "today" ->
          {today, ~T[00:00:00], Date.add(today, 1), ~T[00:00:00]}

        "yesterday" ->
          {Date.add(today, -1), ~T[00:00:00], today, ~T[00:00:00]}

        "this_week" ->
          {monday, ~T[00:00:00], Date.add(monday, 7), ~T[00:00:00]}

        "last_week" ->
          {Date.add(monday, -7), ~T[00:00:00], monday, ~T[00:00:00]}

        "last_night" ->
          {Date.add(today, -1), ~T[18:00:00], today, ~T[06:00:00]}

        "weekday" when is_integer(weekday) and weekday in 1..7 ->
          day = Date.add(today, -Integer.mod(Date.day_of_week(today) - weekday, 7))
          {day, ~T[00:00:00], Date.add(day, 1), ~T[00:00:00]}

        _ ->
          nil
      end

    case dates do
      {first_date, first_time, last_date, last_time} ->
        with {:ok, first} <- local(first_date, first_time, zone),
             {:ok, last} <- local(last_date, last_time, zone) do
          last = if DateTime.compare(last, now) == :gt, do: now, else: last
          {:ok, %{since: first, until: last, period: period}}
        end

      nil ->
        {:error,
         "Use today, yesterday, this_week, last_week, last_night, or weekday (1=Monday through 7=Sunday)."}
    end
  end

  defp local(date, time, zone) do
    case DateTime.new(date, time, zone, Cron.time_zone_database()) do
      {:ok, instant} ->
        {:ok, instant}

      {:ambiguous, _, _} ->
        {:error, "The local time is ambiguous; supply explicit instants with offsets."}

      {:gap, _, _} ->
        {:error, "The local time does not exist; supply explicit instants with offsets."}

      _ ->
        {:error, "The house timezone cannot resolve this time."}
    end
  end

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> {:ok, instant}
      _ -> {:error, "since and until must be ISO 8601 instants with UTC offsets."}
    end
  end

  defp instant(_), do: {:error, "Supply since when using explicit instants."}
  defp ordered(%{since: nil}), do: :ok

  defp ordered(%{since: first, until: last}) do
    if DateTime.compare(first, last) == :lt,
      do: :ok,
      else: {:error, "since must be earlier than until."}
  end

  defp get(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
