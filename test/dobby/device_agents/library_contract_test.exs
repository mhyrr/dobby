defmodule Dobby.DeviceAgents.LibraryContractTest do
  @moduledoc """
  The guard that makes a device type and its test one change.

  Registration without a same-named contract test fails here. The contract
  macro then supplies the shared assertions; each file remains the home for
  the device's own state, capability, refusal, and HA-call scenarios.
  """

  use ExUnit.Case, async: true

  alias Dobby.HomeConfig.Types

  test "every registered type has a same-named contract test" do
    for module <- Types.modules() do
      basename = module |> Module.split() |> List.last() |> Macro.underscore()
      path = Path.join(["test", "dobby", "device_agents", "#{basename}_test.exs"])

      assert File.regular?(path),
             "#{module.config_type()} is registered but #{path} does not exist"

      ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

      assert invokes_contract?(ast, module),
             "#{path} must invoke device_agent_contract #{inspect(module)}"
    end
  end

  test "type names and tool names are unique across the library" do
    modules = Types.modules()
    type_names = Enum.map(modules, & &1.config_type())
    tools = Enum.flat_map(modules, & &1.tools())
    tool_names = Enum.map(tools, & &1.name())

    assert Enum.uniq(type_names) == type_names
    assert Enum.uniq(tool_names) == tool_names
  end

  test "the language agent's compile-time closure matches the registered library" do
    agent_tools = Dobby.DobbyAgent.strategy_opts() |> Keyword.fetch!(:tools)

    assert agent_tools == Dobby.Home.library()
  end

  test "tool and action descriptions are written in the household's words" do
    types = Enum.filter(Types.names(), &String.contains?(&1, "_"))

    tools = Enum.flat_map(Types.modules(), & &1.tools())

    actions =
      Enum.flat_map(Types.modules(), fn module ->
        Enum.map(module.signal_routes(), fn {_signal, action} -> action end)
      end)

    for module <- Enum.uniq(tools ++ actions), description = module.description() do
      # The model reads these sentences, and a config type is our filing word,
      # not a household's: nobody has a wine_cooler in the kitchen.
      for type <- types do
        refute String.contains?(description, type),
               "#{inspect(module)} names a device as #{type}; use the words a person says"
      end

      refute Regex.match?(~r/\ba [aeio]/, description),
             "#{inspect(module)} writes \"a\" before a vowel: #{description}"
    end
  end

  defp invokes_contract?(ast, expected_module) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:device_agent_contract, _meta, [{:__aliases__, _alias_meta, parts} | _rest]} = node,
        found? ->
          {node, found? or Module.concat(parts) == expected_module}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end
