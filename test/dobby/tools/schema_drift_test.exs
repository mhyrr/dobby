defmodule Dobby.Tools.SchemaDriftTest do
  @moduledoc """
  A tool and the action it drives declare one parameter twice, and this is
  where the two declarations are read side by side
  (`docs/design/agent-ergonomics.md` §5, §7).

  The tool's schema is what the model reads; the action's sits beside the
  validation that decides. `CLAUDE.md` puts validation in the device agent and
  gives the tool transport and nothing else, so when the two disagree the
  action is right and the model is being told something the house will
  refuse. The brightness tool said 1 to 100, its action said 0 to 100, and the
  action's `authorize/2` refused 0.

  A tool is paired with the action its signal reaches: the signal string in
  the tool's own source, looked up in its type's `signal_routes/0`, which is
  what `Dobby.DeviceAgent.command/4` will actually dispatch. Pairing by
  `name/0` was the rejected alternative. It is right for most tools and wrong
  for the ones that most need checking: the air purifier's and the range
  hood's speed tools drive `Dobby.DeviceAgents.Fan.SetSpeed`, which answers to
  `fan_set_speed`, and no on/off tool shares a name with the `set_power` it
  drives. A tool that names no signal (a status tool, or `LightTurnOn`, which
  goes through `LightTurnOff.set_power/3`) must take nothing but `device`, so
  there is nothing on it to drift. A paired tool offers only keys its action
  takes, and writes in itself any required key it does not offer, as the
  on/off tools write `power: :on`.

  Agreeing means: a key both declare is required alike, the tool's type is one
  the action admits, and the two docs state the same whole numbers. Identical
  entries were the rejected alternative, because both differences are on
  purpose. `jido_action` renders `{:or, [:integer, :float]}` to the model as
  `"string"`, so the thermostat tool says `:float` and coerces, and its action
  takes either. And the docs have different readers: the tool's is the
  model's, the action's is the label on the admin's schedule form
  (`Dobby.Schedules.action_arguments/2`). The numbers are the part of a doc
  that has to be true for every reader, and comparing them catches "0 to 100"
  against "1-100" without parsing prose. An action with no doc states no
  numbers, so a bound the model is told is written down beside the code that
  enforces it, or this fails. The tool's description is held to the same
  numbers, because it is the sentence the model reads first.
  """

  use ExUnit.Case, async: true

  alias Dobby.DeviceAgent.Args
  alias Dobby.HomeConfig.Types

  test "a tool that reaches no action takes nothing but a device" do
    for {tool, []} <- pairs() do
      assert parameters(tool) == [],
             "#{inspect(tool)} takes #{inspect(Keyword.keys(parameters(tool)))} but names " <>
               "no signal of its type, so no action says what those may be. Open " <>
               "#{source(tool)} and dispatch with the signal as a literal string, as " <>
               "lib/dobby/tools/light_set_brightness.ex does with \"light.set_brightness\""
    end
  end

  test "a tool offers only what its action takes, and fills in whatever else it requires" do
    for {tool, actions} <- pairs(), action <- actions do
      declared = Args.arguments(action)
      offered = parameters(tool)

      for {key, _spec} <- offered do
        assert Keyword.has_key?(declared, key),
               "#{inspect(tool)} offers the model #{key}, which #{inspect(action)} does not " <>
                 "take. Open #{source(action)} for what it takes, then rename or drop " <>
                 "#{key} in #{source(tool)}"
      end

      filled = map_keys(tool)

      for {key, spec} <- declared, spec[:required], not Keyword.has_key?(offered, key) do
        assert key in filled,
               "#{inspect(action)} requires #{key}, and #{inspect(tool)} neither offers it " <>
                 "to the model nor fills it in. Open #{source(tool)} and do one or the " <>
                 "other; #{source(action)} says what #{key} means"
      end
    end
  end

  test "a shared key is required alike, typed compatibly, and bounded by the same numbers" do
    for {tool, actions} <- pairs(),
        action <- actions,
        {key, tool_spec} <- parameters(tool),
        action_spec = Args.arguments(action)[key] do
      disagree = "#{inspect(tool)} and #{inspect(action)} disagree on #{key}"

      fix =
        "The action's validation is the truth: read it in #{source(action)}, then fix " <>
          "#{source(tool)} or the action's own schema to match"

      assert required?(tool_spec) == required?(action_spec),
             "#{disagree}: the tool says required: #{required?(tool_spec)}, the action " <>
               "says required: #{required?(action_spec)}. #{fix}"

      assert admits?(action_spec[:type], tool_spec[:type]),
             "#{disagree}: the tool validates #{inspect(tool_spec[:type])}, which the " <>
               "action's #{inspect(action_spec[:type])} does not admit. #{fix}"

      assert numbers(tool_spec[:doc]) == numbers(action_spec[:doc]),
             "#{disagree}: the tool's doc states #{inspect(numbers(tool_spec[:doc]))}, " <>
               "the action's states #{inspect(numbers(action_spec[:doc]))}. #{fix}"
    end
  end

  test "a number a tool's description gives the model is one its action declares" do
    for {tool, actions} <- pairs(), actions != [] do
      declared =
        actions
        |> Enum.flat_map(&Args.arguments/1)
        |> Enum.flat_map(fn {_key, spec} -> numbers(spec[:doc]) end)

      assert numbers(tool.description()) -- declared == [],
             "#{inspect(tool)}'s description states " <>
               "#{inspect(numbers(tool.description()) -- declared)}, which no argument of " <>
               "#{Enum.map_join(actions, " or ", &inspect/1)} declares. Read the " <>
               "validation in #{Enum.map_join(actions, " and ", &source/1)}, then fix " <>
               "the description in #{source(tool)} or put the bound in the action's doc"
    end
  end

  # Every device tool in the library, with the actions its signal strings
  # reach. Read from the tool's source rather than by running it, because
  # running a command tool needs a house.
  defp pairs do
    for type <- Types.modules(), tool <- type.tools() do
      strings = strings(tool)
      actions = for {signal, action} <- type.signal_routes(), signal in strings, do: action

      {tool, Enum.uniq(actions)}
    end
  end

  defp parameters(tool), do: Keyword.delete(tool.schema(), :device)

  defp required?(spec), do: Keyword.get(spec, :required, false)

  # The tool's type is validated first and the value handed on unchanged, so
  # the action has to take everything the tool lets through.
  defp admits?(type, type), do: true
  defp admits?({:or, types}, type), do: type in types
  defp admits?(_action_type, _tool_type), do: false

  # Whole numbers only, unsigned: "1-100" is one and a hundred, not a
  # negative hundred.
  defp numbers(nil), do: []

  defp numbers(text) do
    ~r/\d+/
    |> Regex.scan(text)
    |> Enum.map(fn [digits] -> String.to_integer(digits) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp strings(module) do
    {_ast, strings} =
      Macro.prewalk(quoted(module), [], fn
        string, acc when is_binary(string) -> {string, [string | acc]}
        node, acc -> {node, acc}
      end)

    strings
  end

  # The keys a tool writes into a map literal: where an on/off tool fills in
  # the `power: :on` its action requires and the model never sees.
  defp map_keys(module) do
    {_ast, keys} =
      Macro.prewalk(quoted(module), [], fn
        {:%{}, _meta, entries} = node, acc when is_list(entries) ->
          {node, Enum.flat_map(entries, &literal_key/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp literal_key({key, _value}) when is_atom(key), do: [key]
  defp literal_key(_other), do: []

  defp quoted(module) do
    path = source(module)
    path |> File.read!() |> Code.string_to_quoted!(file: path)
  end

  defp source(module) do
    module.module_info(:compile)
    |> Keyword.fetch!(:source)
    |> List.to_string()
    |> Path.relative_to_cwd()
  end
end
