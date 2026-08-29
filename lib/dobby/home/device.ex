defmodule Dobby.Home.Device do
  @moduledoc """
  One physical device Dobby manages.

  This struct is the *instance* — `thermostat:main`, its friendly name, the
  HA entities it is bound to, and the household policy narrowing what it may
  be asked to do. `hands_only` is shared policy because it limits the caller,
  not one device type's capability. The reusable *behavior* lives in
  `agent_module`, and the vendor integration underneath HA is
  `ha_integration`, a profile lookup key and never a subclass (design §4).

  A type-specific setting was rejected. It would make every device module
  repeat a rule whose meaning does not change between a lock and a light, and
  it would leave the shared write protocol unable to answer from one place.
  """

  @enforce_keys [:id, :name, :agent_module, :bindings]
  defstruct [
    :id,
    :name,
    :agent_module,
    :bindings,
    :network,
    :ha_integration,
    aliases: [],
    hands_only: false,
    settings: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          agent_module: module(),
          bindings: %{atom() => String.t()},
          network: atom() | nil,
          ha_integration: atom() | nil,
          aliases: [String.t()],
          hands_only: boolean(),
          settings: map()
        }

  @doc """
  Every name this device answers to, for roster projection and disambiguation.
  """
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{name: name, aliases: aliases}), do: [name | aliases]
end
