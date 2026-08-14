defmodule Dobby.Tools.ThermostatSetTemperature do
  @moduledoc """
  Tool: change a thermostat's setpoint.

  Transport only (design §6.2). The decision about whether 82° is allowed
  belongs to the thermostat agent, and this module's job is to carry the
  request there and carry the answer back.

  What comes back is *acceptance*, not observation. `Jido.AgentServer` drains
  the resulting `HACall` after the command returns, so by construction this
  tool cannot know whether the house got warmer — only that the thermostat
  agent agreed to ask. The system prompt is what keeps the model honest about
  the difference.
  """

  use Jido.Action,
    name: "thermostat_set_temperature",
    description: """
    Set a thermostat's target temperature in Fahrenheit. Returns whether the \
    command was accepted, not whether the room has reached that temperature.
    """,
    schema: [
      device: [
        type: :string,
        required: true,
        doc: "Device id from the roster, e.g. thermostat:main"
      ],
      temperature_f: [
        # `:float` and not `{:or, [:integer, :float]}`, which is what this was.
        # jido_action renders a NimbleOptions union as `"type": "string"` in
        # the JSON schema the model is shown — so the model was being told to
        # send "70", dutifully sending "70", and then being rejected by our
        # own validation. `:float` renders as `"number"`, which is the truth.
        type: :float,
        required: true,
        doc: "Target temperature in Fahrenheit"
      ]
    ]

  alias Dobby.DeviceAgents.Thermostat

  # JSON has one number type and Elixir has two: a model that correctly sends
  # `70` against a `"number"` schema arrives here as an integer, which `:float`
  # would reject. Strings are coerced as well — not on principle, but because
  # we watched a real model send one and it costs two lines to survive it.
  @impl true
  def on_before_validate_params(params) do
    {:ok, Map.update(params, :temperature_f, nil, &to_temperature/1)}
  end

  defp to_temperature(value) when is_integer(value), do: value * 1.0
  defp to_temperature(value) when is_float(value), do: value

  defp to_temperature(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> value
    end
  end

  defp to_temperature(value), do: value

  @impl true
  def run(%{device: device_id, temperature_f: temperature}, _context) do
    with {:ok, device, pid} <- Dobby.Home.resolve(device_id, Thermostat),
         ref = Jido.Util.generate_id(),
         signal =
           Jido.Signal.new!("thermostat.set_temperature", %{temperature_f: temperature, ref: ref}),
         {:ok, agent} <- Jido.AgentServer.call(pid, signal) do
      interpret(agent.state.last_command, ref, device, temperature)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # The ref guards against reading someone else's outcome. Turns are
  # serialized today, so a mismatch means an assumption broke rather than a
  # race we tolerate — say so instead of reporting a result that isn't ours.
  defp interpret(%{ref: ref, result: :accepted}, ref, device, temperature) do
    {:ok,
     %{device: device.id, name: device.name, accepted: true, target_temperature_f: temperature}}
  end

  defp interpret(%{ref: ref, result: {:rejected, reason}}, ref, device, _temperature) do
    {:ok, %{device: device.id, name: device.name, accepted: false, reason: reason}}
  end

  defp interpret(_other, _ref, device, _temperature) do
    {:error, "could not confirm the command to #{device.name}; it may have been superseded"}
  end
end
