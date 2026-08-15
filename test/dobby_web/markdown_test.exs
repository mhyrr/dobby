defmodule DobbyWeb.MarkdownTest do
  @moduledoc """
  Taking the markdown out of a reply without taking anything else.

  The interesting half of this is what must survive. A house's conversation is
  full of device ids, temperatures and arithmetic, and a stripper that ate
  `thermostat_set_temperature` or `65 * 2` would be worse than the asterisks
  it was cleaning up.
  """

  use ExUnit.Case, async: true

  alias DobbyWeb.Markdown

  test "emphasis goes" do
    assert Markdown.strip("Set the **main thermostat** to 70.") ==
             "Set the main thermostat to 70."

    assert Markdown.strip("It's *already* on.") == "It's already on."
    assert Markdown.strip("__Done__ — 70.") == "Done — 70."
    assert Markdown.strip("The _kitchen_ TV is awake.") == "The kitchen TV is awake."
    assert Markdown.strip("Call `thermostat_get_status`.") == "Call thermostat_get_status."
    assert Markdown.strip("## The house\nAll quiet.") == "The house\nAll quiet."
  end

  test "what looks like markdown but is not, stays" do
    assert Markdown.strip("thermostat_set_temperature") == "thermostat_set_temperature"
    assert Markdown.strip("binary_sensor.kitchen_tv") == "binary_sensor.kitchen_tv"
    assert Markdown.strip("2 * 3 * 4") == "2 * 3 * 4"
    assert Markdown.strip("70 degrees") == "70 degrees"
    assert Markdown.strip("#1 on the list") == "#1 on the list"
  end

  test "nothing is not an error" do
    assert Markdown.strip(nil) == ""
    assert Markdown.strip("") == ""
  end
end
