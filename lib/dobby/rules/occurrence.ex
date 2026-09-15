defmodule Dobby.Rules.Occurrence do
  @moduledoc """
  One breach, including the acknowledgment that must survive a restart.

  Definitions belong to the home file. Occurrences belong to the record and
  remain readable after a definition is edited or removed. An unresolved row
  suppresses another notice, even after this process loses its timers.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "rule_occurrences" do
    field(:house_id, :string)
    field(:rule_id, :string)
    field(:revision, :string)
    field(:name, :string)
    field(:text, :string)
    field(:observed_since, :utc_datetime_usec)
    field(:acknowledged_by, :string)
    field(:resolved_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
