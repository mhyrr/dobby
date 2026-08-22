defmodule DobbyWeb.MCPTest do
  @moduledoc """
  The MCP door, exercised the way a foreign agent will use it (TK-022 B).

  Everything here goes over HTTP through the real endpoint — the Phantom
  forward, `connect/2`'s bearer check, the tool dispatch — against the rig's
  house. The properties pinned:

  **The token is the door.** No token and a made-up token get the same 401
  with the way in named; a minted one gets the house.

  **The roster is this house's.** `tools/list` is exactly `Dobby.Home.tools/0`
  by name — the library declares every type's tools, and the session narrows
  to what the manifest actually has, so a one-thermostat house offers no
  light switches.

  **Same tools, same refusals, honest attribution.** The discover → propose →
  confirm arc lands in `home.yaml` with the token's *label* as
  `proposed_by`/`confirmed_by` and as the actor on every activity entry, and
  the refusal a house Dobby cannot write hands back is the writer's own
  sentence, not a transport's.
  """

  use Dobby.RigCase, async: false

  alias Dobby.Activity
  alias Dobby.HomeConfig.Proposal
  alias Dobby.HomeConfig.Proposals
  alias Dobby.HomeConfig.Writer
  alias Dobby.Repo
  alias Dobby.Schedules

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @nest "climate.dining_room"

  setup do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})

    # A real socket, not `Phoenix.ConnTest`: Phantom answers a POST by
    # entering a GenServer loop in the request process, which must therefore
    # be a proc_lib process — Bandit's are, a test's is not. This is also the
    # honest wire: the whole endpoint, the `:mcp` pipeline, the forward.
    server = start_supervised!({Bandit, plug: DobbyWeb.Endpoint, ip: :loopback, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  describe "the door" do
    test "no token is a 401 that names the way in", ctx do
      response = rpc(ctx.base, nil, "tools/list", %{})

      assert response.status == 401
      assert [challenge] = response.headers["www-authenticate"]
      assert challenge =~ "Bearer"
    end

    test "a token Dobby never minted gets the same 401", ctx do
      response = rpc(ctx.base, "made-up-token", "tools/list", %{})

      assert response.status == 401
      assert [challenge] = response.headers["www-authenticate"]
      assert challenge =~ "Bearer"
    end

    test "a revoked token is a token Dobby never minted", ctx do
      {:ok, plaintext, token} = Dobby.MCP.mint("the old laptop")
      {:ok, _revoked} = Dobby.MCP.revoke(token.id)

      assert rpc(ctx.base, plaintext, "tools/list", %{}).status == 401
    end

    test "a foreign browser origin is refused and a local one may enter", ctx do
      token = mint!("the kitchen laptop")

      foreign =
        rpc(ctx.base, token, "tools/list", %{}, [{"origin", "https://outside.example"}])

      assert foreign.status == 403

      local = rpc(ctx.base, token, "tools/list", %{}, [{"origin", "http://localhost:4000"}])
      assert %{"tools" => _tools} = result!(local)
    end
  end

  describe "the roster" do
    test "initialize answers as Dobby, and tools/list is exactly this house's tools", ctx do
      token = mint!("Ann's laptop")

      initialized =
        initialize_stream(ctx.base, token, %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "test", version: "0"}
        })

      init = result!(initialized)

      assert init["serverInfo"]["name"] == "Dobby"

      assert [session_id] = initialized.headers["mcp-session-id"]
      session_header = [{"mcp-session-id", session_id}]

      notification =
        Req.post!(ctx.base <> "/mcp",
          json: %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
          headers: headers(token) ++ session_header,
          retry: false
        )

      assert notification.status == 202

      tools = result!(rpc(ctx.base, token, "tools/list", %{}, session_header))["tools"]
      names = tools |> Enum.map(& &1["name"]) |> Enum.sort()

      # Exactly the house's set: the same modules the chat path is narrowed
      # to, by name, nothing missing and nothing extra.
      assert names == Dobby.Home.tools() |> Enum.map(& &1.name()) |> Enum.sort()

      # The library declares light tools; this house has no light, so the
      # session must not offer one.
      refute "light_turn_on" in names
      assert "thermostat_set_temperature" in names

      # And the schema shown is generated from the action module's own.
      discover = Enum.find(tools, &(&1["name"] == "discover_entities"))
      assert %{"type" => "string"} = discover["inputSchema"]["properties"]["type"]
    end
  end

  describe "growing the house through the door" do
    setup do
      config = writable_house!()

      # The Nest, as Home Assistant already knows it and Dobby does not.
      Fake.put_entity(@nest, %{
        state: "heat",
        attributes: %{friendly_name: "Dining Room Nest", current_temperature: 66, temperature: 68}
      })

      {:ok, config: config}
    end

    test "discover → propose → confirm lands in home.yaml, attributed to the label", ctx do
      token = mint!("Ann's laptop")

      # -- discover: a read, answered from the client's own state ------------
      discovered = call_tool(ctx.base, token, "discover_entities", %{})
      refute discovered["isError"]
      assert text(discovered) =~ @nest

      # -- propose: a row, and nothing else moves ----------------------------
      proposed =
        call_tool(ctx.base, token, "propose_device", %{
          "id" => "thermostat:dining_room",
          "type" => "thermostat",
          "name" => "dining room thermostat",
          "entity_id" => @nest,
          "aliases" => ["the nest"]
        })

      refute proposed["isError"]

      assert [proposal] = Proposals.outstanding()
      assert proposal.proposed_by == "Ann's laptop"
      refute File.read!(ctx.config.path) =~ "dining_room"
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]

      # -- confirm: token possession is the blessing on this path ------------
      confirmed = call_tool(ctx.base, token, "confirm_device", %{"id" => proposal.id})
      refute confirmed["isError"]
      assert Jason.decode!(text(confirmed))["applied"] == true

      written = File.read!(ctx.config.path)
      assert written =~ "thermostat:dining_room"
      assert written =~ @nest

      assert {:ok, stored} = Proposals.fetch(proposal.id)
      assert stored.status == :applied
      assert stored.confirmed_by == "Ann's laptop"

      # The immediate-apply path, not the chat path's held restart: by the
      # time the reply was readable the house had already taken the device on.
      assert "thermostat:dining_room" in Enum.map(Dobby.Home.devices(), & &1.id)
      assert is_pid(Dobby.Jido.whereis("thermostat:dining_room"))
      assert Writer.catch_up() == :idle

      # Every call is on the record with the token's label as the speaker.
      calls =
        Activity.recent(20)
        |> Enum.filter(&(&1.kind == "tool_call"))
        |> Enum.reverse()

      assert Enum.map(calls, & &1.action) ==
               ["discover_entities", "propose_device", "confirm_device"]

      assert Enum.all?(calls, &(&1.actor == "Ann's laptop"))
    end
  end

  describe "attribution through the door" do
    test "a schedule records both the token label and the MCP channel", ctx do
      token = mint!("Ann's laptop")

      created =
        call_tool(ctx.base, token, "create_schedule", %{
          "label" => "weekday heat",
          "cron" => "0 20 * * 1-5",
          "device" => @thermostat,
          "action" => "set_temperature",
          "args" => %{"temperature_f" => 70}
        })

      refute created["isError"]
      assert [schedule] = Schedules.list_schedules()
      assert schedule.created_by == "Ann's laptop"
      assert schedule.created_via == :mcp
    end
  end

  describe "a house Dobby cannot write" do
    test "the confirm refusal is the writer's own sentence", ctx do
      # No writable_house! — the rig runs on config/homes/rig.exs, an Elixir
      # home the writer refuses on purpose. The row is planted directly
      # because proposing would be refused for the same reason; what is under
      # test is that *confirm's* refusal crosses MCP as the tool's own words.
      {:ok, proposal} =
        %Proposal{}
        |> Proposal.changeset(%{
          device_id: "thermostat:dining_room",
          type: "thermostat",
          name: "dining room thermostat",
          entry: %{
            "id" => "thermostat:dining_room",
            "type" => "thermostat",
            "name" => "dining room thermostat",
            "entity_id" => @nest
          },
          status: :proposed,
          proposed_by: "Ann's laptop"
        })
        |> Repo.insert()

      token = mint!("Ann's laptop")
      refused = call_tool(ctx.base, token, "confirm_device", %{"id" => proposal.id})

      assert refused["isError"] == true
      assert text(refused) =~ "Dobby writes YAML"
      assert text(refused) =~ "migrate the house to a .yaml file first"

      # Refused means refused: the row is still outstanding and the house is
      # exactly what it was.
      assert {:ok, %{status: :proposed}} = Proposals.fetch(proposal.id)
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
    end
  end

  # -- speaking JSON-RPC over the real wire ----------------------------------

  defp mint!(label) do
    {:ok, plaintext, _token} = Dobby.MCP.mint(label)
    plaintext
  end

  # Streamed and halted at the first complete `message` frame, because two of
  # Phantom's habits otherwise hang or pollute a plain read: an `initialize`
  # POST keeps its stream open on purpose (it becomes the session stream), and
  # every closing POST appends an `event: closed` frame whose data is a word,
  # not JSON.
  defp rpc(base, token, method, params, extra_headers \\ []) do
    Req.post!(base <> "/mcp",
      json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
      headers: headers(token) ++ extra_headers,
      retry: false,
      into: &collect/2
    )
  end

  # Initialize owns the session's long-lived response stream. Keep that
  # request alive while the client sends its initialized notification and
  # later RPCs with the returned session id. Halting at the first frame, as the
  # one-shot helper does, proves only a sequence of unrelated POSTs.
  defp initialize_stream(base, token, params) do
    test = self()
    ref = make_ref()

    child_spec =
      Task.child_spec(fn ->
        Req.post!(base <> "/mcp",
          json: %{jsonrpc: "2.0", id: 1, method: "initialize", params: params},
          headers: headers(token),
          retry: false,
          into: fn {:data, chunk}, {request, response} ->
            body = if(is_binary(response.body), do: response.body, else: "") <> chunk
            response = %{response | body: body}

            if is_nil(Process.get(ref)) and Regex.match?(~r/^data: .*\n\n/m, body) do
              Process.put(ref, :sent)
              send(test, {ref, response})
            end

            {:cont, {request, response}}
          end
        )
      end)
      |> Map.put(:id, {:mcp_initialize_stream, ref})

    _pid = start_supervised!(child_spec)
    assert_receive {^ref, response}, 2_000
    response
  end

  defp collect({:data, chunk}, {request, response}) do
    body = if(is_binary(response.body), do: response.body, else: "") <> chunk
    response = %{response | body: body}

    if Regex.match?(~r/^data: .*\n\n/m, body) do
      {:halt, {request, response}}
    else
      {:cont, {request, response}}
    end
  end

  defp headers(nil), do: [accept: "application/json, text/event-stream"]

  defp headers(token),
    do: [accept: "application/json, text/event-stream", authorization: "Bearer " <> token]

  defp call_tool(base, token, name, arguments) do
    result!(rpc(base, token, "tools/call", %{name: name, arguments: arguments}))
  end

  # The one response to the one request, out of the SSE frames Phantom
  # streams a POST's answers in. A JSON-RPC *error* — wrong method, invalid
  # params — fails the test loudly: every refusal this suite expects arrives
  # as a tool result with `isError`, the shape the contract promises.
  defp result!(%Req.Response{} = http) do
    assert http.status == 200, "expected 200, got #{http.status}: #{inspect(http.body)}"

    assert [response] =
             http.body
             |> String.split("\n\n", trim: true)
             |> Enum.filter(&String.contains?(&1, "event: message"))
             |> Enum.map(fn frame ->
               [_line, json] = Regex.run(~r/^data: (.+)$/m, frame)
               Jason.decode!(json)
             end)

    refute response["error"], "JSON-RPC error: #{inspect(response["error"])}"
    response["result"]
  end

  defp text(result) do
    assert [%{"type" => "text", "text" => text} | _rest] = result["content"]
    text
  end
end
