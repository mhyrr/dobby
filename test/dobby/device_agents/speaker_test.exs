defmodule Dobby.DeviceAgents.SpeakerTest do
  @moduledoc """
  The deterministic layer for the vendor-neutral speaker.

  Play, pause, and volume are each a discovered capability, because HA's
  media-player domain spans devices that can do none of them. What the thread
  says about music is TK-029's question; until it is answered the speaker's
  whole thread posture is "nothing", and that silence is asserted here so
  nobody restores the default by accident.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Speaker
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  # HA's MediaPlayerEntityFeature bits: PAUSE 1, VOLUME_SET 4, PLAY 16384.
  @full_features 16_389

  device_agent_contract(Dobby.DeviceAgents.Speaker,
    bindings: %{media_player: "media_player.contract"},
    entity: [entity_id: "media_player.contract", device_class: "speaker"]
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not a `BadBooleanError` from `nil and`.
  test "commands before the first sync are refused, not crashed" do
    state = booted_state()

    assert {:ok, %{last_command: %{result: {:rejected, playback_reason}}}} =
             Speaker.SetPlayback.run(%{playback: :play, ref: "boot"}, %{state: state})

    assert playback_reason =~ "unavailable"

    assert {:ok, %{last_command: %{result: {:rejected, volume_reason}}}} =
             Speaker.SetVolume.run(%{volume_percent: 25, ref: "boot"}, %{state: state})

    assert volume_reason =~ "unavailable"
  end

  test "capabilities are read from HA's feature bits, per capability" do
    {full, _emit} = sync(booted_state(), "paused", %{"supported_features" => @full_features})
    assert full.capabilities == %{play: true, pause: true, volume: true}

    {volume_only, _emit} = sync(booted_state(), "paused", %{"supported_features" => 4})
    assert volume_only.capabilities == %{play: false, pause: false, volume: true}
  end

  test "a speaker without a capability refuses the command naming it" do
    {state, _emit} = sync(booted_state(), "paused", %{"supported_features" => 4})

    assert {:ok, %{last_command: %{result: {:rejected, play_reason}}}} =
             Speaker.SetPlayback.run(%{playback: :play, ref: "cmd"}, %{state: state})

    assert play_reason =~ "does not support play"

    {mute_button, _emit} = sync(booted_state(), "paused", %{"supported_features" => 0})

    assert {:ok, %{last_command: %{result: {:rejected, volume_reason}}}} =
             Speaker.SetVolume.run(%{volume_percent: 25, ref: "cmd"}, %{state: mute_button})

    assert volume_reason =~ "does not support volume"
  end

  test "a human percentage leaves as HA's zero-to-one volume" do
    {state, _emit} = sync(booted_state(), "paused", %{"supported_features" => @full_features})

    assert {:ok, %{last_command: %{result: :accepted, volume_percent: 25}},
            [
              %HACall{
                domain: "media_player",
                service: "volume_set",
                entity_id: "media_player.test",
                data: %{volume_level: 0.25}
              }
            ]} = Speaker.SetVolume.run(%{volume_percent: 25, ref: "cmd"}, %{state: state})
  end

  test "play and pause emit HA's media calls" do
    {state, _emit} = sync(booted_state(), "paused", %{"supported_features" => @full_features})

    assert {:ok, _accepted, [%HACall{domain: "media_player", service: "media_play"}]} =
             Speaker.SetPlayback.run(%{playback: :play, ref: "cmd"}, %{state: state})

    assert {:ok, _accepted, [%HACall{domain: "media_player", service: "media_pause"}]} =
             Speaker.SetPlayback.run(%{playback: :pause, ref: "cmd"}, %{state: state})
  end

  test "capability discovery is the house learning, never something that happened in it" do
    {state, _emit} =
      sync(booted_state(), "paused", %{
        "supported_features" => 4,
        "volume_level" => 0.3
      })

    # The same observable state with a richer feature word updates the
    # capabilities and emits nothing: capabilities stay out of the
    # changed/moved calculus, as on the light.
    {next, emit} =
      sync(state, "paused", %{
        "supported_features" => @full_features,
        "volume_level" => 0.3
      })

    assert emit == nil
    assert next.capabilities == %{play: true, pause: true, volume: true}
  end

  test "the speaker stays out of the thread entirely, pending TK-029" do
    # HA cannot tell the Sonos app from a hand on the device, and a speaker
    # moves with every track (Greg, 2026-08-23).
    for attribute <- [:playback, :volume_percent, :muted, :media_title, :available] do
      refute Speaker.intervention?(attribute)
    end
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "speaker:test",
      name: "test speaker",
      agent_module: Speaker,
      bindings: %{media_player: "media_player.test"},
      settings: %{}
    }

    Speaker.new(id: device.id, state: Speaker.initial_state(device)).state
  end

  defp sync(state, entity_state, attributes) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: attributes}

    case Speaker.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
