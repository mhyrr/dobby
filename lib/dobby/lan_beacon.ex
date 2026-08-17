defmodule Dobby.LanBeacon do
  @moduledoc """
  Advertises this machine as `dobby.local` while the server runs.

  Design §3 already gives the house this address; production gets it from the
  server's own mDNS daemon. This brings it forward to the dev laptop, where
  the household's first second user reaches the thread by typing the house's
  name rather than an IP and a port.

  The advertisement is a `dns-sd -P` proxy registration held in a port owned
  by this process: the name exists exactly as long as the server does, and a
  crashed server takes its name down with it — which is correct, because a
  name that outlives what it names is a lie waiting for a browser.

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

    case {System.find_executable("dns-sd"), lan_ip()} do
      {nil, _ip} ->
        Logger.warning("dns-sd not found; #{hostname} will not be advertised")
        :ignore

      {_dns_sd, nil} ->
        Logger.warning("no LAN address on this machine; #{hostname} will not be advertised")
        :ignore

      {dns_sd, ip} ->
        state = %{dns_sd: dns_sd, ip: ip, hostname: hostname, port: nil}
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

    port =
      Port.open(
        {:spawn_executable, state.dns_sd},
        [
          :binary,
          :exit_status,
          args: [
            "-P",
            "Dobby",
            "_http._tcp",
            "local",
            Integer.to_string(http_port),
            state.hostname,
            state.ip
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
