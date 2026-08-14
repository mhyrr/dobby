# The eval tier (real inference, real money, non-deterministic) is opt-in. The
# replay tier is what runs on every `mix test` and in CI; see config/test.exs
# for the matching guard that makes a live call impossible by default.
ExUnit.start(exclude: [:eval])
Ecto.Adapters.SQL.Sandbox.mode(Dobby.Repo, :manual)
