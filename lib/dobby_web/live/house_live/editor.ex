defmodule DobbyWeb.HouseLive.Editor do
  @moduledoc """
  The device form, built from the type rather than written for it (TK-018 D).

  Nothing in here knows what a thermostat is. The scaffolding — id, type, name,
  aliases — is the shape `Dobby.HomeConfig` validates every entry against; the
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

  alias Dobby.HomeConfig.Types

  @doc """
  One device, as fields.
  """
  attr :form, :map, required: true, doc: "the string-keyed params being edited"
  attr :module, :atom, required: true, doc: "the agent module the type resolves to"
  attr :new, :boolean, default: false, doc: "whether this device does not exist yet"
  attr :error, :string, default: nil, doc: "why the last save was refused"

  def editor(assigns) do
    ~H"""
    <form id="device-form" class="fields device-form" phx-change="form" phx-submit="save">
      <%!-- The add form opens at the foot of the list, under another device's
            card — without its own nameplate it reads as that card's fields.
            An edit form needs none: it opens inside the card it is about. --%>
      <span :if={@new} class="fields-head">A new device</span>
      <%!-- Added once and then only ever read. See the moduledoc: the id is what
            a schedule stores and the type is where its actions come from. --%>
      <label :if={@new}>
        <span class="arg">id</span>
        <input type="text" name="device[id]" value={@form["id"]} autocomplete="off" />
        <span class="hint">Dobby's own name for it, like thermostat:main. It is set once.</span>
      </label>

      <label :if={@new}>
        <span>Type</span>
        <select name="device[type]">
          <option :for={type <- Types.names()} value={type} selected={type == @form["type"]}>
            {type}
          </option>
        </select>
      </label>

      <%!-- The two that cannot change, said in the record voice as the
            identifiers they are rather than as fields that refuse you. --%>
      <p :if={not @new} class="note">
        <span class="arg">{@form["id"]}</span> · <span class="arg">{@form["type"]}</span>
      </p>

      <label>
        <span>Name</span>
        <input type="text" name="device[name]" value={@form["name"]} autocomplete="off" />
        <span class="hint">What somebody calls it out loud.</span>
      </label>

      <label>
        <span>Also called</span>
        <input type="text" name="device[aliases]" value={@form["aliases"]} autocomplete="off" />
        <span class="hint">Other names for the same thing, separated by commas.</span>
      </label>

      <label :for={binding <- @module.subscribed_bindings()}>
        <span class="arg">bindings.{binding}</span>
        <input
          type="text"
          name={"device[bindings][#{binding}]"}
          value={@form["bindings"][to_string(binding)]}
          autocomplete="off"
        />
        <span class="hint">The Home Assistant entity, exactly as Home Assistant names it.</span>
      </label>

      <%!-- Three of the four types declare no settings at all, and a house
            editing them never sees this. --%>
      <label :for={{key, spec} <- @module.config_schema()}>
        <span class="arg">settings.{key}</span>
        <input
          type={input_type(spec[:type])}
          step={if input_type(spec[:type]) == "number", do: "any"}
          name={"device[settings][#{key}]"}
          value={@form["settings"][to_string(key)]}
          autocomplete="off"
        />
        <span :if={spec[:doc]} class="hint">{spec[:doc]}</span>
      </label>

      <div :if={@error} class="why">{@error}</div>

      <div class="acts">
        <button type="submit">save</button>
        <button type="button" phx-click="cancel">cancel</button>
      </div>
    </form>
    """
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

  defp input_type(type), do: if(numeric?(type), do: "number", else: "text")

  defp numeric?({:or, types}), do: Enum.any?(types, &numeric?/1)
  defp numeric?(type), do: type in [:integer, :float, :number, :pos_integer, :non_neg_integer]
end
