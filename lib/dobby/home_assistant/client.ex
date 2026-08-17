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

  @behaviour Dobby.HomeAssistant

  # How long a service call may wait for HA's result. Connection loss answers
  # sooner; this only catches a healthy socket with a silent server.
  @execute_timeout 10_000

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
    routing: nil,
    pending: %{},
    next_id: 1,
    backoff: @initial_backoff,
    initial_backoff: @initial_backoff
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

  @impl GenServer
  def handle_info(:connect, %{status: :disconnected} = state), do: {:noreply, attempt_connect(state)}
  def handle_info(:connect, state), do: {:noreply, state}

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

  defp attempt_connect(state) do
    endpoint = endpoint(state.url)

    with {:ok, conn} <-
           Mint.HTTP.connect(endpoint.http_scheme, endpoint.host, endpoint.port,
             protocols: [:http1],
             transport_opts: [timeout: 5_000]
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(endpoint.ws_scheme, conn, endpoint.path, []) do
      %{state | conn: conn, ref: ref, status: :connecting}
    else
      {:error, reason} -> retry(state, reason)
      {:error, _conn, reason} -> retry(state, reason)
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

    %{state | status: :connected, backoff: state.initial_backoff}
    |> send_command(%{type: "subscribe_events", event_type: "state_changed"}, :subscription)
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
    dispatch_entity(state, data["entity_id"], data["new_state"])
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

  defp handle_result(state, :initial_sync, %{"success" => true, "result" => states})
       when is_list(states) do
    Enum.reduce(states, state, fn entity_state, state ->
      dispatch_entity(state, entity_state["entity_id"], entity_state)
    end)
  end

  defp handle_result(state, :initial_sync, message) do
    # Survivable: agents stay unknowing until the next state change or
    # reconnect, which is the same posture as a house that just booted.
    Logger.error("Home Assistant could not report current states: #{inspect(message)}")
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

  defp maybe_sync(%{status: :connected, routing: routing} = state) when is_map(routing) do
    send_command(state, %{type: "get_states"}, :initial_sync)
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
