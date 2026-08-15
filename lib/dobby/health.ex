defmodule Dobby.Health do
  @moduledoc """
  Whether the parts of this house are actually there (surface design §9).

  Every answer here is read at the moment it is asked. Nothing is cached and
  nothing is reported from a note a process wrote to itself — a health page
  built on a cache tells you what was true when the cache was written, which is
  precisely the wrong thing to know.

  The most useful row is the last one. `SchedulerAgent.unregistered/0` is the
  set of schedules that *should* have a timer and do not: a row accepted at
  authoring time and then rejected by the timer looks, from every other angle,
  exactly like a schedule that works. Empty is the healthy answer.
  """

  alias Dobby.Home
  alias Dobby.HomeAssistant
  alias Dobby.SchedulerAgent

  @typedoc "One thing that is either there or not, said in the board's words."
  @type row :: %{
          name: String.t(),
          word: String.t(),
          state: :acting | :silent | :refused,
          detail: String.t() | nil
        }

  @doc """
  The agents, the connection to Home Assistant, and the timers.
  """
  @spec rows() :: [row()]
  def rows do
    [dobby_row(), scheduler_row(), home_assistant_row()] ++ device_rows()
  end

  defp dobby_row do
    agent_row("Dobby", Dobby.DobbyAgent.id())
  end

  defp scheduler_row do
    agent_row("Scheduler", SchedulerAgent.id())
  end

  defp device_rows do
    Enum.map(Home.devices(), &agent_row(&1.name, &1.id))
  rescue
    # No manifest means no house. The three rows above already say so.
    ArgumentError -> []
  end

  # The registry id is carried alongside the name because these rows are about
  # *processes*, and the same words appear on `/house` about devices. AWAKE
  # here means the agent for the main thermostat is running; AWAKE there means
  # the thermostat itself is answering, and they can honestly disagree. An id
  # is unmistakably an internal thing, which is what keeps the two apart.
  defp agent_row(name, id) do
    if is_pid(Dobby.Jido.whereis(id)) do
      %{name: name, word: "Awake", state: :acting, detail: id}
    else
      %{name: name, word: "Quiet", state: :silent, detail: id}
    end
  end

  # The client is a process like any other, and which one it is matters as
  # much as whether it is up: a box happily talking to the fake is a box that
  # is not talking to the house.
  defp home_assistant_row do
    module = HomeAssistant.impl()
    detail = module |> Module.split() |> List.last()

    if is_pid(Process.whereis(module)) do
      %{name: "Home Assistant", word: "Awake", state: :acting, detail: detail}
    else
      %{name: "Home Assistant", word: "Quiet", state: :silent, detail: detail}
    end
  end

  @doc """
  The schedules that should have a timer and do not.

  Empty is the healthy answer, and a non-empty one is the gap nothing else on
  this page would show.
  """
  @spec unregistered() :: [map()]
  defdelegate unregistered(), to: SchedulerAgent
end
