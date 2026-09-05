defmodule Dobby.Rules.Watcher do
  @moduledoc """
  One deterministic observer for the house, independent of every browser.

  Timers only measure intervals. They never call a model or Home Assistant.
  Occurrences are persisted together with the thread line before the in-memory
  engine marks them announced. A failed record therefore retries instead of
  silently consuming the only notice the household would have received.

  Reconnection discards cached readings. Until a fresh device event arrives,
  we cannot prove continuity, even if a card still shows the last known state.
  A restart also starts new elapsed intervals, but loads unresolved occurrences
  to avoid repeating a notice somebody already acknowledged.
  """
  use GenServer
  require Logger
  alias Dobby.{Home, Rules}
  alias Dobby.Rules.{Engine, Rule, Window}
  alias Dobby.HomeAssistant.Connection

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def configure(manifest, snapshots \\ []) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:configure, manifest, snapshots}, 30_000),
      else: :ok
  end

  def suspend do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :suspend), else: :ok
  end

  def notices do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :notices), else: []
  end

  def acknowledge(id, actor, opts \\ []),
    do: GenServer.call(__MODULE__, {:acknowledge, id, actor, opts})

  # A synchronous barrier for tests and callers needing all prior deliveries
  # settled. It uses the same injected clock and transition path as the timer.
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @impl true
  def init(opts) do
    Dobby.DeviceEvents.subscribe()
    Dobby.ActivityEvents.subscribe()
    Connection.subscribe()

    state = %{
      house_id: nil,
      timezone: nil,
      rules: %{},
      engines: %{},
      occurrences: %{},
      snapshots: %{},
      activity_cursors: %{},
      running: false,
      connected: Connection.status() == :connected,
      timer: nil,
      generation: make_ref(),
      clock:
        Keyword.get(opts, :clock, fn ->
          {DateTime.utc_now(), System.monotonic_time(:millisecond)}
        end),
      tick_ms: Keyword.get(opts, :tick_ms, 1000)
    }

    manifest = Keyword.get_lazy(opts, :manifest, &Home.manifest/0)
    snapshots = Keyword.get_lazy(opts, :snapshots, &Home.snapshots/0)
    {:ok, load(state, manifest, snapshots) |> schedule()}
  end

  @impl true
  def handle_call({:configure, manifest, snapshots}, _from, state) do
    {:reply, :ok, load(state, manifest, snapshots) |> schedule()}
  end

  def handle_call(:suspend, _from, state) do
    cancel(state.timer)
    # Keep persisted occurrences in memory, but never let a late state event
    # from the departing agents start another timer.
    {:reply, :ok,
     %{state | running: false, snapshots: %{}, engines: %{}, timer: nil, generation: make_ref()}}
  end

  def handle_call(:notices, _from, state) do
    notices =
      state.occurrences
      |> Map.values()
      |> Enum.filter(&is_nil(&1.acknowledged_by))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.map(&Rules.describe_notice/1)

    {:reply, notices, state}
  end

  def handle_call({:acknowledge, id, actor, opts}, _from, state) do
    case Map.get(state.occurrences, id) do
      nil ->
        {:reply, {:error, "that rule has no standing notice"}, state}

      row ->
        cond do
          opts[:expected_occurrence_id] != nil and opts[:expected_occurrence_id] != row.id ->
            {:reply, {:error, "that notice has changed; review the current notice"}, state}

          row.acknowledged_by != nil ->
            {:reply, {:ok, Rules.describe_notice(row)}, state}

          true ->
            case Rules.acknowledge_occurrence(row, actor) do
              {:ok, updated} ->
                {:reply, {:ok, Rules.describe_notice(updated)},
                 %{state | occurrences: Map.put(state.occurrences, id, updated)}}

              error ->
                {:reply, error, state}
            end
        end
    end
  end

  def handle_call(:check, _from, state), do: {:reply, :ok, evaluate(state)}

  @impl true
  def handle_info({:tick, generation}, %{generation: generation} = state),
    do: {:noreply, evaluate(state) |> schedule()}

  def handle_info({:tick, _old}, state), do: {:noreply, state}

  def handle_info(%Jido.Signal{type: "dobby.device.state_changed", data: data}, state) do
    if state.running and state.connected do
      {:noreply,
       evaluate(%{state | snapshots: Map.put(state.snapshots, data.device, data.snapshot)})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:recorded, entry}, state) do
    if state.running and state.connected and Connection.status() == :connected do
      {now, mono} = state.clock.()

      state =
        Enum.reduce(state.rules, state, fn {id, rule}, acc ->
          if rule.enabled and rule.kind == "absence" and
               is_integer(entry.id) and entry.id > Map.get(acc.activity_cursors, id, 0) and
               Rule.event_matches?(rule, entry) do
            acc = recover(acc, id, now)

            %{
              acc
              | activity_cursors: Map.put(acc.activity_cursors, id, entry.id),
                engines:
                  Map.put(acc.engines, id, %{Engine.new() | since: mono, observed_since: now})
            }
          else
            acc
          end
        end)

      {:noreply, evaluate(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:home_assistant, _status}, state) do
    connected = Connection.status() == :connected

    engines =
      Map.new(state.engines, fn {id, engine} ->
        {id, %{engine | since: nil, observed_since: nil}}
      end)

    {:noreply, %{state | connected: connected, snapshots: %{}, engines: engines}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp load(state, manifest, snapshots) do
    {now, _mono} = state.clock.()
    definitions = Map.new(manifest.rules, &{&1.id, &1})
    previous = if state.house_id == manifest.id, do: state.rules, else: %{}
    stored = Rules.standing(manifest.id)

    occurrences =
      Enum.reduce(stored, %{}, fn row, acc ->
        rule = definitions[row.rule_id]

        if rule && rule.enabled && row.revision == Rules.revision(rule) &&
             Window.active?(rule.window, now, manifest.timezone) &&
             Window.key(rule.window, row.observed_since, manifest.timezone) ==
               Window.key(rule.window, now, manifest.timezone) do
          Map.put(acc, row.rule_id, row)
        else
          Rules.resolve(row, now)
          acc
        end
      end)

    engines =
      Map.new(definitions, fn {id, rule} ->
        engine =
          if state.running and previous[id] == rule,
            do: Map.get(state.engines, id, Engine.new(Map.has_key?(occurrences, id))),
            else: Engine.new(Map.has_key?(occurrences, id))

        {id, Map.put_new(engine, :window_key, Window.key(rule.window, now, manifest.timezone))}
      end)

    latest =
      if Enum.any?(manifest.rules, &(&1.kind == "absence")),
        do: Dobby.Activity.latest_id(),
        else: 0

    cursors =
      Map.new(definitions, fn {id, rule} ->
        cursor =
          if state.running and previous[id] == rule,
            do: Map.get(state.activity_cursors, id, latest),
            else: latest

        {id, cursor}
      end)

    cached =
      if state.running and state.house_id == manifest.id,
        do: state.snapshots,
        else: snapshot_map(snapshots)

    %{
      state
      | house_id: manifest.id,
        timezone: manifest.timezone,
        rules: definitions,
        engines: engines,
        activity_cursors: cursors,
        occurrences: occurrences,
        snapshots: cached,
        running: true,
        connected: Connection.status() == :connected
    }
  end

  defp evaluate(%{running: false} = state), do: state

  defp evaluate(state) do
    {now, mono} = state.clock.()
    connected = state.connected and Connection.status() == :connected

    Enum.reduce(state.rules, state, fn {id, rule}, acc ->
      try do
        snapshot = Map.get(acc.snapshots, rule.device)

        condition =
          cond do
            not rule.enabled -> false
            not Window.active?(rule.window, now, state.timezone) -> false
            not connected -> :unknown
            rule.kind == "state" -> Rule.matches?(rule, snapshot)
            is_map(snapshot) and snapshot[:available] == true -> true
            true -> :unknown
          end

        old = Map.fetch!(acc.engines, id)
        window_key = Window.key(rule.window, now, state.timezone)

        {acc, old} =
          if Map.get(old, :window_key) != window_key,
            do: {recover(acc, id, now), Engine.new()},
            else: {acc, old}

        {next, action} = Engine.step(old, condition, rule.duration_seconds, now, mono)
        next = Map.put(next, :window_key, window_key)

        acc =
          case action do
            :notify ->
              {:ok, occurrence} = Rules.notify(state.house_id, rule, next.observed_since, now)
              %{acc | occurrences: Map.put(acc.occurrences, id, occurrence)}

            :resolve ->
              recover(acc, id, now)

            :none ->
              acc
          end

        %{acc | engines: Map.put(acc.engines, id, next)}
      rescue
        # This process is the notice boundary. A database outage must not kill
        # observation of the other rules or consume this rule's pending notice.
        error ->
          Logger.error("could not evaluate rule #{id}: #{Exception.message(error)}")
          acc
      end
    end)
  end

  defp recover(state, id, now) do
    case state.occurrences[id] do
      nil ->
        state

      row ->
        :ok = Rules.resolve(row, now)
        %{state | occurrences: Map.delete(state.occurrences, id)}
    end
  end

  defp schedule(state) do
    cancel(state.timer)
    generation = make_ref()

    timer =
      if state.running and map_size(state.rules) > 0,
        do: Process.send_after(self(), {:tick, generation}, state.tick_ms)

    %{state | timer: timer, generation: generation}
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  defp snapshot_map(snapshots) when is_map(snapshots), do: snapshots
  defp snapshot_map(snapshots), do: Map.new(snapshots, &{&1.id, &1})
end
