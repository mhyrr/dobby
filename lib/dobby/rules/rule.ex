defmodule Dobby.Rules.Rule do
  @moduledoc """
  The household's stated condition, validated against the device's vocabulary.
  Definitions retain JSON values for faithful YAML round trips. Only keys
  declared by a device become atoms; missing readings remain unknown even for
  a negative comparison. Absence means no matching observation in our record,
  never proof the physical event did not happen.
  """

  alias Dobby.Rules.Window

  defstruct [
    :id,
    :name,
    :source,
    :device,
    :kind,
    :attribute,
    :operator,
    :value,
    :duration_seconds,
    :event_kind,
    :action,
    :unit,
    :window,
    :attribute_key,
    :value_type,
    :device_name,
    enabled: true
  ]

  @type t :: %__MODULE__{}
  @common ~w(id name source enabled device kind duration_seconds window)
  @predicate ~w(attribute operator value unit)
  @fields ~w(id name source enabled device kind attribute operator value duration_seconds event_kind action unit window)a

  def load_all(entries, devices) when is_list(entries) and length(entries) <= 100 do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, rules} ->
      case load(entry, devices) do
        {:ok, rule} ->
          if Enum.any?(rules, &(&1.id == rule.id)),
            do: {:halt, {:error, "duplicate rule id #{inspect(rule.id)}"}},
            else: {:cont, {:ok, rules ++ [rule]}}

        error ->
          {:halt, error}
      end
    end)
  end

  def load_all(_, _), do: {:error, "rules must be a list of at most 100 definitions"}

  def load(raw, devices) when is_map(raw) do
    with :ok <- shape(raw),
         :ok <- identity(raw),
         device when not is_nil(device) <- Enum.find(devices, &(&1.id == raw["device"])),
         {:ok, window} <- Window.load(raw["window"]),
         {:ok, key, type} <- predicate(raw, device),
         :ok <- event(raw) do
      rule = struct(__MODULE__, Enum.map(@fields, &{&1, Map.get(raw, Atom.to_string(&1))}))

      {:ok,
       %{
         rule
         | enabled: Map.get(raw, "enabled", true),
           window: window,
           attribute_key: key,
           value_type: type,
           device_name: device.name
       }}
    else
      nil -> {:error, "rule names an unknown device #{inspect(raw["device"])}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_, _), do: {:error, "each rule must be a mapping"}

  def to_map(%__MODULE__{} = rule) do
    Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(rule, &1)})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  def matches?(%__MODULE__{} = rule, snapshot) when is_map(snapshot) do
    actual = reading(snapshot, rule.attribute_key, rule.value_type)

    cond do
      get(snapshot, :available) != true -> :unknown
      not known?(actual, rule.value_type) -> :unknown
      not unit_matches?(rule, snapshot) -> :unknown
      true -> compare(scalar(actual), rule.operator, rule.value)
    end
  end

  def matches?(_, _), do: :unknown

  def event_matches?(%__MODULE__{kind: "absence"} = rule, entry) do
    changed = get(get(entry, :args) || %{}, :changed) || []

    get(entry, :device) == rule.device and get(entry, :kind) == rule.event_kind and
      get(entry, :action) == rule.action and rule.attribute in Enum.map(changed, &to_string/1) and
      matches?(rule, get(entry, :result) || %{}) == true
  end

  def describe(rule) do
    condition = condition(rule)

    sentence =
      if rule.kind == "absence",
        do:
          "Tell the house when Dobby records no change to #{condition} for #{duration(rule.duration_seconds)}",
        else:
          "Tell the house when #{condition} for #{duration(rule.duration_seconds)} continuously"

    sentence <> window_words(rule.window) <> "."
  end

  defp shape(raw) do
    allowed =
      @common ++ @predicate ++ if(raw["kind"] == "absence", do: ~w(event_kind action), else: [])

    case Enum.reject(Map.keys(raw), &(&1 in allowed)) do
      [] -> :ok
      [key | _] -> {:error, "unknown rule field #{inspect(key)}"}
    end
  end

  defp identity(raw) do
    cond do
      not (is_binary(raw["id"]) and byte_size(raw["id"]) <= 80 and
               Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, raw["id"])) ->
        {:error, "rule id must be a lowercase slug"}

      Enum.any?(~w(name source device), &(not is_binary(raw[&1]) or String.trim(raw[&1]) == "")) ->
        {:error, "rule needs nonempty name, source, and device"}

      byte_size(raw["name"]) > 120 or byte_size(raw["source"]) > 2000 or
          byte_size(raw["device"]) > 200 ->
        {:error, "rule name, source, or device exceeds its text limit"}

      not is_boolean(Map.get(raw, "enabled", true)) ->
        {:error, "rule enabled must be true or false"}

      raw["kind"] not in ~w(state absence) ->
        {:error, "rule kind must be state or absence"}

      not is_integer(raw["duration_seconds"]) ->
        {:error, "rule duration_seconds must be an integer"}

      raw["duration_seconds"] < 0 or (raw["kind"] == "absence" and raw["duration_seconds"] == 0) ->
        {:error, "state duration must be nonnegative; absence duration must be positive"}

      raw["duration_seconds"] > 31_536_000 ->
        {:error, "rule duration cannot exceed 365 days"}

      true ->
        :ok
    end
  end

  defp predicate(raw, device) do
    observables = device.agent_module.observables()

    case Enum.find(observables, fn {key, _type} -> Atom.to_string(key) == raw["attribute"] end) do
      nil ->
        {:error, "unsupported observable #{inspect(raw["attribute"])} for #{device.name}"}

      {key, type} ->
        cond do
          raw["operator"] not in operators(type) ->
            {:error, "unsupported operator for #{key}"}

          not valid_value?(raw["value"], type) ->
            {:error, "invalid value for #{key}"}

          match?({:reading, _}, type) and not Map.has_key?(device.bindings, key) ->
            {:error, "#{device.name} has no #{key} binding"}

          match?({:reading, _}, type) and raw["kind"] == "absence" ->
            {:error,
             "environment monitor records group changes, not individual reading events; use a state rule"}

          match?({:reading, _}, type) and
              not (is_binary(raw["unit"]) and raw["unit"] != "" and byte_size(raw["unit"]) <= 32) ->
            {:error, "#{key} requires the explicit unit reported by Home Assistant"}

          not match?({:reading, _}, type) and Map.has_key?(raw, "unit") ->
            {:error, "unit is only accepted for environmental readings"}

          true ->
            {:ok, key, type}
        end
    end
  end

  defp event(%{"kind" => "state"}), do: :ok

  defp event(%{
         "kind" => "absence",
         "event_kind" => "device_changed",
         "action" => "state_changed"
       }),
       do: :ok

  defp event(_),
    do:
      {:error,
       "absence watches recorded device_changed/state_changed observations, with a typed predicate"}

  defp operators(:number), do: ~w(eq ne gt gte lt lte)
  defp operators({:reading, _}), do: operators(:number)
  defp operators(_), do: ~w(eq ne)
  defp valid_value?(value, {:enum, _} = type), do: is_binary(value) and known?(value, type)
  defp valid_value?(value, type), do: known?(value, type)
  defp known?(value, :boolean), do: is_boolean(value)
  defp known?(value, :number), do: is_number(value)
  defp known?(value, {:reading, _}), do: is_number(value)
  defp known?(value, {:enum, values}), do: scalar(value) in Enum.map(values, &Atom.to_string/1)
  defp known?(_, _), do: false

  defp reading(snapshot, key, {:reading, _}), do: get(get(snapshot, :readings) || %{}, key)
  defp reading(snapshot, key, _), do: get(snapshot, key)

  defp unit_matches?(%{value_type: {:reading, key}, unit: unit}, snapshot),
    do: get(get(snapshot, :units) || %{}, key) == unit

  defp unit_matches?(_, _), do: true
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_, _), do: nil

  defp scalar(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp scalar(value), do: value
  defp compare(value, "eq", expected), do: value == expected
  defp compare(value, "ne", expected), do: value != expected
  defp compare(value, "gt", expected), do: value > expected
  defp compare(value, "gte", expected), do: value >= expected
  defp compare(value, "lt", expected), do: value < expected
  defp compare(value, "lte", expected), do: value <= expected
  defp operator_words("eq"), do: "equals"
  defp operator_words("ne"), do: "does not equal"
  defp operator_words("gt"), do: "is greater than"
  defp operator_words("gte"), do: "is at least"
  defp operator_words("lt"), do: "is less than"
  defp operator_words("lte"), do: "is at most"

  def condition(rule) do
    attribute = rule.attribute |> String.replace_suffix("_f", "") |> String.replace("_", " ")

    unit =
      cond do
        rule.unit -> " #{rule.unit}"
        String.ends_with?(rule.attribute, "_f") -> "°F"
        String.ends_with?(rule.attribute, "_percent") -> "%"
        true -> ""
      end

    attribute = String.replace_suffix(attribute, " percent", "")

    value =
      if is_binary(rule.value),
        do: String.replace(rule.value, "_", " "),
        else: to_string(rule.value)

    "#{rule.device_name || rule.device}: #{attribute} #{operator_words(rule.operator)} #{value}#{unit}"
  end

  defp duration(0), do: "0 seconds"

  defp duration(seconds) do
    [{86_400, "day"}, {3600, "hour"}, {60, "minute"}, {1, "second"}]
    |> Enum.reduce({[], seconds}, fn {size, label}, {parts, rest} ->
      count = div(rest, size)
      part = "#{count} #{label}" <> if(count == 1, do: "", else: "s")
      {if(count > 0, do: parts ++ [part], else: parts), rem(rest, size)}
    end)
    |> elem(0)
    |> Enum.join(" ")
  end

  defp window_words(nil), do: ""

  defp window_words(window),
    do:
      ", watching #{window["start"]}–#{window["end"]} local time on days #{Enum.join(window["days"], ", ")} (Monday is 1)"
end
