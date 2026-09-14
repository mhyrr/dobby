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

  ## No device type is named here

  The first version of this module was one function that set a thermostat,
  and it was welded to the thermostat five times over: the module it resolved,
  the signal it sent, the argument it posted, the snapshot key the undo read,
  and the degree sign on the undo line. Copying that per type is the central
  `case` over device types the design forbids, spread across five files.

  So a control is what the device's own module says it is
  (`Dobby.DeviceAgent.controls/2`): the type declares the action, the argument
  it takes, the attribute it moves, and the bounds it will accept, and this
  module carries the value to the action the same way a schedule firing does —
  looked up in `scheduled_actions/0`, typed by `Dobby.DeviceAgent.Args`. What
  the type has not offered cannot be posted, and what the device refuses is
  refused in the device's own words.

  ## What a caller gets back

      {:ok, %{name: ..., target_temperature_f: 72.0}}   the device took it
      {:held, reason}                                    the device said no
      {:error, reason}                                   we could not ask

  The map carries the attribute the command moves, as the type names it and
  as the action typed it.

  `:held` is a fact about the device and not a failure. It stays on the card
  with its reason, and it is deliberately *not* written into the thread: the
  thread records interventions, and a refusal changed nothing. The log records
  it either way.
  """

  require Logger

  alias Dobby.Activity
  alias Dobby.DeviceAgent
  alias Dobby.DeviceAgent.Args
  alias Dobby.DeviceAgents.Lock
  alias Dobby.Home
  alias Dobby.Interventions

  @type result :: {:ok, map()} | {:held, String.t()} | {:error, String.t()}

  @doc """
  Fires one of a device's controls from a card somebody touched.

  `action` is the name a schedule row would store; `value` is what the hand
  chose, as the browser sent it — the action's own schema types it. `:via`
  names the path for the thread's system line — "greg, card". Identity
  personalizes and never permits (design §10.4), so a browser that has not
  been named still gets to turn the heat up; the line just says less about
  who.

  The thread line is written in the attribute the command moves, read the
  way the watcher would read its echo: `Interventions.reading/1` over
  `%{field => value}`, so a released fader says `72°` and a chosen mode says
  `Eco`, and an action with no argument at all (a lock's secure) still has a
  word for what it did.
  """
  @spec command(String.t(), String.t() | atom(), term(), keyword()) :: result()
  def command(device_id, action, value, opts \\ []) when is_binary(device_id) do
    via = Keyword.get(opts, :via, "card")
    action = to_string(action)

    with {:ok, device, pid} <- Home.resolve(device_id),
         {:ok, control} <- offered(device, pid, action),
         {:ok, {signal_type, module}} <- lookup(device, action),
         {:ok, args} <- Args.coerce(module, arguments(control, value)) do
      chosen = Map.get(args, control.arg, value)

      pid
      |> DeviceAgent.command(signal_type, args, %{via: :card})
      |> interpret(device, action, args, %{control.field => chosen}, via)
    else
      {:error, reason} -> fail(device_id, action, value, via, reason)
    end
  end

  @doc """
  Secures a lock from the direct control path.

  This is the card-side proof of `hands_only`: the same lock that refuses a
  language caller accepts this caller because a person's hand remains in
  charge. Unlock stays absent from every surface.
  """
  @spec secure_lock(String.t(), keyword()) :: result()
  def secure_lock(device_id, opts \\ []) when is_binary(device_id) do
    via = Keyword.get(opts, :via, "card")

    with {:ok, device, pid} <- Home.resolve(device_id, Lock) do
      pid
      |> DeviceAgent.command("lock.secure", %{}, %{via: :card})
      |> interpret(device, "secure", %{}, %{lock_state: :locked}, via)
    else
      {:error, reason} -> fail(device_id, "secure", nil, via, reason)
    end
  end

  # -- the lookup ------------------------------------------------------------

  # A control the type has not offered for the device as it is now cannot be
  # fired. This is not a second opinion on the value — the device agent has
  # the only opinion on that — it is the same rule the card draws by: a
  # device that has not reported has not said what it will accept.
  defp offered(device, pid, action) do
    with {:ok, server_state} <- Jido.AgentServer.state(pid) do
      snapshot = device.agent_module.snapshot(server_state.agent.state)

      device.agent_module
      |> DeviceAgent.controls(snapshot)
      |> Enum.find(&(Atom.to_string(&1.action) == action))
      |> case do
        nil -> {:error, "#{device.name} offers no control to #{action} right now"}
        control -> {:ok, control}
      end
    end
  end

  defp lookup(device, action) do
    available = device.agent_module.scheduled_actions()

    case Enum.find(available, fn {name, _spec} -> Atom.to_string(name) == action end) do
      {_name, spec} -> {:ok, spec}
      nil -> {:error, "#{device.name} cannot be asked to #{action}"}
    end
  end

  defp arguments(%{arg: nil}, _value), do: %{}
  defp arguments(%{arg: arg}, value), do: %{Atom.to_string(arg) => value}

  # -- the outcome -----------------------------------------------------------

  defp interpret(:accepted, device, action, args, moved, via) do
    record(device.id, action, args, via, %{"state" => "accepted"})

    Interventions.record(%{
      device: device.id,
      name: device.name,
      value: Interventions.reading(moved),
      action: action,
      via: via
    })

    {:ok, Map.merge(%{device: device.id, name: device.name, action: action}, moved)}
  end

  defp interpret({:rejected, reason}, device, action, args, _moved, via) do
    record(device.id, action, args, via, %{"state" => "held", "reason" => reason})
    {:held, reason}
  end

  # The command went out and its outcome could not be confirmed — it may have
  # been superseded by another one. Saying so is the only honest answer; a card
  # that showed SET here would be claiming something nobody checked.
  defp interpret(:unknown, device, action, args, _moved, via) do
    record(device.id, action, args, via, %{"state" => "unknown"})
    {:error, "could not confirm the command to #{device.name}"}
  end

  defp interpret({:error, reason}, device, action, args, _moved, via) do
    fail(device.id, action, args, via, reason)
  end

  defp fail(device_id, action, value, via, reason) do
    record(device_id, action, value, via, %{"state" => "error", "reason" => describe(reason)})
    {:error, describe(reason)}
  end

  # The log records the arguments as they were sent when they were typed, and
  # what the hand posted when they never got that far — the latter is the
  # evidence when a card posts something its type does not take.
  defp record(device_id, action, args, via, result) do
    Activity.record(%{
      kind: "control",
      actor: via,
      device: device_id,
      action: action,
      args: loggable(args),
      result: result
    })
  end

  defp loggable(args) when is_map(args),
    do: Map.new(args, fn {key, value} -> {to_string(key), value} end)

  defp loggable(nil), do: %{}
  defp loggable(value), do: %{"value" => value}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
