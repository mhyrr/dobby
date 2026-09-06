defmodule DobbyWeb.HouseLive.RulesPanel do
  @moduledoc """
  Standing responsibilities belong beside the devices they watch.

  The form chooses from each type's observables. It only translates input;
  Rules owns validation, descriptions and writes. Notices carry no flap:
  an observed exception is neither an accepted command nor a refusal.
  """
  use DobbyWeb, :html

  attr(:rules, :any, required: true)
  attr(:editable, :boolean, required: true)
  attr(:form, :any, required: true)
  attr(:devices, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:undo, :map, default: nil)

  def panel(assigns) do
    ~H"""
    <section id="standing-rules" class="standing-rules" aria-labelledby="rules-heading">
      <h2 id="rules-heading" class="fields-head">Standing rules</h2>
      <div id="rule-list" phx-update="stream">
        <p id="rules-empty" class="note">No standing rules. Nothing is being watched for you yet.</p>
        <article
          :for={{dom_id, rule} <- @rules}
          id={dom_id}
          class={["standing-rule", !rule.enabled && "paused"]}
        >
          <h3 class="name">{rule.name}</h3>
          <p class="rule-description">{rule.description}</p>
          <p :if={rule.source not in [nil, ""]} class="rule-source">
            Asked as: {rule.source}
          </p>
          <div :if={@editable} class="acts">
            <button
              id={"rule-toggle-#{rule.id}"}
              type="button"
              phx-click="rule_toggle"
              phx-value-id={rule.id}
              phx-value-revision={rule.revision}
              phx-value-enabled={to_string(!rule.enabled)}
            >
              {if rule.enabled, do: "pause", else: "resume"}
            </button>
            <button
              id={"rule-delete-#{rule.id}"}
              type="button"
              class="takes"
              phx-click="rule_delete"
              phx-value-id={rule.id}
              phx-value-revision={rule.revision}
            >delete</button>
          </div>
        </article>
      </div>
      <div :if={@undo} id="rule-undo" class="acts undo">
        <button type="button" phx-click="rule_undo">undo</button>
        <span>put back “{@undo.entry.name}”</span>
      </div>
      <p :if={@error} id="rule-error" class="why">{@error}</p>
      <div :if={@editable and @form == nil and @devices != []} class="acts">
        <button id="rule-add" type="button" phx-click="rule_add">add a standing rule</button>
      </div>
      <.editor :if={@form != nil} form={@form} devices={@devices} />
    </section>
    """
  end

  attr(:notices, :any, required: true)
  attr(:error, :string, default: nil)

  def notices(assigns) do
    ~H"""
    <div
      id="standing-notices"
      class="standing-notices"
      phx-update="stream"
      aria-label="Standing notices"
    >
      <div :for={{dom_id, notice} <- @notices} id={dom_id} class="standing-notice">
        <p>{notice.text}</p>
        <div class="acts">
          <button
            id={"notice-ack-#{notice.rule_id}"}
            type="button"
            phx-click="rule_acknowledge"
            phx-value-id={notice.rule_id}
            phx-value-occurrence={notice.id}
          >acknowledge</button>
        </div>
      </div>
    </div>
    <p :if={@error} id="notice-error" class="why">{@error}</p>
    """
  end

  defp editor(assigns) do
    device = Enum.find(assigns.devices, &(&1.id == assigns.form[:device].value))
    observables = observables(device)

    spec =
      Enum.find_value(observables, fn {key, spec} ->
        if to_string(key) == assigns.form[:attribute].value, do: spec
      end)

    assigns =
      assigns
      |> assign(
        :attributes,
        Enum.map(observables, fn {key, _} -> {humanize(key), to_string(key)} end)
      )
      |> assign(:spec, spec)

    ~H"""
    <.form for={@form} id="rule-form" class="fields" phx-change="rule_form" phx-submit="rule_save">
      <div class="fields-head">A standing rule</div>
      <.input field={@form[:name]} label="What should this rule be called?" />
      <.input
        field={@form[:device]}
        label="Which device should Dobby watch?"
        options={Enum.map(@devices, &{&1.name, &1.id})}
      />
      <.input
        field={@form[:kind]}
        label="What should Dobby watch for?"
        options={[{"A condition that continues", "state"}, {"No event in the record", "absence"}]}
      />
      <.input field={@form[:attribute]} label="Which reading?" options={@attributes} />
      <.input field={@form[:operator]} label="When that reading is" options={operators(@spec)} />
      <.input
        field={@form[:value]}
        label="Compared with"
        type={value_type(@spec)}
        options={values(@spec)}
      />
      <.input
        :if={match?({:reading, _}, @spec)}
        field={@form[:unit]}
        label="In which unit, as reported by this device?"
      />
      <p :if={@form[:kind].value == "absence"} class="note">
        Watch for no recorded change matching this condition. A gap in the record does not prove nothing happened.
      </p>
      <.input field={@form[:minutes]} label="For how many minutes?" type="number" />
      <.input
        field={@form[:windowed]}
        label="When should this rule watch?"
        options={[{"All day, every day", "false"}, {"During a daily window", "true"}]}
      />
      <%= if @form[:windowed].value == "true" do %>
        <.input field={@form[:start]} label="From, in house time" type="time" />
        <.input field={@form[:end]} label="Until, in house time" type="time" />
        <.input
          field={@form[:days]}
          label="On which days?"
          options={
            [{"Every day", "all"}, {"Weekdays", "weekdays"}, {"Weekends", "weekends"}] ++
              Enum.map(
                1..7,
                &{Enum.at(~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday), &1 - 1),
                 to_string(&1)}
              )
          }
        />
      <% end %>
      <p class="note">
        One notice per occurrence. Unknown readings interrupt the wait. Rules never command a device.
      </p>
      <div class="acts">
        <button id="rule-save" type="submit">save</button>
        <button type="button" class="back" phx-click="rule_cancel">cancel</button>
      </div>
    </.form>
    """
  end

  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:options, :any, default: nil)

  defp input(assigns) do
    ~H"""
    <div class="field">
      <label for={@field.id}>
        <span class="asks"><span class="ask">{@label}</span></span>
      </label>
      <%= if @options != nil do %>
        <select id={@field.id} name={@field.name}>
          <option
            :for={{label, value} <- @options}
            value={value}
            selected={to_string(value) == to_string(@field.value)}
          >
            {label}
          </option>
        </select>
      <% else %>
        <input
          id={@field.id}
          name={@field.name}
          type={@type}
          value={@field.value}
          step={if @type == "number", do: "any"}
        />
      <% end %>
    </div>
    """
  end

  def blank(devices) do
    normalize(
      %{
        "name" => "",
        "kind" => "state",
        "device" => Map.get(List.first(devices) || %{}, :id),
        "minutes" => "20",
        "windowed" => "false",
        "days" => "all",
        "start" => "20:00",
        "end" => "07:00"
      },
      %{},
      devices
    )
  end

  def normalize(params, previous, devices) do
    merged = Map.merge(previous, params)
    device = Enum.find(devices, &(&1.id == merged["device"]))
    attrs = observables(device)
    reset? = previous["device"] != merged["device"]
    attribute = if reset?, do: attrs |> List.first() |> attribute_key(), else: merged["attribute"]
    spec = Enum.find_value(attrs, fn {key, spec} -> if to_string(key) == attribute, do: spec end)
    changed? = reset? or previous["attribute"] != attribute

    merged
    |> Map.put("attribute", attribute)
    |> Map.put("operator", if(changed?, do: "eq", else: merged["operator"] || "eq"))
    |> Map.put("value", if(changed?, do: default_value(spec), else: merged["value"] || ""))
  end

  def entry(params, devices) do
    device = Enum.find(devices, &(&1.id == params["device"]))

    spec =
      Enum.find_value(observables(device), fn {key, spec} ->
        if to_string(key) == params["attribute"], do: spec
      end)

    with {minutes, ""} <- Float.parse(params["minutes"] || ""),
         true <- minutes >= 0 and trunc(minutes * 60) == minutes * 60,
         {:ok, value} <- typed_value(spec, params["value"], params["kind"]) do
      base = %{
        "id" => Ecto.UUID.generate(),
        "name" => params["name"],
        "device" => params["device"],
        "kind" => params["kind"],
        "enabled" => true,
        "duration_seconds" => trunc(minutes * 60)
      }

      condition = %{
        "attribute" => params["attribute"],
        "operator" => params["operator"],
        "value" => value
      }

      entry = Map.merge(base, condition)

      entry =
        if params["kind"] == "absence",
          do: Map.merge(entry, %{"event_kind" => "device_changed", "action" => "state_changed"}),
          else: entry

      entry =
        if match?({:reading, _}, spec), do: Map.put(entry, "unit", params["unit"]), else: entry

      entry =
        if params["windowed"] == "true",
          do:
            Map.put(entry, "window", %{
              "start" => params["start"],
              "end" => params["end"],
              "days" => days(params["days"])
            }),
          else: entry

      {:ok, entry}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Use a duration of zero or more minutes, in whole seconds."}
    end
  end

  defp observables(nil), do: []

  defp observables(device) do
    device.agent_module.observables() |> Enum.sort_by(fn {key, _} -> to_string(key) end)
  end

  defp humanize(key), do: key |> to_string() |> String.replace("_", " ")
  defp attribute_key(nil), do: ""
  defp attribute_key({key, _}), do: to_string(key)
  defp option_value(nil), do: ""
  defp option_value({_, value}), do: value

  defp operators(spec) when spec == :number or (is_tuple(spec) and elem(spec, 0) == :reading),
    do: [
      {"equal to", "eq"},
      {"not equal to", "ne"},
      {"above", "gt"},
      {"at least", "gte"},
      {"below", "lt"},
      {"at most", "lte"}
    ]

  defp operators(_), do: [{"equal to", "eq"}, {"not equal to", "ne"}]
  defp values(:boolean), do: [{"Yes", "true"}, {"No", "false"}]
  defp values({:enum, options}), do: Enum.map(options, &{humanize(&1), to_string(&1)})
  defp values(_), do: nil

  defp default_value(spec) do
    case values(spec) do
      nil -> ""
      options -> options |> List.first() |> option_value()
    end
  end

  defp value_type(:number), do: "number"
  defp value_type({:reading, _}), do: "number"
  defp value_type(_), do: "text"
  defp typed_value(:boolean, "true", _), do: {:ok, true}
  defp typed_value(:boolean, "false", _), do: {:ok, false}
  defp typed_value(:boolean, _, _), do: {:error, "Choose yes or no for this reading."}

  defp typed_value(spec, value, _)
       when spec == :number or (is_tuple(spec) and elem(spec, 0) == :reading) do
    case Float.parse(value || "") do
      {number, ""} -> {:ok, number}
      _ -> {:error, "Use a number for this reading."}
    end
  end

  defp typed_value(_, value, _), do: {:ok, value}
  defp days("all"), do: Enum.to_list(1..7)
  defp days("weekdays"), do: Enum.to_list(1..5)
  defp days("weekends"), do: [6, 7]

  defp days(day) do
    case Integer.parse(day || "") do
      {day, ""} -> [day]
      _ -> []
    end
  end
end
