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
end
