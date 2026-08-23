defmodule Dobby.HomeConfig.Types do
  @moduledoc """
  The closed set of device types a home file may name (TK-018).

  A home file says `type: thermostat`. It never says
  `agent_module: Dobby.DeviceAgents.Thermostat`, because somebody describing
  their own house should not have to know that Dobby is written in Elixir, and
  because a file that can name any module is a file that can name any module.

  This is the one central list in a design that otherwise refuses them — see
  `Dobby.DeviceAgent`, whose whole point is that adding a device type touches no
  switch statement. The list is the closure: a type is available because it was
  added here on purpose, and the name it answers to is declared by the module
  itself (`config_type/0`) rather than typed twice.
  """

  @modules [
    Dobby.DeviceAgents.Thermostat,
    Dobby.DeviceAgents.Light,
    Dobby.DeviceAgents.Speaker,
    Dobby.DeviceAgents.Camera,
    Dobby.DeviceAgents.Doorbell,
    Dobby.DeviceAgents.Lock,
    Dobby.DeviceAgents.AccessCover,
    Dobby.DeviceAgents.PowerSwitch,
    Dobby.DeviceAgents.Shade,
    Dobby.DeviceAgents.Fan,
    Dobby.DeviceAgents.EnvironmentMonitor,
    Dobby.DeviceAgents.ContactSensor,
    Dobby.DeviceAgents.OccupancySensor,
    Dobby.DeviceAgents.SafetySensor,
    Dobby.DeviceAgents.Vacuum,
    Dobby.DeviceAgents.WifiEndpoint
  ]

  @doc """
  Every device-agent module a home file can reach.
  """
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc """
  Every type name a home file can write, in the order they are offered.
  """
  @spec names() :: [String.t()]
  def names, do: Enum.map(@modules, & &1.config_type())

  @doc """
  The agent module behind a type name.
  """
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@modules, &(&1.config_type() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def fetch(_other), do: :error

  @doc """
  The type name a module answers to.

  The other direction, and it earns its keep twice: writing a house back out as
  YAML, and reading the `.exs` homes that still name modules directly.
  """
  @spec fetch_name(module()) :: {:ok, String.t()} | :error
  def fetch_name(module) when is_atom(module) do
    if module in @modules, do: {:ok, module.config_type()}, else: :error
  end

  def fetch_name(_other), do: :error

  @doc """
  The list of type names, for an error message that has to say what is on offer.
  """
  @spec roll_call() :: String.t()
  def roll_call, do: "Dobby knows: " <> Enum.join(names(), ", ")
end
