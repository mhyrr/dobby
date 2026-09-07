defmodule Dobby.Rules.EngineTest do
  use ExUnit.Case, async: true
  alias Dobby.Rules.Engine
  @now ~U[2026-09-05 12:00:00Z]

  test "the boundary is inclusive and a lasting breach speaks once" do
    {state, :none} = Engine.step(Engine.new(), true, 20, @now, 0)
    {state, :none} = Engine.step(state, true, 20, DateTime.add(@now, 19), 19_999)
    {state, :notify} = Engine.step(state, true, 20, DateTime.add(@now, 20), 20_000)
    assert {^state, :none} = Engine.step(state, true, 20, DateTime.add(@now, 40), 40_000)
    assert state.observed_since == @now
  end

  test "zero duration notices immediately" do
    assert {%{notified: true}, :notify} = Engine.step(Engine.new(), true, 0, @now, 0)
  end

  test "unknown breaks observation without claiming recovery" do
    {state, :none} = Engine.step(Engine.new(), true, 20, @now, 0)
    {state, :none} = Engine.step(state, :unknown, 20, @now, 19_000)
    {state, :none} = Engine.step(state, true, 20, @now, 20_000)
    assert {_, :none} = Engine.step(state, true, 20, @now, 39_999)
    {state, :notify} = Engine.step(state, true, 20, @now, 40_000)
    {state, :none} = Engine.step(state, :unknown, 20, @now, 41_000)
    assert state.notified
    assert {_, :none} = Engine.step(state, true, 20, @now, 90_000)
  end

  test "a known recovery arms a new occurrence" do
    {state, :notify} = Engine.step(Engine.new(), true, 0, @now, 0)
    {state, :resolve} = Engine.step(state, false, 0, @now, 1)
    assert {_, :notify} = Engine.step(state, true, 0, @now, 2)
  end

  test "wall clock corrections cannot create elapsed observation" do
    {state, :none} = Engine.step(Engine.new(), true, 20, @now, 0)
    {state, :none} = Engine.step(state, true, 20, DateTime.add(@now, 86_400), 10_000)
    assert {_, :notify} = Engine.step(state, true, 20, DateTime.add(@now, -86_400), 20_000)
  end

  test "a restored occurrence never speaks again without a known recovery" do
    {state, :none} = Engine.step(Engine.new(true), true, 0, @now, 0)
    {state, :none} = Engine.step(state, :unknown, 0, @now, 10)
    assert {_, :none} = Engine.step(state, true, 0, @now, 20)
  end
end
