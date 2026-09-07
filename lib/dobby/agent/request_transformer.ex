defmodule Dobby.DobbyAgent.RequestTransformer do
  @moduledoc """
  Injects the house — roster and last-known device state — before each turn.

  Two placement decisions, both deliberate.

  It is **not** in the system prompt, so the system prompt stays byte-identical
  across turns and remains cacheable (design §6.3).

  It is **not** appended to the user's own message either, which is where the
  design originally put it. `Jido.AI.Test.ReActScript` matches a scripted turn
  to a request by exact string equality against the *last user message*
  (`validate_user_match/2`), so decorating the utterance would force every
  replay scenario to spell out the whole rendered blob and would break all of
  them on any prompt tweak. Injecting a separate message immediately *before*
  the utterance keeps the raw utterance last, which keeps scripts readable and
  the caching rationale intact.

  ## Which argument carries the house

  The fourth, not the second. jido_ai calls this as
  `(request, state, config, runtime_context)`
  (`deps/jido_ai/lib/jido_ai/reasoning/react/runner.ex:364`), and the second
  argument is `%Jido.AI.Reasoning.ReAct.State{}` — the *run's* own state:
  iteration, pending tool calls, streaming buffers. It is a fixed Zoi struct
  with no room in it for anything of Dobby's, so reading `:world_model` off it
  returned nil on every turn from the day this file was written. What holds the
  agent's own state — where `Dobby.DobbyAgent.ObserveDevice` writes
  `world_model` — is `runtime_context[:state]`, snapshotted when the request
  starts (`deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex:653`).

  Nothing crashed, which is why it lasted. Every device rendered "state not yet
  known", so the model called `*_get_status` to learn what the block was
  supposed to have told it, and the eval tier quietly paid for the extra turn.
  A scenario cannot catch that by calling `render/1` itself — it has to read
  the messages the runner actually built, which is what
  `Dobby.Scenarios.HouseBlockTest` does.

  One honest limit of that snapshot: it is taken once per request and evolved
  between tool rounds only by state effects the tools themselves returned
  (`evolve_context_state_snapshot/2`, runner.ex:840). A device that moves
  halfway through a turn is in the next turn's block, not this one's.

  ## What else the block carries, and why it is not a tool result

  Beside each device's state, what can be scheduled on it and what can be
  watched on it; beneath the roster, the standing rules and the notices
  standing now. The schedulable surface was rendered here first, because a
  tool schema is fixed at compile time and the answer is a property of the
  house. The observables and the rules followed for a different reason
  (TK-054): the vocabulary lived only in `list_rules`'s result, so the doctrine
  had to ask for that call before every proposal, and every rule request paid
  a model turn — about 5,800 tokens and two to three seconds — to read a list
  that was the same on every turn. Rendered here it costs about 300 tokens
  per turn in the rig house and no turn at all. `list_rules` keeps the same
  vocabulary for the MCP door, whose callers get no house block.
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  @tag "<house>"

  @impl true
  def transform_request(request, _state, _config, runtime_context) do
    context = render(world_model(runtime_context))
    {:ok, %{messages: request.messages |> window() |> inject(context)}}
  end

  defp world_model(runtime_context) when is_map(runtime_context) do
    case Map.get(runtime_context, :state) do
      %{} = agent_state -> Map.get(agent_state, :world_model) || %{}
      _absent -> %{}
    end
  end

  defp world_model(_runtime_context), do: %{}

  @doc """
  Caps the conversation this request carries (`TK-007`).

  `Jido.AI.Context` says of itself "no policies, no windowing, just data", and
  both callers inside jido_ai project it with no limit. So without this a
  DobbyAgent that has been up for a week sends a week of conversation every
  time anybody speaks, and input tokens grow without bound between restarts.
  The window is `Dobby.Conversation.window/0` — the same number the boot-time
  rehydration reads, because it is the same policy at two moments.

  ## Why it cannot just keep the last N

  The projection contains tool traffic: an assistant message carrying
  `tool_calls`, then a `%{role: :tool, tool_call_id: ...}` answering it. Cut
  between those two and the request opens with a tool result whose call is not
  there, which OpenAI and Anthropic both reject outright — an error that would
  appear only after a house had been talking long enough to need trimming,
  which is the worst possible time to find out.

  So the cut lands on the earliest `:user` message that fits. A window always
  starts at somebody speaking, which is both unambiguously legal and the
  natural boundary of a turn.

  When no `:user` message is available to cut at, the messages go through
  untrimmed. That means one request carrying more than forty messages of its
  own tool traffic, which is a real request that must not be corrupted to save
  tokens — and a single request cannot be trimmed from the middle anyway.
  """
  @spec window([map()]) :: [map()]
  def window(messages) do
    case messages do
      [%{role: :system} = system | rest] -> [system | trim(rest, Dobby.Conversation.window())]
      rest -> trim(rest, Dobby.Conversation.window())
    end
  end

  defp trim(messages, limit) do
    count = length(messages)

    if count <= limit do
      messages
    else
      earliest = count - limit

      messages
      |> Enum.with_index()
      |> Enum.find(fn {message, index} -> index >= earliest and role(message) == :user end)
      |> case do
        {_message, index} -> Enum.drop(messages, index)
        nil -> messages
      end
    end
  end

  @doc """
  Renders the roster and world model as the context block the model reads.
  """
  @spec render(map()) :: String.t()
  def render(world_model) do
    devices =
      Dobby.Home.roster()
      |> Enum.map_join("\n", &describe(&1, Map.get(world_model, &1.id)))

    """
    #{@tag}
    #{clock()}
    These are the only devices in the house. Use the id when calling a tool.
    A hands-only device may be read, but language callers may not command or schedule it.
    "watches:" names what a standing rule may watch on a device, with each observable's type or its words.

    #{devices}

    #{rules()}
    </house>
    """
  end

  # The one fact about time the model may not have: which day it is. Without
  # it "September 1st" cannot become an instant, and the eval tier watched the
  # model ask "which year?" rather than call the record. It lives here, not in
  # the system prompt, for the same caching reason as the roster.
  defp clock do
    local = Dobby.Home.local(DateTime.utc_now())

    "The house clock reads #{Calendar.strftime(local, "%A %Y-%m-%d %H:%M")} " <>
      "#{local.zone_abbr}, UTC offset #{offset(local)}."
  end

  defp offset(%DateTime{utc_offset: utc, std_offset: std}) do
    total = utc + std
    sign = if total < 0, do: "-", else: "+"
    hours = total |> abs() |> div(3600)
    minutes = total |> abs() |> div(60) |> rem(60)

    "#{sign}#{String.pad_leading(Integer.to_string(hours), 2, "0")}:#{String.pad_leading(Integer.to_string(minutes), 2, "0")}"
  end

  defp describe(device, nil) do
    "- #{device.id} — #{naming(device)}; state not yet known#{access(device)}#{watches(device)}"
  end

  defp describe(device, snapshot) do
    "- #{device.id} — #{naming(device)}; #{state_phrase(snapshot)}#{access(device)}#{watches(device)}"
  end

  defp access(%{hands_only: true}), do: "; hands only"
  defp access(device), do: schedulable(device)

  # What a standing rule may watch on this device, from the type's own
  # declaration, in the words `Dobby.Tools.ListRules` uses: the observable's
  # name, and its type or the closed set of words it takes. A reading names no
  # unit here, because the unit is the device's to report and the state phrase
  # beside it shows what it reported. Hands-only devices are watchable — a rule
  # only reports — so this follows the access clause rather than replacing it.
  defp watches(device) do
    case device.agent_module.observables() do
      empty when map_size(empty) == 0 ->
        ""

      observables ->
        "; watches: " <>
          (observables
           |> Enum.sort_by(fn {name, _type} -> Atom.to_string(name) end)
           |> Enum.map_join(", ", fn {name, type} -> "#{name} (#{observable_type(type)})" end))
    end
  end

  defp observable_type({:enum, words}), do: Enum.map_join(words, "/", &Atom.to_string/1)
  defp observable_type({:reading, _binding}), do: "number, in the unit the state reports"
  defp observable_type(type), do: Atom.to_string(type)

  # The rules that exist and the notices standing now, by rule id, which is
  # what pausing, deleting and acknowledging take. One line each, so a house
  # with no rules costs a few words and a house with ten costs a hundred.
  defp rules do
    rules =
      case Dobby.Rules.list() do
        [] ->
          "Standing rules: none."

        rules ->
          "Standing rules: " <>
            Enum.map_join(rules, "; ", fn rule ->
              ~s(#{rule.id} "#{rule.name}") <> if(rule.enabled, do: "", else: " (paused)")
            end) <> "."
      end

    case Dobby.Rules.notices() do
      [] ->
        rules

      notices ->
        rules <> "\nStanding notices: " <> Enum.map_join(notices, ", ", & &1.rule_id) <> "."
    end
  end

  # What a schedule may aim at this device, straight from the device type's own
  # declaration (§4.2). Rendered here rather than baked into the
  # `create_schedule` tool's schema, because the answer is a property of the
  # house and tool schemas are fixed at compile time — the same reason the
  # roster lives in this block at all.
  defp schedulable(device) do
    case Map.keys(device.agent_module.scheduled_actions()) do
      [] -> ""
      actions -> "; can be scheduled to: #{Enum.map_join(actions, ", ", &Atom.to_string/1)}"
    end
  end

  defp naming(%{name: name, aliases: []}), do: ~s("#{name}")

  defp naming(%{name: name, aliases: aliases}),
    do: ~s("#{name}", also called #{Enum.join(aliases, ", ")})

  defp state_phrase(%{available: false}), do: "currently unavailable"
  defp state_phrase(%{available: nil}), do: "has not reported yet"

  defp state_phrase(%{type: :thermostat} = snapshot) do
    "thermostat, currently #{temp(snapshot.current_temperature_f)}, set to #{temp(snapshot.target_temperature_f)}, mode #{snapshot.hvac_mode || "unknown"}"
  end

  defp state_phrase(snapshot), do: inspect(Map.drop(snapshot, [:id, :name, :type]))

  defp temp(nil), do: "unknown"
  defp temp(value), do: "#{value}°F"

  # The projection is rebuilt from conversation context each turn, so this is
  # not accumulating across turns. Dropping any prior block anyway makes that
  # a property of this function rather than a property of the caller.
  defp inject(messages, context) do
    messages = Enum.reject(messages, &house_block?/1)
    {before, rest} = split_before_last_user(messages)
    before ++ [%{role: :user, content: context}] ++ rest
  end

  defp house_block?(message) do
    case content(message) do
      text when is_binary(text) -> String.starts_with?(text, @tag)
      _other -> false
    end
  end

  defp split_before_last_user(messages) do
    case last_user_index(messages) do
      nil -> {messages, []}
      index -> Enum.split(messages, index)
    end
  end

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {message, index}, acc ->
      if role(message) in [:user, "user"], do: index, else: acc
    end)
  end

  defp role(%{role: role}), do: role
  defp role(%{"role" => role}) when is_binary(role), do: String.to_existing_atom(role)
  defp role(_message), do: nil

  defp content(%{content: content}), do: content
  defp content(_message), do: nil
end
