defmodule Dobby.HistoryToolRigTest do
  @moduledoc """
  The history tool through Jido's own execution pipeline, against real rows.
  Schema tests prove what the model is offered; this proves what it gets back.
  """
  use Dobby.RigCase, async: false
  alias Dobby.Activity

  test "a count through the tool sees the rows the record holds" do
    for kind <- ["command_refused", "command_never_arrived", "command_never_arrived"] do
      {:ok, _} =
        Activity.record(%{kind: kind, device: "thermostat:main", action: "set_temperature"})
    end

    params = %{
      device: "thermostat:main",
      actor: "",
      kinds: ["command_refused", "command_never_arrived"],
      period: "today",
      since: "",
      until: "",
      weekday: 0,
      mode: "count",
      limit: 50
    }

    assert {:ok, result} = Jido.Exec.run(Dobby.Tools.History, params, %{})
    assert result.count == 3, inspect(result)
  end
end
