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
      # One person has the floor at a time: a ReAct agent takes one request at
      # a time, so this is the queue in front of it (TK-006). Above the house,
      # because an utterance is recorded whether or not the agent is up.
      Dobby.Conversation.Turn.Queue,
      # The one writer for the two things that happen with nobody standing in
      # front of them — a schedule at eight o'clock, and a hand on the dial.
      # A process and not a LiveView: three browsers would write three lines.
      # Above the house, so it is already subscribed when the first device
      # reports on boot.
      Dobby.Interventions.Watcher,
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
