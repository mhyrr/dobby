defmodule Dobby.StalledHost do
  @moduledoc """
  A host that accepts the connection and then says nothing (TK-017).

  `Dobby.HAServer` is Home Assistant answering; this is Home Assistant *not*
  answering in the one way that is worse than being down. A refused connection
  is a fast, honest error and the client has always survived it. A host that
  completes the TCP handshake and then goes silent — a box mid-reboot, a
  reverse proxy holding the socket open, HAOS with its supervisor wedged — is
  the failure that has to be held open in a test, because nothing about it
  arrives on its own.

  It is a bare listener rather than a mode of `Dobby.HAServer`, because Bandit
  cannot go silent: it exists to answer. Silence lives one layer down, where
  the socket is accepted and simply held.

  The port is the useful part, so a scenario can put a real `Dobby.HAServer`
  on it afterwards and watch the client find its way back — the house coming
  home to the address it was already knocking at.

  Both URLs are for the same listener, and which one a scenario uses picks
  which handshake stalls:

    * `:https` — the TLS handshake never completes, so `Mint.HTTP.connect/4`
      blocks for its whole transport timeout;
    * `:http` — the connection is made at once and the WebSocket upgrade is
      what goes unanswered.
  """

  use GenServer

  @type t :: %{port: pos_integer(), http: String.t(), https: String.t(), pid: pid()}

  @doc """
  Starts a listener on an ephemeral port, or on `:port` if one is given.

  Every accepted connection is announced to `:owner` as
  `{:stalled_host, :accepted}`, which is how a scenario knows the client is in
  the middle of a handshake rather than about to start one.
  """
  @spec start!(keyword()) :: t()
  def start!(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())

    pid =
      ExUnit.Callbacks.start_supervised!(%{
        id: {__MODULE__, System.unique_integer([:positive])},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      })

    port = GenServer.call(pid, :port)

    %{
      pid: pid,
      port: port,
      http: "http://127.0.0.1:#{port}",
      https: "https://127.0.0.1:#{port}"
    }
  end

  @doc """
  Takes the listener down and waits for the port to be free.

  Waited on by binding it, rather than by watching the process go, because
  those are not the same moment: sockets are closed as part of cleaning up
  the process that owned them, and a `:DOWN` can arrive first. The next thing
  a scenario does is bind this port, so the only honest answer to "is it
  free?" is to have taken and released it.
  """
  @spec stop(t()) :: :ok
  def stop(%{pid: pid, port: port}) do
    ref = Process.monitor(pid)
    GenServer.stop(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise "the stalled host would not go away"
    end

    await_free(port, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_free(port, deadline) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, probe} ->
        :gen_tcp.close(probe)

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "port #{port} was still #{inspect(reason)} five seconds after the stalled host"
        else
          Process.sleep(10)
          await_free(port, deadline)
        end
    end
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    port = Keyword.get(opts, :port, 0)

    {:ok, listen} =
      :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    owner = Keyword.fetch!(opts, :owner)
    acceptor = spawn_link(fn -> accept_forever(listen, owner, []) end)
    :ok = :gen_tcp.controlling_process(listen, acceptor)

    {:ok, %{port: port, acceptor: acceptor}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  # Killed, and waited for. Every socket this listener holds belongs to the
  # acceptor, and a socket is closed as its owner dies — so "the port is free"
  # and "the acceptor is gone" are the same event, and the caller is about to
  # bind that port. A normal exit would not do it: the acceptor is linked but
  # not trapping, so it would outlive an orderly stop and keep the port.
  def terminate(_reason, %{acceptor: acceptor}) do
    ref = Process.monitor(acceptor)
    Process.exit(acceptor, :kill)

    receive do
      {:DOWN, ^ref, :process, ^acceptor, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  # The accumulator is not bookkeeping: it is what keeps each accepted socket
  # from being garbage collected and closed, which would turn silence into a
  # connection reset and hide the failure this exists to reproduce.
  defp accept_forever(listen, owner, held) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        send(owner, {:stalled_host, :accepted})
        accept_forever(listen, owner, [socket | held])

      {:error, _reason} ->
        :ok
    end
  end
end
