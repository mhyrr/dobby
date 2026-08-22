defmodule Dobby.Topology do
  @moduledoc """
  The command hierarchy of the house, as nodes and edges (TK-016).

  Deliberately **not** the OTP tree. Supervision here is a flat fan under
  `Dobby.Jido.AgentSupervisor`, and that flatness is a decision: it encodes
  failure domains, so the deterministic layer does not restart when the
  probabilistic one dies. A drawing of it would say nothing about what commands
  what.

  What commands what lives in signal routing and in per-request tool sets, and
  it has two directors — `Dobby.DobbyAgent`, the only probabilistic thing in
  the house, and `Dobby.SchedulerAgent`, which is a clock. Everything under
  them is deterministic, which is the one fact this drawing exists to teach.

  ## Every edge is configuration

  Never process introspection. Dobby reaches a device because the device's
  agent module advertises tools; the scheduler reaches one because an enabled
  row in the schedules table names it; a device reaches Home Assistant because
  the manifest bound it to an entity. All three answer the same whether or not
  anything is running, which is what lets the drawing stay a drawing while half
  the house is down.

  ## Liveness and state are somebody else's

  There is nothing here that asks an agent how it is. A surface reads state
  once at mount (`Dobby.Home.snapshots/0`), watches liveness with monitors, and
  takes everything after that from `dobby:devices` — see `DobbyWeb.AdminLive`.
  Asking a running agent on a timer would queue the question in its mailbox
  behind whatever it is doing, and for `DobbyAgent` that is a model call.
  """

  alias Dobby.DobbyAgent
  alias Dobby.Home
  alias Dobby.HomeAssistant
  alias Dobby.SchedulerAgent
  alias Dobby.Schedules

  @house "home_assistant"

  @typedoc """
  One box in the drawing.

  `agent_id` is the registry ID whose liveness the box reports, or `nil` for
  the house, which is a named process rather than an agent.
  """
  @type node_t :: %{
          id: String.t(),
          agent_id: String.t() | nil,
          name: String.t(),
          kind: :dobby | :scheduler | :device | :house,
          detail: String.t() | nil
        }

  @typedoc "One line, from the thing that commands to the thing commanded."
  @type edge :: %{from: String.t(), to: String.t(), band: :command | :house}

  @doc """
  The whole drawing: two directors, the device roster, the house, and the wires.
  """
  @spec read() :: %{directors: [node_t()], devices: [node_t()], house: node_t(), edges: [edge()]}
  def read do
    devices = device_nodes()

    %{
      directors: [dobby_node(), scheduler_node()],
      devices: devices,
      house: house_node(),
      edges: command_edges(devices) ++ house_edges(devices)
    }
  end

  @doc """
  The registry IDs a surface should watch to know what is running.
  """
  @spec agent_ids() :: [String.t()]
  def agent_ids do
    [DobbyAgent.id(), SchedulerAgent.id()] ++ Enum.map(devices(), & &1.id)
  end

  @doc """
  The node ID the house is drawn under.
  """
  @spec house_id() :: String.t()
  def house_id, do: @house

  # -- the nodes -------------------------------------------------------------

  # Which model, and not which alias. The house names the alias everywhere
  # else (§2.1) precisely so the model can be swapped without a rewrite — but
  # this is the page somebody opens to find out what the box is actually doing,
  # and "capable" is the one answer that cannot help them. Same argument as the
  # health row printing `Fake` or `Client`.
  defp dobby_node do
    %{
      id: DobbyAgent.id(),
      agent_id: DobbyAgent.id(),
      name: "Dobby",
      kind: :dobby,
      detail: model()
    }
  end

  defp scheduler_node do
    %{
      id: SchedulerAgent.id(),
      agent_id: SchedulerAgent.id(),
      name: "Scheduler",
      kind: :scheduler,
      detail: nil
    }
  end

  defp device_nodes do
    Enum.map(devices(), fn device ->
      %{
        id: device.id,
        agent_id: device.id,
        name: device.name,
        kind: :device,
        detail: device.id
      }
    end)
  end

  # The client is not an agent and has no registry ID: it is a named process,
  # and whether it is *connected* is a different fact from whether it is there.
  # `Dobby.HomeAssistant.Connection` carries both.
  defp house_node do
    module = HomeAssistant.impl()

    %{
      id: @house,
      agent_id: nil,
      name: "Home Assistant",
      kind: :house,
      detail: module |> Module.split() |> List.last() |> String.downcase()
    }
  end

  # -- the wires -------------------------------------------------------------

  # Dobby reaches a device when the device's agent module advertises a tool —
  # which is the same list `Dobby.Home.tools/0` hands the model each turn, so a
  # read-only endpoint still gets a wire and the drawing does not have to be
  # told about a new device type.
  defp command_edges(devices) do
    scheduled = scheduled_targets()

    Enum.flat_map(devices, fn node ->
      tools = if commandable?(node.id), do: [edge(DobbyAgent.id(), node.id, :command)], else: []

      timer =
        if node.id in scheduled, do: [edge(SchedulerAgent.id(), node.id, :command)], else: []

      tools ++ timer
    end)
  end

  # Every managed device is bound to at least one entity — the manifest refuses
  # one that is not — so this is a wire per device, and it is the line every
  # HACall and every inbound state change travels.
  defp house_edges(devices), do: Enum.map(devices, &edge(&1.id, @house, :house))

  defp edge(from, to, band), do: %{from: from, to: to, band: band}

  defp commandable?(id) do
    case Home.fetch_device(id) do
      {:ok, device} -> device.agent_module.tools() != []
      :error -> false
    end
  rescue
    ArgumentError -> false
  end

  # Enabled rows only. A paused schedule is a row the scheduler has deliberately
  # no timer for, and drawing its wire would claim a command path that cannot
  # fire — the same reason a paused schedule gets no state word.
  defp scheduled_targets do
    Schedules.enabled() |> Enum.map(& &1.target) |> MapSet.new()
  end

  defp devices do
    Home.devices()
  rescue
    # No manifest means no house. The directors and the client are still true.
    ArgumentError -> []
  end

  defp model do
    :jido_ai
    |> Application.get_env(:model_aliases, %{})
    |> Map.get(:capable)
    |> case do
      model when is_binary(model) -> model
      # Nothing configured resolves the alias, which is worth saying as the
      # alias rather than as a blank.
      _unresolved -> "capable"
    end
  end
end
