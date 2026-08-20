defmodule Dobby.Scenarios.AdoptDeviceTest do
  @moduledoc """
  "Add this Nest as the dining room thermostat" (TK-010, TK-018 layer E).

  The arc this layer exists for, run end to end through the real ReAct loop
  with only the model scripted: a person says it in the household thread, Dobby
  looks at what Home Assistant has that the house does not manage, proposes a
  device, says it is *proposed*, somebody says yes in a second turn, and the
  file on disk grows a device.

  ## Two rules this file exists to hold

  **Proposed is reported as proposed.** The turn that proposes writes no file,
  starts no agent and changes no house. If that ever stops being true, the
  first turn's assertions go red before anybody has to notice a sentence.

  **The refusal comes back in its own words.** A house Dobby cannot write, an
  id already taken, a binding that is not one — the model is handed the actual
  sentence and has to account for it, rather than being trusted to be modest.

  ## Why these turns run through `Turn.run/3`

  Because the house restarting is part of the arc. `Dobby.HomeConfig.Writer`
  holds the restart until the turn that confirmed it is over — a request cannot
  survive the agent it is running on being stopped — and
  `Dobby.Conversation.Turn` is what lets it go. A scenario that called
  `DobbyAgent.say/2` would test the tools and skip the sentence.

  ## The scripting rule

  `ReActScript` matches a turn to a request by exact string equality against the
  *last* user message, and `Dobby.DobbyAgent.RequestTransformer` injects the
  house block as its own message before the utterance for exactly that reason.
  So `user(Utterance.to_message(utterance))` is the whole match, and stays true
  however the roster is rendered.
  """

  use Dobby.RigCase, async: false

  import Jido.AI.Test

  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.Conversation.Turn
  alias Dobby.HomeConfig.Proposals
  alias Dobby.HomeConfig.Writer
  alias Dobby.ThreadEvents
  alias Dobby.Utterance

  @thermostat "thermostat:main"
  @entity "climate.main_floor"
  @nest "climate.dining_room"

  setup do
    boot_house!([thermostat_device(@thermostat, "main thermostat", entity: @entity)])
    seed_house(%{@entity => thermostat_entity(current: 68, target: 68)})

    # The Nest, as Home Assistant already knows it and Dobby does not.
    Fake.put_entity(@nest, %{
      state: "heat",
      attributes: %{friendly_name: "Dining Room Nest", current_temperature: 66, temperature: 68}
    })

    ThreadEvents.subscribe()
    {:ok, speaker} = Conversation.name_speaker("greg")

    Trace.reset()
    %{speaker: speaker}
  end

  describe "the propose → confirm arc" do
    setup do
      config = writable_house!()
      {:ok, config: config}
    end

    test "a spoken device is proposed, agreed to, and ends up in home.yaml", ctx do
      # -- turn one: propose ---------------------------------------------------
      said = Utterance.new("greg", "add this Nest as the dining room thermostat")

      proposing =
        expect_react do
          user(Utterance.to_message(said))

          call("discover_entities", %{"type" => "thermostat"})

          call("propose_device", %{
            "id" => "thermostat:dining_room",
            "type" => "thermostat",
            "name" => "dining room thermostat",
            "entity_id" => @nest,
            "aliases" => ["the nest"]
          })

          answer("""
          I've written down a dining room thermostat on climate.dining_room, \
          also answering to "the nest" — that's proposal 1. Nothing's changed \
          yet; say the word and I'll add it.\
          """)
        end

      Turn.run(said, ctx.speaker, react_opts(proposing))

      assert_receive {:replied, %Message{role: :assistant, text: proposed_text}}
      assert proposed_text =~ "proposal 1"

      # Proposed is proposed. The tools ran, and the house did not move.
      assert Trace.tool_calls() == ["discover_entities", "propose_device"]
      assert [proposal] = Proposals.outstanding()
      assert proposal.device_id == "thermostat:dining_room"
      assert proposal.proposed_by == "greg"

      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
      refute File.read!(ctx.config.path) =~ "dining_room"
      assert Trace.ha_calls() == []

      # -- the box reboots between the two ------------------------------------
      #
      # Not a workaround: this is the property the row exists for. A proposal
      # made before dinner has to survive the house restarting and still be the
      # thing "yes" resolves to. It also gives the second turn a fresh
      # conversation, which is what a rehydrated agent has.
      {:ok, _pid} = Dobby.Home.restart()

      assert [^proposal] = Proposals.outstanding()

      # -- turn two: somebody says yes ----------------------------------------
      agreed = Utterance.new("greg", "yes, add it")

      confirming =
        expect_react do
          user(Utterance.to_message(agreed))
          call("confirm_device", %{"id" => proposal.id})
          answer("Done — the dining room thermostat is part of the house now.")
        end

      Turn.run(agreed, ctx.speaker, react_opts(confirming))

      assert_receive {:replied, %Message{role: :assistant, text: applied_text}}
      assert applied_text =~ "dining room thermostat"

      # The file is the record, and it now says so.
      written = File.read!(ctx.config.path)
      assert written =~ "thermostat:dining_room"
      assert written =~ @nest
      assert written =~ "the nest"

      assert {:ok, stored} = Proposals.fetch(proposal.id)
      assert stored.status == :applied
      assert stored.confirmed_by == "greg"
      assert Proposals.outstanding() == []

      # And the house restarted underneath, after the reply rather than during
      # it — which is the only reason the reply exists to be read.
      ids = Enum.map(Dobby.Home.devices(), & &1.id)
      assert "thermostat:dining_room" in ids
      assert is_pid(Dobby.Jido.whereis("thermostat:dining_room"))
    end

    test "the discovery tool hands over ids rather than leaving them to be guessed", ctx do
      _ = ctx
      said = Utterance.new("greg", "what does Home Assistant have that you don't manage?")

      script =
        expect_react do
          user(Utterance.to_message(said))
          call("discover_entities", %{})
          answer("There's a Dining Room Nest I'm not managing — a thermostat, by the look of it.")
        end

      Turn.run(said, ctx.speaker, react_opts(script))

      assert_receive {:replied, %Message{role: :assistant}}

      # Nothing was written, nothing reached Home Assistant, and the bound
      # entity is not on offer. Discovery is a read.
      assert Trace.tool_calls() == ["discover_entities"]
      assert Trace.ha_calls() == []
      assert Proposals.outstanding() == []
    end

    test "a proposal the house refuses comes back to the thread in its own words", ctx do
      said = Utterance.new("greg", "add the Nest as the main thermostat")

      script =
        expect_react do
          user(Utterance.to_message(said))

          # The model extracted an id this house already uses. Our code refuses
          # it; the model has to say why rather than inventing a reason.
          call("propose_device", %{
            "id" => @thermostat,
            "type" => "thermostat",
            "name" => "dining room thermostat",
            "entity_id" => @nest
          })

          answer("There's already a thermostat:main here — pick another name for the Nest.")
        end

      Turn.run(said, ctx.speaker, react_opts(script))

      assert_receive {:replied, %Message{role: :assistant, text: text}}
      assert text =~ "already"

      # The refusal happened in our code, not in the model's manners.
      assert Proposals.outstanding() == []
      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
      refute File.read!(ctx.config.path) =~ "dining_room"

      # And the step is HELD in the thread, which is how a refusal reads on the
      # board — the device declined, not Dobby failing.
      assert_receive {:step, _request_id, %{state: :held, detail: detail}}
      assert detail =~ "already has a device called"
    end

    test "the model cannot confirm a proposal nobody made", ctx do
      _ = ctx
      said = Utterance.new("greg", "yes, add the one we talked about")

      script =
        expect_react do
          user(Utterance.to_message(said))
          call("confirm_device", %{"id" => 99})
          answer("I haven't got a proposal 99 — nothing's been written down yet.")
        end

      Turn.run(said, ctx.speaker, react_opts(script))

      assert_receive {:step, _request_id, %{state: :held, detail: detail}}
      assert detail =~ "there is no proposal 99"

      assert Enum.map(Dobby.Home.devices(), & &1.id) == [@thermostat]
    end
  end

  describe "a house Dobby cannot write" do
    test "the refusal says so plainly, and nothing is proposed", %{speaker: speaker} do
      # No `writable_house!` here: the rig runs on `config/homes/rig.exs`, which
      # is what a household running an Elixir home has. The editing surfaces are
      # read-only there and must say so, and so must the thread.
      said = Utterance.new("greg", "add this Nest as the dining room thermostat")

      script =
        expect_react do
          user(Utterance.to_message(said))

          call("propose_device", %{
            "id" => "thermostat:dining_room",
            "type" => "thermostat",
            "name" => "dining room thermostat",
            "entity_id" => @nest
          })

          answer("""
          I can't add it: this house is described in an .exs file, which isn't \
          one I can write. Move it to a .yaml one and I'll be able to.\
          """)
        end

      Turn.run(said, speaker, react_opts(script))

      assert_receive {:step, _request_id, %{state: :held, detail: detail}}
      assert detail =~ "Dobby writes YAML"
      assert detail =~ "migrate the house to a .yaml file first"

      assert_receive {:replied, %Message{role: :assistant, text: text}}
      assert text =~ "can't"

      # Nothing stored, because a proposal that could never be confirmed invites
      # somebody to say yes to nothing.
      assert Proposals.outstanding() == []
      assert Writer.current().format == :exs
    end
  end
end
