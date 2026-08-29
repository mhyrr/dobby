defmodule Dobby.Tools.Device do
  @moduledoc """
  The transport shared by device tools.

  A tool still has its own typed contract and language. This module only keeps
  resolving a roster device, reading agent state, and reporting a command
  outcome identical across the library.

  The write result always names the device and repeats what was commanded.
  That shape is not decoration: `Dobby.Conversation.Turn` matches on
  `%{accepted: true, device: _, name: _}` to write the thread's record line,
  and `Dobby.Interventions.reading/1` renders the commanded value on it. A
  result without those keys is a command the thread never mentions.
  """

  @spec status(String.t(), module(), (map() -> map())) ::
          {:ok, map()} | {:error, String.t()}
  def status(device_id, module, render) when is_function(render, 1) do
    with {:ok, _device, pid} <- Dobby.Home.resolve(device_id, module),
         {:ok, server_state} <- Jido.AgentServer.state(pid) do
      {:ok, render.(server_state.agent.state)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Sends a command and reports the outcome in the write protocol's shape.

  `report` is what the accepted result says was commanded, in the keys
  `Dobby.Interventions.reading/1` knows. It defaults to the signal arguments
  because for most tools they are the same fact; a tool whose signal carries
  no value — securing a lock, closing a cover — states the commanded state
  explicitly.
  """
  @spec command(String.t(), module(), String.t(), map(), map(), map() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def command(device_id, module, signal_type, args, context, report \\ nil) do
    with {:ok, device, pid} <- Dobby.Home.resolve(device_id, module) do
      case Dobby.DeviceAgent.command(pid, signal_type, args, caller(context)) do
        :accepted ->
          {:ok,
           Map.merge(report || args, %{device: device.id, name: device.name, accepted: true})}

        {:rejected, reason} ->
          {:ok, %{device: device.id, name: device.name, accepted: false, reason: reason}}

        :unknown ->
          {:error, "could not confirm the command to #{device.name}; it may have been superseded"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc false
  @spec caller(map() | nil) :: Dobby.DeviceAgent.caller()
  def caller(%{via: :mcp}), do: %{via: :mcp}

  def caller(context) do
    case Map.get(context || %{}, :request_id) do
      request_id when is_binary(request_id) -> %{via: :conversation, request_id: request_id}
      _missing -> %{via: :conversation}
    end
  end
end
