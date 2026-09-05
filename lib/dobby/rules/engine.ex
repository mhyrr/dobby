defmodule Dobby.Rules.Engine do
  @moduledoc """
  The clock and occurrence transitions, without processes or side effects.

  Elapsed observation uses monotonic milliseconds. UTC is evidence to print,
  never a substitute for elapsed time: a clock correction must not manufacture
  twenty minutes of observation. Unknown readings break the interval but do
  not retract an existing notice. Only a known recovery can do that.
  """

  def new(notified \\ false) do
    %{since: nil, observed_since: nil, notified: notified}
  end

  def step(state, :unknown, _duration, _now, _monotonic),
    do: {%{state | since: nil, observed_since: nil}, :none}

  def step(state, false, _duration, _now, _monotonic) do
    {new(), if(state.notified, do: :resolve, else: :none)}
  end

  def step(state, true, duration, now, monotonic) do
    state =
      if state.since == nil,
        do: %{state | since: monotonic, observed_since: now},
        else: state

    if not state.notified and monotonic - state.since >= duration * 1000 do
      {%{state | notified: true}, :notify}
    else
      {state, :none}
    end
  end
end
