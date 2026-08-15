defmodule Dobby.Schedules.Cron do
  @moduledoc """
  Cron expressions, as the scheduler understands them.

  Two jobs: refuse an expression at authoring time that would never fire, and
  answer "when next?" for a schedule that will.

  ## Why this wraps Crontab rather than Jido

  `Jido.Scheduler.Job` is what actually runs these, and it decides validity with
  functions marked `@doc false`. Reaching into those would tie authoring to a
  private contract. So this module uses `Crontab`'s public API — the same
  library Jido uses — and makes the same parse-mode choice it does.

  That leaves a seam: an expression this module accepts and Jido's timer
  rejects would produce a schedule that silently never fires. The seam is
  closed on the other side — `Dobby.SchedulerAgent.Sync` verifies that every
  schedule it registered actually has a running job, and records the ones that
  do not (`Dobby.Schedules.unregistered/0`). A miss is visible, not silent.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @doc """
  The timezone database this house resolves local time with.

  Jido reads its own from this key, and the two must agree or a schedule could
  validate here and fail to resolve there. Public because the surface converts
  timestamps to the household's clock too, and a second answer to "which
  database" is a second answer to "what time is it".
  """
  @spec time_zone_database() :: Calendar.time_zone_database()
  def time_zone_database do
    Application.get_env(:jido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
  end

  @doc """
  Parses a cron expression.

  Five fields is the household form — `"0 20 * * 1-5"`, eight o'clock on
  weeknights. Six fields is the same thing with a leading seconds column, which
  a person is unlikely to want and the test suite very much does: it is what
  lets a firing test exercise the real timer in one second instead of sixty.

  The mode is chosen by field count, matching `Jido.Scheduler.Job`.
  """
  @spec parse(String.t()) :: {:ok, Crontab.CronExpression.t()} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    expression
    |> parse_modes()
    |> Enum.reduce_while({:error, invalid(expression)}, fn extended, error ->
      case Parser.parse(expression, extended) do
        {:ok, cron} -> {:halt, {:ok, cron}}
        {:error, _reason} -> {:cont, error}
      end
    end)
  end

  def parse(other), do: {:error, "cron must be a string, got #{inspect(other)}"}

  defp parse_modes("@" <> _rest), do: [false]

  defp parse_modes(expression) do
    if length(String.split(expression, ~r/\s+/, trim: true)) > 5, do: [true, false], else: [false]
  end

  defp invalid(expression), do: "#{inspect(expression)} is not a cron expression"

  @doc """
  Checks that a timezone is one the timer can resolve.
  """
  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(timezone) when is_binary(timezone) do
    match?({:ok, _now}, DateTime.now(timezone, time_zone_database()))
  end

  def valid_timezone?(_other), do: false

  @doc """
  The next time this expression fires after `from`.

  Pure with respect to the clock — `from` is supplied, never read — which is
  what makes the schedule *semantics* testable without waiting for Tuesday.
  The admin dashboard's "next: tonight at 8" is the same call.
  """
  @spec next_fire(String.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  def next_fire(expression, timezone, %DateTime{} = from) do
    with {:ok, cron} <- parse(expression),
         {:ok, local} <- shift(from, timezone),
         {:ok, naive} <- next_run_date(cron, local) do
      resolve(naive, timezone)
    end
  end

  defp shift(from, timezone) do
    case DateTime.shift_zone(from, timezone, time_zone_database()) do
      {:ok, local} -> {:ok, local}
      {:error, reason} -> {:error, "unknown timezone #{inspect(timezone)}: #{inspect(reason)}"}
    end
  end

  defp next_run_date(cron, local) do
    case Scheduler.get_next_run_date(cron, DateTime.to_naive(local)) do
      {:ok, naive} -> {:ok, naive}
      {:error, reason} -> {:error, "no next run: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "no next run: #{Exception.message(error)}"}
  end

  # A wall-clock time that falls in a DST gap does not exist; one in a fold
  # happens twice. Taking the later instant in both cases matches what Jido's
  # own scheduler does, so a schedule's next-fire display cannot disagree with
  # when it actually fires.
  defp resolve(naive, timezone) do
    case DateTime.from_naive(naive, timezone, time_zone_database()) do
      {:ok, at} -> {:ok, at}
      {:ambiguous, _first, second} -> {:ok, second}
      {:gap, _before, after_dt} -> {:ok, after_dt}
      {:error, reason} -> {:error, "unknown timezone #{inspect(timezone)}: #{inspect(reason)}"}
    end
  end
end
