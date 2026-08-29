defmodule Dobby.DeviceAgents.Light do
  @moduledoc """
  A light, as Dobby understands one (design §4.2, §7).

  Deterministic and signal-driven, like `Thermostat`: it owns interpretation
  of its HA entity, the decision about what it may be asked to do, and the
  translation of semantic actions into HA service calls. It does not own a
  credential, a connection, or an opinion about language — and deliberately
  not a vendor: Hue, Kasa, and Zigbee are Home Assistant's problem, and this
  module knows only what a *light* means.

  Whether it dims is *discovered*, not declared (design §4.3): HA reports
  `supported_color_modes`, and a bulb that only knows `onoff` cannot be
  asked for brightness — a manifest cannot promise dimming the hardware
  does not have.
  """

  use Jido.Agent,
    name: "light",
    description: "Reports light state, switches it, and sets brightness",
    signal_routes: [
      {"ha.state_changed", Dobby.DeviceAgents.Light.SyncState},
      {"light.set_power", Dobby.DeviceAgents.Light.SetPower},
      {"light.set_brightness", Dobby.DeviceAgents.Light.SetBrightness}
    ],
    schema: [
      dobby_id: [type: :string, required: true],
      name: [type: :string, required: true],
      entity_id: [type: :string, required: true],
      # `nil`, not `false` — see Thermostat: "has not reported yet" and "is
      # not answering" are different facts, and a `false` start makes every
      # first report a move the watcher would record as a boot-time event.
      available: [type: {:or, [:boolean, nil]}, default: nil],
      power: [type: {:or, [:atom, nil]}, default: nil],
      brightness_percent: [type: {:or, [:integer, nil]}, default: nil],
      capabilities: [type: :map, default: %{}],
      settings: [type: :map, default: %{}],
      last_command: [type: {:or, [:map, nil]}, default: nil]
    ]

  @behaviour Dobby.DeviceAgent

  alias Dobby.Home.Device

  @impl Dobby.DeviceAgent
  def config_type, do: "light"

  @impl Dobby.DeviceAgent
  def matches_entity?(entity), do: Dobby.HomeAssistant.Entity.domain(entity) == "light"

  # Nothing to narrow: whether this bulb dims is the bulb's word
  # (`supported_color_modes`), not the household's.
  @impl Dobby.DeviceAgent
  def config_schema, do: []

  @impl Dobby.DeviceAgent
  def validate_device(%Device{bindings: bindings, settings: settings}) do
    with :ok <- require_binding(bindings, :light) do
      if is_map(settings),
        do: :ok,
        else: {:error, "settings must be a map, got #{inspect(settings)}"}
    end
  end

  @impl Dobby.DeviceAgent
  def tools do
    [
      Dobby.Tools.LightGetStatus,
      Dobby.Tools.LightTurnOn,
      Dobby.Tools.LightTurnOff,
      Dobby.Tools.LightSetBrightness
    ]
  end

  @impl Dobby.DeviceAgent
  def subscribed_bindings, do: [:light]

  @impl Dobby.DeviceAgent
  def scheduled_actions do
    %{
      set_power: {"light.set_power", Dobby.DeviceAgents.Light.SetPower},
      set_brightness: {"light.set_brightness", Dobby.DeviceAgents.Light.SetBrightness}
    }
  end

  @impl Dobby.DeviceAgent
  defdelegate snapshot(state), to: Dobby.DeviceAgents.Light.SyncState

  # A light's power *is* somebody's hand on the wall switch — but saying so
  # in the thread needs the commanded?-echo bookkeeping the thermostat has
  # and this agent does not yet. Without it, every light Dobby switched would
  # echo back as "changed at the kitchen light". False until that lands: a
  # missing line costs less than a line about a hand that was never there.
  @impl Dobby.DeviceAgent
  def intervention?(_attribute), do: false

  @impl Dobby.DeviceAgent
  def command_arrived?(%{result: :accepted, action: :set_power, on: on}, snapshot),
    do: snapshot.power == if(on, do: :on, else: :off)

  def command_arrived?(
        %{result: :accepted, action: :set_brightness, brightness_percent: expected},
        snapshot
      ),
      do: snapshot.power == :on and snapshot.brightness_percent == expected

  def command_arrived?(_command, _snapshot), do: false

  @impl Dobby.DeviceAgent
  def initial_state(%Device{} = device),
    do: Dobby.DeviceAgent.initial_state(device, :light)

  @doc """
  Whether the discovered color modes include brightness.

  HA's contract: every color mode except `onoff` carries brightness. Until
  discovery has heard anything, the answer is `false` — a capability nobody
  reported is a capability we do not claim.
  """
  @spec dimmable?(map()) :: boolean()
  def dimmable?(state) do
    case get_in(state, [:capabilities, :color_modes]) do
      modes when is_list(modes) -> Enum.any?(modes, &(&1 != "onoff"))
      _unknown -> false
    end
  end

  defp require_binding(bindings, key) when is_map(bindings) do
    case Map.fetch(bindings, key) do
      {:ok, entity_id} when is_binary(entity_id) ->
        :ok

      {:ok, other} ->
        {:error, "bindings.#{key} must be an entity id string, got #{inspect(other)}"}

      :error ->
        {:error, "missing required binding #{inspect(key)}"}
    end
  end

  defp require_binding(other, _key),
    do: {:error, "bindings must be a map, got #{inspect(other)}"}
end
