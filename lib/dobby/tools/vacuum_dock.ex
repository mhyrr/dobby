defmodule Dobby.Tools.VacuumDock do
  @moduledoc """
  Tool: send a vacuum home to its dock.

  Transport only; the carrier lives in `Dobby.Tools.VacuumStart.command/4`.
  """

  use Jido.Action,
    name: "vacuum_dock",
    description: """
    Send a vacuum back to its dock. Returns whether the command was \
    accepted, not whether the robot has reached home.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. vacuum:roomba"
      ]
    ]

  @behaviour Dobby.Tools

  @impl Dobby.Tools
  def label(arguments), do: "sending the #{Dobby.Tools.device_name(arguments)} home"

  @impl true
  def run(%{device: device_id}, context),
    do: Dobby.Tools.VacuumStart.command(device_id, "vacuum.dock", :dock, context)
end
