defmodule Dobby.Script do
  @moduledoc """
  Scripted model turns the `expect_react` DSL cannot express.

  ## Why this exists

  `Jido.AI.Test.call/3` builds exactly one tool call per turn, and
  `ReActScript.normalize_turns!/1` has no multi-call form. So the DSL cannot
  script a model that asks for two tools in a single turn — which is precisely
  what "set the thermostat to 69 and check all the endpoints" is, and the only
  way to find out whether Jido executes such calls concurrently or one after
  another.

  ## The seam, stated plainly

  `ReActScript.resolve_script/2` returns an explicitly-passed `%ReActScript{}`
  **without normalizing it**, so a hand-built struct carrying
  `tool_calls: [a, b]` flows straight through to the runner. That works, and
  it is off the documented contract: the moduledoc says treat the struct as
  opaque. We are relying on its internal shape, and a jido_ai upgrade may
  break this file. It is confined to this module for that reason — when it
  breaks, it breaks in one place, loudly, in tests.

  If upstream grows a real multi-call form, delete this and use it.
  """

  alias Jido.AI.Test.ReActScript

  @doc """
  A script whose first turn requests several tools at once, then answers.

  `calls` is a list of `{tool_name, arguments}`.
  """
  @spec multi_tool_turn(String.t(), [{String.t() | atom(), map()}], String.t()) :: ReActScript.t()
  def multi_tool_turn(user, calls, answer_text) when is_list(calls) and calls != [] do
    %ReActScript{
      id: "dobby_multi_tool_#{System.unique_integer([:positive])}",
      user: user,
      turns: [
        %{
          type: :tool_call,
          text: nil,
          finish_reason: :tool_calls,
          usage: %{},
          tool_calls: Enum.map(Enum.with_index(calls, 1), &tool_call/1)
        },
        %{type: :answer, text: answer_text, finish_reason: :stop, usage: %{}}
      ]
    }
  end

  defp tool_call({{name, arguments}, index}) when is_map(arguments) do
    %{id: "tc_#{index}", name: to_string(name), arguments: arguments}
  end
end
