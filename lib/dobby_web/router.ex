defmodule DobbyWeb.Router do
  use DobbyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DobbyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Identity personalizes and attributes; it never permits (design §7). This
    # is not authentication and there is nothing below it to authenticate to.
    plug DobbyWeb.Plugs.Speaker
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Three routes, no auth on any of them (surface design §2). LAN-only, flat
  # trust: the Wi-Fi password is the boundary, and identity personalizes rather
  # than permits.
  scope "/", DobbyWeb do
    pipe_through :browser

    # Naming yourself is the one round trip on this surface: a LiveView cannot
    # set a cookie, and the cookie is the whole of identity (§7).
    post "/speaker", SpeakerController, :create
    post "/speaker/switch", SpeakerController, :switch

    live_session :household, on_mount: {DobbyWeb.Plugs.Speaker, :speaker} do
      live "/", ThreadLive
      live "/house", HouseLive
      live "/admin", AdminLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", DobbyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:dobby, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DobbyWeb.Telemetry
    end
  end
end
