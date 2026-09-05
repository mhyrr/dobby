defmodule Dobby.Rules.WindowTest do
  use ExUnit.Case, async: true

  alias Dobby.Rules.Window
  @zone "America/New_York"

  test "no window watches at every instant" do
    assert {:ok, nil} = Window.load(nil)
    assert Window.active?(nil, ~U[2026-09-04 12:00:00Z], @zone)
  end

  test "daily occurrence keys cannot join separate watch intervals" do
    {:ok, window} = Window.load(%{"start" => "22:00", "end" => "07:00"})
    assert Window.key(window, ~U[2026-09-05 03:00:00Z], @zone) == ~D[2026-09-04]
    assert Window.key(window, ~U[2026-09-05 10:00:00Z], @zone) == ~D[2026-09-04]
    assert Window.key(window, ~U[2026-09-06 03:00:00Z], @zone) == ~D[2026-09-05]
    assert Window.key(window, ~U[2026-09-05 12:00:00Z], @zone) == nil
  end

  test "start is included and end is excluded in local time" do
    assert {:ok, window} = Window.load(%{"start" => "08:00", "end" => "09:00"})
    refute Window.active?(window, ~U[2026-09-04 11:59:59Z], @zone)
    assert Window.active?(window, ~U[2026-09-04 12:00:00Z], @zone)
    refute Window.active?(window, ~U[2026-09-04 13:00:00Z], @zone)
  end

  test "a Friday overnight window includes Saturday morning but not Sunday" do
    assert {:ok, window} = Window.load(%{"start" => "22:00", "end" => "07:00", "days" => [5]})
    assert Window.active?(window, ~U[2026-09-05 02:00:00Z], @zone)
    assert Window.active?(window, ~U[2026-09-05 10:59:59Z], @zone)
    refute Window.active?(window, ~U[2026-09-05 11:00:00Z], @zone)
    refute Window.active?(window, ~U[2026-09-06 06:00:00Z], @zone)
  end

  test "both instances of a repeated local hour belong to the window" do
    assert {:ok, window} = Window.load(%{"start" => "01:00", "end" => "02:00", "days" => [7]})
    assert Window.active?(window, ~U[2026-11-01 05:30:00Z], @zone)
    assert Window.active?(window, ~U[2026-11-01 06:30:00Z], @zone)
    refute Window.active?(window, ~U[2026-11-01 07:00:00Z], @zone)
  end

  test "a skipped local hour contributes no invented instants" do
    assert {:ok, window} = Window.load(%{"start" => "02:00", "end" => "03:00", "days" => [7]})
    refute Window.active?(window, ~U[2026-03-08 06:59:59Z], @zone)
    refute Window.active?(window, ~U[2026-03-08 07:00:00Z], @zone)
  end

  test "invalid windows are explicit errors" do
    for raw <- [
          %{},
          [],
          %{"start" => "9:00", "end" => "10:00"},
          %{"start" => "24:00", "end" => "01:00"},
          %{"start" => "12:00", "end" => "12:00"},
          %{"start" => "12:00", "end" => "13:00", "days" => []},
          %{"start" => "12:00", "end" => "13:00", "days" => [0]},
          %{"start" => "12:00", "end" => "13:00", "days" => ["Monday"]},
          %{"start" => "12:00", "end" => "13:00", "timezone" => "UTC"}
        ] do
      assert {:error, _} = Window.load(raw)
    end
  end
end
