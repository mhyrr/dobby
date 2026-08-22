defmodule Dobby.MixProject do
  use Mix.Project

  def project do
    [
      app: :dobby,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Dobby.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.3"},
      # The real Home Assistant client's transport. Mint is already here via
      # Finch; this is the WebSocket extension from the same family. WebSockex
      # (already in the tree via req_llm) was considered and rejected: it has
      # no synchronous call semantics for request correlation and no honest
      # disconnected state — a GenServer over Mint.WebSocket gives both.
      {:mint_web_socket, "~> 1.0"},
      # .env loading for dev (config/runtime.exs). Already in the tree via
      # req_llm; declared because we call it ourselves.
      {:dotenvy, "~> 1.1"},
      # The home file, both directions. Reading was already in the tree via
      # jido_ai; declared because `Dobby.HomeConfig` calls it. `ymlr` is the
      # writing half — the house is machine-round-trippable (TK-018), so
      # something has to emit it.
      {:yaml_elixir, "~> 2.12"},
      {:ymlr, "~> 5.1"},
      # The door for someone else's AI (TK-022 layer B): a streamable-HTTP MCP
      # server as a Plug, chosen over anubis/jido_mcp in the library survey —
      # plug-native, MIT, raw `input_schema:` so the Jido tool mapping stays
      # ours, and a `connect/2` callback that is exactly the bearer-token seam
      # the trust model needs.
      {:phantom_mcp, "~> 0.5.2"},
      # Program dependence graph: what breaks if I change this function, can
      # input reach a sink, did this branch cross a layer boundary. Advisory by
      # default. Dev/test only, never loaded at runtime. `jason` above already
      # unlocks `--format json`.
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      # The other door, for the agent working *on* Dobby rather than through
      # it: an MCP endpoint at /tidewave/mcp that can evaluate code in the
      # running node, read logs, and query the Repo. Dev only, and loopback
      # only by its own default — a LAN-bound dev server does not expose it.
      {:tidewave, "~> 0.9", only: :dev}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind dobby", "esbuild dobby"],
      "assets.deploy": [
        "tailwind dobby --minify",
        "esbuild dobby --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
