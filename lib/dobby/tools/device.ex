defmodule Dobby.Tools.Device do
  @moduledoc """
  The transport shared by device tools.

  A tool still has its own typed contract and language. This module only keeps
  resolving a roster device, reading agent state, and reporting a command
  outcome identical across the library.
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

  @spec command(String.t(), module(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def command(device_id, module, signal_type, args \\ %{}) do
    with {:ok, _device, pid} <- Dobby.Home.resolve(device_id, module) do
      case Dobby.DeviceAgent.command(pid, signal_type, args) do
        :accepted -> {:ok, %{accepted: true}}
        {:rejected, reason} -> {:ok, %{accepted: false, reason: reason}}
        :unknown -> {:error, "the device did not report whether it accepted the command"}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
