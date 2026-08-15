defmodule Dobby.Schedules do
  @moduledoc """
  Schedules as rows (design §9).

  The model authors these and never fires one. Everything a firing needs — the
  device, the action, the arguments — is decided here, at authoring time, and
  written down. At eight o'clock `Dobby.SchedulerAgent` reads the row and
  dispatches it; no inference happens, which is why the firing trace contains
  zero model calls.

  ## Where validation lives

  Split three ways, and the split is the point.

  *Shape* — is this a cron expression, is the label present — is
  `Dobby.Schedules.Schedule.changeset/2`, and is true of any house.

  *The house* — does `thermostat:main` exist, does it accept `set_temperature`,
  are these the arguments that action takes — is `validate_device_action/1`
  here. It is the same closed-by-construction rule the tool layer enforces
  (§6.2), applied a few hours earlier: a schedule cannot name a device the
  manifest does not have, and cannot name an action its device type does not
  publish in `scheduled_actions/0`.

  *Policy* — is 85° inside this household's range, is the thermostat even
  available — stays in the device agent and is applied **at fire time**, not
  here. That is deliberate rather than lazy: the range comes from capabilities
  discovered from the hardware, so a schedule authored before the thermostat
  first reports would be rejected on the strength of a reading we do not have
  yet. The consequence is honest and worth stating plainly — a schedule can be
  accepted now and refused at eight o'clock, and the refusal is recorded rather
  than swallowed.
  """

  import Ecto.Query

  alias Dobby.Repo
  alias Dobby.Schedules.{Cron, Schedule}

  require Logger

  # Supplied by the dispatcher at fire time, exactly as the tool layer supplies
  # it — a correlation ref is not something a schedule stores.
  @runtime_keys [:ref]

  # -- reads -----------------------------------------------------------------

  @doc """
  Every schedule, oldest first.
  """
  @spec list_schedules() :: [Schedule.t()]
  def list_schedules do
    Repo.all(from s in Schedule, order_by: [asc: s.id])
  end

  @doc """
  The enabled schedules — the set `SchedulerAgent` registers timers for.
  """
  @spec enabled() :: [Schedule.t()]
  def enabled do
    Repo.all(from s in Schedule, where: s.enabled == true, order_by: [asc: s.id])
  end

  @doc """
  Fetches a schedule by id.
  """
  @spec fetch(integer() | String.t()) :: {:ok, Schedule.t()} | {:error, String.t()}
  def fetch(id) do
    case cast_id(id) do
      {:ok, id} ->
        case Repo.get(Schedule, id) do
          nil -> {:error, "there is no schedule #{id}"}
          schedule -> {:ok, schedule}
        end

      :error ->
        {:error, "#{inspect(id)} is not a schedule id"}
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
  Coerces a schedule id a model supplied into the integer the schema declares.

  `:integer` renders as `"integer"` in the JSON schema, which is the truth —
  but a model that has just read `id: 3` out of a `list_schedules` result will
  occasionally send it back as `"3"`. Same lesson as the setpoint (§6.2): meet
  the model where it actually is, once, at the edge.
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
  A schedule rendered for a reader — the model, or the admin dashboard.

  `next_fire` is computed rather than stored, so it cannot go stale, and
  `status` says out loud when a schedule can no longer reach its device. A row
  outlives the manifest that made sense of it; a house that drops a thermostat
  leaves its schedules pointing at nothing, and silence there would be the
  worst possible answer.
  """
  @spec describe(Schedule.t(), DateTime.t()) :: map()
  def describe(%Schedule{} = schedule, now \\ DateTime.utc_now()) do
    %{
      id: schedule.id,
      label: schedule.label,
      cron: schedule.cron,
      timezone: schedule.timezone,
      device: schedule.target,
      action: schedule.action,
      args: schedule.args,
      enabled: schedule.enabled,
      created_by: schedule.created_by,
      status: status(schedule),
      next_fire: next_fire_text(schedule, now)
    }
  end

  defp status(%Schedule{enabled: false}), do: "paused"

  defp status(%Schedule{} = schedule) do
    case resolve_action(schedule.target, schedule.action) do
      {:ok, _device, _action} -> "active"
      {:error, reason} -> "cannot run: #{reason}"
    end
  end

  defp next_fire_text(%Schedule{enabled: false}, _now), do: nil

  defp next_fire_text(%Schedule{} = schedule, now) do
    case Cron.next_fire(schedule.cron, schedule.timezone, now) do
      {:ok, at} -> DateTime.to_iso8601(at)
      {:error, _reason} -> nil
    end
  end

  # -- writes ----------------------------------------------------------------

  @doc """
  Creates a schedule and registers its timer.

  Registration is part of creating, not a step a caller can forget: a schedule
  nobody set a timer for is a row, not a schedule.
  """
  @spec create_schedule(map()) :: {:ok, Schedule.t()} | {:error, Ecto.Changeset.t()}
  def create_schedule(attrs) do
    %Schedule{}
    |> Schedule.changeset(attrs)
    |> validate_device_action()
    |> Repo.insert()
    |> resync()
  end

  @doc """
  Pauses or resumes a schedule.
  """
  @spec set_enabled(integer() | String.t(), boolean()) ::
          {:ok, Schedule.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def set_enabled(id, enabled) when is_boolean(enabled) do
    with {:ok, schedule} <- fetch(id) do
      schedule
      |> Schedule.changeset(%{enabled: enabled})
      |> validate_device_action()
      |> Repo.update()
      |> resync()
    end
  end

  @doc """
  Deletes a schedule and cancels its timer.
  """
  @spec delete_schedule(integer() | String.t()) ::
          {:ok, Schedule.t()} | {:error, String.t() | Ecto.Changeset.t()}
  def delete_schedule(id) do
    with {:ok, schedule} <- fetch(id) do
      schedule
      |> Repo.delete()
      |> resync()
    end
  end

  # The timer is downstream of the rows, always. Re-reading the whole enabled
  # set after any write is cheap at household scale and removes a category of
  # bug that incremental registration invites — a timer for a row that no
  # longer says what it said.
  defp resync({:ok, %Schedule{}} = result) do
    Dobby.SchedulerAgent.sync()
    result
  end

  defp resync(other), do: other

  @doc """
  Renders changeset errors as one sentence.

  The schedule tools hand this straight to the model, which reads a refusal as
  an observation and says it back in its own words (§6.2). It has to name the
  actual problem — "unknown device thermostat:kitchen; this house has:
  thermostat:main" is something a person can act on, and "invalid" is not.
  """
  @spec error_message(Ecto.Changeset.t()) :: String.t()
  def error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  # -- the house -------------------------------------------------------------

  @doc """
  Checks a schedule's device, action, and arguments against the running house.

  On success the arguments are written back normalized, so the row stored is
  the row that fires — a model that sent `"70"` does not leave a string in the
  database to be re-interpreted at eight o'clock.
  """
  @spec validate_device_action(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_device_action(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  def validate_device_action(changeset) do
    target = Ecto.Changeset.get_field(changeset, :target)
    action = Ecto.Changeset.get_field(changeset, :action)
    args = Ecto.Changeset.get_field(changeset, :args) || %{}

    case resolve_action(target, action) do
      {:ok, _device, {_signal_type, module}} ->
        case coerce_args(module, args) do
          {:ok, typed} ->
            Ecto.Changeset.put_change(changeset, :args, stringify(typed))

          {:error, reason} ->
            Ecto.Changeset.add_error(changeset, :args, reason)
        end

      {:error, reason} ->
        Ecto.Changeset.add_error(changeset, :target, reason)
    end
  end

  @doc """
  Whether this schedule can still reach its device.

  False when the manifest no longer describes the target, or no longer lets it
  do what the schedule asks. Rows outlive the config that made sense of them.
  """
  @spec runnable?(Schedule.t()) :: boolean()
  def runnable?(%Schedule{} = schedule) do
    match?({:ok, _device, _action}, resolve_action(schedule.target, schedule.action))
  end

  @doc """
  Why a schedule cannot run, or `nil` if it can.
  """
  @spec blocked_reason(Schedule.t()) :: String.t() | nil
  def blocked_reason(%Schedule{} = schedule) do
    case resolve_action(schedule.target, schedule.action) do
      {:ok, _device, _action} -> nil
      {:error, reason} -> reason
    end
  end

  @doc """
  Resolves a schedule's target and action against the manifest.
  """
  @spec resolve_action(String.t(), String.t()) ::
          {:ok, Dobby.Home.Device.t(), {String.t(), module()}} | {:error, String.t()}
  def resolve_action(target, action) do
    with {:ok, device} <- fetch_device(target) do
      lookup_action(device, action)
    end
  end

  defp fetch_device(target) when is_binary(target) do
    case Dobby.Home.fetch_device(target) do
      {:ok, device} ->
        {:ok, device}

      :error ->
        known = Dobby.Home.devices() |> Enum.map_join(", ", & &1.id)
        {:error, "unknown device #{inspect(target)}; this house has: #{known}"}
    end
  end

  defp fetch_device(other), do: {:error, "device must be an id string, got #{inspect(other)}"}

  defp lookup_action(device, action) when is_binary(action) do
    available = device.agent_module.scheduled_actions()

    case Enum.find(available, fn {name, _spec} -> Atom.to_string(name) == action end) do
      {_name, spec} ->
        {:ok, device, spec}

      nil when available == %{} ->
        {:error, "#{device.name} has nothing that can be scheduled"}

      nil ->
        names = available |> Map.keys() |> Enum.map_join(", ", &Atom.to_string/1)
        {:error, "#{device.name} cannot be scheduled to #{inspect(action)}; it can: #{names}"}
    end
  end

  defp lookup_action(_device, other),
    do: {:error, "action must be a name, got #{inspect(other)}"}

  # -- arguments -------------------------------------------------------------

  @doc """
  The schedule's arguments, typed as the device action expects them.

  Validated against the action's own schema rather than a copy of it, which is
  what keeps a new device type from needing anything here.
  """
  @spec typed_args(Schedule.t()) :: {:ok, map()} | {:error, String.t()}
  def typed_args(%Schedule{} = schedule) do
    with {:ok, _device, {_signal_type, module}} <-
           resolve_action(schedule.target, schedule.action) do
      coerce_args(module, schedule.args)
    end
  end

  @doc """
  Rewrites a model-supplied `args` object's keys as the atoms the action declares.

  A tool schema is a contract with the model, and `:map` is another way to
  write one that contradicts itself — the sibling of the union type in §6.2.
  `jido_action` renders `:map` as `"object"`, which is right, and NimbleOptions
  reads `:map` as `{:map, :atom, :any}`, which means the object a model sends
  is rejected for having string keys before `run/2` ever sees it. JSON has no
  atoms and never will.

  So the keys are matched — never `String.to_atom/1`, which on anything a model
  wrote is a way to exhaust the atom table from outside — against the keys the
  target action declares, and an unrecognized one comes back as a sentence the
  model can act on rather than a NimbleOptions complaint about map keys.
  """
  @spec atomize_args(term(), term(), term()) :: {:ok, map()} | {:error, String.t()}
  def atomize_args(target, action, args) when is_map(args) do
    with {:ok, _device, {_signal_type, module}} <- resolve_action(target, action) do
      schema = Keyword.drop(module.schema(), @runtime_keys)

      with {:ok, pairs} <- pair_up(module, schema, args), do: {:ok, Map.new(pairs)}
    end
  end

  def atomize_args(_target, _action, other),
    do: {:error, "arguments must be an object, got #{inspect(other)}"}

  defp coerce_args(module, args) when is_map(args) do
    schema = Keyword.drop(module.schema(), @runtime_keys)

    with {:ok, pairs} <- pair_up(module, schema, args) do
      case NimbleOptions.validate(pairs, schema) do
        {:ok, validated} -> {:ok, Map.new(validated)}
        {:error, %NimbleOptions.ValidationError{message: message}} -> {:error, message}
      end
    end
  end

  defp coerce_args(_module, other),
    do: {:error, "arguments must be an object, got #{inspect(other)}"}

  # Keys arrive as strings — from JSON in the database, and from a model before
  # that. They are matched against the action's declared keys rather than
  # converted, because `String.to_atom/1` on anything a model wrote is a way to
  # exhaust the atom table from the outside.
  defp pair_up(module, schema, args) do
    known = Keyword.keys(schema)

    Enum.reduce_while(args, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Enum.find(known, &(Atom.to_string(&1) == to_string(key))) do
        nil ->
          accepted = Enum.map_join(known, ", ", &Atom.to_string/1)

          {:halt,
           {:error,
            "#{module.name()} takes no argument #{inspect(to_string(key))}; it takes: #{accepted}"}}

        name ->
          {:cont, {:ok, [{name, coerce(schema[name][:type], value)} | acc]}}
      end
    end)
  end

  # JSON has one number type and Elixir has two, and a model will occasionally
  # send a number as a string regardless of what the schema told it. The same
  # coercion the model-facing tools do (§6.2), applied where a schedule's
  # arguments enter.
  defp coerce(type, value) when is_binary(value) do
    cond do
      numeric?(type) ->
        case Float.parse(value) do
          {number, ""} -> as_number(type, number)
          _other -> value
        end

      accepts?(type, :boolean) and value in ["true", "false"] ->
        value == "true"

      true ->
        value
    end
  end

  defp coerce(type, value) when is_integer(value), do: as_number(type, value)
  defp coerce(_type, value), do: value

  # Land on whichever of the two number types the action declared, preferring
  # float wherever it is allowed. JSON has one number type and Elixir has two
  # (§6.2), and the tie has to break the same way here as it does in the
  # model-facing tool — otherwise "set the thermostat to 70" and a schedule
  # that sets it to 70 would put different payloads on the wire for the same
  # command, and the difference would show up first as a puzzling test.
  defp as_number(type, number) do
    cond do
      accepts?(type, :float) -> number / 1
      accepts?(type, :integer) and trunc(number) == number -> trunc(number)
      true -> number
    end
  end

  defp numeric?(type),
    do:
      Enum.any?([:integer, :float, :number, :pos_integer, :non_neg_integer], &accepts?(type, &1))

  defp accepts?({:or, types}, wanted), do: Enum.any?(types, &accepts?(&1, wanted))
  defp accepts?(type, wanted), do: type == wanted

  defp stringify(args), do: Map.new(args, fn {key, value} -> {Atom.to_string(key), value} end)

  # -- firing ----------------------------------------------------------------

  @doc """
  The arguments a device action takes, described well enough to build a form.

  Read from the action's own NimbleOptions schema rather than from a copy of
  it, which is what keeps the admin's form honest when a device type changes
  what it accepts — and what stops a new device type needing a form written for
  it. Same source `coerce_args/2` validates against, so the form can only offer
  fields the row will actually accept.
  """
  @spec action_arguments(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def action_arguments(target, action) do
    with {:ok, _device, {_signal_type, module}} <- resolve_action(target, action) do
      arguments =
        module.schema()
        |> Keyword.drop(@runtime_keys)
        |> Enum.map(fn {name, spec} ->
          %{
            name: Atom.to_string(name),
            type: spec[:type],
            required: Keyword.get(spec, :required, false),
            doc: spec[:doc]
          }
        end)

      {:ok, arguments}
    end
  end

  @doc """
  Every device in this house that has something schedulable, with its actions.

  What the admin's two selects are built from. A read-only device is left out
  rather than offered and then refused — the refusal at authoring time exists
  for a model that cannot see the roster, not for a form that can.
  """
  @spec schedulable_devices() :: [%{id: String.t(), name: String.t(), actions: [String.t()]}]
  def schedulable_devices do
    for device <- Dobby.Home.devices(),
        actions = Map.keys(device.agent_module.scheduled_actions()),
        actions != [] do
      %{id: device.id, name: device.name, actions: Enum.map(actions, &Atom.to_string/1)}
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  The signal a schedule's cron timer carries.

  One definition, two callers: `SchedulerAgent.Sync` registers it with Jido's
  `Cron` directive, and the firing tests cast it. A test that built its own
  would be testing a signal production never sends.

  It carries the id and nothing else on purpose. The row is the schedule, so a
  firing re-reads it — a schedule edited between eight o'clock yesterday and
  eight o'clock today fires as it reads today.
  """
  @spec fire_signal(Schedule.t()) :: Jido.Signal.t()
  def fire_signal(%Schedule{id: id}) do
    Jido.Signal.new!("dobby.schedule.fire", %{schedule_id: id})
  end

  @doc """
  The device signal a firing dispatches.

  The same signal type, the same arguments, and the same correlation ref the
  model's tool builds (§6.2) — a schedule reaches a thermostat by the path a
  person does, so household policy and availability apply identically.
  """
  @spec dispatch_signal(Schedule.t()) ::
          {:ok, pid(), Jido.Signal.t(), String.t()} | {:error, String.t()}
  def dispatch_signal(%Schedule{} = schedule) do
    with {:ok, device, {signal_type, _module}} <-
           resolve_action(schedule.target, schedule.action),
         {:ok, args} <- typed_args(schedule),
         {:ok, _device, pid} <- Dobby.Home.resolve(device.id, device.agent_module) do
      ref = Jido.Util.generate_id()
      {:ok, pid, Jido.Signal.new!(signal_type, Map.put(args, :ref, ref)), ref}
    end
  end

  @doc """
  The cron job id a schedule's timer is registered under.
  """
  @spec job_id(Schedule.t()) :: {:schedule, integer()}
  def job_id(%Schedule{id: id}), do: {:schedule, id}
end
