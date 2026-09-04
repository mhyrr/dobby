defmodule Dobby.LanBeacon do
  @moduledoc """
  Advertises this machine as `dobby.local` while the server runs.

  Design §3 already gives the house this address; production gets it from the
  server's own mDNS daemon. This brings it forward to the dev laptop, where
  the household's first second user reaches the thread by typing the house's
  name rather than an IP and a port.

  The advertisement is held in a port owned by this process: `dns-sd -P` on
  macOS, or an `avahi-publish` address record on Linux. The name exists exactly
  as long as the server does, and a crashed server takes its name down with it
  — which is correct, because a name that outlives what it names is a lie
  waiting for a browser.

  Started only when the `:lan_beacon` config exists, which `runtime.exs` sets
  from `DOBBY_LAN` in dev. Off is the default: binding a laptop to the
  network is a choice, not a side effect.
  """

  use GenServer

  require Logger

  # If dns-sd exits (name conflict, daemon restart), try again rather than
  # crash-looping into the supervisor's restart intensity.
  @retry_after 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    hostname = Keyword.get(opts, :hostname, "dobby.local")

    case {publisher(), lan_ip()} do
      {nil, _ip} ->
        Logger.warning(
          "neither dns-sd nor avahi-publish was found; #{hostname} will not be advertised"
        )

        :ignore

      {_publisher, nil} ->
        Logger.warning("no LAN address on this machine; #{hostname} will not be advertised")
        :ignore

      {publisher, ip} ->
        state = %{publisher: publisher, ip: ip, hostname: hostname, port: nil}
        {:ok, advertise(state)}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "#{state.hostname} advertisement stopped (dns-sd exited #{status}); " <>
        "retrying in #{@retry_after}ms"
    )

    Process.send_after(self(), :readvertise, @retry_after)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:readvertise, %{port: nil} = state), do: {:noreply, advertise(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp advertise(state) do
    http_port = http_port()

    # Through a shell wrapper, because the publishers ignore stdin: a bare
    # port child would survive the VM as an orphan still claiming the name
    # (three of them did, before this). The watcher turns stdin EOF — the port
    # closing, the VM dying — into a kill, and `wait` turns the publisher's
    # own death into an exit this process hears and retries. The fd 3 dance is
    # not optional: POSIX gives backgrounded commands /dev/null as stdin, so
    # without it the watcher's cat sees EOF at birth and kills the name it was
    # guarding. `"$@"` keeps every value as data rather than shell source.
    script = """
    exec 3<&0
    "$@" &
    CHILD=$!
    ( cat <&3 > /dev/null; kill $CHILD 2> /dev/null ) &
    wait $CHILD
    """

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          args: [
            "-c",
            script,
            "dobby-mdns"
            | publish_command(state, http_port)
          ]
        ]
      )

    address =
      if http_port == 80,
        do: "http://#{state.hostname}/",
        else: "http://#{state.hostname}:#{http_port}/"

    Logger.info("the house answers at #{address} (#{state.ip})")

    %{state | port: port}
  end

  defp publisher do
    cond do
      path = System.find_executable("dns-sd") -> {:dns_sd, path}
      path = System.find_executable("avahi-publish") -> {:avahi, path}
      true -> nil
    end
  end

  defp publish_command(%{publisher: {:dns_sd, executable}} = state, http_port) do
    [
      executable,
      "-P",
      "Dobby",
      "_http._tcp",
      "local",
      Integer.to_string(http_port),
      state.hostname,
      state.ip
    ]
  end

  # The browser uses the documented explicit port, so Linux needs the address
  # record. `-f` waits for avahi-daemon across a daemon restart instead of
  # making this GenServer churn every five seconds. `-R` publishes no reverse
  # record: the daemon already owns the one for this machine's own address,
  # and without it every Debian box collided with itself — "Local name
  # collision", once per boot, and no dobby.local (found on the release walk,
  # 2026-09-04; the Linux path had never run on a real host before it).
  defp publish_command(%{publisher: {:avahi, executable}} = state, _http_port) do
    [executable, "-a", "-f", "-R", state.hostname, state.ip]
  end

  defp http_port do
    :dobby
    |> Application.get_env(DobbyWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4000)
  end

  # The first interface that is up, running, broadcast-capable, and has an
  # IPv4 address — which on a laptop is the one the household is on.
  defp lan_ip do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.filter(fn {_name, props} ->
          flags = Keyword.get(props, :flags, [])
          :up in flags and :running in flags and :broadcast in flags
        end)
        |> Enum.find_value(fn {_name, props} ->
          props
          |> Keyword.get_values(:addr)
          |> Enum.find_value(fn
            {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
            _other -> nil
          end)
        end)

      {:error, _reason} ->
        nil
    end
  end
end
