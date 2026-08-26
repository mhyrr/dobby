defmodule Dobby.HomeAssistant.Client do
  @moduledoc """
  The real Home Assistant, over its WebSocket API (design §7, §12 Phase C).

  One process owns the connection, the authentication, the request IDs, and
  the `state_changed` subscription — which is exactly the list of things a
  device agent must never own. Everything above `Dobby.HomeAssistant` is
  identical whether this module or the fake is behind it.

  The connection is a fact about the world, not about this process: the
  application boots whether or not Home Assistant is reachable, connection
  loss answers in-flight calls with `{:error, :disconnected}` rather than
  crashing anybody, and reconnection is automatic with capped backoff.

  Boot survives the *slow* failures too, and that is the harder half. A host
  that refuses the connection says so at once; a host that accepts it and then
  stalls — a wedged HAOS, a reverse proxy holding the socket open, a box
  mid-reboot — used to hold this process for the whole transport timeout,
  which is the same five seconds `Dobby.Home.init/1` has to ask for the
  routing table. So connecting happens in a process of its own and the socket
  is handed back (`Mint.HTTP.controlling_process/2`), and the handshake that
  follows is on a clock, because an open socket that never speaks reports
  nothing to anybody (TK-017).

  On every authenticated connection — first or reconnect — the client
  subscribes to `state_changed` and then fetches current states, fanning the
  routed ones out to their device agents. That is `Fake.configure_routing/1`'s
  semantics made real: agents know the house shortly after boot rather than
  waiting for something to change, and a reconnect heals whatever events the
  outage swallowed.

  Requests are correlated by Home Assistant's message `id`, so any number may
  be in flight at once. `execute/1` returns `:ok` when HA reports the service
  call succeeded — acceptance, not physical confirmation, which arrives
  separately as a `state_changed` like every other fact.
  """

  use GenServer

  require Logger

  alias Dobby.Directive.HACall
  alias Dobby.HomeAssistant.Connection
  alias Dobby.HomeAssistant.Entity

  @behaviour Dobby.HomeAssistant

  # How long a service call may wait for HA's result. Connection loss answers
  # sooner; this only catches a healthy socket with a silent server.
  @execute_timeout 10_000

  # How long one connect attempt may take before it is abandoned. It runs in
  # its own process, so this bounds a socket rather than the mailbox — but it
  # is still what a wedged host costs before the retry.
  @connect_timeout 5_000

  # And how long the handshake that follows may take. Connecting is the only
  # step the transport puts a clock on: after it, an HTTP upgrade that is never
  # answered and an `auth_required` that never arrives look exactly like a
  # healthy connection with nothing to say. Generous, because it is a LAN round
  # trip and two frames, and the cost of firing early is a reconnect loop
  # against a house that was merely slow.
  @handshake_timeout 10_000

  @initial_backoff 1_000
  @max_backoff 30_000

  defstruct [
    :url,
    :token,
    :dispatch,
    :conn,
    :ref,
    :websocket,
    upgrade_status: nil,
    status: :disconnected,
    # The process doing the blocking part, and the attempt it belongs to. Every
    # message from a connect carries its attempt number, so an answer from an
    # attempt this process has already given up on is recognisable as one.
    connector: nil,
    attempt: 0,
    routing: nil,
    # Every entity Home Assistant has reported, routed or not (TK-010). The
    # routing table decides who *hears* about an entity; this is the client
    # remembering what it was told, which is the only way Dobby can answer
    # "what does Home Assistant have that this house does not manage?" without
    # anything above the boundary making a request of its own.
    catalogue: %{},
    entity_registry: %{},
    pending: %{},
    next_id: 1,
    backoff: @initial_backoff,
    initial_backoff: @initial_backoff,
    handshake_timeout: @handshake_timeout
  ]

  # -- client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl Dobby.HomeAssistant
  def execute(%HACall{} = call), do: execute(__MODULE__, call)

  @doc """
  Performs a service call against Home Assistant.

  `:ok` means HA reported success. `{:error, :disconnected}` is immediate when
  there is no authenticated connection — a caller must not sit waiting on a
  house that is not answering.
  """
  @spec execute(GenServer.server(), HACall.t()) :: :ok | {:error, term()}
  def execute(server, %HACall{} = call) do
    GenServer.call(server, {:execute, call}, @execute_timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :client_unavailable}
  end

  @impl Dobby.HomeAssistant
  def configure_routing(routing_table), do: configure_routing(__MODULE__, routing_table)

  @spec configure_routing(GenServer.server(), %{String.t() => String.t()}) :: :ok
  def configure_routing(server, routing_table),
    do: GenServer.call(server, {:configure_routing, routing_table})

  @impl Dobby.HomeAssistant
  def entities, do: entities(__MODULE__)

  @doc """
  Every entity this client has been told about, routed or not.

  Answered from memory, so it costs nothing and cannot hang a conversation on a
  Home Assistant that has stopped answering. A client that has never connected
  knows nothing and says so with an empty list — which discovery reads as "no
  candidates", not as an error, because that is what it is.
  """
  @spec entities(GenServer.server()) :: [Entity.t()]
  def entities(server) do
    GenServer.call(server, :entities)
  catch
    :exit, _reason -> []
  end

  # -- server ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    token = Keyword.fetch!(opts, :token)

    if not (is_binary(token) and token != "") do
      raise ArgumentError,
            "the home_assistant block selected #{inspect(__MODULE__)} but supplied no token"
    end

    initial_backoff = Keyword.get(opts, :backoff, @initial_backoff)

    state = %__MODULE__{
      url: url,
      token: token,
      backoff: initial_backoff,
      initial_backoff: initial_backoff,
      handshake_timeout: Keyword.get(opts, :handshake_timeout, @handshake_timeout),
      # The seam client tests observe delivery through. Production always
      # dispatches to the routed device agent.
      dispatch: Keyword.get(opts, :dispatch, &Dobby.HomeAssistant.dispatch_state_changed/4)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, attempt_connect(state)}

  @impl GenServer
  def handle_call({:execute, %HACall{} = call}, from, %{status: :connected} = state) do
    command = %{
      type: "call_service",
      domain: call.domain,
      service: call.service,
      service_data: call.data,
      target: %{entity_id: call.entity_id}
    }

    {:noreply, send_command(state, command, {:execute, from})}
  end

  def handle_call({:execute, %HACall{}}, _from, state) do
    {:reply, {:error, :disconnected}, state}
  end

  def handle_call({:configure_routing, routing}, _from, state) do
    {:reply, :ok, maybe_sync(%{state | routing: routing})}
  end

  def handle_call(:entities, _from, state) do
    {:reply, Map.values(state.catalogue), state}
  end

  @impl GenServer
  def handle_info(:connect, %{status: :disconnected} = state),
    do: {:noreply, attempt_connect(state)}

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:ha_connected, attempt, conn}, %{attempt: attempt} = state),
    do: {:noreply, upgrade(%{state | connector: nil}, conn)}

  # A connection from an attempt this process has moved on from. Ownership has
  # already been transferred here, so closing it is not tidiness — it is the
  # only place left that can.
  def handle_info({:ha_connected, _attempt, conn}, state) do
    Mint.HTTP.close(conn)
    {:noreply, state}
  end

  def handle_info({:ha_connect_failed, attempt, reason}, %{attempt: attempt} = state),
    do: {:noreply, retry(%{state | connector: nil}, reason)}

  def handle_info({:ha_connect_failed, _attempt, _reason}, state), do: {:noreply, state}

  # The connector died instead of answering. Whatever socket it had died with
  # it, so there is nothing to close and everything to retry. A normal exit is
  # the ordinary end of an attempt that already reported, and says nothing.
  def handle_info({:DOWN, monitor, :process, pid, reason}, %{connector: {pid, monitor}} = state) do
    case reason do
      :normal -> {:noreply, %{state | connector: nil}}
      reason -> {:noreply, retry(%{state | connector: nil}, reason)}
    end
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:handshake_timeout, attempt}, %{attempt: attempt, status: status} = state)
      when status in [:connecting, :authenticating],
      do: {:noreply, disconnect(state, :handshake_timeout)}

  def handle_info({:handshake_timeout, _attempt}, state), do: {:noreply, state}

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, handle_responses(%{state | conn: conn}, responses)}

      {:error, conn, reason, _responses} ->
        {:noreply, disconnect(%{state | conn: conn}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  # -- connection ------------------------------------------------------------

  # Returns immediately, always. Everything that can block about connecting
  # happens in the spawned process; this one goes back to its mailbox, which
  # is where `Dobby.Home.init/1` is waiting.
  defp attempt_connect(state) do
    endpoint = endpoint(state.url)
    client = self()
    attempt = state.attempt + 1

    # Monitored rather than linked: a connector that crashes must cost a retry,
    # not the client. Restarting the client would lose the routing table, which
    # only `Dobby.Home` at boot ever installs.
    connector = spawn_monitor(fn -> connect(client, attempt, endpoint) end)

    %{state | status: :connecting, attempt: attempt, connector: connector}
  end

  # Mint's documented handover, in its documented order: the connection struct
  # is sent first so the client is holding it before any socket message can
  # arrive, and ownership follows. The upgrade is deliberately left undone —
  # it belongs to whichever process is going to read the answer.
  defp connect(client, attempt, endpoint) do
    case Mint.HTTP.connect(endpoint.http_scheme, endpoint.host, endpoint.port,
           protocols: [:http1],
           transport_opts: [timeout: @connect_timeout]
         ) do
      {:ok, conn} ->
        send(client, {:ha_connected, attempt, conn})

        case Mint.HTTP.controlling_process(conn, client) do
          {:ok, _conn} ->
            :ok

          # The client has a connection whose socket it does not own, and this
          # process is about to exit and close it underneath. Better told than
          # discovered.
          {:error, reason} ->
            send(client, {:ha_connect_failed, attempt, reason})
        end

      {:error, reason} ->
        send(client, {:ha_connect_failed, attempt, reason})
    end
  end

  defp upgrade(state, conn) do
    endpoint = endpoint(state.url)

    case Mint.WebSocket.upgrade(endpoint.ws_scheme, conn, endpoint.path, []) do
      {:ok, conn, ref} ->
        # From here the house has a fixed time to say `auth_required`, answer
        # the auth, and let `auth_ok` land. Nothing under this reports a socket
        # that is open and mute.
        Process.send_after(self(), {:handshake_timeout, state.attempt}, state.handshake_timeout)
        %{state | conn: conn, ref: ref, status: :connecting}

      # A failed upgrade means the TCP connection is already up. Retrying
      # forever without closing it leaks a socket per attempt.
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        retry(state, reason)
    end
  end

  defp retry(state, reason) do
    Logger.warning(
      "Home Assistant unreachable at #{state.url} (#{inspect(reason)}); " <>
        "retrying in #{state.backoff}ms"
    )

    schedule_reconnect(state)
  end

  defp disconnect(state, reason) do
    Logger.warning("Home Assistant connection lost: #{inspect(reason)}")

    # In-flight callers get the truth now rather than a timeout later. Their
    # HACalls may or may not have reached HA; if one did, its consequences
    # arrive through the state sync after reconnect like any other change.
    Enum.each(state.pending, fn
      {_id, {:execute, from}} -> GenServer.reply(from, {:error, :disconnected})
      {_id, _tag} -> :ok
    end)

    if state.conn, do: Mint.HTTP.close(state.conn)

    schedule_reconnect(state)
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.backoff)

    # Every path down to a retry comes through here — a refused upgrade, a lost
    # socket, a bad token — so this is the one place the house has to be told.
    Connection.publish(__MODULE__, :reconnecting)

    %{
      state
      | conn: nil,
        ref: nil,
        websocket: nil,
        upgrade_status: nil,
        status: :disconnected,
        pending: %{},
        # Message IDs are per-connection: HA requires them to increase, and a
        # fresh connection starts a fresh sequence.
        next_id: 1,
        backoff: min(state.backoff * 2, @max_backoff)
    }
  end

  # -- HTTP upgrade → WebSocket ----------------------------------------------

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response(&2, &1))
  end

  defp handle_response(%{status: :disconnected} = state, _response), do: state

  defp handle_response(state, {:status, ref, status}) when ref == state.ref,
    do: %{state | upgrade_status: status}

  # An upgraded HTTP/1 request never emits `:done`: the headers are the last
  # of HTTP, and everything after is WebSocket. The socket is built here so
  # that frames arriving in the same batch — HA sends `auth_required`
  # immediately — find it existing.
  defp handle_response(state, {:headers, ref, headers})
       when ref == state.ref and state.websocket == nil do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, headers) do
      {:ok, conn, websocket} ->
        # Authentication is server-initiated: HA opens with `auth_required`
        # and we answer. Nothing to do here but be ready to hear it.
        %{state | conn: conn, websocket: websocket, status: :authenticating}

      {:error, conn, reason} ->
        disconnect(%{state | conn: conn}, reason)
    end
  end

  defp handle_response(state, {:data, ref, data}) when ref == state.ref do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame(&2, &1))

      {:error, websocket, reason} ->
        disconnect(%{state | websocket: websocket}, reason)
    end
  end

  defp handle_response(state, {:error, ref, reason}) when ref == state.ref,
    do: disconnect(state, reason)

  defp handle_response(state, _response), do: state

  # -- frames ----------------------------------------------------------------

  # A disconnect mid-batch (a close frame with more behind it) leaves nothing
  # to speak through; whatever followed it is from a connection we have
  # already given up on.
  defp handle_frame(%{status: :disconnected} = state, _frame), do: state

  defp handle_frame(state, {:text, text}) do
    case Jason.decode(text) do
      {:ok, message} ->
        handle_message(state, message)

      {:error, reason} ->
        Logger.warning("undecodable frame from Home Assistant: #{inspect(reason)}")
        state
    end
  end

  defp handle_frame(state, {:ping, data}), do: send_frame(state, {:pong, data})
  defp handle_frame(state, {:close, _code, _reason}), do: disconnect(state, :closed_by_server)
  defp handle_frame(state, _frame), do: state

  # -- the HA message protocol -----------------------------------------------

  defp handle_message(state, %{"type" => "auth_required"}),
    do: send_json(state, %{type: "auth", access_token: state.token})

  defp handle_message(state, %{"type" => "auth_ok"} = message) do
    Logger.info("connected to Home Assistant #{message["ha_version"]} at #{state.url}")

    # Announced rather than answered on request: the surface that most wants
    # to know the connection is down is the one a dead client could never
    # answer. See `Dobby.HomeAssistant.Connection`.
    Connection.publish(__MODULE__, :connected)

    %{state | status: :connected, backoff: state.initial_backoff}
    |> send_command(%{type: "subscribe_events", event_type: "state_changed"}, :subscription)
    |> send_command(
      %{type: "subscribe_events", event_type: "entity_registry_updated"},
      :registry_subscription
    )
    |> maybe_sync()
  end

  defp handle_message(state, %{"type" => "auth_invalid"} = message) do
    # A bad token does not fix itself, but dying here would take the house
    # console down with it. Stay up, say why, keep trying at the capped pace —
    # the operator's fix is a new token and a restart.
    Logger.error("Home Assistant rejected the access token: #{message["message"]}")
    disconnect(state, :auth_invalid)
  end

  defp handle_message(state, %{"type" => "result", "id" => id} = message) do
    {tag, pending} = Map.pop(state.pending, id)
    handle_result(%{state | pending: pending}, tag, message)
  end

  defp handle_message(
         state,
         %{"type" => "event", "event" => %{"event_type" => "state_changed", "data" => data}}
       ) do
    state
    |> remember(data["entity_id"], data["new_state"])
    |> dispatch_entity(data["entity_id"], data["new_state"])
  end

  defp handle_message(
         state,
         %{"type" => "event", "event" => %{"event_type" => "entity_registry_updated"}}
       ) do
    send_command(state, %{type: "config/entity_registry/list"}, :entity_registry)
  end

  defp handle_message(state, _message), do: state

  # -- results, by what we asked for -----------------------------------------

  # A result for an ID we are not waiting on: a caller that already got
  # {:error, :timeout}, or noise. Either way there is nobody to tell.
  defp handle_result(state, nil, _message), do: state

  defp handle_result(state, {:execute, from}, %{"success" => true}) do
    GenServer.reply(from, :ok)
    state
  end

  defp handle_result(state, {:execute, from}, message) do
    GenServer.reply(from, {:error, error_reason(message)})
    state
  end

  defp handle_result(state, :subscription, %{"success" => true}), do: state

  defp handle_result(state, :subscription, message) do
    # A client that cannot hear state changes is not connected in any sense
    # Dobby cares about. Start over.
    Logger.error("Home Assistant refused the state_changed subscription: #{inspect(message)}")
    disconnect(state, :subscription_refused)
  end

  defp handle_result(state, :registry_subscription, %{"success" => true}), do: state

  defp handle_result(state, :registry_subscription, message) do
    # Registry metadata improves discovery but is not part of control. A house
    # that can still hear state changes remains connected when this optional
    # subscription is unavailable on an older HA release.
    Logger.warning("Home Assistant refused the entity registry subscription: #{inspect(message)}")
    state
  end

  defp handle_result(state, :initial_sync, %{"success" => true, "result" => states})
       when is_list(states) do
    # Replaced wholesale rather than merged. A sync is Home Assistant's complete
    # answer about itself, so an entity somebody deleted stops being a discovery
    # candidate here — where a merge would keep offering it forever.
    catalogue =
      for %{"entity_id" => entity_id} = entity_state <- states, into: %{} do
        {entity_id, entity(entity_id, entity_state, state.entity_registry)}
      end

    Enum.reduce(states, %{state | catalogue: catalogue}, fn entity_state, state ->
      dispatch_entity(state, entity_state["entity_id"], entity_state)
    end)
  end

  defp handle_result(state, :initial_sync, message) do
    # Survivable: agents stay unknowing until the next state change or
    # reconnect, which is the same posture as a house that just booted.
    Logger.error("Home Assistant could not report current states: #{inspect(message)}")
    state
  end

  defp handle_result(state, :entity_registry, %{"success" => true, "result" => entries})
       when is_list(entries) do
    registry =
      for %{"entity_id" => entity_id} = entry <- entries, into: %{} do
        {entity_id, entry}
      end

    catalogue =
      Map.new(state.catalogue, fn {entity_id, entity} ->
        {entity_id, Entity.enrich(entity, Map.get(registry, entity_id, %{}))}
      end)

    %{state | entity_registry: registry, catalogue: catalogue}
  end

  defp handle_result(state, :entity_registry, message) do
    Logger.warning("Home Assistant could not report its entity registry: #{inspect(message)}")
    state
  end

  defp error_reason(%{"error" => %{"code" => code, "message" => message}}), do: {code, message}
  defp error_reason(_message), do: :unknown_error

  # -- inbound state ----------------------------------------------------------

  defp dispatch_entity(%{routing: routing} = state, entity_id, new_state)
       when is_map_key(routing, entity_id) do
    case new_state do
      # An entity HA no longer has a state for — removed, or restarting. To
      # its agent that is indistinguishable from unavailable, which is the
      # honest reading.
      nil ->
        state.dispatch.(routing, entity_id, nil, %{})

      %{"state" => entity_state} ->
        state.dispatch.(routing, entity_id, entity_state, Map.get(new_state, "attributes", %{}))
    end

    state
  end

  defp dispatch_entity(state, _entity_id, _new_state), do: state

  # The catalogue tracks every entity, routed or not — that is the whole point
  # of it. An entity HA no longer has a state for is dropped rather than kept
  # as a candidate nobody could bind.
  defp remember(state, entity_id, nil) when is_binary(entity_id),
    do: %{state | catalogue: Map.delete(state.catalogue, entity_id)}

  defp remember(state, entity_id, %{} = new_state) when is_binary(entity_id),
    do: put_in(state.catalogue[entity_id], entity(entity_id, new_state, state.entity_registry))

  defp remember(state, _entity_id, _new_state), do: state

  defp entity(entity_id, entity_state, registry) do
    Entity.from_attributes(
      entity_id,
      Map.get(entity_state, "state"),
      Map.get(entity_state, "attributes") || %{},
      Map.get(registry, entity_id, %{})
    )
  end

  defp maybe_sync(%{status: :connected, routing: routing} = state) when is_map(routing) do
    state
    |> send_command(%{type: "config/entity_registry/list"}, :entity_registry)
    |> send_command(%{type: "get_states"}, :initial_sync)
  end

  defp maybe_sync(state), do: state

  # -- sending ---------------------------------------------------------------

  defp send_command(state, command, tag) do
    id = state.next_id

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}
    |> send_json(Map.put(command, :id, id))
  end

  defp send_json(state, payload), do: send_frame(state, {:text, Jason.encode!(payload)})

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = %{state | websocket: websocket},
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | conn: conn}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        disconnect(%{state | websocket: websocket}, reason)

      {:error, conn, reason} ->
        disconnect(%{state | conn: conn}, reason)
    end
  end

  # -- addressing ------------------------------------------------------------

  # The manifest says where Home Assistant is the way a person would,
  # `http://host:8123`; the WebSocket API lives at a fixed path under it.
  defp endpoint(url) do
    uri = URI.parse(url)

    {http_scheme, ws_scheme} =
      case uri.scheme do
        scheme when scheme in ["https", "wss"] -> {:https, :wss}
        _other -> {:http, :ws}
      end

    %{
      http_scheme: http_scheme,
      ws_scheme: ws_scheme,
      host: uri.host,
      port: uri.port || if(http_scheme == :https, do: 443, else: 80),
      path: "/api/websocket"
    }
  end
end
