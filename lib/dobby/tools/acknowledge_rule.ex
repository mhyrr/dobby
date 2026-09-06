defmodule Dobby.Tools.AcknowledgeRule do
  @moduledoc """
  The tool carries intent and attribution. The rules context owns the change.

  A notice is listed with its own id beside its rule's, and a model has
  handed over either. Both name the same standing notice, so both are taken.
  """
  use Jido.Action,
    name: "acknowledge_rule",
    description:
      "Silence one rule's standing notice. The rule keeps watching and reports the next occurrence.",
    schema: [
      id: [type: :string, required: true, doc: "Rule id, as listed by list_rules."]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "updating the standing rule"
  @impl true
  def run(params, context) do
    actor = context[:speaker] || "the household"

    case Dobby.Rules.acknowledge(params.id, actor) do
      {:ok, _} ->
        {:ok, %{acknowledged: true, id: params.id}}

      {:error, _} = error ->
        case Enum.find(Dobby.Rules.notices(), &(&1.id == params.id)) do
          %{rule_id: rule_id} ->
            case Dobby.Rules.acknowledge(rule_id, actor) do
              {:ok, _} -> {:ok, %{acknowledged: true, id: rule_id}}
              error -> error
            end

          nil ->
            error
        end
    end
  end
end
