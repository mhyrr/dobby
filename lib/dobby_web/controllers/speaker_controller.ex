defmodule DobbyWeb.SpeakerController do
  @moduledoc """
  The one round trip in the surface (design §7).

  A LiveView cannot set a cookie, and the cookie is the whole of identity here,
  so naming yourself leaves the socket and comes back. It happens once per
  browser and then never again until somebody switches, which is the trade the
  simplest possible identity buys.
  """

  use DobbyWeb, :controller

  alias Dobby.Conversation
  alias DobbyWeb.Plugs.Speaker

  @doc """
  Names whoever is holding this browser, and pins it.
  """
  def create(conn, params) do
    case params |> Map.get("name", "") |> String.trim() do
      "" ->
        redirect(conn, to: back(params))

      name ->
        case Conversation.name_speaker(name) do
          {:ok, speaker} -> conn |> Speaker.remember(speaker) |> redirect(to: back(params))
          # A name the schema refuses — too long, or blank after trimming.
          # The set line comes back still asking, which is the honest answer.
          {:error, _changeset} -> redirect(conn, to: back(params))
        end
    end
  end

  @doc """
  Forgets who this browser is, so the set line asks again.
  """
  def switch(conn, params) do
    conn |> Speaker.forget() |> redirect(to: back(params))
  end

  # Back to the page the form was on. Validated rather than trusted: a
  # redirect target taken from a parameter is an open redirect unless it is
  # pinned to this host, and "it is only on the LAN" is not a reason to leave
  # one lying about.
  defp back(params) do
    case Map.get(params, "return_to") do
      "/" <> _rest = path -> if String.starts_with?(path, "//"), do: "/", else: path
      _other -> "/"
    end
  end
end
