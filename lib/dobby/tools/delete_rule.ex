defmodule Dobby.Tools.DeleteRule do
  @moduledoc """
  The tool carries intent and attribution. The rules context owns the change.
  """
  use Jido.Action,
    name: "delete_rule",
    description: "Delete one rule by id.",
    schema: [
      id: [
        type: :string,
        required: true,
        doc: "Rule id, as the house block's rules line or list_rules gives it."
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "updating the standing rule"
  @impl true
  def run(params, context) do
    case Dobby.Rules.delete(params.id, actor: context[:speaker] || "the household") do
      {:ok, _} -> {:ok, %{deleted: true, id: params.id}}
      error -> error
    end
  end
end
