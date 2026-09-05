defmodule Dobby.Rules do
  @moduledoc """
  The household's standing intentions and the record of their breaches.

  Definitions use the one home-file writer. Proposals and occurrences use
  Postgres because they record a conversation and what happened afterward.
  No function here commands a device. A lock marked hands-only can therefore
  still be watched, without creating a second route around its authority.
  """

  import Ecto.Query
  alias Dobby.{Activity, Conversation, Home, Repo, ThreadEvents}
  alias Dobby.HomeConfig.Writer
  alias Dobby.Rules.{Occurrence, Proposal, Rule}

  @topic "dobby:rules"
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)
  def changed, do: Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, {:rules_changed})

  def list do
    Enum.map(Home.manifest().rules, fn rule ->
      %{
        id: rule.id,
        name: rule.name,
        source: rule.source,
        enabled: rule.enabled,
        description: Rule.describe(rule),
        revision: revision(rule),
        rule: Rule.to_map(rule)
      }
    end)
  end

  def notices do
    Dobby.Rules.Watcher.notices()
  end

  def save(entry, opts \\ []) do
    write(
      fn config ->
        with :ok <- unchanged(config, entry["id"], opts), do: put_rule(config, entry)
      end,
      "rule_saved",
      entry["id"],
      opts
    )
  end

  def set_enabled(id, enabled, opts \\ []) when is_boolean(enabled) do
    write(
      fn config ->
        with :ok <- unchanged(config, id, opts) do
          case find_entry(config, id) do
            nil -> {:error, "there is no rule #{inspect(id)}"}
            entry -> put_rule(config, Map.put(entry, "enabled", enabled))
          end
        end
      end,
      if(enabled, do: "rule_resumed", else: "rule_paused"),
      id,
      opts
    )
  end

  def delete(id, opts \\ []) do
    write(
      fn config ->
        with :ok <- unchanged(config, id, opts) do
          case find_entry(config, id) do
            nil ->
              {:error, "there is no rule #{inspect(id)}"}

            _ ->
              rules = config.house |> Keyword.get(:rules, []) |> Enum.reject(&(&1["id"] == id))
              {:ok, %{config | house: Keyword.put(config.house, :rules, rules)}}
          end
        end
      end,
      "rule_deleted",
      id,
      opts
    )
  end

  defp write(updater, kind, id, opts) do
    case Writer.update(Writer.server(), updater) do
      {:ok, applied} ->
        Activity.record(%{
          kind: kind,
          actor: actor(opts),
          action: id,
          args: %{"rule_id" => id},
          request_id: opts[:request_id]
        })

        changed()
        {:ok, applied}

      error ->
        error
    end
  end

  defp put_rule(config, entry) do
    with :ok <- Writer.writable(config),
         {:ok, manifest} <- Dobby.Home.Manifest.load(config.house),
         {:ok, rule} <- Rule.load(entry, manifest.devices) do
      existing = Keyword.get(config.house, :rules, [])
      canonical = Rule.to_map(rule)

      rules =
        if Enum.any?(existing, &(&1["id"] == rule.id)),
          do: Enum.map(existing, &if(&1["id"] == rule.id, do: canonical, else: &1)),
          else: existing ++ [canonical]

      {:ok, %{config | house: Keyword.put(config.house, :rules, rules)}}
    end
  end

  defp find_entry(config, id),
    do: Enum.find(Keyword.get(config.house, :rules, []), &(&1["id"] == id))

  defp unchanged(config, id, opts) do
    current = find_entry(config, id)

    if opts[:expected_revision] &&
         (current == nil or entry_revision(current) != opts[:expected_revision]) do
      {:error, "that rule changed since this page was opened; review it again"}
    else
      case Keyword.fetch(opts, :expected) do
        :error ->
          :ok

        {:ok, expected} ->
          if find_entry(config, id) == expected,
            do: :ok,
            else: {:error, "that rule changed since this page was opened; review it again"}
      end
    end
  end

  def propose(entry, opts \\ []) do
    config = Writer.current(Writer.server())

    with {:ok, incoming} <- put_rule(config, entry),
         {:ok, _checked} <- Dobby.Home.Manifest.load(incoming.house),
         {:ok, manifest} <- Dobby.Home.Manifest.load(config.house),
         {:ok, rule} <- Rule.load(entry, manifest.devices) do
      attrs = %{
        house_id: manifest.id,
        rule_id: rule.id,
        entry: Rule.to_map(rule),
        previous: find_entry(config, rule.id),
        description: Rule.describe(rule),
        proposed_by: actor(opts),
        request_id: opts[:request_id]
      }

      Repo.transaction(fn ->
        Repo.update_all(
          from(p in Proposal,
            where: p.house_id == ^manifest.id and p.rule_id == ^rule.id and p.status == "proposed"
          ),
          set: [status: "superseded"]
        )

        Repo.insert!(Ecto.Changeset.change(%Proposal{}, attrs))
      end)
    end
  end

  def describe_proposal(proposal) do
    %{
      id: proposal.id,
      rule: proposal.entry,
      description: proposal.description,
      status: proposal.status,
      applied: false
    }
  end

  def proposals do
    house_id = Home.manifest().id
    since = DateTime.add(DateTime.utc_now(), -86_400)

    Repo.all(
      from(p in Proposal,
        where: p.house_id == ^house_id and p.status == "proposed" and p.inserted_at > ^since,
        order_by: [desc: p.id],
        limit: 100
      )
    )
    |> Enum.map(&describe_proposal/1)
  end

  def confirm(id, opts \\ []) do
    with {:ok, id} <- proposal_id(id),
         %Proposal{} = proposal <- Repo.get(Proposal, id),
         :ok <- confirmable(proposal, opts) do
      # The writer serializes the stale-definition comparison with the save.
      # No database lock is held while another process writes the file.
      result =
        Writer.update(Writer.server(), fn config ->
          cond do
            Keyword.fetch!(config.house, :id) != proposal.house_id ->
              {:error, "that proposal belongs to another house"}

            find_entry(config, proposal.rule_id) != proposal.previous ->
              {:error, "that rule changed since the proposal; propose it again"}

            true ->
              put_rule(config, proposal.entry)
          end
        end)

      case result do
        {:ok, applied} ->
          Repo.update!(
            Ecto.Changeset.change(proposal, status: "applied", confirmed_by: actor(opts))
          )

          Activity.record(%{
            kind: "rule_confirmed",
            actor: actor(opts),
            action: proposal.rule_id,
            args: %{"rule_id" => proposal.rule_id},
            request_id: opts[:request_id]
          })

          changed()
          {:ok, applied}

        error ->
          error
      end
    else
      nil -> {:error, "there is no rule proposal #{inspect(id)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirmable(proposal, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      proposal.status != "proposed" ->
        {:error, "that proposal is #{proposal.status}; propose it again"}

      DateTime.diff(now, proposal.inserted_at, :second) >= 86_400 ->
        {:error, "that proposal is over a day old; propose it again"}

      opts[:via] == :conversation and
          (not is_binary(opts[:request_id]) or proposal.request_id == opts[:request_id]) ->
        {:error, "show the rule and wait for the household to agree in a later message"}

      true ->
        :ok
    end
  end

  defp proposal_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp proposal_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, "invalid rule proposal id"}
    end
  end

  defp proposal_id(_), do: {:error, "invalid rule proposal id"}

  def acknowledge(rule_id, actor, opts \\ []) do
    Dobby.Rules.Watcher.acknowledge(rule_id, actor, opts)
  end

  @doc false
  def standing(house_id) do
    Repo.all(from(o in Occurrence, where: o.house_id == ^house_id and is_nil(o.resolved_at)))
  end

  @doc false
  def revision(rule) do
    rule |> Rule.to_map() |> entry_revision()
  end

  defp entry_revision(entry) do
    entry
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def notify(house_id, rule, since, now) do
    text = notice_text(rule, since)

    result =
      Repo.transaction(fn ->
        attrs = %{
          house_id: house_id,
          rule_id: rule.id,
          revision: revision(rule),
          name: rule.name,
          text: text,
          observed_since: since
        }

        occurrence = Repo.insert!(Ecto.Changeset.change(%Occurrence{}, attrs))
        meta = %{"rule_id" => rule.id, "occurrence_id" => occurrence.id, "via" => "standing rule"}
        {:ok, message} = Conversation.append_system_line(text, meta)

        {:ok, _entry} =
          Activity.record(%{
            kind: "rule_breached",
            device: rule.device,
            action: rule.id,
            args: meta,
            result: %{
              "text" => text,
              "observed_since" => DateTime.to_iso8601(since),
              "noticed_at" => DateTime.to_iso8601(now)
            }
          })

        {occurrence, message}
      end)

    case result do
      {:ok, {occurrence, message}} ->
        ThreadEvents.system_line(message)
        changed()
        {:ok, occurrence}

      error ->
        error
    end
  end

  @doc false
  def resolve(%Occurrence{} = occurrence, now) do
    {:ok, _} = Repo.update(Ecto.Changeset.change(occurrence, resolved_at: now))

    Activity.record(%{
      kind: "rule_resolved",
      action: occurrence.rule_id,
      args: %{"rule_id" => occurrence.rule_id, "occurrence_id" => occurrence.id}
    })

    changed()
    :ok
  end

  @doc false
  def acknowledge_occurrence(occurrence, actor) do
    result = Repo.update(Ecto.Changeset.change(occurrence, acknowledged_by: actor))

    case result do
      {:ok, row} ->
        Activity.record(%{
          kind: "rule_acknowledged",
          actor: actor,
          action: row.rule_id,
          args: %{"rule_id" => row.rule_id, "occurrence_id" => row.id}
        })

        changed()
        {:ok, row}

      {:error, changeset} ->
        {:error, Dobby.Changeset.error_message(changeset)}
    end
  end

  @doc false
  def describe_notice(row) do
    %{
      id: row.id,
      rule_id: row.rule_id,
      name: row.name,
      text: row.text,
      acknowledged: row.acknowledged_by != nil
    }
  end

  defp notice_text(rule, since) do
    since = since |> Home.local() |> Calendar.strftime("%-I:%M %p on %b %-d")

    if rule.kind == "absence" do
      "#{rule.name}: no matching change has been recorded since #{since} (#{Rule.condition(rule)})."
    else
      "#{Rule.condition(rule)}. This has held since #{since}."
    end
  end

  defp actor(opts), do: Keyword.get(opts, :actor, "the household")
end
