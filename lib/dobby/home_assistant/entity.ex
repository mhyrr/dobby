defmodule Dobby.HomeAssistant.Entity do
  @moduledoc """
  One thing Home Assistant knows about, as Dobby's boundary reports it (TK-010).

  This is still a projection rather than HA's whole state object. Alongside the
  state and human name, it keeps the small part of the entity registry needed
  to recognize one physical device across several entities: `device_id`, the
  integration platform, and whether an entity is primary or diagnostic. A
  doorbell's ring event, camera, and motion sensor can then become one proposed
  Dobby device without Dobby copying Home Assistant's device registry.

  ## Attribute keys

  Both, always. Real Home Assistant speaks JSON and its attribute keys are
  strings; the rig's fixtures write atoms because that is pleasant in Elixir,
  and `Dobby.HomeAssistant.dispatch_state_changed/4` already normalizes on the
  way to a device agent. `from_attributes/3` does the same job here so that a
  fixture and a house produce the same struct.
  """

  @enforce_keys [:entity_id]
  defstruct [
    :entity_id,
    :state,
    :friendly_name,
    :device_class,
    :device_id,
    :platform,
    :entity_category,
    :supported_features
  ]

  @type t :: %__MODULE__{
          entity_id: String.t(),
          state: String.t() | nil,
          friendly_name: String.t() | nil,
          device_class: String.t() | nil,
          device_id: String.t() | nil,
          platform: String.t() | nil,
          entity_category: String.t() | nil,
          supported_features: non_neg_integer() | nil
        }

  @doc """
  Builds an entity from state and the matching entity-registry entry.

  The registry entry is optional because not every HA entity is registered.
  The state attributes remain the authority for capabilities that can change
  while HA runs, such as `supported_features`.
  """
  @spec from_attributes(String.t(), String.t() | nil, map(), map()) :: t()
  def from_attributes(entity_id, state, attributes, registry_entry \\ %{})
      when is_binary(entity_id) do
    %__MODULE__{
      entity_id: entity_id,
      state: state,
      friendly_name: attribute(attributes, "friendly_name"),
      device_class:
        attribute(attributes, "device_class") || attribute(registry_entry, "device_class"),
      device_id: attribute(registry_entry, "device_id"),
      platform: attribute(registry_entry, "platform"),
      entity_category: attribute(registry_entry, "entity_category"),
      supported_features: integer_attribute(attributes, "supported_features")
    }
  end

  @doc """
  The Home Assistant domain an entity belongs to — `climate`, `light`, `vacuum`.

  The part before the dot, which is HA's own grammar rather than a convention
  Dobby invented.
  """
  @spec domain(t()) :: String.t()
  def domain(%__MODULE__{entity_id: entity_id}) do
    case String.split(entity_id, ".", parts: 2) do
      [domain, _rest] -> domain
      _no_dot -> entity_id
    end
  end

  @doc """
  What a person would call this, falling back to the id.

  A household names its entities in Home Assistant, and that name is the best
  guess Dobby has at the words they actually say. It is a *suggestion*: the
  name a device answers to is the household's to state (TK-010's load-bearing
  half), and this only saves them typing it twice.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{friendly_name: name}) when is_binary(name) and name != "", do: name
  def label(%__MODULE__{entity_id: entity_id}), do: entity_id

  @doc """
  Applies entity-registry metadata to a state Dobby already remembers.

  Registry and state results arrive independently over the WebSocket. This
  lets either arrive first without retaining Home Assistant's raw state map.
  """
  @spec enrich(t(), map()) :: t()
  def enrich(%__MODULE__{} = entity, registry_entry) when is_map(registry_entry) do
    %{
      entity
      | device_class: entity.device_class || attribute(registry_entry, "device_class"),
        device_id: attribute(registry_entry, "device_id"),
        platform: attribute(registry_entry, "platform"),
        entity_category: attribute(registry_entry, "entity_category")
    }
  end

  @doc """
  The key discovery uses to keep one HA device together.

  Entities without a registry device stay alone. Grouping those by name or
  integration would turn coincidence into identity.
  """
  @spec group_key(t()) :: {:device, String.t()} | {:entity, String.t()}
  def group_key(%__MODULE__{device_id: device_id}) when is_binary(device_id),
    do: {:device, device_id}

  def group_key(%__MODULE__{entity_id: entity_id}), do: {:entity, entity_id}

  defp attribute(attributes, key) when is_map(attributes) do
    Enum.find_value(attributes, fn {name, value} ->
      if to_string(name) == key, do: stringify(value)
    end)
  end

  defp attribute(_attributes, _key), do: nil

  defp integer_attribute(attributes, key) when is_map(attributes) do
    Enum.find_value(attributes, fn {name, value} ->
      if to_string(name) == key and is_integer(value), do: value
    end)
  end

  defp integer_attribute(_attributes, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(_value), do: nil
end
