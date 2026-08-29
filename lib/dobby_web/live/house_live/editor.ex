defmodule DobbyWeb.HouseLive.Editor do
  @moduledoc """
  The device form, built from the type rather than written for it (TK-018 D).

  Nothing in here knows what a thermostat is. The scaffolding — id, type, name,
  aliases — is the shape `Dobby.HomeConfig` validates every entry against; the
  shared `hands_only` choice says who may command it; the
  entity fields come from the type's `c:Dobby.DeviceAgent.subscribed_bindings/0`;
  the settings fields come from its `c:Dobby.DeviceAgent.config_schema/0`,
  including the `:doc` that callback says is written for whoever is editing the
  file. So a new device type costs one module and no form code, which is the
  whole reason those two callbacks are declared rather than listed centrally.

  ## Entity ids are typed, in v1

  A free-text field, and honestly so: Dobby learns what entities exist from Home
  Assistant's own state sync, and offering a picker built from something else
  would be a list of guesses. The picker is layer E's, off the client's
  discovery.

  ## What a form cannot change

  The id and the type are set when a device is added and shown as the
  identifiers they are afterwards. Both are what everything else in the house
  points *at*: a schedule stores a device id, and the actions it may fire come
  from the type. Editing either in place would orphan a schedule silently, and
  the one flow that can orphan one — removal — says so in its own words before
  it happens. Changing what a device *is* is a removal and an addition, and
  reads like one.
  """

  use DobbyWeb, :html

  import DobbyWeb.Fields

  alias Dobby.HomeConfig.Types
  alias DobbyWeb.Fields

  @doc """
  One device, as fields.
  """
  attr(:form, :map, required: true, doc: "the string-keyed params being edited")
  attr(:module, :atom, required: true, doc: "the agent module the type resolves to")
  attr(:new, :boolean, default: false, doc: "whether this device does not exist yet")
  attr(:error, :string, default: nil, doc: "why the last save was refused")

  def editor(assigns) do
    assigns = assign(assigns, :settings, settings(assigns.module))

    ~H"""
    <form id="device-form" class="fields device-form" phx-change="form" phx-submit="save">
      <%!-- The add form opens at the foot of the list, under another device's
            card — without its own nameplate it reads as that card's fields.
            An edit form needs none: it opens inside the card it is about. --%>
      <.head :if={@new}>
        A new device
        <:choice>
          <%!-- The one choice that decides which fields follow, so it belongs
                in the head rather than among the questions. Set once with the
                id: changing what a device *is* is a removal and an addition,
                and it reads like one. --%>
          <select name="device[type]">
            <option :for={type <- Types.names()} value={type} selected={type == @form["type"]}>
              {type}
            </option>
          </select>
        </:choice>
      </.head>

      <.field ask="What somebody calls it out loud" key="name">
        <input type="text" name="device[name]" value={@form["name"]} autocomplete="off" />
      </.field>

      <.field ask="Other names for the same thing, separated by commas" key="aliases">
        <input type="text" name="device[aliases]" value={@form["aliases"]} autocomplete="off" />
      </.field>

      <.field ask="Should only a person's hand command this device" key="hands_only">
        <input type="hidden" name="device[hands_only]" value="false" />
        <input
          id="device-hands-only"
          type="checkbox"
          name="device[hands_only]"
          value="true"
          checked={@form["hands_only"] in [true, "true"]}
        />
      </.field>

      <%!-- Three of the four types declare no settings at all, and a house
            editing them never sees either of these two groups. --%>
      <.field :for={setting <- asked_settings(@settings)} ask={setting.ask} key={setting.key}>
        <input
          type={Fields.input_type(setting.type)}
          step={if Fields.input_type(setting.type) == "number", do: "any"}
          name={setting.input}
          value={@form["settings"][setting.field]}
          autocomplete="off"
        />
      </.field>

      <%!-- Everything this device is called in a file: Dobby's own name for it
            and Home Assistant's, plus any setting nobody wrote a sentence for.
            None of them is a question, so none of them gets asked as one. --%>
      <.named say={named_say(@new)} />

      <%!-- Added once and then only ever read. See the moduledoc: the id is
            what a schedule stores and the type is where its actions come
            from. --%>
      <.field :if={@new} key="id">
        <input type="text" name="device[id]" value={@form["id"]} autocomplete="off" />
      </.field>

      <%!-- The two that cannot change, said in the record voice as the
            identifiers they are rather than as fields that refuse you. --%>
      <p :if={not @new} class="note">
        <span class="arg">{@form["id"]}</span> · <span class="arg">{@form["type"]}</span>
      </p>

      <.field :for={binding <- @module.subscribed_bindings()} key={"bindings.#{binding}"}>
        <input
          type="text"
          name={"device[bindings][#{binding}]"}
          value={@form["bindings"][to_string(binding)]}
          autocomplete="off"
        />
      </.field>

      <.field :for={setting <- named_settings(@settings)} key={setting.key}>
        <input
          type={Fields.input_type(setting.type)}
          step={if Fields.input_type(setting.type) == "number", do: "any"}
          name={setting.input}
          value={@form["settings"][setting.field]}
          autocomplete="off"
        />
      </.field>

      <div :if={@error} class="why">{@error}</div>

      <div class="acts">
        <button type="submit">save</button>
        <button type="button" class="back" phx-click="cancel">cancel</button>
      </div>
    </form>
    """
  end

  # A type's settings, as fields. The `:doc` the callback declares — written
  # for whoever edits the file by hand — is the question this form asks, and a
  # setting without one has no question to ask and falls to the second group.
  defp settings(module) do
    Enum.map(module.config_schema(), fn {key, spec} ->
      %{
        key: "settings.#{key}",
        field: to_string(key),
        input: "device[settings][#{key}]",
        ask: Fields.ask(spec[:doc]),
        type: spec[:type]
      }
    end)
  end

  defp asked_settings(settings), do: settings |> Fields.registers() |> elem(0)
  defp named_settings(settings), do: settings |> Fields.registers() |> elem(1)

  # The id is only in the list while it can still be typed. Afterwards this
  # group is Home Assistant's names and nothing else, and a line about setting
  # the id once would be describing a box that is not there.
  defp named_say(true) do
    "The id is Dobby's own name and is set once, because a schedule stores it. " <>
      "The rest are Home Assistant's entities, exactly as Home Assistant names them."
  end

  defp named_say(false) do
    "Home Assistant's entities, exactly as Home Assistant names them."
  end

  # -- the form's two directions ---------------------------------------------

  @doc """
  A blank form for a device that does not exist yet.
  """
  @spec blank() :: map()
  def blank do
    %{
      "id" => "",
      "type" => List.first(Types.names()),
      "name" => "",
      "aliases" => "",
      "hands_only" => "false",
      "bindings" => %{},
      "settings" => %{}
    }
  end

  @doc """
  A manifest entry, as the form that edits it.
  """
  @spec params(map()) :: map()
  def params(entry) do
    {:ok, type} = Types.fetch_name(entry.agent_module)

    %{
      "id" => entry.id,
      "type" => type,
      "name" => entry.name,
      "aliases" => Enum.join(Map.get(entry, :aliases) || [], ", "),
      "hands_only" => to_string(Map.get(entry, :hands_only, false)),
      "bindings" => stringify(Map.get(entry, :bindings) || %{}),
      "settings" => stringify(Map.get(entry, :settings) || %{})
    }
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @doc """
  What the form is saying, as the manifest entry it describes.

  Keys the form does not show — a device's network, its HA integration — are
  carried over from the entry being edited rather than dropped: a form that
  cannot see a field has no business deleting it.

  Blank fields are *left out* rather than written as empty strings, which is
  what makes the type's own refusal the one that reaches the person: an entity
  field nobody filled in produces "missing required binding :climate" from
  `Dobby.DeviceAgents.Thermostat`, not a second sentence written here that says
  the same thing in different words.
  """
  @spec entry(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def entry(form, existing \\ %{}) do
    with {:ok, module} <- fetch_type(form["type"]),
         {:ok, id} <- present(form["id"], "a device needs an id"),
         {:ok, name} <- present(form["name"], "a device needs a name"),
         {:ok, settings} <- settings(module, form["settings"] || %{}) do
      {:ok,
       Map.merge(existing, %{
         id: id,
         name: name,
         aliases: aliases(form["aliases"]),
         hands_only: hands_only?(form["hands_only"]),
         agent_module: module,
         bindings: bindings(module, form["bindings"] || %{}),
         settings: settings
       })}
    end
  end

  @doc """
  The agent module a form's chosen type resolves to.
  """
  @spec module(map()) :: module()
  def module(form) do
    case Types.fetch(form["type"]) do
      {:ok, module} -> module
      :error -> hd(Types.modules())
    end
  end

  defp fetch_type(name) do
    case Types.fetch(name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown type #{inspect(name)}; #{Types.roll_call()}"}
    end
  end

  defp present(value, message) do
    case String.trim(value || "") do
      "" -> {:error, message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp aliases(nil), do: []

  defp aliases(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp hands_only?(value), do: value in [true, "true", "on", "1"]

  defp bindings(module, submitted) do
    for key <- module.subscribed_bindings(),
        entity = String.trim(submitted[to_string(key)] || ""),
        entity != "",
        into: %{} do
      {key, entity}
    end
  end

  # Cast by what the schema declared, then validated against the same schema —
  # the browser sends every field as text, and a setting the file holds as a
  # number has to reach the file as one. A value that will not cast is left as
  # it was typed so that NimbleOptions is the one to name the field.
  defp settings(module, submitted) do
    schema = module.config_schema()

    pairs =
      for {key, spec} <- schema,
          typed = String.trim(submitted[to_string(key)] || ""),
          typed != "" do
        {key, cast(typed, spec[:type])}
      end

    case NimbleOptions.validate(pairs, schema) do
      {:ok, options} ->
        {:ok, Map.new(options)}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, "settings: #{message}"}
    end
  end

  defp cast(value, type) do
    if numeric?(type) do
      case Integer.parse(value) do
        {integer, ""} -> integer
        _not_an_integer -> float(value)
      end
    else
      value
    end
  end

  defp float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_a_number -> value
    end
  end

  defp numeric?({:or, types}), do: Enum.any?(types, &numeric?/1)
  defp numeric?(type), do: type in [:integer, :float, :number, :pos_integer, :non_neg_integer]
end
