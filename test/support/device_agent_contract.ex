defmodule Dobby.DeviceAgentContract do
  @moduledoc """
  The executable extension contract for a device type (TK-014).

  Every module registered in `Dobby.HomeConfig.Types` gets one same-named test
  file and invokes `device_agent_contract/2`. The generated test exercises the
  seams every type must carry before type-specific scenarios begin: manifest
  validation, discovery, initial state, snapshot construction, closed tools,
  and schedulable actions.

  This is deliberately test support, not a production DSL. The production
  extension point remains `Dobby.DeviceAgent`; this module proves an
  implementation honors it.

  ## `arrivals:`

  A writable type must also prove its echo matcher. `command_arrived?/2` is
  what turns an inbound state change into "the command got there", so a wrong
  one is not a cosmetic bug: it produces a NOT KNOWN line for a command that
  arrived, every time, and no other test notices. Each writable type therefore
  supplies at least one `{command, satisfying_snapshot, unsatisfying_snapshot}`
  and the contract asserts both answers — a matcher that says yes to
  everything is as wrong as one that says no to everything.

  "Writable" is not a judgment call: it is a signal route whose action takes a
  `:ref`, which is the write protocol's own marker (`Dobby.DeviceAgent.command/3`).
  """

  import ExUnit.Assertions

  defmacro device_agent_contract(module_ast, opts_ast) do
    module = Macro.expand(module_ast, __CALLER__)
    {opts, _binding} = Code.eval_quoted(opts_ast, [], __CALLER__)
    type = module.config_type()

    quote bind_quoted: [module: module, opts: Macro.escape(opts), type: type] do
      @device_agent_module module
      @device_agent_contract_options opts

      def __device_agent_under_test__, do: @device_agent_module
      def __device_agent_contract__, do: {@device_agent_module, @device_agent_contract_options}

      test "#{type} satisfies the device-agent extension contract" do
        Dobby.DeviceAgentContract.assert_contract(
          @device_agent_module,
          @device_agent_contract_options
        )
      end
    end
  end

  def assert_contract(module, opts) do
    bindings = Keyword.fetch!(opts, :bindings)
    settings = Keyword.get(opts, :settings, %{})

    device = %Dobby.Home.Device{
      id: "#{module.config_type()}:contract",
      name: "contract #{module.config_type()}",
      agent_module: module,
      bindings: bindings,
      settings: settings
    }

    assert module in Dobby.HomeConfig.Types.modules()
    assert is_binary(module.config_type()) and module.config_type() != ""
    assert is_list(module.config_schema())
    assert :ok = module.validate_device(device)

    subscribed = module.subscribed_bindings()
    assert [_binding | _rest] = subscribed
    assert Enum.uniq(subscribed) == subscribed
    assert Enum.all?(Map.keys(bindings), &(&1 in subscribed))

    entity_options = Keyword.fetch!(opts, :entity)
    entity = struct!(Dobby.HomeAssistant.Entity, entity_options)
    related_options = Keyword.get(opts, :related, [entity_options])
    related = Enum.map(related_options, &struct!(Dobby.HomeAssistant.Entity, &1))

    assert module.matches_entity?(entity)

    assert {:ok, ^bindings} =
             Dobby.DeviceAgent.discovery_bindings(module, entity, related)

    state = module.initial_state(device)
    assert state.dobby_id == device.id
    assert state.name == device.name
    assert state.settings == settings

    agent = module.new(id: device.id, state: state)
    device_id = device.id
    device_name = device.name

    assert %{
             id: ^device_id,
             name: ^device_name,
             type: snapshot_type,
             available: nil
           } = module.snapshot(agent.state)

    assert Atom.to_string(snapshot_type) == module.config_type()

    tools = module.tools()
    assert [_tool | _rest] = tools
    assert Enum.uniq(tools) == tools
    assert Enum.all?(tools, &(&1 in Dobby.Home.library()))

    for tool <- tools do
      assert Code.ensure_loaded?(tool)
      assert function_exported?(tool, :name, 0)
      assert function_exported?(tool, :schema, 0)
      assert function_exported?(tool, :label, 1)
      assert function_exported?(tool, :run, 2)
    end

    assert_arrivals(module, Keyword.get(opts, :arrivals, []))

    scheduled_actions = module.scheduled_actions()
    assert is_map(scheduled_actions)

    for {action, {signal_type, action_module}} <- scheduled_actions do
      assert is_atom(action)
      assert is_binary(signal_type) and signal_type != ""
      assert Code.ensure_loaded?(action_module)
      assert function_exported?(action_module, :run, 2)
      assert Keyword.has_key?(action_module.schema(), :ref)
    end

    :ok
  end

  # The type's own vocabulary, in both directions. `command_arrived?/2` is
  # asked through `Dobby.DeviceAgent` rather than directly, because the
  # read-only default lives there and a type that quietly stopped exporting
  # the callback would otherwise look like a type that answers false.
  defp assert_arrivals(module, arrivals) do
    if writable?(module) do
      assert arrivals != [],
             "#{inspect(module)} has a write route and must supply :arrivals — " <>
               "an echo matcher nothing exercises is a permanent false NOT KNOWN"
    end

    for {command, satisfying, unsatisfying} <- arrivals do
      assert Dobby.DeviceAgent.command_arrived?(module, command, satisfying),
             "#{inspect(module)} did not recognize its own echo of #{inspect(command)}"

      refute Dobby.DeviceAgent.command_arrived?(module, command, unsatisfying),
             "#{inspect(module)} read #{inspect(unsatisfying)} as the echo of #{inspect(command)}"
    end

    :ok
  end

  defp writable?(module) do
    Enum.any?(module.signal_routes(), fn {_type, action} ->
      Code.ensure_loaded?(action) and function_exported?(action, :schema, 0) and
        Keyword.has_key?(action.schema(), :ref)
    end)
  end
end
