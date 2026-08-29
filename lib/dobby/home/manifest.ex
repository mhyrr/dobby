defmodule Dobby.Home.Manifest do
  @moduledoc """
  Turns the raw manifest read from `config/homes/*.exs` into validated structs,
  or refuses.

  Validation is deliberately loud. Design §4.1: a typo should fail application
  startup naming the exact device and field, because silently skipping a
  thermostat would make the house unusually philosophical about heating.
  """

  alias Dobby.Home.Device

  @enforce_keys [:id, :name, :timezone]
  defstruct [:id, :name, :timezone, home_assistant: [], networks: [], devices: []]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          timezone: String.t(),
          home_assistant: keyword(),
          networks: [map()],
          devices: [Device.t()]
        }

  @doc """
  Builds a manifest from raw keyword configuration.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(config) when is_list(config) do
    with {:ok, id} <- fetch(config, :id),
         {:ok, name} <- fetch(config, :name),
         {:ok, timezone} <- fetch(config, :timezone),
         networks = Keyword.get(config, :networks, []),
         {:ok, devices} <- load_devices(Keyword.get(config, :devices, []), networks) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         timezone: timezone,
         home_assistant: Keyword.get(config, :home_assistant, []),
         networks: networks,
         devices: devices
       }}
    end
  end

  def load(other), do: {:error, "expected keyword configuration, got: #{inspect(other)}"}

  @doc """
  Builds a manifest or raises. This is the bootstrap path — an invalid house
  should take the application down with it.
  """
  @spec load!(keyword()) :: t()
  def load!(config) do
    case load(config) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid home manifest: #{reason}"
    end
  end

  @doc """
  Finds a device by its stable Dobby ID.
  """
  @spec fetch_device(t(), String.t()) :: {:ok, Device.t()} | :error
  def fetch_device(%__MODULE__{devices: devices}, id) do
    case Enum.find(devices, &(&1.id == id)) do
      nil -> :error
      device -> {:ok, device}
    end
  end

  @doc """
  Maps every bound HA entity to the Dobby ID of the agent that owns it.

  This is the client's routing table (design §4.1 step 6): HA speaks in
  `climate.main_floor`, Dobby speaks in `thermostat:main`, and this is where
  the two are reconciled.
  """
  @spec routing_table(t()) :: %{String.t() => String.t()}
  def routing_table(%__MODULE__{devices: devices}) do
    for device <- devices,
        key <- device.agent_module.subscribed_bindings(),
        entity_id = Map.get(device.bindings, key),
        entity_id != nil,
        into: %{} do
      {entity_id, device.id}
    end
  end

  # -- devices ---------------------------------------------------------------

  defp load_devices(entries, networks) when is_list(entries) do
    with {:ok, devices} <- map_ok(entries, &load_device(&1, networks)),
         :ok <- reject_duplicate_ids(devices),
         :ok <- reject_duplicate_names(devices) do
      {:ok, devices}
    end
  end

  defp load_devices(other, _networks),
    do: {:error, "devices must be a list, got: #{inspect(other)}"}

  defp load_device(%{} = entry, networks) do
    with {:ok, id} <- fetch_device_key(entry, :id, "<unknown>"),
         {:ok, name} <- fetch_device_key(entry, :name, id),
         {:ok, agent_module} <- fetch_device_key(entry, :agent_module, id),
         {:ok, bindings} <- fetch_device_key(entry, :bindings, id),
         :ok <- validate_agent_module(agent_module, id),
         :ok <- validate_hands_only(Map.get(entry, :hands_only, false), id),
         :ok <- validate_network(Map.get(entry, :network), networks, id) do
      device = %Device{
        id: id,
        name: name,
        agent_module: agent_module,
        bindings: bindings,
        network: Map.get(entry, :network),
        ha_integration: Map.get(entry, :ha_integration),
        aliases: Map.get(entry, :aliases, []),
        hands_only: Map.get(entry, :hands_only, false),
        settings: Map.get(entry, :settings, %{})
      }

      case agent_module.validate_device(device) do
        :ok -> {:ok, device}
        {:error, reason} -> {:error, "device #{inspect(id)}: #{reason}"}
      end
    end
  end

  defp load_device(other, _networks),
    do: {:error, "each device must be a map, got: #{inspect(other)}"}

  defp fetch_device_key(entry, key, id) do
    case Map.fetch(entry, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "device #{inspect(id)} is missing required field #{inspect(key)}"}
    end
  end

  defp validate_agent_module(module, id) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, "device #{inspect(id)}: unknown agent_module #{inspect(module)}"}

      not function_exported?(module, :validate_device, 1) ->
        {:error, "device #{inspect(id)}: #{inspect(module)} does not implement Dobby.DeviceAgent"}

      true ->
        :ok
    end
  end

  defp validate_agent_module(other, id),
    do: {:error, "device #{inspect(id)}: agent_module must be a module, got: #{inspect(other)}"}

  defp validate_network(nil, _networks, _id), do: :ok

  defp validate_network(network, networks, id) do
    if Enum.any?(networks, &(&1.id == network)) do
      :ok
    else
      {:error, "device #{inspect(id)}: unknown network #{inspect(network)}"}
    end
  end

  defp validate_hands_only(value, _id) when is_boolean(value), do: :ok

  defp validate_hands_only(value, id),
    do:
      {:error, "device #{inspect(id)}: hands_only must be true or false, got: #{inspect(value)}"}

  defp reject_duplicate_ids(devices) do
    case duplicates(Enum.map(devices, & &1.id)) do
      [] -> :ok
      dupes -> {:error, "duplicate device ids: #{inspect(dupes)}"}
    end
  end

  # Names and aliases share one namespace because the model resolves a spoken
  # name to exactly one device. Two devices answering to "the thermostat" is a
  # configuration error, not a clarification opportunity.
  defp reject_duplicate_names(devices) do
    case devices
         |> Enum.flat_map(&Device.names/1)
         |> Enum.map(&String.downcase/1)
         |> duplicates() do
      [] -> :ok
      dupes -> {:error, "duplicate device names or aliases: #{inspect(dupes)}"}
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # -- helpers ---------------------------------------------------------------

  defp fetch(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "missing required key #{inspect(key)}"}
    end
  end

  defp map_ok(entries, fun) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
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
end
