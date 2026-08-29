defmodule Dobby.Directive.HACall do
  @moduledoc """
  A Home Assistant service call, described but not performed (design §7).

  Device agents return this instead of touching the network. The agent stays
  pure and testable; the runtime owns the effect. `Jido.AgentServer` drains
  directives after the command completes, so an `HACall` executes
  *asynchronously* — the tool that triggered it has already returned
  "accepted" by the time HA hears about it.
  """

  @enforce_keys [:domain, :service, :entity_id]
  defstruct [:domain, :service, :entity_id, data: %{}]

  @type t :: %__MODULE__{
          domain: String.t(),
          service: String.t(),
          entity_id: String.t(),
          data: map()
        }
end

defimpl Jido.AgentServer.DirectiveExec, for: Dobby.Directive.HACall do
  @moduledoc """
  Hands an `HACall` to the shared HA client.

  This is the documented extension point for external-effect directives, and
  it is the *only* place in Dobby where a device agent's intent becomes a
  network call. It announces the expectation and any refusal because absence
  of a state change is not an event an agent can learn from. Leaving the error
  only in a log was rejected: the household that asked would never hear it.
  """

  require Logger

  def exec(%Dobby.Directive.HACall{} = call, input_signal, state) do
    expectation = expectation(call, input_signal, state)
    Dobby.CommandEvents.expected(expectation)

    result = Dobby.HomeAssistant.execute(call)

    # Emitted inline, on the same telemetry spine Jido uses for signals, LLM
    # calls, and tool calls. That is what lets the rig assemble one ordered
    # trace across all of them — and later, what feeds the activity log.
    :telemetry.execute([:dobby, :ha, :call], %{system_time: System.system_time(:nanosecond)}, %{
      call: call,
      result: result
    })

    case result do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        # The physical world declining is not an agent crash. The device agent
        # already accepted the semantic command, so the witness records Home
        # Assistant's refusal and tells the household without involving a model.
        Logger.warning("HACall failed: #{inspect(call)} -> #{inspect(reason)}")
        Dobby.CommandEvents.failed(Map.put(expectation, :reason, reason))
        {:ok, state}
    end
  end

  defp expectation(call, input_signal, state) do
    agent_state = state.agent.state
    ref = input_signal.data[:ref]

    %{
      ref: ref,
      device: agent_state.dobby_id,
      name: agent_state.name,
      action: input_signal.type,
      command: command(agent_state.last_command, ref),
      call: Dobby.Activity.jsonable(call),
      asked_at: DateTime.utc_now(),
      timeout_ms: Dobby.DeviceAgent.confirmation_timeout(state.agent_module),
      request_id: request_id(input_signal)
    }
  end

  defp command(%{ref: ref} = command, ref), do: command
  defp command(_other, _ref), do: %{}

  defp request_id(%{extensions: extensions}) when is_map(extensions) do
    extensions[:request_id] || extensions["request_id"]
  end

  defp request_id(_signal), do: nil
end
