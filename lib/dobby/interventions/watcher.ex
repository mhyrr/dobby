defmodule Dobby.Interventions.Watcher do
  @moduledoc """
  The house's witness (design §10.3).

  Two things happen in this house with nobody standing in front of them: a
  schedule going off at eight o'clock, and somebody turning the dial in the
  hallway. Both are interventions and both belong in the thread, and neither
  has a surface to write from — so one process subscribes and writes them down.

  ## Why a process and not a LiveView

  Because there are three browsers. A LiveView that wrote the line would write
  three of them, and the fourth phone that connects a minute later would show
  a thread that never happened. The thread has exactly one writer per event,
  which is the same rule `Dobby.Conversation.Turn` follows.

  ## The two destinations

  **The log takes everything.** Every device state change is recorded, including
  an endpoint flapping at 3am — that is the row `TK-004` reads by, and the
  question it answers ("is this the third time this week") is a question about
  the boring ones.

  **The thread takes the subset a person should read.** Which changes those are
  is `Dobby.DeviceAgent.intervention?/1` — a setpoint is commanded, connectivity
  is observed — and whether *this house* commanded it is the device agent's own
  answer, because every path that moves a setpoint already announced itself at
  the moment it acted. Saying it a second time when Home Assistant echoes it
  back would read as though somebody had gone and turned the dial.

  ## What is deliberately not said

  A schedule that could not be dispatched at all — a device that left the
  manifest, arguments that no longer type — is a configuration problem and not
  a household event. It goes to the log, and the admin's health page is where
  it surfaces. A schedule the *device* refused is different: the thermostat made
  a decision, the heat did not come on, and a household that finds that out at
  bedtime is worse served by silence.
  """

  use GenServer

  require Logger

  alias Dobby.Activity
  alias Dobby.DeviceEvents
  alias Dobby.Home
  alias Dobby.Interventions
  alias Dobby.ScheduleEvents

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    DeviceEvents.subscribe()
    ScheduleEvents.subscribe()
    {:ok, %{}}
  end

  # Nothing moved, so nothing happened: this is a device reporting for the
  # first time and the house learning what it has. Writing it down would mean
  # every restart announced the boot sequence to the kitchen and filled the log
  # with rows saying the thermostat exists.
  @impl GenServer
  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: %{moved: []}}, state) do
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: data}, state) do
    guard(fn ->
      record_change(data)
      maybe_intervention(data)
    end)

    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "dobby.schedule.fired", data: data}, state) do
    guard(fn ->
      record_firing(data)
      announce_firing(data)
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A barrier for tests, and the only reason this GenServer answers a call at
  # all: a synchronous call queues behind everything already in the mailbox, so
  # a caller that gets a reply knows the watcher is done writing. See
  # `Dobby.RigCase.settle_watcher!/0` for what that prevents.
  @impl GenServer
  def handle_call(:settle, _from, state), do: {:reply, :ok, state}

  # This process describes things that have already happened. A write that
  # fails must never take down the witness, because the next thing it would
  # miss is the one somebody asks about.
  defp guard(fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "the watcher could not record: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      :ok
  end

  # -- devices ---------------------------------------------------------------

  defp record_change(%{device: device, snapshot: snapshot} = data) do
    Activity.record(%{
      kind: "device_changed",
      device: device,
      action: "state_changed",
      args: %{"changed" => Enum.map(data[:changed] || [], &to_string/1)},
      result: jsonable(snapshot)
    })
  end

  defp maybe_intervention(%{commanded?: true}), do: :ok

  defp maybe_intervention(%{device: device, snapshot: snapshot} = data) do
    with {:ok, agent_module} <- agent_module(device),
         attribute when not is_nil(attribute) <-
           Enum.find(data[:moved] || [], &agent_module.intervention?/1) do
      Interventions.record(%{
        device: device,
        name: snapshot[:name] || device,
        value: Interventions.reading(snapshot),
        action: to_string(attribute),
        # Nobody asked Dobby for this and no surface of ours did it. Somebody
        # walked up to the device, which is the case §10.3 calls the
        # interesting one.
        via: "changed at the #{snapshot[:name] || "device"}"
      })
    else
      _not_an_intervention -> :ok
    end
  end

  defp maybe_intervention(_data), do: :ok

  # A device can leave the manifest while its agent is still emitting, and the
  # house can be restarting with no manifest at all. Both read as "nothing to
  # say about this", which is better than a crash in the one process that is
  # supposed to be watching.
  defp agent_module(device) do
    case Home.fetch_device(device) do
      {:ok, %{agent_module: module}} -> {:ok, module}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # -- schedules -------------------------------------------------------------

  defp record_firing(data) do
    Activity.record(%{
      kind: "schedule_fired",
      actor: schedule_via(data),
      device: data[:device],
      action: data[:action],
      args: jsonable(data[:args] || %{}),
      result: %{"outcome" => inspect(data[:outcome])}
    })
  end

  defp announce_firing(%{outcome: :accepted} = data) do
    Interventions.record(%{
      device: data[:device],
      name: device_name(data[:device]),
      value: Interventions.reading(data[:args] || %{}),
      action: data[:action],
      via: schedule_via(data)
    })
  end

  defp announce_firing(%{outcome: {:rejected, reason}} = data) do
    Interventions.held(%{
      device: data[:device],
      name: device_name(data[:device]),
      action: data[:action],
      reason: reason,
      via: schedule_via(data)
    })
  end

  defp announce_firing(_data), do: :ok

  defp schedule_via(data), do: ~s(schedule "#{data[:label]}")

  defp device_name(device) do
    case Home.fetch_device(device) do
      {:ok, %{name: name}} -> name
      :error -> device
    end
  rescue
    ArgumentError -> device
  end

  defp jsonable(value), do: Activity.jsonable(value)
end
