import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/dobby start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Development reads a gitignored .env first, so running against the local
# Home Assistant does not mean re-exporting a token in every shell (see
# .env.example). The real environment is sourced last, so anything actually
# exported still wins. Dev only, deliberately: the test environment's
# determinism — the replay tier's closed loopback ports above all — must not
# be changeable by a file nobody passed to mix.
if config_env() == :dev do
  System.put_env(Dotenvy.source!([".env", System.get_env()]))
end

if System.get_env("PHX_SERVER") do
  config :dobby, DobbyWeb.Endpoint, server: true
end

# The home manifest is read here, at runtime, and deliberately not imported by
# config/config.exs (design §4). Imported at compile time it would be frozen
# into the release, and every corrected entity ID would cost a rebuild and a
# redeploy. Read here, changing the house is edit-and-restart.
#
# `import_config` is unavailable in runtime.exs; Config.Reader.read!/1 is the
# supported path.
home_manifest =
  System.get_env("DOBBY_HOME_MANIFEST") ||
    case config_env() do
      :prod -> "/opt/dobby/config/home.exs"
      _ -> "config/homes/rig.exs"
    end

config :dobby, Dobby.Home, get_in(Config.Reader.read!(home_manifest), [:dobby, Dobby.Home])

# Dobby's soul travels with the manifest and for the same reason: the two files
# under /opt/dobby/config are the parts of Dobby a person should be able to
# change without a release. One says what the house contains; the other says
# who is answering.
soul_path =
  System.get_env("DOBBY_SOUL") ||
    case config_env() do
      :prod -> "/opt/dobby/config/soul.md"
      _ -> "config/soul.md"
    end

config :dobby, :soul_path, soul_path

config :dobby, DobbyWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # The dev server boots against FakeHA by default, and the one thing the
  # fake cannot stand in for is the model. Point `:capable` at whatever
  # provider this machine has a key for and the surface streams for real:
  #
  #     DOBBY_MODEL=openai:gpt-5.6-luna mix phx.server
  #
  # Which is the swap design §2.1 says the alias exists to make — the agent
  # names the alias, never the provider. Here rather than dev.exs so a model
  # named in .env is seen.
  if model = System.get_env("DOBBY_MODEL") do
    config :jido_ai, :model_aliases, %{capable: model}
  end

  # Reload browser tabs when matching files change.
  config :dobby, DobbyWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/dobby_web/router\.ex$"E,
        ~r"lib/dobby_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dobby, Dobby.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :dobby, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :dobby, DobbyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dobby, DobbyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dobby, DobbyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
