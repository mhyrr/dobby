defmodule Dobby.Tools.SetRuleEnabled do
  @moduledoc """
  The tool carries intent and attribution. The rules context owns the change.
  """
  use Jido.Action,
    name: "set_rule_enabled",
    description:
      "Pause or resume an existing rule by exact id. Pause stops watching; resume begins a new observation interval.",
    schema: [id: [type: :string, required: true], enabled: [type: :boolean, required: true]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "updating the standing rule"
  @impl true
  def run(params, context) do
    case Dobby.Rules.set_enabled(params.id, params.enabled,
           actor: context[:speaker] || "the household"
         ) do
      {:ok, _} -> {:ok, %{applied: true, id: params.id, enabled: params.enabled}}
      error -> error
    end
  end
end
