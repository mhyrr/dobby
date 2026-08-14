defmodule Dobby.Tools.CreateSchedule do
  @moduledoc """
  Tool: write down something the house should do on its own (design §6.2, §9).

  This is where the language work concentrates. "I always want the thermostat
  at 70 by 8pm on weekdays" has to leave as `0 20 * * 1-5` and
  `set_temperature(70)`, because from that moment on nothing re-reads the
  sentence — `SchedulerAgent` reads the row, and the row is all there is.

  Two things are deliberately not the model's to supply.

  The **timezone** comes from the home manifest. A household means its own
  eight o'clock, and a model asked to name a timezone is a model given a way
  to be wrong about one.

  **Who asked** comes from the request context, not from an argument. The
  speaker is input framing (§6.4) and asking the model to repeat it back would
  make attribution something it could get wrong.

  What this returns is a schedule *created*. Not a room that got warm, not a
  thermostat that moved — the doctrine's rule about reporting what you
  commanded extends here, and this is the earliest of all such reports: the
  house will not act on it until eight o'clock.
  """

  use Jido.Action,
    name: "create_schedule",
    description: """
    Create a recurring schedule that changes a device automatically. Returns \
    the schedule as saved — the device is not changed now, only at the times \
    the schedule names.\
    """,
    schema: [
      label: [
        type: :string,
        required: true,
        doc: "Short name for the schedule, e.g. \"weeknight heat\""
      ],
      cron: [
        type: :string,
        required: true,
        doc: """
        Cron expression in the household's local time: minute hour day-of-month \
        month day-of-week. "0 20 * * 1-5" is 8pm Monday through Friday; \
        "30 6 * * *" is 6:30am every day.\
        """
      ],
      device: [
        type: :string,
        required: true,
        doc: "Device id from the house list, e.g. thermostat:main"
      ],
      action: [
        type: :string,
        required: true,
        doc:
          "What to do to the device. The house list shows what each one can be scheduled to do."
      ],
      args: [
        type: :map,
        required: true,
        doc: "Arguments for the action, e.g. {\"temperature_f\": 70}"
      ]
    ]

  alias Dobby.Schedules

  # `args` arrives from the model as a JSON object, so its keys are strings —
  # and NimbleOptions reads a `:map` schema as `{:map, :atom, :any}`, which
  # rejects that before `run/2` is reached. See `Schedules.atomize_args/3`;
  # it is the same class of self-contradicting schema as the union type §6.2
  # records, and the same fix: meet the model where it actually is, once, at
  # the edge.
  #
  # This runs before the schema does, so it is also where a device or action
  # that will not resolve gets refused. That is the better message anyway:
  # "unknown device thermostat:kitchen; this house has: thermostat:main" is
  # something the model can say back to a person, and a NimbleOptions
  # complaint about map keys is not.
  @impl true
  def on_before_validate_params(params) do
    case Schedules.atomize_args(params[:device], params[:action], params[:args]) do
      {:ok, args} -> {:ok, Map.put(params, :args, args)}
      {:error, message} -> {:error, message}
    end
  end

  @impl true
  def run(params, context) do
    attrs = %{
      label: params.label,
      cron: params.cron,
      timezone: Dobby.Home.manifest().timezone,
      target: params.device,
      action: params.action,
      args: params.args,
      created_by: speaker(context),
      created_via: :conversation
    }

    case Schedules.create_schedule(attrs) do
      {:ok, schedule} -> {:ok, Schedules.describe(schedule)}
      {:error, changeset} -> {:error, Schedules.error_message(changeset)}
    end
  end

  # The request context carries the speaker (`Dobby.DobbyAgent.say/2`). A
  # schedule authored through some future channel that does not set one is
  # still attributable to the household rather than to nobody.
  defp speaker(context) do
    case Map.get(context || %{}, :speaker) do
      speaker when is_binary(speaker) and speaker != "" -> speaker
      _other -> "the household"
    end
  end
end
