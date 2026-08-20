defmodule DobbyWeb.SpeakerControllerTest do
  @moduledoc """
  The one round trip on this surface (design §7).

  What these prove is the half a LiveView cannot: that a name typed once ends
  up in a cookie the browser keeps, and that switching clears it.
  """

  use DobbyWeb.ConnCase, async: true

  alias Dobby.Conversation
  alias DobbyWeb.Plugs.Speaker

  describe "naming yourself" do
    test "creates the speaker and pins the browser to them", %{conn: conn} do
      conn = post(conn, ~p"/speaker", %{"name" => "greg", "return_to" => "/"})

      assert redirected_to(conn) == "/"
      assert %{value: value, max_age: max_age} = conn.resp_cookies[Speaker.cookie()]
      assert Conversation.get_speaker_by_name("greg")

      # Ten years, not a browser session. A household tablet that quietly
      # forgot who it was every few weeks would look like a bug in Dobby.
      assert max_age > 365 * 24 * 60 * 60
      assert is_binary(value)
    end

    test "a name that already exists is the same person", %{conn: conn} do
      {:ok, existing} = Conversation.name_speaker("Greg")

      post(conn, ~p"/speaker", %{"name" => "greg"})

      assert length(Conversation.list_speakers()) == 1
      assert Conversation.get_speaker_by_name("greg").id == existing.id
    end

    test "an empty name leaves the browser as it was", %{conn: conn} do
      conn = post(conn, ~p"/speaker", %{"name" => "   "})

      assert redirected_to(conn) == "/"
      assert conn.resp_cookies[Speaker.cookie()] == nil
      assert Conversation.list_speakers() == []
    end

    # Observed in the wild: the placeholder question vanished under the
    # typing, and a whole request went in as a name. The schema refuses
    # anything over 40 letters, and no speaker or cookie comes of it.
    test "a sentence typed as a name is not a name", %{conn: conn} do
      sentence = "Hey Dobby, can you set the thermostat to seventy three?"

      conn = post(conn, ~p"/speaker", %{"name" => sentence})

      assert redirected_to(conn) == "/"
      assert conn.resp_cookies[Speaker.cookie()] == nil
      assert Conversation.list_speakers() == []
    end

    # A redirect target taken from a parameter is an open redirect unless it is
    # pinned to this host, and "it is only on the LAN" is not a reason to leave
    # one lying about.
    test "will not be redirected off this house", %{conn: conn} do
      assert conn
             |> post(~p"/speaker", %{"name" => "greg", "return_to" => "//evil.test"})
             |> redirected_to() == "/"

      assert build_conn()
             |> post(~p"/speaker", %{"name" => "sam", "return_to" => "https://evil.test"})
             |> redirected_to() == "/"
    end

    test "comes back to the page the form was on", %{conn: conn} do
      conn = post(conn, ~p"/speaker", %{"name" => "greg", "return_to" => "/house"})

      assert redirected_to(conn) == "/house"
    end
  end

  describe "switching" do
    test "forgets who this browser is", %{conn: conn} do
      conn = post(conn, ~p"/speaker/switch", %{"return_to" => "/"})

      assert redirected_to(conn) == "/"
      assert %{max_age: 0} = conn.resp_cookies[Speaker.cookie()]
    end
  end

  describe "the plug" do
    test "a browser carrying a name is known on the next request", %{conn: conn} do
      conn = conn |> post(~p"/speaker", %{"name" => "greg"}) |> get(~p"/")

      assert conn.assigns.speaker.name == "greg"
      assert get_session(conn, :speaker_id) == conn.assigns.speaker.id
    end

    # The cookie outlives the row it points at — the speaker could be removed
    # from the database while a tablet in the kitchen is still carrying the id.
    # That has to read as "nobody", not as a crash.
    test "a cookie pointing at nobody is nobody", %{conn: conn} do
      conn = post(conn, ~p"/speaker", %{"name" => "greg"})
      Dobby.Repo.delete_all(Dobby.Conversation.Speaker)

      conn = get(conn, ~p"/")

      assert conn.assigns.speaker == nil
      assert get_session(conn, :speaker_id) == nil
    end
  end
end
