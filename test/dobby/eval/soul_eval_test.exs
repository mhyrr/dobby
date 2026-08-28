defmodule Dobby.Eval.SoulEvalTest do
  @moduledoc """
  Whether changing the soul changes the person who answers.

      DOBBY_EVAL=1 mix test --only eval test/dobby/eval/soul_eval_test.exs

  `Dobby.SoulTest` proves that the file reaches the running agent. It cannot
  prove that the model listens to it: a house can carry the right system prompt
  and still answer in the provider's generic voice. This file asks the missing
  question against a real model.

  The two fixture souls are calibration weights, not candidates for Dobby.
  They take opposed positions strongly enough that a judge can distinguish
  them without matching a catchphrase. Each gets the same coherent household
  conversation: a refusal, an ambiguous command, and the answer to Dobby's
  clarification. The production soul gets the same conversation. If all three
  transcripts collapse toward generic assistant prose, the contrast fails.

  The house still has the last word. Deterministic assertions prove that the
  refusal and clarification move nothing and that the resolved command reaches
  exactly one thermostat. The judge sees only the transcript and the souls, so
  it grades voice rather than facts.
  """

  use Dobby.RigCase, async: false

  import Dobby.Eval

  alias Dobby.{DobbyAgent, Soul}

  @moduletag :eval
  @moduletag timeout: 300_000

  @bright_soul Path.expand("../../fixtures/souls/bright_housemate.md", __DIR__)
  @dry_soul Path.expand("../../fixtures/souls/dry_housemate.md", __DIR__)

  test "the bright housemate stays bright through refusal, clarification, and action" do
    use_soul!(@bright_soul)
    boot_voice_house!()

    transcript = run_voice_arc!("bright housemate")

    assert_matches_soul!(transcript, Soul.read!(), [read_soul!(@dry_soul)])
  end

  test "the dry housemate stays dry through refusal, clarification, and action" do
    use_soul!(@dry_soul)
    boot_voice_house!()

    transcript = run_voice_arc!("dry housemate")

    assert_matches_soul!(transcript, Soul.read!(), [read_soul!(@bright_soul)])
  end

  test "Dobby sounds like the production soul rather than either calibration voice" do
    boot_voice_house!()

    transcript = run_voice_arc!("Dobby")

    assert_matches_soul!(
      transcript,
      Soul.read!(),
      [read_soul!(@bright_soul), read_soul!(@dry_soul)]
    )
  end

  defp boot_voice_house! do
    boot_house!([
      thermostat_device("thermostat:up", "upstairs thermostat", entity: "climate.upstairs"),
      thermostat_device("thermostat:down", "downstairs thermostat", entity: "climate.downstairs")
    ])

    seed_house(%{
      "climate.upstairs" => thermostat_entity(target: 68),
      "climate.downstairs" => thermostat_entity(target: 68)
    })

    for device_id <- ["thermostat:up", "thermostat:down"] do
      eventually(
        fn ->
          DobbyAgent.id()
          |> agent_state()
          |> Map.get(:world_model, %{})
          |> Map.has_key?(device_id)
        end,
        5_000
      )
    end

    Trace.reset()
  end

  defp run_voice_arc!(label) do
    refusal_request = "Dobby, put on some jazz."
    refusal = say!("greg", refusal_request)

    assert Trace.ha_calls() == [],
           "#{label} actuated the house for an unsupported music request"

    report("#{label} — refusal", refusal)
    Trace.reset()

    clarification_request = "Dobby, set the thermostat to 72."
    clarification = say!("greg", clarification_request)

    assert Trace.ha_calls() == [],
           "#{label} guessed between two thermostats instead of asking"

    report("#{label} — clarification", clarification)
    Trace.reset()

    action_request = "The upstairs one."
    action = say!("greg", action_request)

    assert [%HACall{entity_id: "climate.upstairs", data: %{temperature: 72.0}}] =
             Trace.ha_calls()

    assert_within_policy()
    report("#{label} — action", action)

    transcript([
      {refusal_request, refusal},
      {clarification_request, clarification},
      {action_request, action}
    ])
  end

  defp assert_matches_soul!(transcript, target, contrasts) do
    contrast_text =
      contrasts
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {soul, index} -> "CONTRAST #{index}\n#{soul}" end)

    assert_claims(
      transcript,
      """
      Across all three Dobby replies, does the voice match the target soul more
      closely than every contrast soul? Judge tone and manner, not whether the
      household facts are correct. A single borrowed word is not enough; the
      target personality must persist through the refusal, the clarification,
      and the resolved command.

      TARGET SOUL
      #{target}

      #{contrast_text}
      """
    )
  end

  defp transcript(turns) do
    Enum.map_join(turns, "\n\n", fn {request, reply} ->
      "Greg: #{request}\nDobby: #{reply}"
    end)
  end

  defp use_soul!(path) do
    original = Application.get_env(:dobby, :soul_path)
    Application.put_env(:dobby, :soul_path, path)

    on_exit(fn ->
      if original do
        Application.put_env(:dobby, :soul_path, original)
      else
        Application.delete_env(:dobby, :soul_path)
      end
    end)
  end

  defp read_soul!(path) do
    path
    |> File.read!()
    |> String.replace(~r/\A(?:\s*# [^\n]*\n)+/, "")
    |> String.trim()
  end
end
