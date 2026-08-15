defmodule Dobby.Tools.ListSchedules do
  @moduledoc """
  Tool: what the house does on its own.

  Every schedule, including the paused ones and the broken ones. A schedule
  whose device left the manifest reports `status: "cannot run: ..."` rather
  than being quietly omitted — the household asked for it and is entitled to
  know it is not happening.

  `next_fire` is computed at read time, so it cannot be stale.
  """

  use Jido.Action,
    name: "list_schedules",
    description: """
    List every schedule the house has, with its id, when it runs, when it next \
    runs, and whether it is active or paused.\
    """,
    schema: []

  @behaviour Dobby.Tools

  alias Dobby.Schedules

  @impl Dobby.Tools
  def label(_arguments), do: "reading the schedules"

  @impl true
  def run(_params, _context) do
    {:ok, %{schedules: Enum.map(Schedules.list_schedules(), &Schedules.describe/1)}}
  end
end
