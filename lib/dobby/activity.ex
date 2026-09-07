defmodule Dobby.Activity do
  @moduledoc """
  Everything that happened (design §10.6).

  The counterpart to `Dobby.Conversation`, and the split between them is design
  §10.3: **the thread records interventions, the admin records everything.** An
  endpoint flapping at 3am belongs here and nowhere else; a thermostat somebody
  set belongs in both, said once for a person and once for the record.

  This is also the table the diagnostic agent (`TK-004`) reads. Its premise is
  answering "is this the third time this week", which is a question about
  history rather than about the event in hand — so the reads below are by
  device and by time, not only by recency.
  """

  import Ecto.Query

  alias Dobby.Activity.Entry
  alias Dobby.Repo

  @doc """
  The newest record id at the start of a watch. Queued deliveries from before
  activation must not count as new events, or extend an absence interval.
  """
  def latest_id, do: Repo.one(from(e in Entry, select: max(e.id))) || 0

  @doc """
  Records something that happened.

  Deliberately total: an activity entry is a side record, and failing to write
  one must never take down the thing it was describing. Callers that care can
  match on the result; callers in a hot path should not have to.
  """
  @spec record(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
    |> announce()
  end

  # Announced from the write rather than from each caller, so the feed cannot
  # end up showing a different set of events from the table it claims to be a
  # view of. There are three callers already and they have nothing else in
  # common.
  defp announce({:ok, entry} = result) do
    Dobby.ActivityEvents.recorded(entry)
    result
  end

  defp announce(result), do: result

  @doc """
  Coerces a term into something the `:map` columns can hold.

  `args` and `result` are JSON, and what goes into them is ordinary Elixir —
  tuples, structs, atoms, whatever an action or a device snapshot happened to
  contain. A log write that raised on one would take down the thing it was only
  supposed to describe, which is the opposite of what a log is for.
  """
  @spec jsonable(term()) :: term()
  def jsonable(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  def jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def jsonable(value) when is_struct(value), do: value |> Map.from_struct() |> jsonable()
  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> jsonable()
  def jsonable(value) when is_binary(value) or is_number(value), do: value
  def jsonable(value) when is_boolean(value) or is_nil(value), do: value
  def jsonable(value) when is_atom(value), do: to_string(value)
  def jsonable(value), do: inspect(value)

  @doc """
  The most recent entries, newest first.

  Newest first because this one is read as a feed rather than as a
  conversation — the admin opens it to see what just happened, not to read
  from the beginning.
  """
  @spec recent(non_neg_integer()) :: [Entry.t()]
  def recent(limit \\ 100) when is_integer(limit) and limit >= 0 do
    Repo.all(from(e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit))
  end

  @doc """
  Everything recorded while answering one request.

  Oldest first: within a single request this is a story, and the order it
  happened in is the point.
  """
  @spec for_request(String.t()) :: [Entry.t()]
  def for_request(request_id) when is_binary(request_id) do
    Repo.all(
      from(e in Entry,
        where: e.request_id == ^request_id,
        order_by: [asc: e.inserted_at, asc: e.id]
      )
    )
  end

  @doc """
  When each device was last recorded moving, keyed by device.

  One query for the whole house, because the caller is a diagram with a line
  per device and N queries for N devices is a page that gets slower as the
  house grows.

  It answers from `device_changed` entries, which the watcher writes only when
  something went from one known value to another — so "last change" here means
  the same thing it means in the feed underneath it, and a device reporting for
  the first time does not read as one that just moved.
  """
  @spec last_changes() :: %{String.t() => DateTime.t()}
  def last_changes do
    Repo.all(
      from(e in Entry,
        where: e.kind == "device_changed" and not is_nil(e.device),
        group_by: e.device,
        select: {e.device, max(e.inserted_at)}
      )
    )
    |> Map.new()
  end

  @doc """
  Recent entries for one device, newest first.

  The shape `TK-004` needs: has this device been refusing all week.
  """
  @spec for_device(String.t(), non_neg_integer()) :: [Entry.t()]
  def for_device(device, limit \\ 100) when is_binary(device) do
    Repo.all(
      from(e in Entry,
        where: e.device == ^device,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
      )
    )
  end

  @doc """
  Exact filtered history, with full-window totals and capped evidence.

  `Dobby.History` validates public filters. This query deliberately does not
  join the current device roster: a removed device still has a past.
  """
  def history(filters, window, limit) do
    query = from(e in Entry, where: e.inserted_at < ^window.until)

    query =
      if window.since, do: from(e in query, where: e.inserted_at >= ^window.since), else: query

    query =
      Enum.reduce(
        [{"device", :device}, {"action", :action}, {"actor", :actor}, {"kind", :kind}],
        query,
        fn {key, column}, query ->
          case filters[key] do
            nil -> query
            value -> from(e in query, where: field(e, ^column) == ^value)
          end
        end
      )

    query =
      case filters["kinds"] do
        nil -> query
        kinds -> from(e in query, where: e.kind in ^kinds)
      end

    # One statement gives counts and evidence the same database snapshot even
    # while the watcher writes another event. Window aggregates preserve the
    # total before the outer limit is applied.
    rows =
      Repo.all(
        from(e in query,
          select: {e, fragment("count(*) OVER ()")},
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: ^limit
        )
      )

    count =
      case rows do
        [{_, count} | _] -> count
        [] -> 0
      end

    %{
      entries: Enum.map(rows, &elem(&1, 0)),
      count: count,
      returned: length(rows),
      truncated: count > length(rows)
    }
  end
end
