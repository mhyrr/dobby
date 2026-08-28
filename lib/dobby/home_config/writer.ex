defmodule Dobby.HomeConfig.Writer do
  @moduledoc """
  The one process that writes the home file (TK-018).

  A GenServer and not a function, for the reason `Dobby.Interventions.Watcher`
  is one: three browsers would otherwise write three files, and the last one to
  finish would win an argument nobody had. Everything that changes the house or
  the system panel comes through here — /admin, /house, and eventually the
  household thread — so the file has a single author and a save is a queue
  rather than a race.

  ## What a save is

  Render, write, apply, announce. The write is a temporary file in the same
  directory followed by `File.rename/2`, which on one filesystem is atomic: a
  reader — a person, an editor, the next boot — sees either the old file or the
  new one, never half of either. A crash mid-write leaves the house it had.

  Applying is where the honesty is. A changed house is applied by putting the
  manifest back into the application environment and restarting `Dobby.Home`,
  which is what changing the house has always meant (design §2.4) and what the
  rig has proven on every scenario. A changed model alias applies live. A
  changed port or LAN binding cannot: those belong to a socket opened at boot,
  and the result says so rather than pretending — see
  `Dobby.HomeConfig.Applied`.

  One caller applies the house half a moment late rather than at once, and for
  a reason rather than for comfort: see `catch_up/1`.

  ## What it will not do

  It will not write an Elixir home. `config/homes/rig.exs` is a test fixture
  that belongs to the suite, and a file with logic in it is not a file a machine
  can round-trip. A house that wants an editable surface is a YAML house.
  """

  use GenServer

  alias Dobby.ConfigEvents
  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Applied

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{config: starting_config(opts), pending_house: nil}}
  end

  # A caller that has already loaded one hands it over; everyone else names a
  # file, and by default the file this boot actually read. Loading here is loud
  # and safe to be: `config/runtime.exs` read the same file on the way up, so a
  # file that fails here failed there first and there is no house to write for.
  defp starting_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %HomeConfig{} = config} ->
        config

      :error ->
        opts
        |> Keyword.get_lazy(:path, fn -> Application.fetch_env!(:dobby, :home_config_path) end)
        |> HomeConfig.load!()
    end
  end

  @doc """
  Which writer a surface should talk to.

  The application's own, unless something has said otherwise — the shape
  `Dobby.HomeAssistant.impl/0` already takes, and for the same reason: the one
  supervised writer holds the file this boot actually read, and a test that
  wants an editable house points at a writer holding a file of its own rather
  than at the rig's Elixir.
  """
  @spec server() :: GenServer.server()
  def server, do: Application.get_env(:dobby, :home_config_writer, __MODULE__)

  # -- reads -----------------------------------------------------------------

  @doc """
  The configuration currently on disk and in effect.

  A surface reads this once when it opens and stays current on `dobby:config`
  after that — the same shape every live surface here takes.
  """
  @spec current(GenServer.server()) :: HomeConfig.t()
  def current(server \\ __MODULE__), do: GenServer.call(server, :current)

  @doc """
  Whether this house is one Dobby is allowed to write, and why not if it isn't.

  A pure function and public on purpose: the rule has to be checked three
  times — by a surface deciding whether to offer an edit at all, by a tool
  refusing a proposal, and by this process before it touches the file — and
  copies of it would eventually be two rules. The sentence a household reads
  comes from here either way.
  """
  @spec writable(HomeConfig.t()) :: :ok | {:error, String.t()}
  def writable(%HomeConfig{format: :yaml}), do: :ok

  def writable(%HomeConfig{format: format, path: path}) do
    {:error,
     "Dobby writes YAML and #{path} is #{format}; migrate the house to a .yaml file first"}
  end

  @doc """
  The same rule as a bare yes or no, for a surface deciding whether to draw a
  form at all — a form that can only ever be refused is worse than a sentence
  saying why there is no form.
  """
  @spec writable?(HomeConfig.t()) :: boolean()
  def writable?(%HomeConfig{} = config), do: writable(config) == :ok

  # -- writes ----------------------------------------------------------------

  @doc """
  Writes a configuration and applies as much of it as can be applied.

  This is an exact replacement, for a configuration already owned by the
  caller. A read-modify-write path must use `update/3` so the read and write
  are one serialized operation.

  Refuses, without touching the file, a house `Dobby.Home.Manifest` would not
  accept or a credential reference the environment cannot answer. Announces on
  `dobby:config` when something actually changed.
  """
  @spec save(GenServer.server(), HomeConfig.t(), keyword()) ::
          {:ok, Applied.t()} | {:error, String.t()}
  def save(server \\ __MODULE__, %HomeConfig{} = config, opts \\ []) do
    GenServer.call(server, {:save, config, opts}, 30_000)
  end

  @doc """
  Derives and saves a configuration while holding the writer's queue.

  The updater receives the latest configuration and returns either the next
  one or a refusal. This is the mutation API for forms and tools. Serializing
  only `save/3` is too late: two callers can otherwise read the same house,
  each add one device, and then replace each other with two individually valid
  files.
  """
  @spec update(
          GenServer.server(),
          (HomeConfig.t() -> {:ok, HomeConfig.t()} | {:error, String.t()}),
          keyword()
        ) :: {:ok, Applied.t()} | {:error, String.t()}
  def update(server, updater, opts \\ []) when is_function(updater, 1) do
    GenServer.call(server, {:update, updater, opts}, 30_000)
  end

  @doc """
  Restarts the house on a save that asked to be applied later.

  Deferral exists for exactly one caller: a change made from inside the
  household thread. Restarting `Dobby.Home` stops `DobbyAgent` with everything
  else, and a request cannot survive its own agent being stopped — so a
  confirmation that restarted the house immediately would write the file
  correctly and then lose the sentence saying so. A browser is not inside the
  request it is changing; a conversation is.

  So the file is written, validated, and announced synchronously, and the house
  is told to catch up once the turn that changed it has finished
  (`Dobby.Conversation.Turn`). `:idle` when there is nothing waiting, which is
  every turn but the rare one.
  """
  @spec catch_up(GenServer.server()) :: :idle | {:ok, Applied.t()} | {:error, String.t()}
  def catch_up(server \\ __MODULE__), do: GenServer.call(server, :catch_up, 30_000)

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.config, state}

  def handle_call({:save, incoming, opts}, _from, state) do
    persist(incoming, opts, state)
  end

  def handle_call({:update, updater, opts}, _from, state) do
    case updater.(state.config) do
      {:ok, %HomeConfig{} = incoming} -> persist(incoming, opts, state)
      {:error, reason} when is_binary(reason) -> {:reply, {:error, reason}, state}
      other -> {:reply, {:error, "configuration update returned #{inspect(other)}"}, state}
    end
  end

  def handle_call(:catch_up, _from, %{pending_house: nil} = state), do: {:reply, :idle, state}

  def handle_call(:catch_up, _from, state) do
    %Applied{config: config} = state.pending_house

    case restart_house() do
      {:ok, applied} ->
        applied = %Applied{config: config, applied: applied}
        ConfigEvents.applied(applied)
        {:reply, {:ok, applied}, %{state | pending_house: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | pending_house: nil}}
    end
  end

  defp persist(incoming, opts, state) do
    case write_and_apply(state.config, incoming, opts) do
      {:ok, %Applied{} = applied} ->
        pending = pending_house(state.pending_house, applied)
        {:reply, {:ok, applied}, %{state | config: applied.config, pending_house: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A later save cannot make the deferred result point back at an older file.
  # A synchronous house restart catches up every house change already in the
  # writer and clears the debt. A system-only save keeps the debt but advances
  # the configuration that the catch-up event will publish.
  defp pending_house(previous, %Applied{} = applied) do
    cond do
      :house in applied.applied -> nil
      :house in applied.on_restart -> applied
      previous != nil -> %{previous | config: applied.config}
      true -> nil
    end
  end

  defp write_and_apply(previous, incoming, opts) do
    with :ok <- writable(incoming),
         {:ok, manifest} <- HomeConfig.validate(incoming),
         :ok <- write(incoming) do
      apply_changes(previous, incoming, manifest, opts)
    end
  end

  defp write(%HomeConfig{path: path} = config) do
    temporary = path <> ".writing-#{System.unique_integer([:positive])}"

    # Beside the file rather than in /tmp, deliberately: rename is only atomic
    # within one filesystem, and across one it silently becomes copy-then-delete.
    case File.write(temporary, HomeConfig.to_yaml(config)) do
      :ok -> rename(temporary, path)
      {:error, reason} -> {:error, "could not write #{path}: #{message(reason)}"}
    end
  end

  defp rename(temporary, path) do
    case File.rename(temporary, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not replace #{path}: #{message(reason)}"}
    end
  end

  defp message(reason), do: reason |> :file.format_error() |> to_string()

  # -- applying --------------------------------------------------------------

  defp apply_changes(previous, incoming, manifest, opts) do
    {live, later, overridden} = apply_system(previous.system, incoming.system)

    case apply_house(previous, incoming, manifest, opts) do
      {:ok, house, waiting} ->
        applied = %Applied{
          config: incoming,
          applied: house ++ live,
          on_restart: waiting ++ later,
          overridden: overridden
        }

        if Applied.changed?(applied), do: ConfigEvents.applied(applied)
        {:ok, applied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_house(%{house: house}, %{house: house}, _manifest, _opts), do: {:ok, [], []}

  defp apply_house(_previous, _incoming, manifest, opts) do
    Application.put_env(:dobby, Dobby.Home, manifest)

    # Deferred, the manifest is already the applied one and only the processes
    # are behind — which is precisely the state an external hand edit leaves the
    # house in until it restarts, so it is a state the design already accepts.
    if Keyword.get(opts, :defer_house, false) do
      {:ok, [], [:house]}
    else
      case restart_house() do
        {:ok, house} -> {:ok, house, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp restart_house do
    case Dobby.Home.restart() do
      {:ok, _pid} ->
        {:ok, [:house]}

      {:error, reason} ->
        # The file is already the new house, which is the truthful state: the
        # description changed and the house would not come up on it. Saying so
        # is better than a silent half-applied save.
        {:error, "the house was written but would not restart: #{inspect(reason)}"}
    end
  end

  # The `:capable` alias is a system setting that is only ever read at the
  # moment it is used, which is exactly why design §2.1 made the agent name an
  # alias instead of a provider: swapping the model is configuration, and here
  # it is configuration that does not need a restart. `reasoning` and `routing`
  # reach the model the same way, as options on each request.
  defp apply_system(previous, incoming) do
    exported_model = System.get_env("DOBBY_MODEL")

    live_model =
      if incoming.model != previous.model and incoming.model != nil and is_nil(exported_model) do
        Application.put_env(:jido_ai, :model_aliases, %{capable: incoming.model})
        [:model]
      else
        []
      end

    # Put as one value even when one field changed: what the model is told is
    # the section's whole answer, and `HomeConfig.System.llm_opts/1` is the one
    # place the file's words become the provider's.
    live_options =
      for field <- [:reasoning, :routing],
          Map.get(incoming, field) != Map.get(previous, field),
          do: field

    if live_options != [] do
      Application.put_env(:dobby, :llm_opts, HomeConfig.System.llm_opts(incoming))
    end

    live = live_model ++ live_options

    # A model *removed* is the committed default coming back, and the committed
    # default is a compile-time value this process no longer holds. So it waits,
    # with everything else that is a property of a socket already open.
    changed_model? = incoming.model != previous.model

    overridden =
      if changed_model? and not is_nil(exported_model), do: [:model], else: []

    later =
      [
        {:model, changed_model? and incoming.model == nil and is_nil(exported_model)},
        {:port, incoming.port != previous.port},
        {:lan, incoming.lan != previous.lan},
        {:hostname, incoming.hostname != previous.hostname}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {live, later, overridden}
  end
end
