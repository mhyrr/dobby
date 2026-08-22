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

  # The MCP door (TK-022): none of the browser plugs, and no `:accepts`
  # either. CSRF protection defends forms a browser submits, and nothing here
  # is one; the session cookie and the speaker plug are the household
  # surface's identity, and this surface's identity is the bearer token
  # `DobbyWeb.MCP.Router` checks in `connect/2`. Content negotiation is
  # Phantom's: a POST carries JSON or it answers 400, and the GET listen
  # stream every client opens after initialize — `accept: text/event-stream`
  # alone — gets its 405 from Phantom, where `:accepts, ["json"]` turned it
  # into a 406 exception page on every connection.
  pipeline :mcp do
  end

  # Three routes, no auth on any of them (design §10.1). LAN-only, flat
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

  # A user's own AI on the LAN, presenting a token minted on /admin. The
  # tools-only JSON path adds no processes: Phantom answers each POST in the
  # endpoint's own request process, which is a sibling of Dobby.Home — so a
  # confirmed house change restarting the house cannot kill the reply that
  # reports it. `validate_origin` is off at the plug because Phantom's check
  # refuses a *missing* Origin header too, and MCP clients are programs that
  # send none; the origin rule lives in `DobbyWeb.MCP.Router.connect/2`,
  # where absent passes and a foreign page is refused.
  scope "/mcp" do
    pipe_through :mcp

    forward "/", Phantom.Plug,
      router: DobbyWeb.MCP.Router,
      validate_origin: false
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
