# Initializes a freshly started local Home Assistant rig (docs/local-ha.md).
#
#     mix run --no-start dev/home-assistant/onboard.exs
#
# --no-start because this needs Req and a socket, not a booted house.
#
# One shot, idempotent by refusal: if the instance is already onboarded it
# says so and stops. It creates the owner account, sets US customary units —
# Dobby's thermostat fields say Fahrenheit, and this is where that stays true
# — finishes onboarding, and mints the long-lived access token Dobby needs.
# The credentials are printed, never written anywhere.

defmodule Dobby.Dev.HAOnboard do
  @moduledoc false

  def run do
    {:ok, _apps} = Application.ensure_all_started(:req)

    url = System.get_env("DOBBY_HA_URL", "http://localhost:8123")
    username = System.get_env("DOBBY_HA_USERNAME", "dobby")
    password = System.get_env("DOBBY_HA_PASSWORD") || random_password()
    client_id = url <> "/"

    ensure_fresh!(url)

    IO.puts("Creating owner account #{inspect(username)} ...")

    auth_code = create_user!(url, client_id, username, password)
    access_token = exchange_code!(url, client_id, auth_code)
    finish_onboarding!(url, client_id, access_token)

    IO.puts("Setting US customary units ...")

    [config_result, token_result] =
      websocket_commands(url, access_token, [
        %{
          type: "config/core/update",
          unit_system: "us_customary",
          time_zone: System.get_env("DOBBY_HA_TIMEZONE", "America/New_York")
        },
        %{type: "auth/long_lived_access_token", client_name: "dobby", lifespan: 3650}
      ])

    unless config_result["success"], do: abort("could not set units: #{inspect(config_result)}")
    unless token_result["success"], do: abort("could not mint token: #{inspect(token_result)}")

    IO.puts("""

    Done. Home Assistant is onboarded at #{url}.

      username: #{username}
      password: #{password}

    Write the password down — it exists nowhere else.

    Restart Home Assistant once — entities rendered before the unit change
    keep reporting Celsius until they do:

      (cd dev/home-assistant && docker compose restart)

    Dobby's environment (put these in .env — see .env.example):

      DOBBY_HA_URL=#{url}
      DOBBY_HA_TOKEN=#{token_result["result"]}
    """)
  end

  # -- REST onboarding --------------------------------------------------------

  defp ensure_fresh!(url) do
    case Req.get(url <> "/api/onboarding", retry: false) do
      {:ok, %{status: 200, body: steps}} ->
        user_step = Enum.find(steps, &(&1["step"] == "user"))

        if user_step == nil or user_step["done"] do
          abort("""
          this Home Assistant is already onboarded. To start over:

              cd dev/home-assistant && docker compose down && rm -rf config && docker compose up -d
          """)
        end

      {:ok, %{status: status}} ->
        abort("unexpected #{status} from #{url}/api/onboarding — is this Home Assistant?")

      {:error, reason} ->
        abort("""
        cannot reach Home Assistant at #{url} (#{inspect(reason)}). Start it first:

            cd dev/home-assistant && docker compose up -d
        """)
    end
  end

  defp create_user!(url, client_id, username, password) do
    body = %{
      client_id: client_id,
      name: "Dobby",
      username: username,
      password: password,
      language: "en-US"
    }

    case Req.post!(url <> "/api/onboarding/users", json: body, retry: false) do
      %{status: 200, body: %{"auth_code" => auth_code}} -> auth_code
      %{status: status, body: body} -> abort("creating the user failed (#{status}): #{inspect(body)}")
    end
  end

  defp exchange_code!(url, client_id, auth_code) do
    form = [grant_type: "authorization_code", code: auth_code, client_id: client_id]

    case Req.post!(url <> "/auth/token", form: form, retry: false) do
      %{status: 200, body: %{"access_token" => token}} -> token
      %{status: status, body: body} -> abort("token exchange failed (#{status}): #{inspect(body)}")
    end
  end

  defp finish_onboarding!(url, client_id, access_token) do
    auth = [{"authorization", "Bearer " <> access_token}]

    for {step, body} <- [
          {"core_config", %{}},
          {"analytics", %{}},
          {"integration", %{client_id: client_id, redirect_uri: client_id <> "?auth_callback=1"}}
        ] do
      case Req.post!(url <> "/api/onboarding/#{step}", headers: auth, json: body, retry: false) do
        %{status: 200} -> :ok
        %{status: status, body: body} -> abort("onboarding #{step} failed (#{status}): #{inspect(body)}")
      end
    end
  end

  # -- a small WebSocket session ---------------------------------------------

  # Authenticates, runs each command in order, returns the result messages.
  # Sequential and blocking on purpose: this is a setup script, not a client.
  defp websocket_commands(url, access_token, commands) do
    uri = URI.parse(url)
    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/api/websocket", [])

    session = %{conn: conn, ref: ref, websocket: nil, messages: [], buffer: []}
    {session, %{"type" => "auth_required"}} = next_message(session)

    session = send_json(session, %{type: "auth", access_token: access_token})
    {session, %{"type" => "auth_ok"}} = next_message(session)

    {_session, results} =
      commands
      |> Enum.with_index(1)
      |> Enum.reduce({session, []}, fn {command, id}, {session, results} ->
        session = send_json(session, Map.put(command, :id, id))
        {session, %{"type" => "result", "id" => ^id} = result} = next_message(session)
        {session, [result | results]}
      end)

    Enum.reverse(results)
  end

  defp next_message(%{messages: [message | rest]} = session),
    do: {%{session | messages: rest}, message}

  defp next_message(%{messages: []} = session) do
    tcp_message =
      receive do
        message -> message
      after
        10_000 -> abort("timed out waiting for Home Assistant")
      end

    case Mint.WebSocket.stream(session.conn, tcp_message) do
      {:ok, conn, responses} ->
        next_message(Enum.reduce(responses, %{session | conn: conn}, &absorb(&2, &1)))

      {:error, _conn, reason, _responses} ->
        abort("Home Assistant connection failed: #{inspect(reason)}")

      :unknown ->
        next_message(session)
    end
  end

  defp absorb(session, {:status, ref, status}) when ref == session.ref,
    do: Map.put(session, :upgrade_status, status)

  defp absorb(session, {:headers, ref, headers}) when ref == session.ref do
    {:ok, conn, websocket} =
      Mint.WebSocket.new(session.conn, ref, session.upgrade_status, headers)

    %{session | conn: conn, websocket: websocket}
  end

  defp absorb(session, {:data, ref, data}) when ref == session.ref do
    {:ok, websocket, frames} = Mint.WebSocket.decode(session.websocket, data)

    decoded =
      for {:text, text} <- frames do
        Jason.decode!(text)
      end

    %{session | websocket: websocket, messages: session.messages ++ decoded}
  end

  defp absorb(session, _response), do: session

  defp send_json(session, payload) do
    {:ok, websocket, data} = Mint.WebSocket.encode(session.websocket, {:text, Jason.encode!(payload)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(session.conn, session.ref, data)
    %{session | conn: conn, websocket: websocket}
  end

  defp random_password do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp abort(message) do
    IO.puts(:stderr, "\n#{message}")
    System.halt(1)
  end
end

Dobby.Dev.HAOnboard.run()
