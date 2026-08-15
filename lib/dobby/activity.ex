defmodule Dobby.Activity do
  @moduledoc """
  Everything that happened (design §10.4).

  The counterpart to `Dobby.Conversation`, and the split between them is design
  §10.1: **the thread records interventions, the admin records everything.** An
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
  end

  @doc """
  The most recent entries, newest first.

  Newest first because this one is read as a feed rather than as a
  conversation — the admin opens it to see what just happened, not to read
  from the beginning.
  """
  @spec recent(non_neg_integer()) :: [Entry.t()]
  def recent(limit \\ 100) when is_integer(limit) and limit >= 0 do
    Repo.all(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc """
  Everything recorded while answering one request.

  Oldest first: within a single request this is a story, and the order it
  happened in is the point.
  """
  @spec for_request(String.t()) :: [Entry.t()]
  def for_request(request_id) when is_binary(request_id) do
    Repo.all(
      from e in Entry,
        where: e.request_id == ^request_id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc """
  Recent entries for one device, newest first.

  The shape `TK-004` needs: has this device been refusing all week.
  """
  @spec for_device(String.t(), non_neg_integer()) :: [Entry.t()]
  def for_device(device, limit \\ 100) when is_binary(device) do
    Repo.all(
      from e in Entry,
        where: e.device == ^device,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end
end
