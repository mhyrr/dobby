defmodule Dobby.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DobbyWeb.Telemetry,
      Dobby.Repo,
      {DNSCluster, query: Application.get_env(:dobby, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dobby.PubSub},
      # One task per request, and it has to be somebody's child. `ask_stream/3`
      # makes the calling process the event sink, so the process that iterates
      # a request cannot be the LiveView — see `Dobby.Conversation.Turn`.
      {Task.Supervisor, name: Dobby.TaskSupervisor},
      # Order is the design's boot order (§5) and it is load-bearing: the Jido
      # instance supplies the registry device agents register in, the HA client
      # must exist before Dobby.Home hands it a routing table, and Dobby.Home
      # starts the agents that routing table points at.
      Dobby.Jido,
      {Dobby.HomeAssistant.impl(), Dobby.HomeAssistant.options()},
      Dobby.Home,
      # Start to serve requests, typically the last entry
      DobbyWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Dobby.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DobbyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
