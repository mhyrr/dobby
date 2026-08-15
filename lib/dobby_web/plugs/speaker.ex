defmodule DobbyWeb.Plugs.Speaker do
  @moduledoc """
  Who is holding this browser (surface design §7).

  A name typed on a browser sticks until somebody switches it. That is the
  whole feature. There is no shared-device flag, no idle re-prompt, and no
  per-session identity: the kitchen iPad is a browser like any other, and if
  four people use it, it says whatever the last person set it to.

  That cost is affordable **because identity gates nothing.** It personalizes
  and attributes; it never permits (design §10.2). The blast radius of a wrong
  name is a wrong name in one sentence and a wrong `created_by` on a schedule —
  which is also why the kids setting it to each other's names as a joke is a
  known and accepted outcome rather than a hole.

  ## Two halves, one cookie

  The plug runs on every HTML request: it reads the signed cookie, resolves the
  speaker, and copies the id into the session. `on_mount/4` reads it back out of
  the session when a LiveView connects, because a LiveView socket has a session
  and does not have the request's cookies.

  Writing the cookie is a controller's job — `DobbyWeb.SpeakerController` — since
  a LiveView cannot set one. That is the only reason naming yourself is a round
  trip rather than an event, and it happens once per browser.
  """

  import Plug.Conn

  alias Dobby.Conversation

  @cookie "_dobby_speaker"

  # Ten years. The cookie is the whole of identity here, and a household
  # tablet that quietly forgot who it was every few weeks would look like a
  # bug in Dobby rather than an expiring cookie.
  @max_age 10 * 365 * 24 * 60 * 60

  @doc """
  The cookie a browser's speaker id is kept in.
  """
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])

    case Conversation.fetch_speaker(conn.cookies[@cookie]) do
      {:ok, speaker} ->
        conn |> assign(:speaker, speaker) |> put_session(:speaker_id, speaker.id)

      # Nobody, or a cookie pointing at a speaker who no longer exists. Both
      # mean the same thing to every surface — ask who this is.
      :error ->
        conn |> assign(:speaker, nil) |> delete_session(:speaker_id)
    end
  end

  @doc """
  Pins this browser to a speaker.
  """
  @spec remember(Plug.Conn.t(), Conversation.Speaker.t()) :: Plug.Conn.t()
  def remember(conn, %Conversation.Speaker{} = speaker) do
    put_resp_cookie(conn, @cookie, speaker.id,
      sign: true,
      max_age: @max_age,
      same_site: "Lax",
      http_only: true
    )
  end

  @doc """
  Forgets who this browser is.
  """
  @spec forget(Plug.Conn.t()) :: Plug.Conn.t()
  def forget(conn), do: delete_resp_cookie(conn, @cookie)

  @doc """
  Puts the browser's speaker on a connecting LiveView.

  Used as a `live_session` `on_mount` hook, so every route in the household
  session gets the same answer without each LiveView reaching for the session
  itself.
  """
  def on_mount(:speaker, _params, session, socket) do
    speaker =
      case Conversation.fetch_speaker(session["speaker_id"]) do
        {:ok, speaker} -> speaker
        :error -> nil
      end

    {:cont, Phoenix.Component.assign(socket, :speaker, speaker)}
  end
end
