defmodule Dobby.Release do
  @moduledoc """
  What a box needs from Dobby with no Mix installed: bring the schema up, and
  take one step back.

  `bin/migrate` runs `migrate/0` before every start (`ExecStartPre` in
  `box/dobby.service`), so an upgrade is untar, repoint `current`, restart —
  and a migration that cannot run keeps the house down with the reason in the
  journal, rather than starting a house that is about to miss a table.
  Migrating from `Dobby.Application.start/2` was rejected: a schema change
  would become a supervisor's concern, the rig and the suite would have to opt
  out of it, and a person could no longer run the one step by itself.

  `rollback/2` is by hand only, through `bin/dobby eval`. Nothing rolls back on
  its own: a box that undid its own migrations is one nobody could reason
  about the next morning.

  `config/runtime.exs` runs before either function, so the house file and the
  service environment must be in place to migrate — the same `dobby.env` the
  service loads. That is the point: a box that can migrate is a box that can
  boot.
  """
  @app :dobby

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Postgres over TLS needs :ssl started, and on the box it may be.
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
