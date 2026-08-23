defmodule Dobby.HomeAssistant.Fake do
  @moduledoc """
  A Home Assistant that lives in a GenServer.

  This is the rig (design §12), and it lives in `lib/` rather than
  `test/support/` on purpose: `mix phx.server` in dev boots the entire
  application — thread, cards, scheduler — against it with no VM present.

  It models the small part of HA that Dobby actually depends on:

    * an entity state store, which is HA's view of the world;
    * service calls, which mutate that store the way a real integration would
      and then publish the change;
    * a `state_changed` fan-out to whichever device agent owns the entity.

  That last property is what makes the physical confirm loop real in tests.
  A `set_temperature` does not update thermostat agent state directly — it
  goes out as an `HACall`, lands here, mutates the entity, and comes *back* as
  an inbound event. Exactly the round trip production makes, minus the house.

  It also records every executed `HACall` in an ordered trace, which is the
  assertion surface for the replay tier.
  """

  use GenServer

  alias Dobby.Directive.HACall
  alias Dobby.HomeAssistant.Connection
  alias Dobby.HomeAssistant.Entity

  @behaviour Dobby.HomeAssistant

  @type entity :: %{state: String.t() | nil, attributes: map()}

  defstruct routing: %{}, entities: %{}, trace: [], subscribers: [], failures: %{}

  # -- client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Dobby.HomeAssistant
  def execute(%HACall{} = call), do: GenServer.call(__MODULE__, {:execute, call})

  @impl Dobby.HomeAssistant
  def configure_routing(routing_table),
    do: GenServer.call(__MODULE__, {:configure_routing, routing_table})

  @impl Dobby.HomeAssistant
  def entities, do: GenServer.call(__MODULE__, :entities)

  @doc """
  Seeds HA's view of an entity without publishing an event.

  This is HA having state, not Dobby having state — the distinction the rig
  turns on. Use it for the world as it stands before a scenario begins.
  """
  @spec put_entity(String.t(), entity()) :: :ok
  def put_entity(entity_id, entity),
    do: GenServer.call(__MODULE__, {:put_entity, entity_id, entity})

  @doc """
  Changes an entity and publishes the resulting `state_changed` to its agent.

  This is how the world moves on its own: someone turns the dial by hand, a
  sensor drops offline, the furnace catches up.
  """
  @spec inject_state_changed(String.t(), entity()) :: :ok
  def inject_state_changed(entity_id, entity),
    do: GenServer.call(__MODULE__, {:inject, entity_id, entity})

  @doc """
  Makes the next service call against `entity_id` fail.

  For the scenario where the device is unavailable and the honest answer is
  that Dobby could not do it.
  """
  @spec fail_next(String.t(), term()) :: :ok
  def fail_next(entity_id, reason \\ :unavailable),
    do: GenServer.call(__MODULE__, {:fail_next, entity_id, reason})

  @doc """
  Every `HACall` executed so far, in order.
  """
  @spec trace() :: [HACall.t()]
  def trace, do: GenServer.call(__MODULE__, :trace)

  @doc """
  Receives `{:ha_call, %HACall{}}` for every executed call.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc """
  Clears the trace, entities, and pending failures between scenarios.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Walks the rig's connection through a transition, as the real client would.

  From inside the fake's own process, because `Connection` only takes a
  transition from the process holding the client's name — a test announcing on
  the fake's behalf would be exactly the impersonation that rule exists for.
  """
  @spec set_connection(Dobby.HomeAssistant.Connection.status()) :: :ok
  def set_connection(status), do: GenServer.call(__MODULE__, {:set_connection, status})

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # A rig with nothing to lose is connected, and says so through the same
    # seam the real client does — otherwise the panel that reports the
    # connection is honest in production and blank in dev and test, which is
    # the wrong way round for a surface nobody looks at until something breaks.
    connected()

    {:ok, %__MODULE__{entities: Keyword.get(opts, :entities, %{})}}
  end

  @impl GenServer
  def handle_call({:configure_routing, routing}, _from, state) do
    state = %{state | routing: routing}

    # A real client subscribes and then receives current state for every
    # entity it cares about. Device agents therefore come up knowing the
    # world, rather than knowing nothing until something happens to change.
    for {entity_id, _agent_id} <- routing, entity = state.entities[entity_id], entity != nil do
      dispatch_state_changed(state, entity_id, entity)
    end

    {:reply, :ok, state}
  end

  def handle_call({:execute, %HACall{} = call}, _from, state) do
    state = %{state | trace: state.trace ++ [call]}
    Enum.each(state.subscribers, &send(&1, {:ha_call, call}))

    case Map.pop(state.failures, call.entity_id) do
      {nil, _failures} ->
        {:reply, :ok, confirm(state, call)}

      {reason, failures} ->
        {:reply, {:error, reason}, %{state | failures: failures}}
    end
  end

  def handle_call({:put_entity, entity_id, entity}, _from, state) do
    {:reply, :ok, put_in(state.entities[entity_id], entity)}
  end

  def handle_call({:inject, entity_id, entity}, _from, state) do
    state = put_in(state.entities[entity_id], entity)
    dispatch_state_changed(state, entity_id, entity)
    {:reply, :ok, state}
  end

  def handle_call({:fail_next, entity_id, reason}, _from, state) do
    {:reply, :ok, put_in(state.failures[entity_id], reason)}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call({:set_connection, status}, _from, state) do
    Connection.publish(__MODULE__, status)
    {:reply, :ok, state}
  end

  # The fake's entity store *is* HA's view of the world, so discovery reads it
  # directly — the same store the routed entities are fanned out from, which is
  # what makes an unbound entity in the rig genuinely unbound rather than a
  # second list somebody remembered to keep in step.
  def handle_call(:entities, _from, state) do
    entities =
      Enum.map(state.entities, fn {entity_id, entity} ->
        Entity.from_attributes(
          entity_id,
          Map.get(entity, :state),
          Map.get(entity, :attributes, %{}),
          entity
        )
      end)

    {:reply, entities, state}
  end

  def handle_call(:trace, _from, state), do: {:reply, state.trace, state}

  def handle_call(:reset, _from, state) do
    # The world as it stands before a scenario begins, and that includes the
    # connection: a test that walked the fake through a disconnection must not
    # leave the next one starting from it.
    connected()

    {:reply, :ok, %{state | trace: [], entities: %{}, failures: %{}, subscribers: []}}
  end

  defp connected, do: Connection.publish(__MODULE__, :connected)

  # -- the physical confirm loop --------------------------------------------

  # HA applies an accepted service call to the entity and publishes the result.
  # Dobby learns its command worked the same way it learns anything else.
  defp confirm(state, %HACall{} = call) do
    entity = Map.get(state.entities, call.entity_id, %{state: nil, attributes: %{}})
    updated = apply_service(call, entity)

    if updated == entity do
      state
    else
      state = put_in(state.entities[call.entity_id], updated)
      dispatch_state_changed(state, call.entity_id, updated)
      state
    end
  end

  defp apply_service(%HACall{domain: "climate", service: "set_temperature", data: data}, entity) do
    case fetch_any(data, [:temperature, "temperature"]) do
      {:ok, temperature} -> put_in(entity.attributes[:temperature], temperature)
      :error -> entity
    end
  end

  defp apply_service(%HACall{domain: "climate", service: "set_hvac_mode", data: data}, entity) do
    case fetch_any(data, [:hvac_mode, "hvac_mode"]) do
      {:ok, mode} -> %{entity | state: to_string(mode)}
      :error -> entity
    end
  end

  # Real HA's light semantics, kept faithfully: turn_on with brightness_pct
  # lights the bulb at that level, turn_off nulls the brightness attribute —
  # an off light has no brightness to report.
  defp apply_service(%HACall{domain: "light", service: "turn_on", data: data}, entity) do
    entity = %{entity | state: "on"}

    case fetch_any(data, [:brightness_pct, "brightness_pct"]) do
      {:ok, percent} -> put_in(entity.attributes[:brightness], round(percent * 255 / 100))
      :error -> entity
    end
  end

  defp apply_service(%HACall{domain: "light", service: "turn_off"}, entity) do
    put_in(%{entity | state: "off"}.attributes[:brightness], nil)
  end

  defp apply_service(%HACall{domain: "media_player", service: "media_play"}, entity),
    do: %{entity | state: "playing"}

  defp apply_service(%HACall{domain: "media_player", service: "media_pause"}, entity),
    do: %{entity | state: "paused"}

  defp apply_service(
         %HACall{domain: "media_player", service: "volume_set", data: data},
         entity
       ) do
    case fetch_any(data, [:volume_level, "volume_level"]) do
      {:ok, level} -> put_in(entity.attributes[:volume_level], level)
      :error -> entity
    end
  end

  defp apply_service(%HACall{domain: "lock", service: "lock"}, entity),
    do: %{entity | state: "locked"}

  defp apply_service(%HACall{domain: "cover", service: "close_cover"}, entity) do
    entity
    |> Map.put(:state, "closed")
    |> put_in([:attributes, :current_position], 0)
  end

  defp apply_service(%HACall{domain: "cover", service: "open_cover"}, entity) do
    entity
    |> Map.put(:state, "open")
    |> put_in([:attributes, :current_position], 100)
  end

  defp apply_service(%HACall{domain: "cover", service: "set_cover_position", data: data}, entity) do
    case fetch_any(data, [:position, "position"]) do
      {:ok, position} ->
        entity
        |> Map.put(:state, if(position == 0, do: "closed", else: "open"))
        |> put_in([:attributes, :current_position], position)

      :error ->
        entity
    end
  end

  defp apply_service(%HACall{domain: domain, service: "turn_on"}, entity)
       when domain in ["switch", "fan"],
       do: %{entity | state: "on"}

  defp apply_service(%HACall{domain: domain, service: "turn_off"}, entity)
       when domain in ["switch", "fan"],
       do: %{entity | state: "off"}

  defp apply_service(%HACall{domain: "fan", service: "set_percentage", data: data}, entity) do
    case fetch_any(data, [:percentage, "percentage"]) do
      {:ok, percentage} ->
        entity
        |> Map.put(:state, "on")
        |> put_in([:attributes, :percentage], percentage)

      :error ->
        entity
    end
  end

  # The vacuum acknowledges by moving: start reports cleaning, return_to_base
  # reports returning — reaching the dock is a later, separate event, which
  # tests inject when the scenario needs the robot home.
  defp apply_service(%HACall{domain: "vacuum", service: "start"}, entity),
    do: %{entity | state: "cleaning"}

  defp apply_service(%HACall{domain: "vacuum", service: "return_to_base"}, entity),
    do: %{entity | state: "returning"}

  defp apply_service(_call, entity), do: entity

  defp dispatch_state_changed(state, entity_id, entity) do
    Dobby.HomeAssistant.dispatch_state_changed(
      state.routing,
      entity_id,
      entity.state,
      entity.attributes
    )
  end

  defp fetch_any(data, keys) do
    Enum.find_value(keys, :error, fn key ->
      case Map.fetch(data, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end
end
