defmodule DobbyWeb.PageController do
  use DobbyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
