defmodule Dobby.ActivityEvents do
  @moduledoc """
  The `dobby:activity` seam (design §11).

  One topic for the full record. The admin subscribes; nothing else does, and
  that is the point of it being separate from `dobby:thread` — the thread is a
  document a household reads and this is a log a maintainer queries, so a
  kitchen tablet has no business receiving an endpoint's every flap.

  Follows `Dobby.DeviceEvents` and `Dobby.ThreadEvents`: both sides agree on
  the payload in one place rather than in two that drift.

      {:recorded, %Entry{}}   something happened and was written down
  """

  alias Dobby.Activity.Entry

  @topic "dobby:activity"

  @doc """
  The PubSub topic carrying the full record.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to the full record.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  Announces an entry that has just been written.
  """
  @spec recorded(Entry.t()) :: :ok
  def recorded(%Entry{} = entry) do
    Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, {:recorded, entry})
  end
end
