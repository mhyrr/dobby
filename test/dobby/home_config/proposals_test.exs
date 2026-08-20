defmodule Dobby.HomeConfig.ProposalsTest do
  @moduledoc """
  Proposing a device, and agreeing to one (TK-010).

  Two properties carry this file. **Proposed is not applied** — nothing about
  `propose/2` touches a file, a manifest, or a house — and **confirm is where
  the writer is**, which is also where the second validation happens, against
  the house as it stands rather than as it stood when somebody said the words.

  The model is absent from all of it, on purpose. Everything here is what the
  deterministic layer does with fields, whoever produced them.
  """

  use Dobby.RigCase, async: false

  import Ecto.Query

  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Proposals
  alias Dobby.HomeConfig.Writer

  @thermostat "thermostat:main"
  @entity "climate.main_floor"

  setup do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity()})
    :ok
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "thermostat:dining_room",
        "type" => "thermostat",
        "name" => "dining room thermostat",
        "aliases" => ["the nest"],
        "bindings" => %{"climate" => "climate.dining_room"}
      },
      overrides
    )
  end

  describe "proposing" do
    setup do
      writable_house!()
      :ok
    end

    test "a valid entry is stored, with an id, and the house does not move" do
      assert {:ok, proposal} = Proposals.propose(entry(), proposed_by: "greg")

      assert proposal.id
      assert proposal.status == :proposed
      assert proposal.device_id == "thermostat:dining_room"
      assert proposal.type == "thermostat"
      assert proposal.name == "dining room thermostat"
      assert proposal.proposed_by == "greg"

      # The whole point. Nothing was written and nothing was started.
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
      refute File.read!(Writer.current().path) =~ "dining_room"
    end

    test "the entry is kept exactly as it was agreed, not re-read later" do
      assert {:ok, proposal} = Proposals.propose(entry(), proposed_by: "greg")

      assert proposal.entry == entry()
      assert Proposals.describe(proposal).entry == entry()
    end

    test "an entry the file format would refuse comes back in the file format's words" do
      # Not a copy of the rule — `HomeConfig.add_device/2` is the same function a
      # loaded home file goes through, so the sentence names the field the way
      # it would if somebody had typed it.
      assert {:error, reason} =
               Proposals.propose(entry(%{"bindings" => %{"heater" => "climate.dining_room"}}))

      assert reason =~ "unknown binding \"heater\""
      assert reason =~ "a thermostat binds: climate"
      assert Proposals.outstanding() == []
    end

    test "a setting out of the device type's range is refused naming the setting" do
      assert {:error, reason} =
               Proposals.propose(
                 entry(%{
                   "settings" => %{"min_temperature_f" => 80, "max_temperature_f" => 60}
                 })
               )

      assert reason =~ "settings.min_temperature_f"
      assert reason =~ "exceeds max_temperature_f"
      assert Proposals.outstanding() == []
    end

    test "an id this house already uses is refused before anybody says yes" do
      assert {:error, reason} = Proposals.propose(entry(%{"id" => @thermostat}))

      assert reason =~ "already has a device called"
      assert reason =~ @thermostat
    end

    test "an entity another device is already bound to is refused naming that device" do
      assert {:error, reason} =
               Proposals.propose(entry(%{"bindings" => %{"climate" => @entity}}))

      assert reason =~ @entity
      assert reason =~ "main thermostat"
    end

    test "a name another device already answers to is refused by the whole-house check" do
      # `add_device/2` validates the entry; this is the other half — one
      # namespace for names, because the model resolves speech against it.
      assert {:error, reason} = Proposals.propose(entry(%{"name" => "main thermostat"}))

      assert reason =~ "duplicate device names"
    end
  end

  describe "supersession and expiry" do
    setup do
      writable_house!()
      :ok
    end

    test "proposing the same device again supersedes the first, rather than stacking" do
      # "No — call it the dining room one" is a correction to a proposal, not a
      # second device. Two outstanding proposals for one id would make "yes"
      # ambiguous, which is the one thing a confirmation cannot be.
      assert {:ok, first} = Proposals.propose(entry(%{"name" => "nest"}))
      assert {:ok, second} = Proposals.propose(entry(%{"name" => "dining room thermostat"}))

      assert Enum.map(Proposals.outstanding(), & &1.id) == [second.id]

      assert {:ok, superseded} = Proposals.fetch(first.id)
      assert superseded.status == :superseded
      assert superseded.decided_at
    end

    test "a different device proposed alongside it stays outstanding" do
      assert {:ok, first} = Proposals.propose(entry())

      assert {:ok, second} =
               Proposals.propose(
                 entry(%{
                   "id" => "light:porch",
                   "type" => "light",
                   "name" => "porch light",
                   "aliases" => [],
                   "bindings" => %{"light" => "light.porch"}
                 })
               )

      assert Enum.map(Proposals.outstanding(), & &1.id) == [first.id, second.id]
    end

    test "a proposal goes stale after a day, and says so rather than being deleted" do
      # Computed from `inserted_at` at read time, never swept: a stored expiry
      # can be wrong and a computed one cannot. The row stays because the
      # household asked for it and is entitled to see that it did.
      assert {:ok, proposal} = Proposals.propose(entry())

      fresh = proposal.inserted_at
      stale = DateTime.add(fresh, Proposals.ttl_hours() * 3600 + 60, :second)

      refute Proposals.expired?(proposal, fresh)
      assert Proposals.expired?(proposal, stale)

      assert Proposals.status(proposal, fresh) == "proposed"
      assert Proposals.status(proposal, stale) == "expired"
      assert Proposals.describe(proposal, stale).status == "expired"
    end

    test "confirming a stale proposal is refused, with the age in the sentence" do
      assert {:ok, proposal} = Proposals.propose(entry())

      backdate!(proposal, Proposals.ttl_hours() + 1)

      assert {:error, reason} = Proposals.confirm(proposal.id)
      assert reason =~ "hours old"
      assert reason =~ "propose it again"

      # Refused means refused: the house did not take it.
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
    end
  end

  describe "confirming" do
    setup do
      config = writable_house!()
      {:ok, config: config}
    end

    test "the file is written and the manifest applied before it returns", %{config: config} do
      assert {:ok, proposal} = Proposals.propose(entry(), proposed_by: "greg")
      assert {:ok, applied, result} = Proposals.confirm(proposal.id, confirmed_by: "kate")

      assert applied.status == :applied
      assert applied.confirmed_by == "kate"
      assert applied.decided_at

      # Applied is true when it is said: the file says so and the manifest in
      # effect says so. The processes catch up a moment later — see
      # `Dobby.HomeConfig.Writer.catch_up/1`.
      assert File.read!(config.path) =~ "thermostat:dining_room"
      assert :house in result.on_restart

      manifest = Application.get_env(:dobby, Dobby.Home)
      ids = manifest |> Keyword.fetch!(:devices) |> Enum.map(& &1.id)
      assert "thermostat:dining_room" in ids
    end

    test "the house takes the device on when it is told to catch up", %{config: _config} do
      assert {:ok, proposal} = Proposals.propose(entry())
      assert {:ok, _applied, _result} = Proposals.confirm(proposal.id)

      # Deferred until here on purpose: this is what `Dobby.Conversation.Turn`
      # calls once a turn has finished, because restarting the house stops the
      # agent any in-flight request is running on.
      assert {:ok, _applied} = Writer.catch_up()

      ids = Enum.map(Dobby.Home.devices(), & &1.id)
      assert "thermostat:dining_room" in ids

      # And it is a real device, not a manifest line: it has an agent, and the
      # roster the model reads each turn knows its name.
      assert is_pid(Dobby.Jido.whereis("thermostat:dining_room"))
      assert Enum.any?(Dobby.Home.roster(), &(&1.name == "dining room thermostat"))
    end

    test "catching up with nothing waiting is idle rather than a restart" do
      assert Writer.catch_up() == :idle
    end

    test "a proposal cannot be applied twice" do
      assert {:ok, proposal} = Proposals.propose(entry())
      assert {:ok, _applied, _result} = Proposals.confirm(proposal.id)

      assert {:error, reason} = Proposals.confirm(proposal.id)
      assert reason =~ "already applied"
    end

    test "a superseded proposal cannot be confirmed by mistake" do
      assert {:ok, first} = Proposals.propose(entry(%{"name" => "nest"}))
      assert {:ok, _second} = Proposals.propose(entry())

      assert {:error, reason} = Proposals.confirm(first.id)
      assert reason =~ "replaced by a later one"
    end

    test "a proposal id nobody made is refused rather than guessed at" do
      assert {:error, "there is no proposal 4242"} = Proposals.confirm(4242)
      assert {:error, reason} = Proposals.confirm("the nest one")
      assert reason =~ "is not a proposal id"
    end

    test "a house that changed underneath the proposal refuses it at confirm time" do
      # The load-bearing check. A proposal is a sentence somebody remembered,
      # and between the sentence and the yes the house can move.
      assert {:ok, proposal} = Proposals.propose(entry())

      config = Writer.current()

      {:ok, taken} =
        HomeConfig.add_device(config, %{
          "id" => "thermostat:dining_room",
          "type" => "thermostat",
          "name" => "someone else's dining room",
          "bindings" => %{"climate" => "climate.elsewhere"}
        })

      {:ok, _applied} = Writer.save(Writer, taken, defer_house: true)

      assert {:error, reason} = Proposals.confirm(proposal.id)
      assert reason =~ "already has a device called"
    end

    test "a model id that arrived as a string still resolves" do
      assert {:ok, proposal} = Proposals.propose(entry())

      assert %{id: id} = Proposals.coerce_id_param(%{id: to_string(proposal.id)})
      assert id == proposal.id
    end
  end

  describe "a house Dobby is not allowed to write" do
    test "proposing is refused up front, in the writer's own words" do
      # The rig's house is `config/homes/rig.exs`, which is what a household
      # running an Elixir home has. A proposal that could never be confirmed is
      # worse than a plain no: it invites somebody to say yes to nothing.
      assert {:error, reason} = Proposals.propose(entry())

      assert reason =~ "Dobby writes YAML"
      assert reason =~ "rig.exs"
      assert reason =~ "migrate the house to a .yaml file first"

      assert Proposals.outstanding() == []
    end

    test "the refusal is the writer's rule, asked without writing anything" do
      assert {:error, message} = Writer.writable(Writer.current())
      assert {:error, ^message} = Proposals.propose(entry())
    end
  end

  # Ages a row by rewriting the column the clock is read from. Expiry is
  # computed rather than stored, so this is the only way to be old.
  defp backdate!(proposal, hours) do
    id = proposal.id

    Dobby.Repo.update_all(
      from(p in Dobby.HomeConfig.Proposal, where: p.id == ^id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -hours * 3600, :second)]
    )
  end
end
