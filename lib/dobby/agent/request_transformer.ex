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
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  @tag "<house>"

  @impl true
  def transform_request(request, state, _config, _extra) do
    context = render(Map.get(state, :world_model) || %{})
    {:ok, %{messages: request.messages |> window() |> inject(context)}}
  end

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
    These are the only devices in the house. Use the id when calling a tool.
    A hands-only device may be read, but language callers may not command or schedule it.

    #{devices}
    </house>
    """
  end

  defp describe(device, nil) do
    "- #{device.id} — #{naming(device)}; state not yet known#{access(device)}"
  end

  defp describe(device, snapshot) do
    "- #{device.id} — #{naming(device)}; #{state_phrase(snapshot)}#{access(device)}"
  end

  defp access(%{hands_only: true}), do: "; hands only"
  defp access(device), do: schedulable(device)

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
