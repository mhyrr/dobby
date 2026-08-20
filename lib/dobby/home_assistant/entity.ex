defmodule Dobby.HomeAssistant.Entity do
  @moduledoc """
  One thing Home Assistant knows about, as Dobby's boundary reports it (TK-010).

  Deliberately four fields and not HA's whole state object. Discovery asks one
  question — "what is this, and what would a person call it?" — and the answer
  is the entity id, whatever HA is currently saying about it, the friendly name
  somebody already typed into Home Assistant, and the device class that tells a
  `binary_sensor` apart from every other `binary_sensor`.

  Keeping it to four means the real client can remember every entity in a
  household without holding a copy of Home Assistant, and means the fake and
  the real client answer in exactly the same shape.

  ## Attribute keys

  Both, always. Real Home Assistant speaks JSON and its attribute keys are
  strings; the rig's fixtures write atoms because that is pleasant in Elixir,
  and `Dobby.HomeAssistant.dispatch_state_changed/4` already normalizes on the
  way to a device agent. `from_attributes/3` does the same job here so that a
  fixture and a house produce the same struct.
  """

  @enforce_keys [:entity_id]
  defstruct [:entity_id, :state, :friendly_name, :device_class]

  @type t :: %__MODULE__{
          entity_id: String.t(),
          state: String.t() | nil,
          friendly_name: String.t() | nil,
          device_class: String.t() | nil
        }

  @doc """
  Builds an entity from an id, a state, and Home Assistant's attribute map.
  """
  @spec from_attributes(String.t(), String.t() | nil, map()) :: t()
  def from_attributes(entity_id, state, attributes) when is_binary(entity_id) do
    %__MODULE__{
      entity_id: entity_id,
      state: state,
      friendly_name: attribute(attributes, "friendly_name"),
      device_class: attribute(attributes, "device_class")
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

  defp attribute(attributes, key) when is_map(attributes) do
    Enum.find_value(attributes, fn {name, value} ->
      if to_string(name) == key, do: stringify(value)
    end)
  end

  defp attribute(_attributes, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(_value), do: nil
end
