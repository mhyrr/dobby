defmodule Dobby.Tools.VacuumStart do
  @moduledoc """
  Tool: start a vacuum cleaning.

  Transport only, and also home of the shared `command/3` carrier both
  vacuum command tools ride: start and dock are one decision shape in the
  agent, so they are one code path here.
  """

  use Jido.Action,
    name: "vacuum_start",
    description: """
    Start a vacuum cleaning. Returns whether the command was accepted, not \
    whether the robot has left its dock.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. vacuum:roomba"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Vacuum

  @impl Dobby.Tools
  def label(arguments), do: "starting the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context),
    do: command(device_id, "vacuum.start_cleaning", :start_cleaning)

  @doc false
  def command(device_id, signal_type, action) do
    with {:ok, device, pid} <- Dobby.Home.resolve(device_id, Vacuum),
         ref = Jido.Util.generate_id(),
         signal = Jido.Signal.new!(signal_type, %{ref: ref}),
         {:ok, agent} <- Jido.AgentServer.call(pid, signal) do
      agent.state
      |> Dobby.DeviceAgent.command_outcome(ref)
      |> interpret(device, action)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp interpret(outcome, device, action) do
    case outcome do
      :accepted ->
        {:ok, %{device: device.id, name: device.name, accepted: true, action: action}}

      {:rejected, reason} ->
        {:ok, %{device: device.id, name: device.name, accepted: false, reason: reason}}

      :unknown ->
        {:error, "could not confirm the command to #{device.name}; it may have been superseded"}
    end
  end
end
