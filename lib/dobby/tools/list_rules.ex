defmodule Dobby.Tools.ListRules do
  @moduledoc """
  Rules and their closed authoring vocabulary are readable without a model.
  Device types own the available facts, just as they own the available actions.

  The household's own agent no longer needs this before a proposal: the house
  block carries the same observables per device and the same rules and
  notices on every turn (TK-054), so the doctrine asks for this call only when
  the block's rules line does not identify a rule. The vocabulary stays here
  whole for the MCP door, whose callers get no house block, and the words are
  the block's words — one vocabulary, whichever way it is read.
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
