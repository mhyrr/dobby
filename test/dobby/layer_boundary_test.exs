defmodule Dobby.LayerBoundaryTest do
  @moduledoc """
  The line the codebase is built around, kept by the suite rather than by a
  sentence (CLAUDE.md; design §6.2, §7).

  The language layer acts only through tools, a tool calls a device agent,
  and the Home Assistant call is a `Dobby.Directive.HACall` the runtime
  performs. So no module in that layer may name `Dobby.HomeAssistant`,
  anything under it, or an HTTP or WebSocket client. The layer is
  `Dobby.Tools` and every tool, `Dobby.DobbyAgent` and its helpers under
  `lib/dobby/agent/`, and the MCP door. The door is in because it only speaks
  through the same tools: `DobbyWeb.MCP.Router` hands someone else's model
  the tool modules and proxies nothing else, and `Dobby.MCP` with its token
  is a digest table that says who is asking. Leaving them out would give a
  model that is not ours the one route to the house that the household's own
  thread does not have.

  The clients are the ones in the dependency tree, `Req`, `Finch`, `Mint`
  (which covers `Mint.WebSocket`) and `WebSockex`, plus `:httpc`, `:gun` and
  `Fresh` for the day one is reached for. `ReqLLM` is not on the list: the
  language layer's one network path is to its own model, which is what it
  is. The rule is about the house.

  One module under `Dobby.HomeAssistant` is allowed by name.
  `Dobby.HomeAssistant.Entity` is a struct and pure functions over it, with
  no process and no socket; discovery answers in it, and a tool that matches
  on one has not reached the house. Nothing in the layer names it today. The
  facade, the client, its connection and the fake are never exceptions,
  because each is where a command goes to be performed.

  The check reads each module's compiled abstract code, the forms `:xref`
  reads, and collects every atom in its function bodies. That is after macro
  expansion, so `alias Dobby.HomeAssistant, as: HA`, an `import`, and a `use`
  that injects a call all arrive as full names. `:xref`'s call graph was the
  first choice and was rejected because it sees calls only, and the client is
  reached as a value as often as by a call: `Dobby.HomeConfig` plugs it in
  as `client: Dobby.HomeAssistant.Client`, and a `GenServer.call` to its
  name is a call to `GenServer`. Walking the source, as `LibraryContractTest` does,
  was rejected too: it sees what was typed rather than what was compiled, has
  to re-implement alias resolution, and cannot see through a `use`.
  Typespecs are not read, because a spec cannot open a socket.

  Only direct references count. Followed far enough, every tool reaches Home
  Assistant; that is the product. What this proves is that the crossing
  happens in the deterministic layer, never in this one.
  """

  use ExUnit.Case, async: true

  @layer [
    "lib/dobby/tools.ex",
    "lib/dobby/tools/**/*.ex",
    "lib/dobby/agent.ex",
    "lib/dobby/agent/**/*.ex",
    "lib/dobby/mcp.ex",
    "lib/dobby/mcp/**/*.ex",
    "lib/dobby_web/mcp/**/*.ex"
  ]

  @forbidden [Dobby.HomeAssistant, Req, Finch, Mint, WebSockex, Fresh, :httpc, :gun]

  @allowed [Dobby.HomeAssistant.Entity]

  @why "a tool calls a device agent, never the house"
  @where "CLAUDE.md, the line the codebase is built around"

  test "no module in the language layer references Home Assistant or an HTTP client" do
    crossings = Enum.flat_map(layer_modules(), &crossings/1)

    assert crossings == [], Enum.join(crossings, "\n")
  end

  test "the language layer is every module its paths compile to" do
    modules = layer_modules()

    assert modules != []
    assert Dobby.Tools.LightTurnOn in modules
    assert Dobby.DobbyAgent in modules
    assert DobbyWeb.MCP.Router in modules

    sources = modules |> Enum.map(&source/1) |> Enum.uniq() |> Enum.sort()
    files = layer_files() |> MapSet.to_list() |> Enum.sort()

    assert sources == files
  end

  defp layer_modules do
    files = layer_files()

    :dobby
    |> Application.spec(:modules)
    |> Enum.filter(&MapSet.member?(files, source(&1)))
    |> Enum.sort()
  end

  defp layer_files do
    @layer |> Enum.flat_map(&Path.wildcard/1) |> MapSet.new()
  end

  defp source(module) do
    compile_info = module.module_info(:compile)

    compile_info
    |> Keyword.get(:source, ~c"")
    |> to_string()
    |> Path.relative_to(File.cwd!())
  end

  defp crossings(module) do
    case functions(module) do
      {:ok, functions} ->
        functions
        |> Enum.flat_map(&references/1)
        |> Enum.filter(fn {target, _how} -> forbidden?(target) end)
        |> Enum.map(fn {_target, how} -> how end)
        |> Enum.uniq()
        |> Enum.map(fn how -> "#{inspect(module)} references #{how}; #{@why} (#{@where})" end)

      :error ->
        ["#{inspect(module)} has no abstract code to read; compile it with debug_info"]
    end
  end

  defp functions(module) do
    with {^module, beam, _path} <- :code.get_object_code(module),
         {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} <-
           :beam_lib.chunks(beam, [:abstract_code]) do
      {:ok, Enum.filter(forms, &match?({:function, _anno, _name, _arity, _clauses}, &1))}
    else
      _unreadable -> :error
    end
  end

  defp references({:call, _anno, {:remote, _, {:atom, _, module}, {:atom, _, name}}, args}) do
    [{module, "#{inspect(module)}.#{name}/#{length(args)}"} | references(args)]
  end

  defp references({:atom, _anno, atom}) when is_atom(atom), do: [{atom, inspect(atom)}]
  defp references(node) when is_tuple(node), do: node |> Tuple.to_list() |> references()
  defp references(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &references/1)
  defp references(_leaf), do: []

  defp forbidden?(atom) do
    atom not in @allowed and Enum.any?(@forbidden, &within?(atom, &1))
  end

  defp within?(atom, root) do
    name = Atom.to_string(atom)
    root_name = Atom.to_string(root)

    name == root_name or String.starts_with?(name, root_name <> ".")
  end
end
