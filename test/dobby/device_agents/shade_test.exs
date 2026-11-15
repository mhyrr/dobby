defmodule Dobby.DeviceAgents.ShadeTest do
  @moduledoc """
  The deterministic layer for blinds, shades, curtains, shutters, and awnings.

  Open and close are portable across every cover; a stated position is not,
  and rides HA's `SET_POSITION` feature bit. The boundary with AccessCover is
  tested from the access side (`access_cover_test.exs`), in both directions.
  """

  use ExUnit.Case, async: true
  import Dobby.DeviceAgentContract

  alias Dobby.DeviceAgents.Shade
  alias Dobby.Directive.HACall
  alias Jido.Agent.Directive.Emit

  device_agent_contract(Dobby.DeviceAgents.Shade,
    bindings: %{cover: "cover.contract"},
    entity: [entity_id: "cover.contract", device_class: "shade"],
    arrivals: [
      {%{result: :accepted, action: :open}, %{shade_state: :opening}, %{shade_state: :closed}},
      {%{result: :accepted, action: :close}, %{shade_state: :closing}, %{shade_state: :open}},
      {%{result: :accepted, action: :set_position, position: 40}, %{position: 40},
       %{position: 60}}
    ],
    # `move` takes a direction (open/close) that is not a value of
    # `shade_state` (open/closed/opening/closing), so a choice row could not
    # mark the current one; and the position fader would land on the
    # TK-070 case-1 echo bug. Held for the shade's own pass (TK-069,
    # follow-up).
    controls: :none
  )

  # `available` is nil between agent start and the first sync — a command in
  # that window deserves a refusal, not an `ArgumentError` from `not nil`.
  test "a command before the first sync is refused, not crashed" do
    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Shade.SetPosition.run(%{position: 40, ref: "boot"}, %{state: booted_state()})

    assert reason =~ "unavailable"
  end

  test "a shade without the position feature refuses a percentage, and no call leaves" do
    {state, _emit} = sync(booted_state(), "open", %{"supported_features" => 0})
    refute state.supports_position

    assert {:ok, %{last_command: %{result: {:rejected, reason}}}} =
             Shade.SetPosition.run(%{position: 40, ref: "cmd"}, %{state: state})

    assert reason =~ "does not support position"
  end

  test "an allowed position emits exactly HA's set_cover_position call" do
    {state, _emit} = sync(booted_state(), "open", %{"supported_features" => 4})

    assert {:ok, %{last_command: %{result: :accepted, position: 20}},
            [
              %HACall{
                domain: "cover",
                service: "set_cover_position",
                entity_id: "cover.test",
                data: %{position: 20}
              }
            ]} = Shade.SetPosition.run(%{position: 20, ref: "cmd"}, %{state: state})
  end

  test "each movement emits exactly HA's cover call, with no position feature needed" do
    {state, _emit} = sync(booted_state(), "closed", %{"supported_features" => 0})

    assert {:ok, %{last_command: %{result: :accepted, action: :open}},
            [%HACall{domain: "cover", service: "open_cover", data: %{}}]} =
             Shade.Move.run(%{movement: :open, ref: "cmd"}, %{state: state})

    assert {:ok, _accepted, [%HACall{domain: "cover", service: "close_cover"}]} =
             Shade.Move.run(%{movement: :close, ref: "cmd"}, %{state: state})
  end

  test "the echo of a commanded position is commanded; a hand on the wand is not" do
    {state, _emit} =
      sync(booted_state(), "open", %{"current_position" => 80, "supported_features" => 4})

    {:ok, command, _calls} = Shade.SetPosition.run(%{position: 20, ref: "cmd"}, %{state: state})
    state = Map.merge(state, command)

    {state, %Emit{signal: echo}} =
      sync(state, "open", %{"current_position" => 20, "supported_features" => 4})

    assert echo.data.commanded?

    {_state, %Emit{signal: hand}} =
      sync(state, "open", %{"current_position" => 55, "supported_features" => 4})

    refute hand.data.commanded?
  end

  # The travel allowance is bounded by the shade's deadline. A shade still
  # moving toward a commanded end long after the command is somebody's hand,
  # and crediting it to an old command would hide that person (TK-070 case 1).
  test "a report on the way counts as the command's only while it is in flight" do
    {state, _emit} =
      sync(booted_state(), "closed", %{"current_position" => 0, "supported_features" => 4})

    {:ok, command, _calls} = Shade.Move.run(%{movement: :open, ref: "cmd"}, %{state: state})
    in_flight = Map.merge(state, command)

    {_state, %Emit{signal: travelling}} =
      sync(in_flight, "opening", %{"current_position" => 40})

    assert travelling.data.commanded?

    expired =
      put_in(in_flight.last_command.in_flight_until, System.monotonic_time(:millisecond) - 1)

    {_state, %Emit{signal: late}} = sync(expired, "opening", %{"current_position" => 40})
    refute late.data.commanded?
  end

  # An awning or a big shutter can take longer than the deadline. Each report
  # on the way pushes the window on, so travel ends when the reports stop,
  # not at a fixed minute.
  test "each report on the way keeps the command in flight" do
    {state, _emit} =
      sync(booted_state(), "open", %{"current_position" => 100, "supported_features" => 4})

    {:ok, command, _calls} = Shade.Move.run(%{movement: :close, ref: "cmd"}, %{state: state})
    nearly_over = System.monotonic_time(:millisecond) + 5

    in_flight =
      state
      |> Map.merge(command)
      |> put_in([:last_command, :in_flight_until], nearly_over)

    {state, %Emit{signal: first}} = sync(in_flight, "closing", %{"current_position" => 70})
    assert first.data.commanded?
    assert state.last_command.in_flight_until > nearly_over + 1_000

    Process.sleep(10)
    {_state, %Emit{signal: later}} = sync(state, "closing", %{"current_position" => 40})
    assert later.data.commanded?
  end

  # A shade that drops off the network mid-travel has not been turned back by
  # anybody; when it answers again it is still on Dobby's errand.
  test "a shade that goes quiet on its way is still in flight when it answers" do
    {state, _emit} =
      sync(booted_state(), "closed", %{"current_position" => 0, "supported_features" => 4})

    {:ok, command, _calls} = Shade.Move.run(%{movement: :open, ref: "cmd"}, %{state: state})
    {state, _emit} = sync(Map.merge(state, command), "opening", %{"current_position" => 40})
    {state, _emit} = sync(state, "unavailable", %{})
    {state, _emit} = sync(state, "opening", %{"current_position" => 40})

    {_state, %Emit{signal: back}} = sync(state, "opening", %{"current_position" => 70})
    assert back.data.commanded?
  end

  # No position at all: the in-flight state for the command's direction is the
  # only evidence, and the opposite one is not this command.
  test "a shade with no position travels by its in-flight state alone" do
    {state, _emit} = sync(booted_state(), "closed", %{})
    {:ok, command, _calls} = Shade.Move.run(%{movement: :open, ref: "cmd"}, %{state: state})
    in_flight = Map.merge(state, command)

    {_state, %Emit{signal: opening}} = sync(in_flight, "opening", %{})
    assert opening.data.commanded?

    {_state, %Emit{signal: closing}} = sync(in_flight, "closing", %{})
    refute closing.data.commanded?
  end

  test "movement and position are somebody's doing; discovery and availability are not" do
    assert Shade.intervention?(:shade_state)
    assert Shade.intervention?(:position)
    refute Shade.intervention?(:supports_position)
    refute Shade.intervention?(:available)
  end

  defp booted_state do
    device = %Dobby.Home.Device{
      id: "shade:test",
      name: "test shade",
      agent_module: Shade,
      bindings: %{cover: "cover.test"},
      settings: %{}
    }

    Shade.new(id: device.id, state: Shade.initial_state(device)).state
  end

  defp sync(state, entity_state, attributes) do
    params = %{entity_id: state.entity_id, state: entity_state, attributes: attributes}

    case Shade.SyncState.run(params, %{state: state}) do
      {:ok, next} -> {Map.merge(state, next), nil}
      {:ok, next, [%Emit{} = emit]} -> {Map.merge(state, next), emit}
    end
  end
end
