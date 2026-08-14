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
  network call.
  """

  require Logger

  def exec(%Dobby.Directive.HACall{} = call, _input_signal, state) do
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
        # learns about it the same way it learns about everything else: an
        # inbound state change, or the absence of one.
        Logger.warning("HACall failed: #{inspect(call)} -> #{inspect(reason)}")
        {:ok, state}
    end
  end
end
