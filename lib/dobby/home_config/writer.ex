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
    {:ok, %{config: starting_config(opts)}}
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
  Whether this is a house Dobby can write at all.

  Asked by the editing surfaces before they offer a control, because a form
  that can only ever be refused is worse than a sentence saying why there is no
  form — the same call `/admin` already makes about a house with nothing
  schedulable. One rule, two readers: the refusal below is this predicate with
  the message attached.
  """
  @spec writable?(HomeConfig.t()) :: boolean()
  def writable?(%HomeConfig{format: format}), do: format == :yaml

  # -- writes ----------------------------------------------------------------

  @doc """
  Writes a configuration and applies as much of it as can be applied.

  Refuses, without touching the file, a house `Dobby.Home.Manifest` would not
  accept or a credential reference the environment cannot answer. Announces on
  `dobby:config` when something actually changed.
  """
  @spec save(GenServer.server(), HomeConfig.t()) :: {:ok, Applied.t()} | {:error, String.t()}
  def save(server \\ __MODULE__, %HomeConfig{} = config) do
    GenServer.call(server, {:save, config}, 30_000)
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.config, state}

  def handle_call({:save, incoming}, _from, state) do
    case write_and_apply(state.config, incoming) do
      {:ok, %Applied{} = applied} -> {:reply, {:ok, applied}, %{state | config: applied.config}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp write_and_apply(previous, incoming) do
    with :ok <- writable(incoming),
         {:ok, manifest} <- resolved(incoming),
         :ok <- house_holds_together(manifest),
         :ok <- write(incoming) do
      apply_changes(previous, incoming, manifest)
    end
  end

  defp writable(%HomeConfig{format: format, path: path} = config) do
    if writable?(config) do
      :ok
    else
      {:error,
       "Dobby writes YAML and #{path} is #{format}; migrate the house to a .yaml file first"}
    end
  end

  # The resolver owns the raise, and at boot a missing credential taking the
  # application down is the right shape. A save is a request, so here the one
  # raise becomes the one refusal, with the same message.
  defp resolved(config) do
    {:ok, HomeConfig.manifest(config)}
  rescue
    error in RuntimeError -> {:error, Exception.message(error)}
  end

  # `Dobby.HomeConfig` validated each entry on the way in. This is the other
  # half — two devices answering to "the thermostat", a device pointing at a
  # network nobody declared — and it is asked before the file is touched, so a
  # house that would not boot is never the house on disk.
  defp house_holds_together(manifest) do
    case Dobby.Home.Manifest.load(manifest) do
      {:ok, _manifest} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp apply_changes(previous, incoming, manifest) do
    {live, later} = apply_system(previous.system, incoming.system)

    case apply_house(previous, incoming, manifest) do
      {:ok, house} ->
        applied = %Applied{config: incoming, applied: house ++ live, on_restart: later}
        if Applied.changed?(applied), do: ConfigEvents.applied(applied)
        {:ok, applied}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_house(%{house: house}, %{house: house}, _manifest), do: {:ok, []}

  defp apply_house(_previous, _incoming, manifest) do
    Application.put_env(:dobby, Dobby.Home, manifest)

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

  # The `:capable` alias is the one system setting that is only ever read at the
  # moment it is used, which is exactly why design §2.1 made the agent name an
  # alias instead of a provider: swapping the model is configuration, and here
  # it is configuration that does not need a restart.
  defp apply_system(previous, incoming) do
    live =
      if incoming.model != previous.model and incoming.model != nil do
        Application.put_env(:jido_ai, :model_aliases, %{capable: incoming.model})
        [:model]
      else
        []
      end

    # A model *removed* is the committed default coming back, and the committed
    # default is a compile-time value this process no longer holds. So it waits,
    # with everything else that is a property of a socket already open.
    later =
      [
        {:model, incoming.model != previous.model and incoming.model == nil},
        {:port, incoming.port != previous.port},
        {:lan, incoming.lan != previous.lan},
        {:hostname, incoming.hostname != previous.hostname}
      ]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    {live, later}
  end
end
