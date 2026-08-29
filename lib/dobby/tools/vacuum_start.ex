defmodule Dobby.Tools.VacuumStart do
  @moduledoc """
  Tool: start a vacuum cleaning.

  Transport only, and also home of the shared `command/4` carrier both
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
  def run(%{device: device_id}, context),
    do: command(device_id, "vacuum.start_cleaning", :start_cleaning, context)

  @doc false
  def command(device_id, signal_type, action, context) do
    case Dobby.Tools.Device.command(device_id, Vacuum, signal_type, %{}, context, %{
           action: action
         }) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end
end
