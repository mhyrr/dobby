defmodule Dobby.Rules.Window do
  @moduledoc """
  A local daily watch window. Overnight windows belong to the day they start.
  UTC instants are converted to local time, so repeated DST hours need no guess
  and skipped hours cannot acquire invented elapsed observation.
  """

  def load(nil), do: {:ok, nil}

  def load(%{"start" => first, "end" => last} = raw) do
    days = Map.get(raw, "days", Enum.to_list(1..7))

    with true <- Enum.all?(Map.keys(raw), &(&1 in ~w(start end days))),
         {:ok, start_time} <- clock(first),
         {:ok, end_time} <- clock(last),
         true <- start_time != end_time,
         true <-
           is_list(days) and days != [] and Enum.all?(days, &(is_integer(&1) and &1 in 1..7)) do
      {:ok, %{"start" => first, "end" => last, "days" => Enum.sort(Enum.uniq(days))}}
    else
      _ ->
        {:error, "window needs distinct start/end HH:MM times and days numbered 1 (Monday) to 7"}
    end
  end

  def load(_), do: {:error, "window must contain start and end times"}

  @doc """
  Identifies one daily watch interval. A delayed tick must not join yesterday's
  observation to today's across hours when the rule was not watching.
  """
  def key(nil, _utc, _timezone), do: :always

  def key(window, utc, timezone) do
    if active?(window, utc, timezone) do
      {:ok, local} = DateTime.shift_zone(utc, timezone, Dobby.Schedules.Cron.time_zone_database())
      {:ok, first} = clock(window["start"])
      date = DateTime.to_date(local)
      if Time.compare(DateTime.to_time(local), first) == :lt, do: Date.add(date, -1), else: date
    end
  end

  def active?(nil, _utc, _timezone), do: true

  def active?(window, utc, timezone) do
    case DateTime.shift_zone(utc, timezone, Dobby.Schedules.Cron.time_zone_database()) do
      {:ok, local} ->
        {:ok, first} = clock(window["start"])
        {:ok, last} = clock(window["end"])
        time = DateTime.to_time(local)
        date = DateTime.to_date(local)

        if Time.compare(first, last) == :lt do
          Date.day_of_week(date) in window["days"] and
            Time.compare(time, first) != :lt and Time.compare(time, last) == :lt
        else
          cond do
            Time.compare(time, first) != :lt ->
              Date.day_of_week(date) in window["days"]

            Time.compare(time, last) == :lt ->
              Date.day_of_week(Date.add(date, -1)) in window["days"]

            true ->
              false
          end
        end

      _ ->
        false
    end
  end

  defp clock(value) when is_binary(value) do
    if Regex.match?(~r/^\d{2}:\d{2}$/, value), do: Time.from_iso8601(value <> ":00"), else: :error
  end

  defp clock(_), do: :error
end
