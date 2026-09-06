defmodule Dobby.SoulTest do
  @moduledoc """
  The soul is a file on the box, not a constant in the release.

  These tests exist because the failure mode is quiet: if the soul never
  reaches the agent, Dobby still runs the house correctly and simply sounds
  like whichever model is behind him. That is easy to ship and hard to notice.
  """

  use Dobby.RigCase, async: false

  alias Dobby.{DobbyAgent, Soul}

  describe "reading" do
    test "the soul comes from a file that can be edited without a rebuild" do
      assert Soul.path() =~ "soul.md"
      assert Soul.read!() =~ "capable person who lives here"
    end

    test "a missing soul takes the boot down rather than shipping a blank one" do
      original = Application.get_env(:dobby, :soul_path)
      Application.put_env(:dobby, :soul_path, "config/no_such_soul.md")
      on_exit(fn -> Application.put_env(:dobby, :soul_path, original) end)

      assert_raise RuntimeError, ~r/could not read Dobby's soul/, &Soul.read!/0
    end
  end

  describe "composition" do
    test "doctrine follows the soul, so honesty is what the model reads last" do
      prompt = Soul.system_prompt()

      {soul_at, _} = :binary.match(prompt, "capable person who lives here")
      {doctrine_at, _} = :binary.match(prompt, "You act only through your tools")

      assert soul_at < doctrine_at
    end

    test "the compiled-in floor is doctrine alone" do
      # If the soul is never installed, Dobby is charmless but still honest.
      refute DobbyAgent.doctrine() =~ "capable person who lives here"
      assert DobbyAgent.doctrine() =~ "You act only through your tools"
    end

    test "write shape belongs to doctrine and not the editable voice" do
      # The one write example lives in doctrine because a soul example teaches
      # shape, and shape moved five replies on 2026-08-27 (TK-033). Since
      # decision 27 the example is warm and state-shaped on purpose; what the
      # doctrine still forbids is a reading the model never took.
      refute Soul.read!() =~ "I set the main thermostat"
      refute Soul.read!() =~ "Coffee station"
      assert DobbyAgent.doctrine() =~ "Coffee station's on, Greg"
      assert DobbyAgent.doctrine() =~ "is yours to say and"
    end

    test "the rule paragraph says itself that an ambiguous device is a question" do
      # glm-5.2, 2026-09-06: "tell me if the door stays unlocked for an hour"
      # in a house with two locks was proposed for the front door. The general
      # ambiguity rule sits eight paragraphs above the rule paragraph, and a
      # model reading the rule paragraph for what to do did not carry it down.
      assert DobbyAgent.doctrine() =~ ~r/"the door"\s+in a house with two locks is a question/
    end
  end

  test "the running agent actually has the soul, not just the doctrine floor" do
    installed =
      agent_state(DobbyAgent.id())
      |> Map.get(:__strategy__, %{})
      |> Map.get(:config, %{})
      |> Map.get(:system_prompt)

    assert is_binary(installed), "no system prompt installed on the running agent"
    assert installed =~ "capable person who lives here", "soul never reached the agent"
    assert installed =~ "You act only through your tools", "doctrine missing from the live prompt"
  end
end
