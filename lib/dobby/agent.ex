defmodule Dobby.DobbyAgent do
  @moduledoc """
  Dobby's language and orchestration agent (design §6).

  One long-lived ReAct agent holding the household conversation, a live
  picture of every managed device, and no way to touch the world except the
  typed tools below. It cannot reach Home Assistant and it cannot invent a
  device operation.

  ## On the tools list

  The design has this deriving from the manifest — `tools: Dobby.Home.tools()`.
  It cannot: `Jido.AI.Agent` resolves `:tools` at macro-expansion time and
  raises `CompileError` on a function call there. So the compile-time list is
  the *library* — every tool module that exists in this codebase — and the
  manifest narrows it to this house per request, via the `:tools` option on
  `ask/3`. `Dobby.Home.tools/0` supplies that.

  The model still sees only tools for devices this house actually has. Jido's
  literal restriction means a new registered type must also add its tools to
  the declaration below. `LibraryContractTest` compares this declaration with
  `Dobby.Home.library/0`, so the test suite refuses either list drifting from
  the other.
  """

  @id "dobby"

  # Two halves, kept apart on purpose.
  #
  # The doctrine below is load-bearing: it is what stops Dobby inventing a
  # device, actuating on a guess, or claiming a room got warm when all that
  # happened was a command being accepted. It lives in code, changes
  # deliberately, and the eval tier is what tells you whether a change broke it.
  #
  # The voice — who Dobby *is* — lives in `config/soul.md` and is read at boot
  # (`Dobby.Soul`), so editing the personality of the thing you live with costs
  # a restart rather than a release. `Dobby.Home` composes the two and installs
  # the result at startup.
  #
  # The compile-time `system_prompt:` below is doctrine only. It is the floor:
  # if the soul never gets installed, Dobby is charmless but still honest.
  @doctrine """
  Every message you receive is prefixed with the speaker's name in brackets,
  like [greg]. That prefix is how you know who is talking; it is not part of
  how you talk. Never begin your own reply with a bracketed name or repeat the
  prefix back — just answer the person.

  Several people may be talking in the same thread. Attribute correctly,
  address people by name when it helps, and when two people ask for
  conflicting things, do both in the order they asked and tell the second
  person what the first one wanted: "Sam, setting it to 68 — that replaces the
  72 Greg asked for." Never stop and ask them to settle it first.

  Before each message you are given a <house> block listing every device you
  can act on, with its id and last known state. Those ids are the only ones
  that exist. If someone names a device that is not in the list, say you don't
  have it.

  If what they said could mean more than one device in the list, ask which one.
  Do not guess, and do not act on all of them: "the thermostat" in a house with
  two thermostats is an ambiguous request, not permission to change both. Only
  act on several devices when the person actually asked you to — "all the
  endpoints" is a request about several things; "the thermostat" is not.

  You act only through your tools. Report what you commanded, not what you
  observed. When you set a thermostat, the tool tells you the command was
  accepted; it does not tell you the room is now that temperature, and you
  should not say that it is. Most devices are not like the thermostat: the
  command and the state are the same word — you lock a door and the door is
  locked. Say what you told the device to do, not what it now is. "Locking the
  front door", never "front door locked", and never "done". If a tool reports
  that it refused, say so and say why, in plain language. Never claim something
  worked when it did not.

  You can write down things the house should do on its own, on a repeating
  schedule. Creating one changes nothing now — say it is set for those times,
  never that the house is already that way. Give times as the household's own
  local clock; the timezone is not yours to supply. Only schedule what a device
  says it can be scheduled to do; the house list shows that per device.

  "By 8pm" is not the same request as "at 8pm" — one asks for the house to
  already be that way when eight o'clock arrives, and you can only do the
  other. Ask which they meant rather than picking one. Before pausing or
  deleting a schedule, be sure which one is meant; check the list if more than
  one could fit.

  You can also help the household give you a device you do not have yet. Ask
  the discovery tool what Home Assistant has that this house does not manage,
  and use the entity ids it gives you exactly — never invent one, and never
  guess at one you have not been shown.

  Sometimes somebody hands you the whole house at once — the thermostat, these
  lights, the vacuum, everything they have. Do not walk that one device per
  exchange. Ask discovery once, propose every entity it showed you that
  matches what they named, and present the proposals as a single list with
  each one's id. One yes to that list is agreement to everything on it:
  confirm each proposal in turn. Anything they named that discovery did not
  show you, say you cannot see it — a yes to the list is not a yes to a guess.

  Proposing a device changes nothing. Say what you would write down and say
  that it is proposed, then wait: only after somebody has agreed to that
  proposal, and the confirming tool has told you it was applied, may you say
  the house has it. Reporting a proposal as done is the same lie as reporting
  a room got warm, and a list does not dilute it: every entry on one stays
  proposed until its own confirmation is applied, and only the ones that were
  applied are part of the house.

  You do not validate a device and you do not write files — the tools do both.
  When one refuses, say what it said and why, plainly: a name already taken, a
  setting out of range, a house file Dobby is not able to write. A refusal is
  something the person can act on, and inventing a reason for it is worse than
  repeating the real one.
  """

  @doc """
  The rules Dobby cannot bend, whatever the soul file says.

  Composed after the soul by `Dobby.Soul.system_prompt/0`, so on any conflict
  between personality and honesty, honesty is what the model read last.
  """
  @spec doctrine() :: String.t()
  def doctrine, do: @doctrine

  # Every option below must be a literal. `Jido.AI.Agent`'s macro reads them at
  # expansion time — `name:` is stringified directly, and `tools:` rejects
  # function calls outright — so `@id` cannot be substituted here even though
  # it is the same string.
  use Jido.AI.Agent,
    name: "dobby",
    description: "The household conversational agent",
    model: :capable,
    tools: [
      Dobby.Tools.ThermostatGetStatus,
      Dobby.Tools.ThermostatSetTemperature,
      Dobby.Tools.LightGetStatus,
      Dobby.Tools.LightTurnOn,
      Dobby.Tools.LightTurnOff,
      Dobby.Tools.LightSetBrightness,
      Dobby.Tools.SpeakerGetStatus,
      Dobby.Tools.SpeakerPlay,
      Dobby.Tools.SpeakerPause,
      Dobby.Tools.SpeakerSetVolume,
      Dobby.Tools.CameraGetStatus,
      Dobby.Tools.DoorbellGetStatus,
      Dobby.Tools.LockGetStatus,
      Dobby.Tools.LockSecure,
      Dobby.Tools.AccessCoverGetStatus,
      Dobby.Tools.AccessCoverClose,
      Dobby.Tools.PowerSwitchGetStatus,
      Dobby.Tools.PowerSwitchTurnOn,
      Dobby.Tools.PowerSwitchTurnOff,
      Dobby.Tools.ShadeGetStatus,
      Dobby.Tools.ShadeOpen,
      Dobby.Tools.ShadeClose,
      Dobby.Tools.ShadeSetPosition,
      Dobby.Tools.FanGetStatus,
      Dobby.Tools.FanTurnOn,
      Dobby.Tools.FanTurnOff,
      Dobby.Tools.FanSetSpeed,
      Dobby.Tools.EnvironmentMonitorGetStatus,
      Dobby.Tools.ContactSensorGetStatus,
      Dobby.Tools.OccupancySensorGetStatus,
      Dobby.Tools.SafetySensorGetStatus,
      Dobby.Tools.VacuumGetStatus,
      Dobby.Tools.VacuumStart,
      Dobby.Tools.VacuumDock,
      Dobby.Tools.WifiGetStatus,
      Dobby.Tools.CreateSchedule,
      Dobby.Tools.ListSchedules,
      Dobby.Tools.SetScheduleEnabled,
      Dobby.Tools.DeleteSchedule,
      Dobby.Tools.DiscoverEntities,
      Dobby.Tools.ProposeDevice,
      Dobby.Tools.ConfirmDevice
    ],
    system_prompt: @doctrine,
    # A whole-house adoption turn can spend one iteration on discovery and one
    # per proposed device before it answers. Thirty-two covers a practical
    # spoken inventory while retaining a firm stop for a model that loops.
    max_iterations: 32,
    streaming: true,
    # The ReAct config always sends `temperature` and `max_tokens` — schema
    # defaults with no way to unset them — and req_llm adapts both per model,
    # renaming or dropping as the model requires, narrating every adaptation
    # as a warning on every call. In a name-the-alias-never-the-provider
    # design (§2.1) that adaptation is normal operation, and two warnings per
    # turn is how a real warning gets missed. Silence the narration, keep the
    # adaptation. The cost, accepted: a translation warning that ever does
    # carry news will also be silent here.
    llm_opts: [on_unsupported: :ignore],
    request_transformer: Dobby.DobbyAgent.RequestTransformer,
    signal_routes: [
      {"dobby.device.state_changed", Dobby.DobbyAgent.ObserveDevice},
      # jido_ai casts `ai.tool.started` to the agent but its ReAct strategy
      # routes every sibling signal (`ai.tool.result`, `ai.request.started`,
      # `ai.llm.delta`, ...) to Noop and omits this one. Without the entry,
      # every actuating turn logs a routing error — which would eventually
      # hide a real one. Same idiom the strategy uses for the rest.
      {"ai.tool.started", Jido.Actions.Control.Noop}
    ]

  alias Dobby.Utterance

  @doc """
  The registry ID DobbyAgent runs under.
  """
  @spec id() :: String.t()
  def id, do: @id

  @doc """
  Delivers an utterance and waits for the reply.

  Narrows the tool set to this house on the way in — see the note above about
  why that happens per request rather than at compile time.
  """
  @spec say(Utterance.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def say(%Utterance{} = utterance, opts \\ []) do
    case Dobby.Jido.whereis(@id) do
      pid when is_pid(pid) ->
        ask_sync(pid, Utterance.to_message(utterance), request_opts(utterance, opts))

      nil ->
        {:error, :dobby_not_running}
    end
  end

  @doc """
  Delivers an utterance and returns the runtime event stream for it.

  **The calling process is the event sink.** `ask_stream/3` sets
  `stream_to: {:pid, self()}` (`jido_ai/agent.ex:571`) and the returned
  enumerable blocks in `receive` (`jido_ai/request/stream.ex:107`), so this
  must be called from a process that can afford to sit and iterate — which is
  why `Dobby.Conversation.Turn` runs one task per request and why a LiveView
  cannot call this itself.

  Same request options as `say/2`: the house's tools, and the speaker on the
  tool context.
  """
  @spec stream(Utterance.t(), keyword()) ::
          {:ok, %{request: term(), events: Enumerable.t()}} | {:error, term()}
  def stream(%Utterance{} = utterance, opts \\ []) do
    case Dobby.Jido.whereis(@id) do
      pid when is_pid(pid) ->
        ask_stream(pid, Utterance.to_message(utterance), request_opts(utterance, opts))

      nil ->
        {:error, :dobby_not_running}
    end
  end

  # `:tool_context` reaches every tool the request executes. That is how
  # `create_schedule` learns who asked without the model supplying it:
  # attribution stays a property of the request rather than something the model
  # could get wrong (§6.4).
  defp request_opts(%Utterance{} = utterance, opts) do
    Keyword.merge(
      [
        tools: Dobby.Home.tools(),
        tool_context: %{speaker: utterance.speaker, via: :conversation}
      ],
      opts
    )
  end
end
