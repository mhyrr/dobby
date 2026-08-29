defmodule Dobby.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = refuse_unsendable_settings()

    children =
      [
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
        # The one author of the home file, and a sibling of the house rather
        # than a child of it: applying a changed house means restarting
        # Dobby.Home, which a process living underneath it could not do.
        Dobby.HomeConfig.Writer,
        # Start to serve requests, typically the last entry
        DobbyWeb.Endpoint
      ] ++ lan_beacon()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Dobby.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Before any child, because the failure this catches is a house that starts
  # perfectly and then cannot answer a single turn. `system: routing: latency`
  # with a model not reached through OpenRouter is rejected by ReqLLM while it
  # builds each request, so the only symptom is "Dobby couldn't answer that",
  # once per person who tries. Boot is where that gets a sentence naming the
  # setting; see `Dobby.HomeConfig.System.check_llm_opts/2`.
  #
  # The file is read a second time here rather than carried from
  # `config/runtime.exs`, which has it in hand: ReqLLM resolves models out of a
  # catalog its own application owns, and runtime configuration is evaluated
  # before any application starts. A check that quietly cannot run is worse
  # than no check.
  defp refuse_unsendable_settings do
    path = Application.get_env(:dobby, :home_config_path)
    model = :jido_ai |> Application.get_env(:model_aliases, %{}) |> Map.get(:capable)

    with true <- is_binary(path),
         {:ok, config} <- Dobby.HomeConfig.load(path) do
      exported = System.get_env("DOBBY_MODEL")

      case Dobby.HomeConfig.System.check_llm_opts(config.system, model, exported) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, reason
      end
    else
      # No file named, or one that will not parse. Neither is this check's to
      # report: `Dobby.Home` raises on the second a moment from now, in its own
      # words, and two boot errors about one file help nobody.
      _unavailable -> :ok
    end
  end

  # After the endpoint, on purpose: a name should not exist before the thing
  # it names answers — and only when the endpoint actually serves. A one-shot
  # mix task boots this application too, and `mix dobby.ha.verify` has no
  # business claiming the house's name on its way through.
  defp lan_beacon do
    with opts when opts != nil <- Application.get_env(:dobby, :lan_beacon),
         true <- Phoenix.Endpoint.server?(:dobby, DobbyWeb.Endpoint) do
      [{Dobby.LanBeacon, opts}]
    else
      _not_serving -> []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DobbyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
