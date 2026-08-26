defmodule Dobby.HAServer do
  @moduledoc """
  A Home Assistant WebSocket endpoint, for testing the real client.

  Where `Dobby.HomeAssistant.Fake` stands in for HA *behind* the boundary,
  this stands in for HA *on the wire*: a Bandit-hosted socket at
  `/api/websocket` speaking the actual protocol — server-initiated auth,
  id-correlated results, event frames. It is what lets the client's
  connection, correlation, and reconnect behavior be tested against real
  frames without a Home Assistant running.

  The test owns the script. Every inbound command is forwarded to the owner as
  `{:ha_server, :received, message}`, each accepted connection announces
  itself as `{:ha_server, :connected, handler_pid}`, and the owner drives the
  server by messaging the handler:

    * `{:push, map}` — push a JSON frame (events, out-of-order results);
    * `:close` — drop the connection, for reconnect scenarios.

  Options (all but `:owner` optional):

    * `:owner` — the test pid;
    * `:port` — the port to bind (default: an ephemeral one). Given, so that a
      scenario can put a real Home Assistant on the port a
      `Dobby.StalledHost` was wedging and watch the client find its way back;
    * `:token` — the access token `auth` must present (default `"rig-token"`);
    * `:states` — the `get_states` result (default `[]`);
    * `:entity_registry` — the `config/entity_registry/list` result (default `[]`);
    * `:call_service` — `:ok` to answer success (default), `{:error, code,
      message}` to refuse, `:silent` to never answer.
  """

  @behaviour Plug

  @doc """
  Starts a server under the test supervisor, returning its base URL.
  """
  @spec start!(keyword()) :: String.t()
  def start!(opts) do
    {port, opts} = Keyword.pop(opts, :port, 0)
    config = opts |> Keyword.put_new(:token, "rig-token") |> Map.new()

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, config}, scheme: :http, ip: {127, 0, 0, 1}, port: port}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(%Plug.Conn{path_info: ["api", "websocket"]} = conn, config) do
    WebSockAdapter.upgrade(conn, __MODULE__.Socket, config, timeout: 60_000)
  end

  def call(conn, _config), do: Plug.Conn.send_resp(conn, 404, "not found")

  defmodule Socket do
    @moduledoc false

    @behaviour WebSock

    @impl WebSock
    def init(config) do
      send(config.owner, {:ha_server, :connected, self()})
      {:push, frame(%{type: "auth_required", ha_version: "2026.8.0"}), config}
    end

    @impl WebSock
    def handle_in({text, opcode: :text}, config) do
      message = Jason.decode!(text)
      send(config.owner, {:ha_server, :received, message})
      handle_message(message, config)
    end

    @impl WebSock
    def handle_info({:push, message}, config), do: {:push, frame(message), config}
    def handle_info(:close, config), do: {:stop, :normal, config}
    def handle_info(_message, config), do: {:ok, config}

    defp handle_message(%{"type" => "auth", "access_token" => token}, %{token: token} = config),
      do: {:push, frame(%{type: "auth_ok", ha_version: "2026.8.0"}), config}

    defp handle_message(%{"type" => "auth"}, config),
      do: {:push, frame(%{type: "auth_invalid", message: "Invalid access token"}), config}

    defp handle_message(%{"type" => "subscribe_events", "id" => id}, config),
      do: {:push, frame(%{id: id, type: "result", success: true, result: nil}), config}

    defp handle_message(%{"type" => "get_states", "id" => id}, config) do
      states = Map.get(config, :states, [])
      {:push, frame(%{id: id, type: "result", success: true, result: states}), config}
    end

    defp handle_message(%{"type" => "config/entity_registry/list", "id" => id}, config) do
      entries = Map.get(config, :entity_registry, [])
      {:push, frame(%{id: id, type: "result", success: true, result: entries}), config}
    end

    defp handle_message(%{"type" => "call_service", "id" => id}, config) do
      case Map.get(config, :call_service, :ok) do
        :ok ->
          {:push, frame(%{id: id, type: "result", success: true, result: %{}}), config}

        {:error, code, message} ->
          {:push,
           frame(%{
             id: id,
             type: "result",
             success: false,
             error: %{code: code, message: message}
           }), config}

        :silent ->
          {:ok, config}
      end
    end

    defp handle_message(_message, config), do: {:ok, config}

    defp frame(map), do: {:text, Jason.encode!(map)}
  end
end
