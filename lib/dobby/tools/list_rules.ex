defmodule Dobby.Tools.ListRules do
  @moduledoc """
  Rules and their closed authoring vocabulary are readable without a model.
  Device types own the available facts, just as they own the available actions.
  """
  use Jido.Action,
    name: "list_rules",
    description:
      "List the standing rules, open proposals, standing notices, and each device's observables with their types.",
    schema: []

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "reading the standing rules"
  @impl true
  def run(_params, _context) do
    vocabulary =
      Enum.map(Dobby.Home.devices(), fn device ->
        observables =
          Map.new(device.agent_module.observables(), fn {name, type} ->
            {name, describe_type(type)}
          end)

        %{device: device.id, name: device.name, observables: observables}
      end)

    {:ok,
     %{
       rules: Dobby.Rules.list(),
       proposals: Dobby.Rules.proposals(),
       notices: Dobby.Rules.notices(),
       vocabulary: vocabulary,
       absence:
         "No recorded change into the condition; a gap in observation restarts the interval."
     }}
  end

  defp describe_type({:enum, values}), do: Enum.map(values, &to_string/1)
  defp describe_type({:reading, _}), do: "number; exact reported unit required"
  defp describe_type(type), do: to_string(type)
end
