defmodule Dobby.Tools.DeleteSchedule do
  @moduledoc """
  Tool: remove a schedule for good.

  The timer goes with the row. Nothing here asks "are you sure" — the model is
  told to confirm which schedule before deleting one, and a household of four
  people sharing one thread does not need a permissions dialog (§10.4). What it
  needs is for the deletion to be announced, which the reply is.
  """

  use Jido.Action,
    name: "delete_schedule",
    description: """
    Delete a schedule permanently. Use list_schedules to find the id, and be \
    sure which one is meant before calling this.\
    """,
    schema: [
      id: [type: :integer, required: true, doc: "Schedule id from list_schedules"]
    ]

  @behaviour Dobby.Tools

  alias Dobby.Schedules

  @impl Dobby.Tools
  def label(_arguments), do: "deleting a schedule"

  @impl true
  def on_before_validate_params(params), do: {:ok, Schedules.coerce_id_param(params)}

  @impl true
  def run(%{id: id}, _context) do
    case Schedules.delete_schedule(id) do
      {:ok, schedule} -> {:ok, %{deleted: schedule.id, label: schedule.label}}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Schedules.error_message(changeset)}
      {:error, reason} -> {:error, reason}
    end
  end
end
