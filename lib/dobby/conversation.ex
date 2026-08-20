defmodule Dobby.Conversation do
  @moduledoc """
  The household thread and the people in it (design §10.2, §10.4, §10.8).

  One shared, persistent conversation. Everyone reads the same document, which
  is why nothing here is scoped to a viewer: there is no "my messages", no
  unread count per person, and no per-speaker thread. A house has one
  conversation and this is it.

  ## What gets written here, and what does not

  The thread records **interventions** — things somebody said, things Dobby
  answered, and changes to the house by any path. Passive observation (an
  endpoint flapping at 3am) belongs to `Dobby.Activity`, which records
  everything. That split is design §10.3 and it is the reason two modules exist
  rather than one: the thread is something a person reads, and a log is
  something a machine queries.
  """

  import Ecto.Query

  alias Dobby.Conversation.{Message, Speaker}
  alias Dobby.Repo
  alias Dobby.Utterance

  # How much conversation this house keeps in mind (`TK-007`).
  #
  # It is one number in one place because it is one policy, applied at two
  # moments: `Dobby.Conversation.Rehydrate` reads this many rows at boot, and
  # `Dobby.DobbyAgent.RequestTransformer` sends at most this many messages on
  # every request afterwards. Before the second of those existed the first was
  # the only bound in the system and applied at boot alone, so a process up for
  # a week sent a week of conversation every time anybody spoke.
  #
  # Forty is Greg's call (2026-08-15, "40-50 sounds right"). The live window
  # counts projected messages rather than transcript rows, so it holds slightly
  # less conversation than the boot window does — tool calls and their results
  # are messages too.
  @window 40

  @doc """
  How many messages of conversation the house keeps in mind.
  """
  @spec window() :: pos_integer()
  def window, do: @window

  # -- speakers --------------------------------------------------------------

  @doc """
  Every speaker, alphabetically.
  """
  @spec list_speakers() :: [Speaker.t()]
  def list_speakers do
    Repo.all(from s in Speaker, order_by: [asc: fragment("lower(?)", s.name)])
  end

  @doc """
  Fetches a speaker by id.
  """
  @spec fetch_speaker(integer() | String.t()) :: {:ok, Speaker.t()} | :error
  def fetch_speaker(nil), do: :error

  def fetch_speaker(id) do
    case Repo.get(Speaker, id) do
      nil -> :error
      speaker -> {:ok, speaker}
    end
  end

  @doc """
  Finds a speaker by name, case-insensitively.
  """
  @spec get_speaker_by_name(String.t()) :: Speaker.t() | nil
  def get_speaker_by_name(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase()

    Repo.one(from s in Speaker, where: fragment("lower(?)", s.name) == ^normalized)
  end

  @doc """
  Returns the speaker with this name, creating them if they are new.

  This is the whole of the "Who's this?" prompt: a name is typed once and the
  browser holds the resulting id until somebody switches it.

  Two browsers naming the same person at the same moment is a real race in a
  house where everyone is home, so the unique index is the arbiter and losing
  the race resolves to the row that won rather than to an error. Nobody should
  see a failure for having typed their own name.
  """
  @spec name_speaker(String.t()) :: {:ok, Speaker.t()} | {:error, Ecto.Changeset.t()}
  def name_speaker(name) when is_binary(name) do
    case get_speaker_by_name(name) do
      %Speaker{} = speaker ->
        {:ok, speaker}

      nil ->
        %Speaker{}
        |> Speaker.changeset(%{name: name})
        |> Repo.insert()
        |> case do
          {:ok, speaker} -> {:ok, speaker}
          {:error, changeset} -> resolve_speaker_race(changeset, name)
        end
    end
  end

  defp resolve_speaker_race(changeset, name) do
    case get_speaker_by_name(name) do
      %Speaker{} = speaker -> {:ok, speaker}
      nil -> {:error, changeset}
    end
  end

  # -- the thread ------------------------------------------------------------

  @doc """
  Records what somebody said.

  Takes the envelope rather than a bare string for the same reason
  `DobbyAgent` does (design §1): the speaker and the channel are part of the
  utterance, and a transcript that drops them cannot be replayed into a model
  that attributes across interleaved speakers.
  """
  @spec append_utterance(Utterance.t(), Speaker.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_utterance(%Utterance{} = utterance, %Speaker{} = speaker, opts \\ []) do
    insert_message(%{
      speaker_id: speaker.id,
      role: :user,
      channel: utterance.channel,
      text: utterance.text,
      request_id: Keyword.get(opts, :request_id)
    })
  end

  @doc """
  Records Dobby's reply.

  `meta` carries what the board showed while the reply was being composed —
  the steps, how long it took. It is persisted rather than held in a LiveView
  so that scrolling back to yesterday still shows the work, which is the whole
  point of showing it.
  """
  @spec append_reply(String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_reply(text, opts \\ []) when is_binary(text) do
    insert_message(%{
      role: :assistant,
      text: text,
      request_id: Keyword.get(opts, :request_id),
      meta: Keyword.get(opts, :meta, %{})
    })
  end

  @doc """
  Records a change to the house, whatever caused it.

  `meta` carries the structured half — device, action, outcome, and the `via`
  naming which path did it. `text` is the human half, because the thread is
  read by people and a row of keys is not a sentence.
  """
  @spec append_system_line(String.t(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def append_system_line(text, meta \\ %{}, opts \\ []) when is_binary(text) and is_map(meta) do
    insert_message(%{
      role: :system,
      text: text,
      meta: meta,
      request_id: Keyword.get(opts, :request_id)
    })
  end

  defp insert_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The most recent messages, oldest first.

  Ordered ascending on the way out because that is the order a thread is read
  and the order a model is given its history, but selected from the newest end
  because that is the only end anybody looks at.
  """
  @spec recent(non_neg_integer()) :: [Message.t()]
  def recent(limit \\ 50) when is_integer(limit) and limit >= 0 do
    from(m in Message,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit,
      preload: [:speaker]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The most recent things people and Dobby actually said, oldest first.

  The conversation without the record-keeping: system lines are excluded in
  SQL rather than filtered out afterwards, and that is not an optimization.
  Fetching a fixed number of rows and discarding the system lines among them
  means a busy hour of card taps can push the surrounding conversation out of
  the window — the history goes missing exactly when the house was busiest.
  """
  @spec recent_dialogue(non_neg_integer()) :: [Message.t()]
  def recent_dialogue(limit \\ 40) when is_integer(limit) and limit >= 0 do
    from(m in Message,
      where: m.role in [:user, :assistant],
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit,
      preload: [:speaker]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  The whole transcript, oldest first.

  For the admin and for tests. The thread itself pages with `recent/1`.
  """
  @spec list_messages() :: [Message.t()]
  def list_messages do
    Repo.all(from m in Message, order_by: [asc: m.inserted_at, asc: m.id], preload: [:speaker])
  end
end
