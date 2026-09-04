defmodule Dobby.Interventions.Watcher do
  @moduledoc """
  The house's witness (design §10.3).

  Three things happen in this house with nobody standing in front of them: a
  schedule goes off, somebody turns a dial, or Home Assistant declines or
  never echoes an accepted command. All three need one writer outside any
  browser, so this process subscribes and writes them down.

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

  A command outcome is different from a state report. A refusal becomes
  `HELD`, while a missing echo becomes `NOT KNOWN`. A late matching echo clears
  `NOT KNOWN` on the board without adding another line. The language model is
  deliberately absent from this loop: it declared the intent already, and the
  deterministic layer owns what Home Assistant said next.

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
  alias Dobby.CommandEvents
  alias Dobby.DeviceAgent
  alias Dobby.DeviceEvents
  alias Dobby.Home
  alias Dobby.Interventions
  alias Dobby.ScheduleEvents
  alias Dobby.ThreadEvents

  @finished_ttl 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds any standing command uncertainty to a public device snapshot.

  The observed values remain the device agent's. This adds only the fact that
  an accepted command has not echoed, which is why a late matching state change
  can clear the word without rewriting what Home Assistant reported.
  """
  @spec decorate(map()) :: map()
  def decorate(%{id: device} = snapshot) do
    GenServer.call(__MODULE__, {:decorate, device, snapshot})
  catch
    :exit, _watcher_not_running -> snapshot
  end

  @doc """
  Drops every expectation and every standing NOT KNOWN.

  Called by `Dobby.Home.stop/0`, which is the one moment the question these
  answer stops having a subject: the device agents that accepted the commands
  are gone. Silent by design — a house that is being rebuilt has nothing to
  tell the thread about what the old one was still waiting for.
  """
  @spec forget_commands() :: :ok
  def forget_commands do
    GenServer.call(__MODULE__, :forget_commands)
  catch
    :exit, _watcher_not_running -> :ok
  end

  @impl GenServer
  def init(_opts) do
    CommandEvents.subscribe()
    DeviceEvents.subscribe()
    ScheduleEvents.subscribe()
    ThreadEvents.subscribe()

    {:ok,
     %{expectations: %{}, unknown: %{}, pending_outcomes: %{}, finished_requests: MapSet.new()}}
  end

  @impl GenServer
  def handle_info(%Jido.Signal{type: "dobby.command.expected", data: data}, state) do
    {:noreply, safely(state, fn -> expect(state, data) end)}
  end

  def handle_info(%Jido.Signal{type: "dobby.ha.call_failed", data: data}, state) do
    {:noreply, safely(state, fn -> refuse(state, data) end)}
  end

  def handle_info({:expectation_expired, ref}, state) do
    {:noreply, safely(state, fn -> expire(state, ref) end)}
  end

  def handle_info({:turn_finished, request_id}, state) do
    {:noreply, safely(state, fn -> finish_request(state, request_id) end)}
  end

  def handle_info({:forget_finished_request, request_id}, state) do
    {:noreply, %{state | finished_requests: MapSet.delete(state.finished_requests, request_id)}}
  end

  # Nothing moved, so nothing happened: this is a device reporting for the
  # first time and the house learning what it has. Writing it down would mean
  # every restart announced the boot sequence to the kitchen and filled the log
  # with rows saying the thermostat exists.
  @impl GenServer
  def handle_info(
        %Jido.Signal{type: "dobby.device.state_changed", data: %{moved: []} = data},
        state
      ) do
    {:noreply, safely(state, fn -> resolve(state, data) end)}
  end

  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: data}, state) do
    guard(fn ->
      record_change(data)
      maybe_intervention(data)
    end)

    {:noreply, safely(state, fn -> resolve(state, data) end)}
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

  def handle_call(:forget_commands, _from, state) do
    Enum.each(state.expectations, fn {_ref, expectation} ->
      Process.cancel_timer(expectation.timer)
    end)

    {:reply, :ok, %{state | expectations: %{}, unknown: %{}}}
  end

  def handle_call({:decorate, device, snapshot}, _from, state) do
    decorated =
      if unknown_for?(state, device),
        do: Map.put(snapshot, :command_status, :not_known),
        else: snapshot

    {:reply, decorated, state}
  end

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

  # Broad on purpose, and the exit clause matters as much as the rescue. This
  # is the only thing in the house that turns an unanswered command into a
  # NOT KNOWN line, and its state holds every expectation currently in flight.
  # A Postgres timeout inside one handler, or a `GenServer.call` into a device
  # agent that has died, exits rather than raises — and an exit here would take
  # every other household's expectation down with it. Whatever one handler
  # cannot do, the witness keeps watching.
  defp safely(state, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "the watcher could not track a command: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      state
  catch
    :exit, reason ->
      Logger.error("the watcher could not track a command: exited with #{inspect(reason)}")

      state
  end

  # -- command confirmation -------------------------------------------------

  defp expect(state, %{ref: ref} = data) when is_binary(ref) do
    if arrived?(data, data[:snapshot]) do
      state
    else
      timer = Process.send_after(self(), {:expectation_expired, ref}, data.timeout_ms)
      expectation = Map.put(data, :timer, timer)
      put_in(state, [:expectations, ref], expectation)
    end
  end

  defp expect(state, _uncorrelated), do: state

  defp refuse(state, %{ref: ref} = data) do
    {state, removed_unknown?} = forget(state, ref)

    Activity.record(%{
      kind: "command_refused",
      device: data.device,
      action: data.action,
      args: data.call,
      result: %{"reason" => Activity.jsonable(data.reason)},
      request_id: data.request_id
    })

    state = outcome(state, :held, data)

    maybe_clear_status(state, data.device, removed_unknown?)
  end

  defp expire(state, ref) do
    case Map.pop(state.expectations, ref) do
      {nil, _expectations} ->
        state

      {expectation, expectations} ->
        # Asked before the ref joins `unknown`, so it answers "was this device
        # already NOT KNOWN". Say it once: three silent commands to one device
        # are one fact about that device, and three identical lines under each
        # other read as three separate failures. The ref still becomes unknown
        # and the log still takes its own row, because "how often does the
        # garage not answer" is a question about every command, not about the
        # first one that went quiet.
        already_unknown? = unknown_for?(state, expectation.device)

        state = %{
          state
          | expectations: expectations,
            unknown: Map.put(state.unknown, ref, Map.delete(expectation, :timer))
        }

        Activity.record(%{
          kind: "command_never_arrived",
          device: expectation.device,
          action: expectation.action,
          args: expectation.call,
          result: %{"timeout_ms" => expectation.timeout_ms},
          request_id: expectation.request_id
        })

        if already_unknown? do
          state
        else
          state = outcome(state, :not_known, expectation)
          DeviceEvents.command_status(expectation.device, :not_known)
          state
        end
    end
  end

  defp resolve(state, %{device: device, snapshot: snapshot}) do
    matching =
      state.expectations
      |> Map.merge(state.unknown)
      |> Enum.filter(fn {_ref, expectation} ->
        expectation.device == device and arrived?(expectation, snapshot)
      end)
      |> Enum.map(&elem(&1, 0))

    {state, cleared_unknown?} =
      Enum.reduce(matching, {state, false}, fn ref, {state, cleared?} ->
        {next, removed_unknown?} = forget(state, ref)
        {next, cleared? or removed_unknown?}
      end)

    maybe_clear_status(state, device, cleared_unknown?)
  end

  defp resolve(state, _event), do: state

  defp forget(state, ref) do
    {expectation, expectations} = Map.pop(state.expectations, ref)
    {_unknown, unknown} = Map.pop(state.unknown, ref)

    if expectation, do: Process.cancel_timer(expectation.timer)

    {%{state | expectations: expectations, unknown: unknown}, Map.has_key?(state.unknown, ref)}
  end

  defp maybe_clear_status(state, device, true) do
    unless unknown_for?(state, device), do: DeviceEvents.command_status(device, :clear)
    state
  end

  defp maybe_clear_status(state, _device, false), do: state

  defp unknown_for?(state, device),
    do: Enum.any?(state.unknown, fn {_ref, expectation} -> expectation.device == device end)

  defp arrived?(expectation, snapshot) when is_map(snapshot) do
    case Home.fetch_device(expectation.device) do
      {:ok, %{agent_module: module}} ->
        DeviceAgent.command_arrived?(module, expectation.command, snapshot)

      :error ->
        false
    end
  end

  defp arrived?(_expectation, _snapshot), do: false

  defp never_arrived_reason(expectation) do
    action = expectation.call["service"] || expectation.action
    local = expectation.asked_at |> Home.local() |> Calendar.strftime("%I:%M %p")
    "asked to #{String.replace(action, "_", " ")} at #{String.downcase(local)}, no answer since"
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # A device directive and a conversation reply run in different processes.
  # Their PubSub messages therefore have no useful ordering guarantee. Hold a
  # correlated outcome until the turn says its own last line is stored; direct
  # controls and schedules have no such line and announce immediately.
  defp outcome(state, kind, %{request_id: request_id} = data) when is_binary(request_id) do
    if MapSet.member?(state.finished_requests, request_id) do
      announce_outcome(kind, data)
      state
    else
      pending =
        Map.update(state.pending_outcomes, request_id, [{kind, data}], &(&1 ++ [{kind, data}]))

      %{state | pending_outcomes: pending}
    end
  end

  defp outcome(state, kind, data) do
    announce_outcome(kind, data)
    state
  end

  defp finish_request(state, request_id) do
    {pending, pending_outcomes} = Map.pop(state.pending_outcomes, request_id, [])
    Enum.each(pending, fn {kind, data} -> announce_outcome(kind, data) end)
    Process.send_after(self(), {:forget_finished_request, request_id}, @finished_ttl)

    %{
      state
      | pending_outcomes: pending_outcomes,
        finished_requests: MapSet.put(state.finished_requests, request_id)
    }
  end

  defp announce_outcome(:held, data) do
    Interventions.held(%{
      device: data.device,
      name: data.name,
      action: data.action,
      reason: "Home Assistant: #{describe(data.reason)}",
      via: "Home Assistant",
      request_id: data.request_id
    })
  end

  defp announce_outcome(:not_known, data) do
    Interventions.not_known(%{
      device: data.device,
      name: data.name,
      action: data.action,
      reason: never_arrived_reason(data),
      via: "Home Assistant",
      request_id: data.request_id
    })
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
