defmodule Dobby.DeviceAgents.LibraryContractTest do
  @moduledoc """
  The guard that makes a device type and its test one change.

  Adding a type is a checklist, and this file is where the checklist lives.
  It was read off the commits that added types (45a7090, dba14d9, 8bfcd02)
  and the ones that had to finish them, not off `CLAUDE.md`, which names five
  places. The commits touched more: the fifteen appliances reached the board
  two days after the library, because nothing said a type needs a word there
  (5762f6a), and every row fell to the fallback in the meantime. A checklist
  written as prose is the alternative this replaces. It is read at the start
  of a session and summarised away by the end, and a check is read every time.

  So each failure is an instruction naming the file to create or the line to
  edit: the same-named contract test, the agent's and its actions' files, a
  state-sync action of the type's own, one status tool, a tool for every
  write it routes, each tool in `lib/dobby/tools/` under its own name, the
  literal list in `Dobby.DobbyAgent`, the guide's device types, the example
  house, and the board's word. The inverse is here too: a module that
  implements `Dobby.DeviceAgent` and was never registered.

  Some checks read files rather than modules, because the missing piece is a
  file: a tool nobody finds by its name, a guide row, a clause of
  `DobbyWeb.Flap.read/1`. What stays out is what no rule covers. The README,
  the rig roster, and the design notes name some types and not others, on
  purpose.

  The contract macro then supplies the shared assertions; each contract test
  remains the home for the device's own state, capability, refusal, and
  HA-call scenarios.
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

  # The inverse of registration. A type that was written and never listed is
  # invisible: no house can name it, and every check below skips it.
  test "every device agent written under lib/dobby/device_agents is registered" do
    for path <- Path.wildcard("lib/dobby/device_agents/*.ex") do
      name = path |> Path.basename(".ex") |> Macro.camelize()
      module = Module.concat(Dobby.DeviceAgents, name)

      assert Code.ensure_loaded?(module),
             "#{path} must define #{inspect(module)}: a file is named for its module"

      if Dobby.DeviceAgent in behaviours(module) do
        assert module in Types.modules(),
               "#{path} implements Dobby.DeviceAgent but is not registered; " <>
                 "add #{inspect(module)} to @modules in lib/dobby/home_config/types.ex"
      end
    end
  end

  test "a registered type's agent and actions live in the files their modules name" do
    for module <- Types.modules(),
        file_module <- [module | Enum.map(module.signal_routes(), &elem(&1, 1))] do
      path = source_path(file_module)

      assert File.regular?(path),
             "#{module.config_type()} is registered but #{path} does not exist; " <>
               "#{inspect(file_module)} belongs there"
    end
  end

  # Actions may be shared: a purifier and a hood are fans to Home Assistant,
  # and they send the fan's commands. What a type reads is its own.
  test "every registered type hears Home Assistant through a sync action of its own" do
    for module <- Types.modules() do
      type = module.config_type()
      directory = Path.rootname(source_path(module))
      route = List.keyfind(module.signal_routes(), "ha.state_changed", 0)

      assert route,
             "#{type} routes no ha.state_changed signal, so it never hears its entity; " <>
               "route it to #{inspect(module)}.SyncState in #{directory}/sync_state.ex"

      {_signal, action} = route

      assert Path.dirname(source_path(action)) == directory,
             "#{type} syncs through #{inspect(action)}; its own state action belongs " <>
               "in #{directory}/sync_state.ex"
    end
  end

  test "every tool lives in lib/dobby/tools under its own name, and reads as a step" do
    for module <- Types.modules(), tool <- module.tools() do
      type = module.config_type()
      path = Path.join(["lib", "dobby", "tools", "#{tool.name()}.ex"])

      assert source_path(tool) == path,
             "#{type} advertises #{inspect(tool)} as #{tool.name()}; a tool's module, file, " <>
               "and name are one word, so it is Dobby.Tools.#{Macro.camelize(tool.name())} " <>
               "in #{path}"

      assert File.regular?(path), "#{type} advertises #{tool.name()} but #{path} does not exist"

      assert Dobby.Tools in behaviours(tool),
             "#{path} must declare @behaviour Dobby.Tools and write label/1 as a step"
    end
  end

  # The model reads a device only through its status tool, and LibraryTest's
  # library-wide status check finds those tools by this suffix, so a type
  # without one would escape it by omission.
  test "every registered type has exactly one status tool" do
    for module <- Types.modules() do
      type = module.config_type()
      status = Enum.filter(module.tools(), &String.ends_with?(&1.name(), "_get_status"))

      assert match?([_tool], status),
             "#{type} must advertise one *_get_status tool, as " <>
               "lib/dobby/tools/#{type}_get_status.ex; it advertises #{inspect(status)}"
    end
  end

  # "Writable" is the contract's own test: an action that takes a `:ref`. A
  # write no tool sends is a command only a card can give, which is a choice
  # nobody has made for any type yet.
  test "every write a type routes has a tool that sends it" do
    for module <- Types.modules(), {signal, action} <- module.signal_routes(), writes?(action) do
      sources =
        for tool <- module.tools(), {:ok, source} <- [File.read(source_path(tool))], do: source

      assert Enum.any?(sources, &String.contains?(&1, ~s("#{signal}"))),
             "#{module.config_type()} routes #{signal} to #{inspect(action)}, which no tool " <>
               "sends; add a tool under lib/dobby/tools/ that sends it, and list it in " <>
               "#{inspect(module)}.tools/0"
    end
  end

  # The same fact as the closure test above, told tool by tool, because a list
  # diff of eighty modules does not say which line to add.
  test "every tool a type advertises is in the language agent's literal list" do
    agent_tools = Dobby.DobbyAgent.strategy_opts() |> Keyword.fetch!(:tools)

    for module <- Types.modules(), tool <- module.tools() do
      assert tool in agent_tools,
             "#{module.config_type()} advertises #{inspect(tool)}; add it to the tools: " <>
               "list in lib/dobby/agent.ex, which Jido reads at compile time"
    end
  end

  test "the user's guide names every registered type" do
    path = "docs/house.html"
    [_before, types_onward] = path |> File.read!() |> String.split(~s(<h2 id="types">), parts: 2)
    [section | _rest] = String.split(types_onward, "<h2", parts: 2)

    for type <- Types.names() do
      assert String.contains?(section, ["<code>#{type}</code>", ">#{type}</h3>"]),
             "#{type} is registered but the device types section of #{path} does not name " <>
               "it; give it a row there, with its bindings and what Dobby offers"
    end
  end

  test "the example house has one of every registered type" do
    path = "config/homes/example.yaml"
    yaml = File.read!(path)

    for type <- Types.names() do
      assert Regex.match?(~r/^\s+type: #{type}$/m, yaml),
             "#{type} is registered but #{path} has no device of that type; add one " <>
               "with the bindings a household would write"
    end
  end

  # The board's fallback clause says so itself: a registered type reaching it
  # is a bug rather than a default, because it can only say whether the device
  # answers, never whether anybody asked for what it shows.
  test "the board has a word for every registered type" do
    path = "lib/dobby_web/components/flap.ex"
    named = board_types(path)

    for type <- Types.names() do
      assert type in named,
             "#{type} is registered but DobbyWeb.Flap.read/1 has no clause for it, so its " <>
               "row falls to the availability fallback; add one in #{path}"
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

  # Every file under lib/ is named for the one module it defines, which is
  # what lets a search for a module and a listing of a directory agree.
  defp source_path(module), do: Path.join("lib", Macro.underscore(inspect(module)) <> ".ex")

  defp behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  defp writes?(action) do
    Code.ensure_loaded?(action) and function_exported?(action, :schema, 0) and
      Keyword.has_key?(action.schema(), :ref)
  end

  # The type names `DobbyWeb.Flap.read/1` dispatches on, read off its clause
  # heads: the atom a pattern matches, or the list a guard checks it against.
  defp board_types(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    {_ast, heads} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [head | _body]} = node, heads -> {node, [head | heads]}
        node, heads -> {node, heads}
      end)

    for head <- heads, read_head?(head), atom <- literal_atoms(head), do: Atom.to_string(atom)
  end

  defp read_head?({:when, _meta, [head, _guard]}), do: read_head?(head)
  defp read_head?({:read, _meta, [_snapshot]}), do: true
  defp read_head?(_head), do: false

  defp literal_atoms(ast) do
    {_ast, atoms} =
      Macro.prewalk(ast, [], fn
        atom, atoms when is_atom(atom) -> {atom, [atom | atoms]}
        node, atoms -> {node, atoms}
      end)

    atoms
  end
end
