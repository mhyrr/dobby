defmodule Dobby.ApplianceReadingRenderTest do
  use ExUnit.Case, async: true

  test "new accepted values render for live and persisted schedule arguments" do
    for {key, value, expected} <- [
          {:target_humidity_percent, 45, "45%"},
          {:mode, "eco", "Eco"},
          {:away_mode, false, "Away mode off"},
          {:away_mode, true, "Away mode on"},
          {:power, :off, "Off"}
        ] do
      assert Dobby.Interventions.reading(%{key => value}) == expected
      assert Dobby.Interventions.reading(%{Atom.to_string(key) => value}) == expected
    end
  end
end
