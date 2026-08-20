defmodule Dobby.Tools.LightTurnOff do
  @moduledoc """
  Tool: turn a light off.

  Transport only, and also home of the shared `set_power/2` carrier both
  switch tools ride: on and off are one decision in the agent
  (`Light.SetPower`), so they are one code path here — split into two tools
  only because two names leave the model nothing to encode in arguments.
  """

  use Jido.Action,
    name: "light_turn_off",
    description: """
    Turn a light off. Returns whether the command was accepted.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. light:living_room"
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.DeviceAgents.Light

  @impl Dobby.Tools
  def label(arguments), do: "turning off the #{Dobby.Tools.device_name(arguments)}"

  @impl true
  def run(%{device: device_id}, _context), do: set_power(device_id, false)

  @doc false
  def set_power(device_id, on) do
    with {:ok, device, pid} <- Dobby.Home.resolve(device_id, Light),
         ref = Jido.Util.generate_id(),
         signal = Jido.Signal.new!("light.set_power", %{on: on, ref: ref}),
         {:ok, agent} <- Jido.AgentServer.call(pid, signal) do
      agent.state
      |> Dobby.DeviceAgent.command_outcome(ref)
      |> interpret(device, on)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp interpret(outcome, device, on) do
    case outcome do
      :accepted ->
        {:ok, %{device: device.id, name: device.name, accepted: true, on: on}}

      {:rejected, reason} ->
        {:ok, %{device: device.id, name: device.name, accepted: false, reason: reason}}

      :unknown ->
        {:error, "could not confirm the command to #{device.name}; it may have been superseded"}
    end
  end
end
