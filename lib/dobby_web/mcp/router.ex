defmodule DobbyWeb.MCP.Router do
  @moduledoc """
  The house's tools, offered to an agent that is not Dobby (TK-022 layer B).

  A person sits at their own computer and tells their own AI what to do; that
  AI presents a Dobby-minted token and gets the same tools the household
  thread has — same modules, same schemas, same refusals — with the token's
  label recorded as the speaker. **The tools, not the chat**: the foreign
  agent brings its own model, and nothing here proxies into `DobbyAgent`'s
  ReAct loop.

  ## The roster

  The declarations below are the library — `Dobby.Home.library/0`, every tool
  any house could have — because a declaration cannot read the manifest, the
  same macro-shaped constraint `Dobby.DobbyAgent` documents. `connect/2`
  narrows each connection to `Dobby.Home.tools/0`, so `tools/list` shows a
  visitor exactly what this house has and nothing it does not.

  Each tool's schema is generated from the action module's own NimbleOptions
  declaration — the schema the chat path validates against is the schema the
  MCP client is shown. Phantom is told the schema and deliberately not asked
  to enforce it: `Jido.Action.Tool.execute_action/3` runs the same
  `Jido.Exec` pipeline as the conversation path, so coercion hooks fire and a
  refusal arrives in the tool's own words rather than a transport's.

  ## Trust, stated plainly

  The token is minted on /admin and anyone presenting it on the local network
  is the household — Home Assistant's own long-lived-token posture, ratified
  in TK-022. So `confirm_device` is on the roster: on this path, token
  possession is the blessing. What the token buys the *record* is its label:
  every call is logged with it, so the feed and `confirmed_by` name the agent.

  ## The restart a confirmed change earns

  The chat path holds a confirmed house restart until the turn's reply has
  landed, because a conversation dies with the agent it is running on. This
  path does not: the request runs in the endpoint's own process, a sibling of
  `Dobby.Home`, so the restart is released here, immediately, the way the
  /house forms apply — and the reply that says "applied" is written by a
  process the restart cannot kill.
  """

  use Phantom.Router,
    name: "Dobby",
    vsn: "0.1.0",
    instructions: """
    Dobby is a household agent; these tools read and act on the real devices \
    of one home. Statuses are readings, actuating tools report what was \
    commanded rather than what a room became, and a refusal carries the \
    device's or the house's own reason. `discover_entities`, \
    `propose_device` and `confirm_device` grow the house: a proposal changes \
    nothing until it is confirmed, and confirming is only for when the \
    person you are working for has agreed to that specific proposal.\
    """

  require Logger

  alias Dobby.Activity
  alias Phantom.Session
  alias Phantom.Tool

  # The library, declared. `for` at module scope runs at compile time, so
  # every registered device type's tools are declared here without a central
  # list to edit — a new device type (TK-014) lands on this surface by being
  # added to `Dobby.HomeConfig.Types`, exactly like everywhere else.
  @library Dobby.Home.library()
  @actions Map.new(@library, &{&1.name(), &1})

  for module <- @library do
    json = Jido.Action.Schema.to_json_schema(module.schema())

    tool(module.name(),
      description: module.description(),
      function: :call,
      input_schema: %{
        type: json["type"],
        properties: json["properties"],
        required: json["required"]
      }
    )
  end

  @impl Phantom.Router
  def connect(session, %Plug.Conn{} = conn) do
    with :ok <- not_a_foreign_page(conn),
         {:ok, label} <- bearer_label(conn) do
      {:ok,
       session
       |> Session.assign(:speaker, label)
       |> Session.allow_tools(roster())}
    end
  end

  # MCP clients are programs, not pages, and programs send no Origin header.
  # A request that carries one is a browser being pointed here — and the only
  # browser with any business on this box is a local one. This is the
  # DNS-rebinding defence the MCP spec asks for, done in `connect/2` because
  # Phantom's own `validate_origin: true` refuses the *absent* header too,
  # which would bar every legitimate client this surface exists for.
  defp not_a_foreign_page(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _rest] ->
        if URI.parse(origin).host in ["localhost", "127.0.0.1", "::1"] do
          :ok
        else
          {:forbidden, "this is a household surface; #{origin} is not in the house"}
        end
    end
  end

  # The whole of authentication: the presented bytes are digested and looked
  # up, and the label that comes back is who is speaking. A missing header, a
  # malformed one, a revoked token and an invented one all get the same 401 —
  # the door does not say which.
  defp bearer_label(conn) do
    with ["Bearer " <> presented | _rest] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, label} <- Dobby.MCP.verify(presented) do
      {:ok, label}
    else
      _missing_or_unknown -> {:unauthorized, %{method: "Bearer"}}
    end
  end

  # This house's tools, by name, for the session's allow-list. Empty when the
  # house is between manifests (mid-restart, or a boot with no home file):
  # an honestly empty roster rather than a crash on the doorstep.
  defp roster do
    Enum.map(Dobby.Home.tools(), & &1.name())
  rescue
    ArgumentError -> []
  end

  @doc """
  Every tool call lands here; the tool's own spec says which action runs.

  `execute_action/3` is the same executor the conversation path uses —
  `on_before_validate_params` coercions fire, schema validation refuses in
  the same words, and the speaker rides the context exactly as
  `Dobby.DobbyAgent` sends it, so `create_schedule` and the proposal tools
  attribute to the token's label without the model being asked to repeat it.
  """
  def call(params, session) do
    module = Map.fetch!(@actions, session.request.spec.name)
    speaker = session.assigns.speaker

    started = System.monotonic_time(:millisecond)
    result = Jido.Action.Tool.execute_action(module, params, %{speaker: speaker})
    took = System.monotonic_time(:millisecond) - started

    catch_up()
    record(module, params, result, speaker, session, took)

    case result do
      {:ok, json} -> {:reply, Tool.text(json), session}
      {:error, json} -> {:reply, Tool.error(refusal(json)), session}
    end
  end

  # A confirmed house change is written, validated and announced inside the
  # tool call; the restart is held by the writer. The chat path releases it
  # after the reply lands because a conversation cannot survive its own agent
  # stopping — this request can, so it is released here and "applied" is
  # already true when the client reads it. Every other call finds nothing
  # waiting and this costs one message to the writer.
  defp catch_up do
    case Dobby.HomeConfig.Writer.catch_up() do
      {:error, reason} ->
        Logger.error("the house would not take on a confirmed change: #{reason}")

      _idle_or_applied ->
        :ok
    end

    :ok
  catch
    # No writer means no house file to catch up with.
    :exit, _reason -> :ok
  end

  # The record the admin feed reads, in the same shape `Dobby.Conversation.Turn`
  # writes for the chat path — the actor is the token's label, which is the
  # reason labels exist.
  defp record(module, params, result, speaker, session, took) do
    {state, value} =
      case result do
        {:ok, json} -> {:done, decoded(json)}
        {:error, json} -> {:held, refusal(json)}
      end

    Activity.record(%{
      kind: "tool_call",
      actor: speaker,
      device: params["device"],
      action: module.name(),
      args: Activity.jsonable(params),
      result: %{"state" => to_string(state), "value" => Activity.jsonable(value)},
      duration_ms: took,
      request_id: "mcp:" <> session.id
    })
  end

  # `execute_action/3` wraps a refusal as `{"error": reason}` JSON for the
  # model's eyes; the MCP client is owed the reason itself — the tool's own
  # sentence, which is the same one the chat path hands the model.
  defp refusal(json) do
    case Jason.decode(json) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _other_shape -> json
    end
  end

  defp decoded(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _undecodable -> json
    end
  end
end
