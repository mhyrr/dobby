defmodule Dobby.Interventions do
  @moduledoc """
  What changed in the house, and who did it (design §10.3).

  The thread records **interventions**; `Dobby.Activity` records everything.
  This is the writer for the first half — one line per thing somebody did,
  whatever path they did it by:

      · MAIN THERMOSTAT   SET 70°   — greg, card
      · MAIN THERMOSTAT   SET 70°   — schedule "weeknight heat"
      · MAIN THERMOSTAT   SET 68°   — changed at the thermostat

  Four callers, and that is the point of the module existing. `Dobby.Controls`
  writes one when a card is tapped, `Dobby.Conversation.Turn` when a tool call
  is accepted, and `Dobby.Interventions.Watcher` for the two nobody is standing
  in front of — a schedule at eight o'clock, and a hand on the dial in the
  hallway. A card tap that left no line would make the thread lie by omission:
  somebody scrolls back, sees 70°, and finds no reason for it.

  ## The word is always SET

  There is no per-device vocabulary question here. `SET` means "a commanded
  value" (`DESIGN.md`), and an intervention *is* a commanded value — so the
  word is the same for every device that will ever be commanded. `HELD` is the
  other half: the device declined, and the reason goes beside it.

  That is a different question from what a device currently *reads*, which is
  `DobbyWeb.Flap.read/1`'s job and depends on the device type. Both draw on the
  same eight words.
  """

  require Logger

  alias Dobby.Conversation
  alias Dobby.Conversation.Message
  alias Dobby.ThreadEvents

  @doc """
  Writes one intervention into the thread and tells every surface.

  Required: `:device`, `:name`, `:via`. Optional: `:value` (already rendered),
  `:action`, `:reason`, `:request_id`, and `:word` / `:state` for the refusal
  shape.

  Total by construction. A line in the thread is a description of something
  that already happened in the house, and failing to describe it must never
  take down the thing it was describing.
  """
  @spec record(map()) :: {:ok, Message.t()} | :error
  def record(%{device: device, name: name, via: via} = attrs) do
    meta =
      %{
        "via" => via,
        "device" => device,
        "action" => attrs[:action],
        "word" => attrs[:word] || "Set",
        "state" => to_string(attrs[:state] || :set),
        "value" => attrs[:value],
        "reason" => attrs[:reason]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Conversation.append_system_line(name, meta, request_id: attrs[:request_id]) do
      {:ok, message} ->
        ThreadEvents.system_line(message)
        {:ok, message}

      {:error, changeset} ->
        Logger.error("could not record an intervention: #{inspect(changeset.errors)}")
        :error
    end
  rescue
    error ->
      Logger.error("could not record an intervention: #{Exception.message(error)}")
      :error
  end

  @doc """
  Writes the other half: a device that declined.

  A refused schedule is not an intervention — nothing changed — but a household
  that finds out at bedtime that the heat never came on is worse served by
  silence than by a quiet line. `HELD` is deliberately not loud: a refusal is a
  fact about the device, not a failure of Dobby's.
  """
  @spec held(map()) :: {:ok, Message.t()} | :error
  def held(attrs) do
    record(Map.merge(attrs, %{word: "Held", state: :refused, value: nil}))
  end

  @doc """
  How a commanded value reads on the board.

  Three names for one number, because the tool's result, a schedule's stored
  arguments, and a device snapshot each named it for their own purpose.
  Normalizing that upstream would mean changing three contracts to render one
  line; matching all three here costs a list.
  """
  @spec reading(map()) :: String.t() | nil
  def reading(source) when is_map(source) do
    case first_of(source, [
           :target_temperature_f,
           "target_temperature_f",
           :temperature_f,
           "temperature_f"
         ]) do
      value when is_number(value) -> "#{round(value)}°"
      _absent -> state_reading(source)
    end
  end

  def reading(_source), do: nil

  defp state_reading(source) do
    # `last_event` is the doorbell's ring, and it is a string because Home
    # Assistant's event types are; the rest are Dobby's own state atoms. The
    # explicit nil head matters: nil is an atom, and without it an absent
    # state key reads as the word "Nil" instead of falling through to the
    # percent readings.
    case first_of(source, [
           :lock_state,
           :cover_state,
           :shade_state,
           :power,
           :playback,
           :last_event
         ]) do
      nil ->
        percent_reading(source)

      value when is_atom(value) or is_binary(value) ->
        value |> to_string() |> String.replace("_", " ") |> String.capitalize()

      _other ->
        percent_reading(source)
    end
  end

  defp percent_reading(source) do
    case first_of(source, [:position, :speed_percent, :volume_percent]) do
      value when is_number(value) -> "#{round(value)}%"
      _absent -> nil
    end
  end

  defp first_of(source, keys), do: Enum.find_value(keys, &Map.get(source, &1))
end
