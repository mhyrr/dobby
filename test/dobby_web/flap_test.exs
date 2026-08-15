defmodule DobbyWeb.FlapTest do
  @moduledoc """
  The board's vocabulary, read straight from device snapshots.

  These are the sentences the surface says on Dobby's behalf, so they carry
  the same rule his replies do: report what was commanded, never what was
  observed about the room.
  """

  use ExUnit.Case, async: true

  import DobbyWeb.Flap, only: [read: 1]

  describe "a thermostat" do
    test "holding its setpoint is SET" do
      assert %{word: "Set", state: :set, value: "70°"} =
               read(thermostat(current: 70, target: 70))
    end

    test "closing a gap upward is WARMING" do
      assert %{word: "Warming", state: :acting} = read(thermostat(current: 64, target: 70))
    end

    test "closing a gap downward is COOLING" do
      assert %{word: "Cooling", state: :acting} =
               read(thermostat(current: 76, target: 70, hvac_mode: :cool))
    end

    test "a heating thermostat above its setpoint is not COOLING" do
      # It is a furnace, not an air conditioner. The word has to come from
      # what the device can actually do, or the board is inventing a state
      # nobody commanded.
      assert %{word: "Set"} = read(thermostat(current: 76, target: 70, hvac_mode: :heat))
    end

    test "sitting within half a degree does not flap between words" do
      # A thermostat resting on its setpoint wobbles. A board that flipped
      # between SET and WARMING every few minutes would be describing the
      # sensor rather than the house.
      assert %{word: "Set"} = read(thermostat(current: 69.7, target: 70))
    end

    test "unavailable is QUIET, and unset is NOT KNOWN" do
      assert %{word: "Quiet", state: :silent} = read(thermostat(available: false))

      assert %{word: "Not known", state: :silent} =
               read(thermostat(current: 68, target: nil))
    end
  end

  describe "an endpoint" do
    test "answering is AWAKE" do
      assert %{word: "Awake", state: :acting} = read(endpoint(online: true))
    end

    test "not answering is QUIET" do
      assert %{word: "Quiet", state: :silent} = read(endpoint(online: false))
    end

    test "not yet heard from is NOT KNOWN, which is not the same as offline" do
      # `wifi_get_status` insists on this distinction to the model. A board
      # that said QUIET for both would be the surface contradicting the tool.
      assert %{word: "Not known", state: :silent} = read(endpoint(online: nil))
      assert %{word: "Not known", state: :silent} = read(endpoint(available: false))
    end
  end

  defp thermostat(opts) do
    %{
      id: "thermostat:main",
      name: "main thermostat",
      type: :thermostat,
      available: Keyword.get(opts, :available, true),
      current_temperature_f: Keyword.get(opts, :current),
      target_temperature_f: Keyword.get(opts, :target),
      hvac_mode: Keyword.get(opts, :hvac_mode, :heat)
    }
  end

  defp endpoint(opts) do
    %{
      id: "wifi:kitchen_tv",
      name: "kitchen TV",
      type: :wifi_endpoint,
      available: Keyword.get(opts, :available, true),
      online: Keyword.get(opts, :online),
      last_changed_at: nil
    }
  end
end
