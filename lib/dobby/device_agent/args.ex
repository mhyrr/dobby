defmodule Dobby.DeviceAgent.Args do
  @moduledoc """
  A device action's arguments, typed as the action itself declares them.

  Three callers hand an action arguments they did not type: a schedule row
  (JSON out of Postgres), the model's `create_schedule` (JSON out of a model),
  and a card (form values out of a browser). All three arrive with string keys
  and with numbers, booleans, and choices that may be strings, and all three
  have to land on the same payload the model's own tool would put on the wire.
  Otherwise "set the thermostat to 70", a schedule that sets it to 70, and a
  fader released at 70 would differ, and the difference would show up first as
  a puzzling test.

  Keys are matched against the action's declared keys rather than converted:
  `String.to_atom/1` on anything a model or a browser wrote is a way to
  exhaust the atom table from outside. `:ref` is the write protocol's own key,
  minted by `Dobby.DeviceAgent.command/4`, and is never an argument.
  """

  @runtime_keys [:ref]

  @doc """
  The action's arguments, validated against its own NimbleOptions schema.

  The schema is read from the action rather than copied, which is what keeps a
  new device type from needing anything here.
  """
  @spec coerce(module(), term()) :: {:ok, map()} | {:error, String.t()}
  def coerce(module, args) when is_map(args) do
    schema = arguments(module)

    with {:ok, pairs} <- pair_up(module, schema, args) do
      case NimbleOptions.validate(pairs, schema) do
        {:ok, validated} -> {:ok, Map.new(validated)}
        {:error, %NimbleOptions.ValidationError{message: message}} -> {:error, message}
      end
    end
  end

  def coerce(_module, other),
    do: {:error, "arguments must be an object, got #{inspect(other)}"}

  @doc """
  The action's arguments with their keys as the atoms the action declares,
  values coerced but not yet validated.

  What a tool schema's `:map` cannot say: `jido_action` renders `:map` as
  `"object"`, which is right, and NimbleOptions reads it as `{:map, :atom,
  :any}`, so an object a model sends is rejected for its string keys before
  `run/2` ever sees it. An unrecognized key comes back as a sentence the model
  can act on rather than a complaint about map keys.
  """
  @spec atomize(module(), term()) :: {:ok, map()} | {:error, String.t()}
  def atomize(module, args) when is_map(args) do
    with {:ok, pairs} <- pair_up(module, arguments(module), args), do: {:ok, Map.new(pairs)}
  end

  def atomize(_module, other),
    do: {:error, "arguments must be an object, got #{inspect(other)}"}

  @doc """
  The action's declared arguments, without the write protocol's own key.
  """
  @spec arguments(module()) :: keyword()
  def arguments(module), do: Keyword.drop(module.schema(), @runtime_keys)

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
          {:cont, {:ok, [{name, coerce_value(schema[name][:type], value)} | acc]}}
      end
    end)
  end

  # JSON has one number type and Elixir has two, a model will occasionally
  # send a number as a string regardless of what the schema told it, and a
  # browser sends everything as a string. The same coercion the model-facing
  # tools do (§6.2), applied where a schedule's or a card's arguments enter.
  #
  # A choice declared as atoms (`{:in, [:on, :off]}`) is matched by name for
  # the same reason keys are: the atom already exists in the schema, so the
  # string is compared against it and never converted.
  defp coerce_value(type, value) when is_binary(value) do
    cond do
      numeric?(type) ->
        case Float.parse(value) do
          {number, ""} -> as_number(type, number)
          _other -> value
        end

      accepts?(type, :boolean) and value in ["true", "false"] ->
        value == "true"

      true ->
        choice(type, value)
    end
  end

  defp coerce_value(type, value) when is_integer(value), do: as_number(type, value)
  defp coerce_value(_type, value), do: value

  defp choice({:in, choices}, value) do
    Enum.find(choices, value, &(is_atom(&1) and Atom.to_string(&1) == value))
  end

  defp choice(_type, value), do: value

  # Land on whichever of the two number types the action declared, preferring
  # float wherever it is allowed. The tie has to break the same way here as it
  # does in the model-facing tool, or the same command would put different
  # payloads on the wire depending on who asked.
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
end
