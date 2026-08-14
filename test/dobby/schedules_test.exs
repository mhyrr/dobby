defmodule Dobby.SchedulesTest do
  @moduledoc """
  Authoring a schedule, with no model and no clock.

  Two things get proved here. That a schedule which cannot possibly work is
  refused when someone asks for it rather than at eight o'clock — the whole
  reason authoring validates against the running house. And that "eight pm on
  weekdays" means what a person means by it, which is a question about
  calendars and daylight saving that can be answered without waiting for
  Tuesday: `next_fire/3` takes `from` as an argument, so the clock is an input.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Schedules
  alias Dobby.Schedules.Cron

  @thermostat "thermostat:main"

  setup do
    seed_house(%{"climate.main_floor" => thermostat_entity(current: 68, target: 68)})
    :ok
  end

  describe "authoring" do
    test "a well-formed schedule is stored normalized and attributed" do
      assert {:ok, schedule} = create(%{args: %{"temperature_f" => 70}})

      assert schedule.cron == "0 20 * * 1-5"
      assert schedule.target == @thermostat
      assert schedule.action == "set_temperature"
      assert schedule.created_by == "greg"
      assert schedule.created_via == :conversation
      assert schedule.enabled

      # The manifest's timezone, not one anybody typed. A household means its
      # own eight o'clock.
      assert schedule.timezone == Dobby.Home.manifest().timezone

      # Stored as the device action will read it, so nothing is reinterpreted
      # hours later.
      assert schedule.args == %{"temperature_f" => 70.0}
    end

    test "a number sent as a string is coerced once, at the edge" do
      # The bug the eval tier found in the tool layer (§6.2) arrives here too:
      # a model that has been told "number" will still occasionally send "70".
      assert {:ok, schedule} = create(%{args: %{"temperature_f" => "70"}})
      assert schedule.args == %{"temperature_f" => 70.0}
    end

    test "a device this house does not have is refused, naming what it does have" do
      assert {:error, changeset} = create(%{target: "thermostat:kitchen"})

      message = Schedules.error_message(changeset)
      assert message =~ "unknown device"
      assert message =~ @thermostat
    end

    test "a device with nothing schedulable is refused rather than half-accepted" do
      assert {:error, changeset} = create(%{target: "wifi:kitchen_tv", action: "set_temperature"})
      assert Schedules.error_message(changeset) =~ "nothing that can be scheduled"
    end

    test "an action the device type does not publish is refused, naming the ones it does" do
      assert {:error, changeset} = create(%{action: "set_hvac_mode"})

      message = Schedules.error_message(changeset)
      assert message =~ "cannot be scheduled"
      assert message =~ "set_temperature"
    end

    test "an argument the action does not take is refused" do
      assert {:error, changeset} = create(%{args: %{"temperature_c" => 21}})

      message = Schedules.error_message(changeset)
      assert message =~ "takes no argument"
      assert message =~ "temperature_f"
    end

    test "a missing argument is refused by the action's own schema" do
      assert {:error, changeset} = create(%{args: %{}})
      assert Schedules.error_message(changeset) =~ "temperature_f"
    end

    test "an expression that is not a cron expression is refused" do
      assert {:error, changeset} = create(%{cron: "every evening at eight"})
      assert Schedules.error_message(changeset) =~ "not a cron expression"
    end

    test "two schedules cannot share a name" do
      assert {:ok, _first} = create(%{label: "weeknight heat"})
      assert {:error, changeset} = create(%{label: "Weeknight Heat"})

      # Case-insensitively, because "pause the weeknight heat one" has to
      # resolve to exactly one row.
      assert Schedules.error_message(changeset) =~ "already been taken"
    end

    test "a setpoint outside household policy is accepted now and refused at eight" do
      # Deliberate, and the sharpest edge in this module. The accepted range
      # comes from capabilities discovered from the hardware, so refusing here
      # would mean refusing a schedule authored before the thermostat first
      # reported. The refusal happens at fire time instead, and is announced —
      # see the firing scenario.
      assert {:ok, schedule} = create(%{args: %{"temperature_f" => 85}})
      assert schedule.args == %{"temperature_f" => 85.0}
    end
  end

  describe "next fire" do
    test "eight pm on weekdays skips the weekend" do
      # Saturday lunchtime.
      from = ~U[2026-08-15 16:00:00Z]

      assert {:ok, at} = Cron.next_fire("0 20 * * 1-5", "America/New_York", from)

      assert at.year == 2026 and at.month == 8 and at.day == 17
      assert at.hour == 20 and at.minute == 0
      assert Date.day_of_week(DateTime.to_date(at)) == 1
    end

    test "a schedule due later the same day fires the same day" do
      # Monday, seven in the evening, local.
      from = ~U[2026-08-17 23:00:00Z]

      assert {:ok, at} = Cron.next_fire("0 20 * * 1-5", "America/New_York", from)
      assert at.day == 17 and at.hour == 20
    end

    test "a time that does not exist on a spring-forward morning still resolves" do
      # 2027-03-14, the clocks go from 01:59 to 03:00 in New York, so a
      # schedule set for two in the morning has no two in the morning to fire
      # at. Answering "error" would be technically true and useless; the
      # schedule fires when the hour it wanted would have been.
      from = ~U[2027-03-13 17:00:00Z]

      assert {:ok, at} = Cron.next_fire("0 2 * * *", "America/New_York", from)
      assert at.day == 14
      assert at.hour == 3
    end

    test "an expression with no next run does not pretend to have one" do
      # The thirtieth of February.
      assert {:error, _reason} = Cron.next_fire("0 20 30 2 *", "UTC", DateTime.utc_now())
    end
  end

  describe "describe" do
    test "reports a schedule whose device left the manifest instead of hiding it" do
      assert {:ok, schedule} = create(%{})

      # The house changes underneath the row, which is what a manifest edit
      # plus a restart does in production (§2.4).
      boot_house!([thermostat_device("thermostat:spare", "spare thermostat")])

      described = Schedules.describe(schedule)

      assert described.status =~ "unknown device"
      assert described.id == schedule.id
    end

    test "a paused schedule has no next fire and says so" do
      assert {:ok, schedule} = create(%{})
      assert {:ok, paused} = Schedules.set_enabled(schedule.id, false)

      described = Schedules.describe(paused)

      assert described.status == "paused"
      assert described.next_fire == nil
    end
  end

  defp create(overrides) do
    %{
      label: "weeknight heat",
      cron: "0 20 * * 1-5",
      timezone: Dobby.Home.manifest().timezone,
      target: @thermostat,
      action: "set_temperature",
      args: %{"temperature_f" => 70},
      created_by: "greg",
      created_via: :conversation
    }
    |> Map.merge(overrides)
    |> Schedules.create_schedule()
  end
end
