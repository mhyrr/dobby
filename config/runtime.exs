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

# The test environment honours no environment variable at all, and that is the
# whole rule rather than a list of exceptions (TK-018). The rig is the house the
# suite describes; which house `mix test` boots must not depend on what a shell
# happens to export.
#
# The .env guard above was written for this and did not reach far enough. An
# exported DOBBY_HOME_MANIFEST arrives in every environment, test included, and
# on 2026-08-20 it did: the suite booted the real WebSocket client against a
# real Home Assistant, and the interventions watcher committed real device rows
# to the test database before the sandbox engaged.
test? = config_env() == :test

# The home file is read here, at runtime, and deliberately not imported by
# config/config.exs (design §4). Imported at compile time it would be frozen
# into the release, and every corrected entity ID would cost a rebuild and a
# redeploy. Read here, changing the house is edit-and-restart.
#
# `import_config` is unavailable in runtime.exs, and neither format is an import
# anyway: `Dobby.HomeConfig` reads the household's YAML and the rig's Elixir and
# hands back the one manifest shape `Dobby.Home` has always taken. It is called
# from here because it is pure — runtime.exs runs with the dependencies loaded
# and the application not started.
#
# Read once rather than inside the cond, because the raise below has to know
# whether the environment is what chose this path.
manifest_env = if test?, do: nil, else: System.get_env("DOBBY_HOME_MANIFEST")

home_path =
  cond do
    test? -> "config/homes/rig.exs"
    manifest_env -> manifest_env
    config_env() == :prod -> "/opt/dobby/config/home.yaml"
    true -> "config/homes/rig.exs"
  end

# A variable exported in a shell outlives the file it names. This one still
# said `local.exs` after YAML became canonical and the file became
# `local.yaml`, and because the real environment is sourced after .env above,
# the stale export beat the corrected line .env.example has carried all along.
# What the boot reported was a missing path — never the variable that chose
# it, which is the sentence that ends the search.
#
# By here the two layers have already been flattened into one environment, so
# the message cannot say which of them holds the bad value. It says both, and
# says which one wins, because that ambiguity is the trap itself: correcting
# .env changes nothing while an export shadows it.
#
# `Dobby.HomeConfig.load!/1` cannot carry this and should not learn how — every
# other caller hands it a path whose provenance it already knows. This is the
# one place a path arrives from the environment, so this is where the
# environment gets named.
if manifest_env && not File.regular?(manifest_env) do
  nearby =
    case Path.wildcard("config/homes/*") do
      [] -> ""
      files -> " This tree has: #{Enum.join(files, ", ")}."
    end

  raise ArgumentError,
        "DOBBY_HOME_MANIFEST names #{manifest_env}, and there is no such file. " <>
          "It is set in this shell or in .env, and an export beats .env — so a " <>
          "stale export survives every correction made there. Point it at a home " <>
          "file, or clear it in both to boot the rig." <> nearby
end

home = Dobby.HomeConfig.load!(home_path)

config :dobby, Dobby.Home, Dobby.HomeConfig.manifest(home)

# Which file that was, so `Dobby.HomeConfig.Writer` writes back to the one this
# boot actually read rather than to wherever the default points.
config :dobby, :home_config_path, home_path

# Dobby's soul travels with the home file and for the same reason: the two files
# under /opt/dobby/config are the parts of Dobby a person should be able to
# change without a release. One says what the house contains; the other says
# who is answering.
soul_path =
  cond do
    test? -> "config/soul.md"
    path = System.get_env("DOBBY_SOUL") -> path
    config_env() == :prod -> "/opt/dobby/config/soul.md"
    true -> "config/soul.md"
  end

config :dobby, :soul_path, soul_path

# The system section, in every environment except the pinned one. All three of
# these used to sit inside `if config_env() == :dev`, which meant a household
# running a release could not choose a provider without rebuilding, and could
# not be reached from its own kitchen at all (TK-018, broken items 1 and 3).
#
# The environment still has the last word wherever it always did: the real
# environment is sourced last, so a variable somebody actually exported beats
# the file — which keeps `DOBBY_MODEL=… mix phx.server` working for the one-off
# it is good at, without it being the only way.
runtime_port =
  if test? do
    nil
  else
    case System.get_env("PORT") do
      nil -> home.system.port || 4000
      exported -> String.to_integer(exported)
    end
  end

if not test? do
  # The section as it is actually in force, which is not always the section the
  # file describes: `DOBBY_MODEL` outranks the model line, and the two settings
  # about how that model answers are the file's either way. Named once, because
  # both of the next two lines are about the same model and used not to be —
  # the alias took the export while the options took the file, and a house was
  # sent OpenRouter's `routing` on a model not reached through OpenRouter and
  # failed every turn from boot (TK-037).
  #
  # Whether the pair is sendable is not asked here and cannot be: ReqLLM
  # resolves a model out of a catalog its own application owns, and no
  # application has started. `Dobby.Application` asks `Dobby.HomeConfig.sendable/3`
  # about this same model before any child starts.
  system = %{home.system | model: Dobby.HomeConfig.model_in_force(home.system)}

  # The `:capable` alias, which is the swap design §2.1 says an alias exists to
  # make: the agent names the alias, never the provider. Unset on both sides
  # means the committed default in config/config.exs.
  if system.model do
    config :jido_ai, :model_aliases, %{capable: system.model}
  end

  # How the model answers — how hard it reasons, what OpenRouter optimizes for
  # — read by DobbyAgent on every request, the way the alias is. No environment
  # override: the file is the durable place, and the eval tier has its own.
  config :dobby, :llm_opts, Dobby.HomeConfig.System.llm_opts(system)

  # Opening Dobby to the household: bind every interface and advertise this
  # machine on the LAN for as long as the server runs (Dobby.LanBeacon). Off by
  # default — loopback is explicit in every environment, and putting a machine
  # on the network is a choice, not a server adapter's default.
  lan? =
    case System.get_env("DOBBY_LAN") do
      nil -> home.system.lan
      exported -> exported in ~w(1 true)
    end

  ip = if lan?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

  config :dobby, DobbyWeb.Endpoint, http: [ip: ip, port: runtime_port]

  if lan? do
    config :dobby, :lan_beacon, hostname: home.system.hostname || "dobby.local"
  end
end

if config_env() == :dev do
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

  host = System.get_env("PHX_HOST") || home.system.hostname || "dobby.local"

  config :dobby, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :dobby, DobbyWeb.Endpoint,
    # One scheme, matching the listener above and the address the household
    # opens. A reverse proxy that changes this contract owns its public URL too.
    url: [host: host, port: runtime_port, scheme: "http"],
    secret_key_base: secret_key_base
end
