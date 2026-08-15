defmodule Dobby.Controls do
  @moduledoc """
  A person turning a control, with no model anywhere in the path (TK-001).

  This is the deterministic surface, and it is first-class rather than a
  fallback: it is what the house does when the model is down, what a test can
  assert against without a language model in the room, and what somebody
  reaches for when saying a sentence is more work than moving a dial.

  It reaches a device by exactly the path the model's tool does — the same
  signal, the same `ref`, the same `Dobby.DeviceAgent.command_outcome/2` read —
  so household policy applies identically. A card cannot set a temperature a
  sentence could not, and the thermostat's refusal reads the same either way.

  ## What a caller gets back

      {:ok, %{name: ..., temperature_f: ...}}   the device took it
      {:held, reason}                            the device said no
      {:error, reason}                           we could not ask

  `:held` is a fact about the device and not a failure. It stays on the card
  with its reason, and it is deliberately *not* written into the thread: the
  thread records interventions, and a refusal changed nothing. The log records
  it either way.
  """

  require Logger

  alias Dobby.Activity
  alias Dobby.DeviceAgent
  alias Dobby.DeviceAgents.Thermostat
  alias Dobby.Home
  alias Dobby.Interventions

  @type result :: {:ok, map()} | {:held, String.t()} | {:error, String.t()}

  @doc """
  Sets a thermostat's setpoint from a control somebody touched.

  `:via` names the path for the thread's system line — "greg, card". Identity
  personalizes and never permits (design §10.2), so a browser that has not been
  named still gets to turn the heat up; the line just says less about who.
  """
  @spec set_temperature(String.t(), number(), keyword()) :: result()
  def set_temperature(device_id, temperature_f, opts \\ [])
      when is_binary(device_id) and is_number(temperature_f) do
    via = Keyword.get(opts, :via, "card")

    with {:ok, device, pid} <- Home.resolve(device_id, Thermostat) do
      pid
      |> DeviceAgent.command("thermostat.set_temperature", %{temperature_f: temperature_f / 1})
      |> interpret(device, temperature_f, via)
    else
      {:error, reason} -> fail(device_id, temperature_f, via, reason)
    end
  end

  defp interpret(:accepted, device, temperature_f, via) do
    record(device.id, temperature_f, via, %{"state" => "accepted"})

    Interventions.record(%{
      device: device.id,
      name: device.name,
      value: Interventions.reading(%{temperature_f: temperature_f}),
      action: "set_temperature",
      via: via
    })

    {:ok, %{device: device.id, name: device.name, temperature_f: temperature_f}}
  end

  defp interpret({:rejected, reason}, device, temperature_f, via) do
    record(device.id, temperature_f, via, %{"state" => "held", "reason" => reason})
    {:held, reason}
  end

  # The command went out and its outcome could not be confirmed — it may have
  # been superseded by another one. Saying so is the only honest answer; a card
  # that showed SET here would be claiming something nobody checked.
  defp interpret(:unknown, device, temperature_f, via) do
    record(device.id, temperature_f, via, %{"state" => "unknown"})
    {:error, "could not confirm the command to #{device.name}"}
  end

  defp interpret({:error, reason}, device, temperature_f, via) do
    fail(device.id, temperature_f, via, reason)
  end

  defp fail(device_id, temperature_f, via, reason) do
    record(device_id, temperature_f, via, %{"state" => "error", "reason" => describe(reason)})
    {:error, describe(reason)}
  end

  defp record(device_id, temperature_f, via, result) do
    Activity.record(%{
      kind: "control",
      actor: via,
      device: device_id,
      action: "set_temperature",
      args: %{"temperature_f" => temperature_f},
      result: result
    })
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
