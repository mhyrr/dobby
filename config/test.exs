import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dobby, Dobby.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "dobby_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# A fixed ReAct checkpoint secret keeps the rig's logs free of the ephemeral
# -secret warning, so a real warning during a scenario stays visible. Nothing
# in the replay tier depends on checkpoints surviving a VM restart.
config :jido_ai, react_token_secret: "rig-only-not-a-secret-0000000000000000"

# The replay tier must never reach a real model, and nothing in jido_ai stops
# it: when no script matches a request, `ReAct.Runner` falls straight through
# to `ReqLLM.Generation.stream_text/3`. Since Dobby's agents are started by the
# application supervisor, scripts have to be threaded explicitly through the
# ask — so forgetting one is an ordinary mistake with a billable outcome.
#
# Pointing every provider at a closed loopback port turns that mistake into an
# instant connection refusal naming this URL. The fake keys matter as much as
# the base_url: without them the suite would be passing only because no real
# credentials happen to be exported, and would start dialing out the day
# someone sets one up for the eval tier.
# Lifted only for the eval tier, which is supposed to reach a real model:
#
#     mix test                              # replay only; network impossible
#     DOBBY_EVAL=1 mix test --only eval     # real inference, real credentials
#
# The default is the safe one, so the guard cannot be lost by forgetting a flag.
if System.get_env("DOBBY_EVAL") in [nil, ""] do
  for provider <- [:anthropic, :openai, :openrouter, :groq, :google] do
    config :req_llm, provider,
      base_url: "http://127.0.0.1:1/replay-tier-must-not-call-a-real-model"
  end

  config :req_llm,
    anthropic_api_key: "rig-fake-key-never-valid",
    openai_api_key: "rig-fake-key-never-valid"
else
  # The eval tier resolves `:capable` to a real model. It points at OpenAI
  # rather than the Anthropic default in config/exs because that is the key
  # this machine actually has — which is exactly the swap design §2.1 says an
  # alias exists to make.
  #
  # gpt-5.6-luna is the model Dobby is being built against (Greg, 2026-08-14).
  # Note the dots: the dashed form resolves as an unverified model. Rotating
  # models is still a test — a single-model eval hides model-specific defects,
  # and both of the two the suite has caught were found by swapping — so
  # DOBBY_EVAL_MODEL is how a rotation is run deliberately, rather than a
  # second model being carried permanently.
  config :jido_ai, :model_aliases, %{
    capable: System.get_env("DOBBY_EVAL_MODEL", "openai:gpt-5.6-luna")
  }
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dobby, DobbyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NiFM7PDLaZSvmozhw+v2cdQW5zWyEmlh0dV9rZQvs4OrAr3zUWh9uYcB9owB20Vj",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
