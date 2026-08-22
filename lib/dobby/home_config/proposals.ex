defmodule Dobby.HomeConfig.Proposals do
  @moduledoc """
  Proposing a device, and agreeing to one (TK-010, TK-018 layer E).

  "Add this Nest as the dining room thermostat" arrives as a sentence and has
  to leave as a mapping in `home.yaml`. Between those two things sits the split
  this whole design turns on: **the model extracts, code computes**. The model
  reads the sentence and produces fields. Nothing here asks it whether the
  fields are any good — `Dobby.HomeConfig.add_device/2` decides that, using the
  same validation a hand-typed file gets, and a refusal comes back in the
  refusal's own words with the field named.

  ## Why proposals are stored

  The same reason schedules are (design §9): the household has to be able to
  see what is outstanding, and a proposal made before dinner has to survive the
  box restarting before somebody says yes after it. It also gives the thing an
  id, which is what "yes, that one" resolves to when two are open.

  ## Proposed is not applied

  `propose/2` writes no file, starts no agent and changes no house. It is
  reported as proposed, and doctrine holds Dobby to saying so. Only
  `confirm/2` reaches `Dobby.HomeConfig.Writer`, which is the one process that
  writes the home file — and the reply may say the house has the device only
  after that has returned.

  ## Supersession and expiry

  Two different problems, handled differently on purpose.

  *Supersession* is a correction. "No — call it the dining room one" is a
  second proposal for the same device id, and the first is superseded rather
  than left lying around to be confirmed by mistake. A partial unique index
  makes one-outstanding-per-id the only reachable state, so this cannot be
  forgotten in code.

  *Expiry* is a change of mind that nobody said out loud. A proposal older than
  a day is stale: the household thread is a slow medium, "yes" the next
  morning is a real yes and "yes" a fortnight later is somebody scrolling. It
  is computed from `inserted_at` at read time rather than swept by a job,
  because a stored expiry can be wrong and a computed one cannot — the same
  posture `Dobby.Schedules` takes about `next_fire`. A stale proposal is
  refused with its age in the sentence, and asking again costs one turn.

  Expiry is deliberately *not* the safety property. The safety property is that
  `confirm/2` re-validates against the house as it is now, so a proposal that
  stopped making sense — its entity bound by somebody else, its id taken —
  is refused however fresh it is.
  """

  import Ecto.Query

  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Discovery
  alias Dobby.HomeConfig.Proposal
  alias Dobby.HomeConfig.Writer
  alias Dobby.Repo

  @ttl_hours 24

  # -- reads -----------------------------------------------------------------

  @doc """
  Every proposal that is still outstanding, oldest first.
  """
  @spec outstanding() :: [Proposal.t()]
  def outstanding do
    Repo.all(from p in Proposal, where: p.status == :proposed, order_by: [asc: p.id])
  end

  @doc """
  Fetches a proposal by the id a person would say out loud.
  """
  @spec fetch(integer() | String.t()) :: {:ok, Proposal.t()} | {:error, String.t()}
  def fetch(id) do
    case cast_id(id) do
      {:ok, id} ->
        case Repo.get(Proposal, id) do
          nil -> {:error, "there is no proposal #{id}"}
          proposal -> {:ok, proposal}
        end

      :error ->
        {:error, "#{inspect(id)} is not a proposal id"}
    end
  end

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _other -> :error
    end
  end

  defp cast_id(_other), do: :error

  @doc """
  Coerces a proposal id a model supplied into the integer the schema declares.

  Same edge, same lesson as `Dobby.Schedules.coerce_id_param/1`: a model that
  has just read `id: 2` out of a tool result will occasionally send it back as
  `"2"`, and meeting it there once is cheaper than a contradiction.
  """
  @spec coerce_id_param(map()) :: map()
  def coerce_id_param(params) do
    Map.update(params, :id, nil, fn
      value when is_binary(value) ->
        case Integer.parse(value) do
          {id, ""} -> id
          _other -> value
        end

      value ->
        value
    end)
  end

  @doc """
  A proposal rendered for a reader — the model, or a surface.

  `status` is the stored status with the clock applied, so an outstanding
  proposal that has gone stale reports `"expired"` rather than inviting a
  confirmation that would be refused a moment later.
  """
  @spec describe(Proposal.t(), DateTime.t()) :: map()
  def describe(%Proposal{} = proposal, now \\ DateTime.utc_now()) do
    %{
      id: proposal.id,
      status: status(proposal, now),
      device: proposal.device_id,
      type: proposal.type,
      name: proposal.name,
      entry: proposal.entry,
      proposed_by: proposal.proposed_by,
      proposed_at: DateTime.to_iso8601(proposal.inserted_at)
    }
  end

  @doc """
  What this proposal is, right now, with the clock taken into account.
  """
  @spec status(Proposal.t(), DateTime.t()) :: String.t()
  def status(proposal, now \\ DateTime.utc_now())

  def status(%Proposal{status: :proposed} = proposal, now) do
    if expired?(proposal, now), do: "expired", else: "proposed"
  end

  def status(%Proposal{status: status}, _now), do: Atom.to_string(status)

  @doc """
  Whether a proposal has been outstanding longer than anybody meant it to be.
  """
  @spec expired?(Proposal.t(), DateTime.t()) :: boolean()
  def expired?(%Proposal{inserted_at: at}, now \\ DateTime.utc_now()) do
    DateTime.diff(now, at, :hour) >= @ttl_hours
  end

  @doc """
  How long a proposal stays confirmable, in hours.
  """
  @spec ttl_hours() :: pos_integer()
  def ttl_hours, do: @ttl_hours

  # -- writes ----------------------------------------------------------------

  @doc """
  Validates a proposed device against the running house and writes it down.

  Changes nothing about the house. The entry is the YAML shape a home file
  holds, and it is put through `Dobby.HomeConfig.add_device/2` — the same
  function a loaded file goes through — so the refusal a household reads is the
  file format's own sentence, naming the field.

  Refuses up front on a house Dobby cannot write, because a proposal that could
  never be confirmed is worse than a plain no: it invites somebody to say yes
  to nothing. `Dobby.HomeConfig.Writer.writable/1` owns that sentence.
  """
  @spec propose(map(), keyword()) :: {:ok, Proposal.t()} | {:error, String.t()}
  def propose(entry, opts \\ []) when is_map(entry) do
    config = Writer.current()

    with :ok <- Writer.writable(config),
         {:ok, proposed} <- HomeConfig.add_device(config, entry),
         {:ok, _manifest} <- HomeConfig.validate(proposed),
         :ok <- Discovery.validate_entry(entry) do
      store(entry, config, opts)
    end
  end

  # Superseding and inserting in one transaction, so the partial unique index
  # cannot be reached from two directions at once.
  defp store(entry, config, opts) do
    device = added_device(config, entry)

    Repo.transaction(fn ->
      supersede_outstanding(device.id)

      attrs = %{
        device_id: device.id,
        type: Map.get(entry, "type"),
        name: device.name,
        entry: entry,
        status: :proposed,
        proposed_by: actor(opts, :proposed_by)
      }

      case Repo.insert(Proposal.changeset(%Proposal{}, attrs)) do
        {:ok, proposal} -> proposal
        {:error, changeset} -> Repo.rollback(Dobby.Changeset.error_message(changeset))
      end
    end)
  end

  # The validated device, not the raw mapping: the id and name stored on the
  # row have to be the ones the file would carry, and `add_device/2` is what
  # says so.
  defp added_device(config, entry) do
    {:ok, proposed} = HomeConfig.add_device(config, entry)
    proposed.house |> Keyword.fetch!(:devices) |> List.last()
  end

  defp supersede_outstanding(device_id) do
    Repo.update_all(
      from(p in Proposal, where: p.status == :proposed and p.device_id == ^device_id),
      set: [status: :superseded, decided_at: DateTime.utc_now()]
    )
  end

  @doc """
  Applies a proposal somebody agreed to, through the one writer.

  Validated a second time, against the house as it is at this moment rather
  than as it was when the words were said. That check carries the guarantee: a
  proposal is a sentence somebody remembered, and between the sentence and the
  yes another device may have taken the id or claimed the entity.

  The household thread restarts the house a moment late — see
  `Dobby.HomeConfig.Writer.catch_up/1` — so its own reply can land first. An
  external request passes `defer_house: false` because its process survives a
  house restart and its success must mean the running house took the device on.
  """
  @spec confirm(integer() | String.t(), keyword()) ::
          {:ok, Proposal.t(), Dobby.HomeConfig.Applied.t()} | {:error, String.t()}
  def confirm(id, opts \\ []) do
    with {:ok, proposal} <- fetch(id),
         :ok <- confirmable(proposal),
         {:ok, applied} <-
           Writer.update(
             Writer.server(),
             fn config ->
               with :ok <- Writer.writable(config),
                    {:ok, incoming} <- HomeConfig.add_device(config, proposal.entry),
                    :ok <- Discovery.validate_entry(proposal.entry) do
                 {:ok, incoming}
               end
             end,
             defer_house: Keyword.get(opts, :defer_house, true)
           ) do
      {:ok, mark_applied(proposal, opts), applied}
    end
  end

  defp confirmable(%Proposal{status: :applied} = proposal),
    do: {:error, "proposal #{proposal.id} was already applied"}

  defp confirmable(%Proposal{status: :superseded} = proposal),
    do: {:error, "proposal #{proposal.id} was replaced by a later one"}

  defp confirmable(%Proposal{} = proposal) do
    if expired?(proposal) do
      {:error,
       "proposal #{proposal.id} is more than #{@ttl_hours} hours old; propose it again to be sure it still says what you want"}
    else
      :ok
    end
  end

  defp mark_applied(proposal, opts) do
    {:ok, applied} =
      proposal
      |> Proposal.changeset(%{
        status: :applied,
        confirmed_by: actor(opts, :confirmed_by),
        decided_at: DateTime.utc_now()
      })
      |> Repo.update()

    applied
  end

  # The speaker travels on the request context, never as something the model was
  # asked to repeat back (§6.4). A channel that sets none still attributes to
  # the household rather than to nobody.
  defp actor(opts, key) do
    case Keyword.get(opts, key) do
      name when is_binary(name) and name != "" -> name
      _other -> "the household"
    end
  end
end
