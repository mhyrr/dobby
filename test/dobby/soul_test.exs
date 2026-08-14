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
      {doctrine_at, _} = :binary.match(prompt, "Report what you commanded")

      assert soul_at < doctrine_at
    end

    test "the compiled-in floor is doctrine alone" do
      # If the soul is never installed, Dobby is charmless but still honest.
      refute DobbyAgent.doctrine() =~ "capable person who lives here"
      assert DobbyAgent.doctrine() =~ "Report what you commanded"
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
    assert installed =~ "Report what you commanded", "doctrine missing from the live prompt"
  end
end
