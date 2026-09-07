defmodule Dobby.Repo.Migrations.AddRuleProposalsAndOccurrences do
  use Ecto.Migration

  def change do
    create table(:rule_proposals) do
      add(:house_id, :text, null: false)
      add(:rule_id, :text, null: false)
      add(:entry, :map, null: false)
      add(:previous, :map)
      add(:description, :text, null: false)
      add(:proposed_by, :text, null: false)
      add(:request_id, :text)
      add(:status, :text, null: false, default: "proposed")
      add(:confirmed_by, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:rule_proposals, [:house_id, :rule_id]))

    create table(:rule_occurrences, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:house_id, :text, null: false)
      add(:rule_id, :text, null: false)
      add(:revision, :text, null: false)
      add(:name, :text, null: false)
      add(:text, :text, null: false)
      add(:observed_since, :utc_datetime_usec, null: false)
      add(:acknowledged_by, :text)
      add(:resolved_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:rule_occurrences, [:house_id, :rule_id],
        where: "resolved_at IS NULL",
        name: :rule_occurrences_one_standing
      )
    )
  end
end
