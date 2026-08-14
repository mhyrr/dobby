defmodule Dobby.Repo do
  use Ecto.Repo,
    otp_app: :dobby,
    adapter: Ecto.Adapters.Postgres
end
