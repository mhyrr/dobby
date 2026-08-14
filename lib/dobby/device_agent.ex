defmodule Dobby.DeviceAgent do
  @moduledoc """
  The extension contract for a reusable device-agent module (design §4.2).

  A module implementing this behaviour is the *behavior* half of a device —
  `Thermostat`, `WifiEndpoint`. The *instance* half is a `Dobby.Home.Device`
  entry in the manifest. Adding a new kind of device to Dobby means writing
  one of these plus its actions; no central switch statement changes.
  """

  alias Dobby.Home.Device

  @doc """
  Validates the manifest entry for one instance of this device type.

  Called during `Dobby.Home` bootstrap, before any agent starts. Return an
  error naming the offending field — the message reaches the operator as a
  startup failure.
  """
  @callback validate_device(Device.t()) :: :ok | {:error, String.t()}

  @doc """
  The starting agent state for one instance, built from its manifest entry.

  Identity and configuration only. Everything observable — availability,
  readings, capabilities — starts empty and arrives from Home Assistant.
  """
  @callback initial_state(Device.t()) :: map()

  @doc """
  The tool modules this device type advertises to `DobbyAgent`.

  These become the model's only means of acting on this kind of device.
  """
  @callback tools() :: [module()]

  @doc """
  The HA entity bindings this device type subscribes to, as binding keys.

  `Dobby.Home` uses this to build the client's entity-to-agent routing table.
  """
  @callback subscribed_bindings() :: [atom()]
end
