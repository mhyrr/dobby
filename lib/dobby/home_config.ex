defmodule Dobby.HomeConfig do
  @moduledoc """
  The one file a household owns, read (TK-018).

  Two top-level sections. `house` is what the house contains — the same thing
  `config/homes/*.exs` has always described. `system` is the box: the model
  behind the `:capable` alias, the port, whether to answer on the household
  network. Operator business — the database, the secret key base — is not in
  here and is not meant to be.

  ## Two formats, on purpose

  `.yaml` is the canonical one: the audience already speaks Home Assistant's
  `configuration.yaml`, and a data file is a file a machine can write back, which
  is what /admin and /house are built on (`Dobby.HomeConfig.Writer`).

  `.exs` is still read, and not only out of politeness. The rig manifest is
  Elixir and stays Elixir — the test suite pins it, builds manifests by hand,
  and has no business round-tripping through a file — and Greg's own house was
  an `.exs` until the migration that introduced this module. Both formats come
  out as the same keyword list, which is exactly the shape `Dobby.Home` has
  always read, so nothing downstream knows which one it got.

  ## Where validation stops

  This module validates one entry at a time: the scaffolding against its own
  schema, each device against its type's (`c:Dobby.DeviceAgent.config_schema/0`
  for the settings a household narrows, `c:Dobby.DeviceAgent.validate_device/1`
  for the rules that span two fields). Errors name the field, because a typo
  should fail saying which word was wrong.

  What it does *not* do is judge the house as a whole — two devices answering to
  "the thermostat", a device pointing at a network nobody declared. That is
  `Dobby.Home.Manifest`'s job, it already does it on every boot, and it has to
  keep doing it for manifests built in Elixir that never touched a file.

  ## Secrets

  Values are held exactly as the file wrote them, `env:DOBBY_HA_TOKEN` and all.
  Resolution happens in `manifest/1`, on the way to `Dobby.Home` — never on the
  way in — so that a struct loaded from a file and written back out cannot put a
  token in a file meant to be shared.
  """

  alias Dobby.Home.Device
  alias Dobby.HomeConfig.Resolver
  alias Dobby.HomeConfig.Types

  @enforce_keys [:path, :format]
  defstruct [:path, :format, system: %Dobby.HomeConfig.System{}, house: []]

  @type t :: %__MODULE__{
          path: Path.t(),
          format: :yaml | :exs,
          system: Dobby.HomeConfig.System.t(),
          house: keyword()
        }

  @sections ~w(house system)
  @house_keys ~w(id name timezone home_assistant networks devices)
  @device_keys ~w(id type name aliases network ha_integration bindings settings)
  @home_assistant_keys ~w(url token)
  @network_keys ~w(id name ssid)

  # What a machine-written file says for itself. No timestamp: the writer runs
  # on every edit and a header that changed every time would make the file
  # noisy in exactly the place a person looks to see what actually changed.
  @header [
    "This file is written by Dobby, and rewritten in full every time the",
    "house or the system panel is changed. Comments and key order do not",
    "survive that — the file is the record, not the document.",
    "",
    "Editing it by hand is fine and supported: the changes apply when Dobby",
    "restarts. Credentials belong in the environment, referenced from here as",
    "`env:NAME`, so this file stays safe to share."
  ]

  @doc """
  Reads and validates a home file, in either format.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with :ok <- exists(path),
         {:ok, format} <- format(path),
         {:ok, raw} <- read(format, path) do
      build(path, format, raw)
    end
  end

  @doc """
  Reads a home file or refuses to have a house.

  The bootstrap path, and loud on purpose: a house described wrongly should take
  the application down naming the field, which is the posture
  `Dobby.Home.Manifest` already takes about devices.
  """
  @spec load!(Path.t()) :: t()
  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid home configuration in #{path}: #{reason}"
    end
  end

  @doc """
  The manifest keyword `Dobby.Home` reads, with `env:` references resolved.

  Raises when a referenced variable is unset — see `Dobby.HomeConfig.Resolver`,
  which owns that message.
  """
  @spec manifest(t()) :: keyword()
  def manifest(%__MODULE__{house: house}), do: Resolver.resolve!(house)

  @doc """
  Loads a file straight through to the manifest `Dobby.Home` reads.

  What `config/runtime.exs` calls.
  """
  @spec manifest!(Path.t()) :: keyword()
  def manifest!(path), do: path |> load!() |> manifest()

  @doc """
  Renders a configuration as the YAML file it came from, or will become.

  The inverse of `load/1` and it belongs next to it, though the only caller is
  `Dobby.HomeConfig.Writer` — which owns the file, the atomicity, and the
  applying, and has no business also owning the shape.

  Secrets are written as the references they are. A configuration loaded from
  `.exs` can be rendered too, which is how a house migrates, but the two
  Elixir-only keys — the client module and the fake's seeded entities — are
  dropped: a YAML house is a real house.
  """
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{} = config) do
    document =
      %{"house" => house_yaml(config.house)}
      |> put_present("system", system_yaml(config.system))

    Ymlr.document!({@header, document})
  end

  # -- reading ---------------------------------------------------------------

  defp exists(path) do
    if File.regular?(path), do: :ok, else: {:error, "no such file"}
  end

  defp format(path) do
    case Path.extname(path) do
      ext when ext in [".yaml", ".yml"] -> {:ok, :yaml}
      ".exs" -> {:ok, :exs}
      other -> {:error, "a home file must be .yaml or .exs, this one is #{inspect(other)}"}
    end
  end

  defp read(:yaml, path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{} = raw} -> {:ok, raw}
      {:ok, other} -> {:error, "expected a mapping at the top level, got: #{inspect(other)}"}
      {:error, %{message: message}} -> {:error, message}
    end
  end

  defp read(:exs, path) do
    case get_in(Config.Reader.read!(path), [:dobby, Dobby.Home]) do
      config when is_list(config) -> {:ok, config}
      nil -> {:error, "this file configures no `:dobby, Dobby.Home`"}
      other -> {:error, "expected keyword configuration, got: #{inspect(other)}"}
    end
  end

  # -- building --------------------------------------------------------------

  defp build(path, :yaml, raw) do
    with :ok <- only_known(raw, @sections, "the file"),
         {:ok, system} <- Dobby.HomeConfig.System.load(Map.get(raw, "system") || %{}),
         {:ok, section} <- fetch_map(raw, "house", "the file"),
         {:ok, house} <- yaml_house(section) do
      {:ok, %__MODULE__{path: path, format: :yaml, system: system, house: house}}
    end
  end

  # The `.exs` form predates the system section and carries only a house, which
  # is why the environment still has the last word on the model and the LAN when
  # one is in use.
  defp build(path, :exs, raw) do
    with {:ok, house} <- exs_house(raw) do
      {:ok, %__MODULE__{path: path, format: :exs, house: house}}
    end
  end

  defp yaml_house(raw) do
    with :ok <- only_known(raw, @house_keys, "house"),
         {:ok, id} <- fetch_string(raw, "id", "house"),
         {:ok, name} <- fetch_string(raw, "name", "house"),
         {:ok, timezone} <- fetch_string(raw, "timezone", "house"),
         {:ok, home_assistant} <- yaml_home_assistant(Map.get(raw, "home_assistant") || %{}),
         {:ok, networks} <- map_ok(Map.get(raw, "networks") || [], &yaml_network/1),
         {:ok, devices} <- map_ok(Map.get(raw, "devices") || [], &yaml_device/1) do
      {:ok,
       [
         id: id,
         name: name,
         timezone: timezone,
         home_assistant: home_assistant,
         networks: networks,
         devices: devices
       ]}
    end
  end

  # The client is not the household's to choose. A YAML house talks to a real
  # Home Assistant; the fake is a test fixture and lives in Elixir, where the
  # tests that use it already live.
  defp yaml_home_assistant(raw) when is_map(raw) do
    with :ok <- only_known(raw, @home_assistant_keys, "home_assistant"),
         {:ok, url} <- fetch_string(raw, "url", "home_assistant"),
         {:ok, token} <- optional_string(raw, "token", "home_assistant") do
      token_option = if token, do: [token: token], else: []
      {:ok, [client: Dobby.HomeAssistant.Client, url: url] ++ token_option}
    end
  end

  defp yaml_home_assistant(other),
    do: {:error, "home_assistant must be a mapping, got: #{inspect(other)}"}

  defp yaml_network(raw) when is_map(raw) do
    with :ok <- only_known(raw, @network_keys, "network"),
         {:ok, id} <- fetch_string(raw, "id", "network"),
         {:ok, name} <- optional_string(raw, "name", "network #{inspect(id)}"),
         {:ok, ssid} <- optional_string(raw, "ssid", "network #{inspect(id)}") do
      {:ok, %{id: id} |> put_present(:name, name) |> put_present(:ssid, ssid)}
    end
  end

  defp yaml_network(other), do: {:error, "each network must be a mapping, got: #{inspect(other)}"}

  defp yaml_device(raw) when is_map(raw) do
    where = device_label(Map.get(raw, "id"))

    with :ok <- only_known(raw, @device_keys, where),
         {:ok, id} <- fetch_string(raw, "id", where),
         {:ok, type} <- fetch_string(raw, "type", where),
         {:ok, module} <- fetch_type(type, where),
         {:ok, name} <- fetch_string(raw, "name", where),
         {:ok, aliases} <- string_list(Map.get(raw, "aliases") || [], where, "aliases"),
         {:ok, bindings} <- yaml_bindings(module, Map.get(raw, "bindings") || %{}, where),
         {:ok, settings} <- yaml_settings(module, Map.get(raw, "settings") || %{}, where),
         {:ok, network} <- optional_string(raw, "network", where),
         {:ok, integration} <- optional_string(raw, "ha_integration", where) do
      %{
        id: id,
        name: name,
        aliases: aliases,
        agent_module: module,
        bindings: bindings,
        settings: settings
      }
      |> put_present(:network, network)
      |> put_present(:ha_integration, integration)
      |> validated(module, where)
    end
  end

  defp yaml_device(other), do: {:error, "each device must be a mapping, got: #{inspect(other)}"}

  # Binding keys are closed by the type, which is what keeps a file's words out
  # of the atom table: `climate` is an atom because Thermostat says it has one,
  # not because somebody wrote it down.
  defp yaml_bindings(module, raw, where) when is_map(raw) do
    known = Map.new(module.subscribed_bindings(), &{Atom.to_string(&1), &1})

    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case {Map.fetch(known, to_string(key)), value} do
        {{:ok, binding}, entity_id} when is_binary(entity_id) ->
          {:cont, {:ok, Map.put(acc, binding, entity_id)}}

        {{:ok, _binding}, other} ->
          {:halt,
           {:error, "#{where}: bindings.#{key} must be an entity id, got: #{inspect(other)}"}}

        {:error, _value} ->
          {:halt,
           {:error,
            "#{where}: unknown binding #{inspect(to_string(key))}; " <>
              "a #{module.config_type()} binds: #{Enum.map_join(known, ", ", &elem(&1, 0))}"}}
      end
    end)
  end

  defp yaml_bindings(_module, other, where),
    do: {:error, "#{where}: bindings must be a mapping, got: #{inspect(other)}"}

  defp yaml_settings(module, raw, where) when is_map(raw) do
    schema = module.config_schema()
    known = Map.new(schema, fn {key, _spec} -> {Atom.to_string(key), key} end)

    with {:ok, pairs} <- known_settings(raw, known, module, where) do
      validate_settings(pairs, schema, where)
    end
  end

  defp yaml_settings(_module, other, where),
    do: {:error, "#{where}: settings must be a mapping, got: #{inspect(other)}"}

  defp known_settings(raw, known, module, where) do
    Enum.reduce_while(raw, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(known, to_string(key)) do
        {:ok, setting} ->
          {:cont, {:ok, [{setting, value} | acc]}}

        :error ->
          {:halt,
           {:error,
            "#{where}: unknown setting #{inspect(to_string(key))}; " <>
              settings_roll_call(module, known)}}
      end
    end)
  end

  defp settings_roll_call(module, known) when map_size(known) == 0,
    do: "a #{module.config_type()} takes no settings"

  defp settings_roll_call(module, known),
    do: "a #{module.config_type()} takes: " <> Enum.map_join(known, ", ", &elem(&1, 0))

  defp validate_settings(pairs, schema, where) do
    case NimbleOptions.validate(pairs, schema) do
      {:ok, options} ->
        {:ok, Map.new(options)}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, "#{where}: settings: #{message}"}
    end
  end

  # -- the Elixir format -----------------------------------------------------

  defp exs_house(config) when is_list(config) do
    with {:ok, id} <- fetch_key(config, :id, "house"),
         {:ok, name} <- fetch_key(config, :name, "house"),
         {:ok, timezone} <- fetch_key(config, :timezone, "house"),
         {:ok, devices} <- map_ok(Keyword.get(config, :devices, []), &exs_device/1) do
      {:ok,
       [
         id: id,
         name: name,
         timezone: timezone,
         home_assistant: Keyword.get(config, :home_assistant, []),
         networks: Keyword.get(config, :networks, []),
         devices: devices
       ]}
    end
  end

  defp exs_house(other), do: {:error, "expected keyword configuration, got: #{inspect(other)}"}

  # An Elixir home names the module directly, which is the thing YAML exists to
  # stop a stranger having to do — but it still has to name one Dobby offers,
  # so the same registry answers in both directions.
  defp exs_device(%{} = entry) do
    where = device_label(Map.get(entry, :id))

    with {:ok, module} <- exs_type(Map.get(entry, :agent_module), where),
         {:ok, settings} <- exs_settings(module, Map.get(entry, :settings) || %{}, where) do
      entry
      |> Map.put(:settings, settings)
      |> validated(module, where)
    end
  end

  defp exs_device(other), do: {:error, "each device must be a map, got: #{inspect(other)}"}

  defp exs_type(module, where) when is_atom(module) and module != nil do
    case Types.fetch_name(module) do
      {:ok, _name} -> {:ok, module}
      :error -> {:error, "#{where}: #{inspect(module)} is not a device type Dobby offers"}
    end
  end

  defp exs_type(nil, where), do: {:error, "#{where} is missing required field :agent_module"}

  defp exs_type(other, where),
    do: {:error, "#{where}: agent_module must be a module, got: #{inspect(other)}"}

  defp exs_settings(module, raw, where) when is_map(raw) do
    schema = module.config_schema()
    known = Map.new(schema, fn {key, _spec} -> {Atom.to_string(key), key} end)

    with {:ok, pairs} <- known_settings(raw, known, module, where) do
      validate_settings(pairs, schema, where)
    end
  end

  defp exs_settings(_module, other, where),
    do: {:error, "#{where}: settings must be a map, got: #{inspect(other)}"}

  # -- per-type validation ---------------------------------------------------

  # The type has the last word on its own entry. `config_schema/0` said the
  # settings are numbers; this is where a minimum above a maximum is refused,
  # and where a missing binding is named.
  defp validated(entry, module, where) do
    device = %Device{
      id: Map.get(entry, :id),
      name: Map.get(entry, :name),
      agent_module: module,
      bindings: Map.get(entry, :bindings) || %{},
      network: Map.get(entry, :network),
      ha_integration: Map.get(entry, :ha_integration),
      aliases: Map.get(entry, :aliases) || [],
      settings: Map.get(entry, :settings) || %{}
    }

    cond do
      not is_binary(device.id) -> {:error, "#{where} is missing required field :id"}
      not is_binary(device.name) -> {:error, "#{where} is missing required field :name"}
      true -> per_type(device, module, entry, where)
    end
  end

  defp per_type(device, module, entry, where) do
    case module.validate_device(device) do
      :ok -> {:ok, entry}
      {:error, reason} -> {:error, "#{where}: #{reason}"}
    end
  end

  defp fetch_type(name, where) do
    case Types.fetch(name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, "#{where}: unknown type #{inspect(name)}; #{Types.roll_call()}"}
    end
  end

  # -- writing ---------------------------------------------------------------

  defp house_yaml(house) do
    %{
      "id" => Keyword.fetch!(house, :id),
      "name" => Keyword.fetch!(house, :name),
      "timezone" => Keyword.fetch!(house, :timezone),
      "home_assistant" => home_assistant_yaml(Keyword.get(house, :home_assistant, [])),
      "devices" => Enum.map(Keyword.get(house, :devices, []), &device_yaml/1)
    }
    |> put_present("networks", networks_yaml(Keyword.get(house, :networks, [])))
  end

  defp home_assistant_yaml(home_assistant) do
    %{"url" => Keyword.get(home_assistant, :url)}
    |> put_present("token", Keyword.get(home_assistant, :token))
  end

  defp networks_yaml([]), do: nil

  defp networks_yaml(networks) do
    Enum.map(networks, fn network ->
      Map.new(network, fn {key, value} -> {to_string(key), scalar(value)} end)
    end)
  end

  defp device_yaml(entry) do
    {:ok, type} = Types.fetch_name(entry.agent_module)

    %{
      "id" => entry.id,
      "type" => type,
      "name" => entry.name,
      "bindings" => Map.new(entry.bindings, fn {key, value} -> {to_string(key), value} end)
    }
    |> put_present("aliases", presence(Map.get(entry, :aliases, [])))
    |> put_present("network", scalar(Map.get(entry, :network)))
    |> put_present("ha_integration", scalar(Map.get(entry, :ha_integration)))
    |> put_present("settings", settings_yaml(Map.get(entry, :settings, %{})))
  end

  defp settings_yaml(settings) when map_size(settings) == 0, do: nil

  defp settings_yaml(settings),
    do: Map.new(settings, fn {key, value} -> {to_string(key), value} end)

  defp system_yaml(system) do
    system
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> presence()
  end

  # -- helpers ---------------------------------------------------------------

  defp device_label(id) when is_binary(id), do: "device #{inspect(id)}"
  defp device_label(_missing), do: "device <unnamed>"

  defp fetch_map(raw, key, where) do
    case Map.fetch(raw, key) do
      {:ok, %{} = value} ->
        {:ok, value}

      {:ok, other} ->
        {:error, "#{where}: #{inspect(key)} must be a mapping, got: #{inspect(other)}"}

      :error ->
        {:error, "#{where} has no #{inspect(key)} section"}
    end
  end

  defp fetch_string(raw, key, where) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, other} -> {:error, "#{where}: #{inspect(key)} must be text, got: #{inspect(other)}"}
      :error -> {:error, "#{where} is missing required field #{inspect(key)}"}
    end
  end

  defp optional_string(raw, key, where) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, other} -> {:error, "#{where}: #{inspect(key)} must be text, got: #{inspect(other)}"}
      :error -> {:ok, nil}
    end
  end

  defp string_list(values, where, key) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "#{where}: #{key} must all be text, got: #{inspect(values)}"}
    end
  end

  defp string_list(other, where, key),
    do: {:error, "#{where}: #{key} must be a list, got: #{inspect(other)}"}

  defp fetch_key(config, key, where) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{where} is missing required field #{inspect(key)}"}
    end
  end

  defp only_known(raw, keys, where) do
    case Enum.reject(Map.keys(raw), &(to_string(&1) in keys)) do
      [] ->
        :ok

      [unknown | _rest] ->
        {:error,
         "#{where}: unknown key #{inspect(to_string(unknown))}; " <>
           "it holds: #{Enum.join(keys, ", ")}"}
    end
  end

  defp map_ok(entries, fun) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case fun.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_ok(other, _fun), do: {:error, "expected a list, got: #{inspect(other)}"}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp presence(empty) when empty in [[], %{}], do: nil
  defp presence(value), do: value

  defp scalar(nil), do: nil
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value), do: value
end
