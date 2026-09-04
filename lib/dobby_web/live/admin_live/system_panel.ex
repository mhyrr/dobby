defmodule DobbyWeb.AdminLive.SystemPanel do
  @moduledoc """
  The box's own settings, on the page a maintainer opens (TK-018 layer C).

  Not the house — the house is what `/house` edits and what the cards are about.
  This is what `config/runtime.exs` used to gate behind `config_env() == :dev`
  — the model behind the `:capable` alias, the port, and whether Dobby answers
  on the household network at all — and, since TK-034, how that model answers.

  ## Drawn from the schema, never from a list written out here

  Every field on this panel comes from `Dobby.HomeConfig.System.schema/0` — the
  same declaration the loader validates against — down to its input type, its
  explanation and the words it is refused in. A new system knob is a schema
  entry and nothing else: no field added here, no form written for it, and its
  `:doc`, which was put there for whoever edits the file by hand, gets a second
  reader for free.

  ## Two leaves, one composition

  `Dobby.HomeConfig.Writer` will not write an Elixir home, and the dev and test
  rig boots from one — so read-only is the ordinary case here rather than an
  edge. The panel renders the same blocks either way, with the value where the
  box would be, and says in one sentence why there is nothing to type in. It is
  the call `/admin` already makes about a house with nothing schedulable: a form
  that could only ever be refused is worse than a line saying why there is no
  form.

  ## What a save did, per field

  Some of this takes effect the moment it is written and some of it cannot: the
  model alias is read at the moment it is used, and a port belongs to a socket
  opened at boot. `Dobby.HomeConfig.Applied` knows which is which, and this
  panel says so on the field it is about rather than in one line underneath
  claiming the whole save worked — the honesty rule the board keeps about
  devices, carried into configuration.

  It says it about the save, which is what it can honestly know. Nothing here
  asks the running system what port it is actually listening on, so a browser
  opened after the fact shows the file's values and no per-field word; the file
  is the record, and what a save did is a thing that was just said.
  """

  use DobbyWeb, :html

  import DobbyWeb.Fields

  alias Dobby.HomeConfig
  alias Dobby.HomeConfig.Applied
  alias Dobby.HomeConfig.System
  alias Dobby.HomeConfig.Writer
  alias DobbyWeb.Fields

  @doc """
  The panel.
  """
  attr :config, :any, required: true, doc: "the applied configuration, or nil when there is none"
  attr :form, :map, required: true, doc: "field name => what is in the box"

  attr :effects, :map,
    default: %{},
    doc: "field => :applied | :on_restart | {:overridden, reason}, from the saves so far"

  attr :error, :string, default: nil

  def system(assigns) do
    assigns =
      assigns
      |> assign(:editable, editable?(assigns.config))
      |> assign(:fields, fields(assigns.config, assigns.form, assigns.effects))

    ~H"""
    <section class="panel system">
      <%!-- No writer, no file. A heading over a void is the board declining to
            answer, and the box coming up without a home file is a reading like
            any other. --%>
      <p :if={@config == nil} class="note">The home file has not been read.</p>

      <%!-- The same blocks as the read-only leaf below, with a box where the
            value is. Every field here declares a `:doc`, so every one of them
            asks its question in words and carries its schema key beside it —
            the person who can edit this panel is also the person who may go
            and edit the file, and the key is how they find the line. --%>
      <form :if={@editable} id="system" class="fields" phx-change="system" phx-submit="save">
        <.field :for={field <- @fields} ask={field.ask} key={field.name}>
          <%!-- Words rather than a checkbox or a free box: a tick is an icon,
                and a setting with three allowed words offers the three. --%>
          <select :if={field.input == "select"} name={"system[#{field.name}]"}>
            <option
              :for={{value, word} <- field.choices}
              value={value}
              selected={field.value == value}
            >
              {word}
            </option>
          </select>

          <%!-- No `min` on the number, deliberately. The schema knows a port
                is positive, and a browser silently refusing to submit would
                take the place of the board saying so in its own words. --%>
          <input
            :if={field.input != "select"}
            type={field.input}
            name={"system[#{field.name}]"}
            value={field.value}
            autocomplete="off"
          />

          <:note>
            <p :if={field.effect} class={["effect", waiting?(field.effect) && "waiting"]}>
              {effect(field.effect)}
            </p>
          </:note>
        </.field>

        <div :if={@error} class="why">{@error}</div>

        <%!-- Lower case, like every other quiet control on this board: it is a
              verb, and capitals here mean a state, a name or a time. --%>
        <button type="submit">save</button>
      </form>

      <div :if={@config != nil and not @editable} class="fields">
        <.field :for={field <- @fields} ask={field.ask} key={field.name}>
          <span class={["reading", not field.set? && "unset"]}>{field.reading}</span>
        </.field>
      </div>

      <%!-- One sentence, and it names the file rather than saying "read-only":
            a person who cannot edit this panel is owed the reason and the place
            the settings actually live. --%>
      <p :if={@config != nil and not @editable} class="note">
        The house is described in <span class="file arg">{@config.path}</span>, which Dobby reads
        and does not write.
      </p>
    </section>
    """
  end

  # -- what the panel is made of ---------------------------------------------

  @doc """
  The configuration the box is running, or `nil` when there is no writer.

  Read once when the page opens; `Dobby.ConfigEvents` keeps it current after
  that, which is why v1 needs no file watcher.
  """
  @spec current() :: HomeConfig.t() | nil
  def current do
    case GenServer.whereis(Writer.server()) do
      nil -> nil
      server -> Writer.current(server)
    end
  end

  @doc """
  The boxes, filled from a configuration.
  """
  @spec values(HomeConfig.t() | nil) :: %{String.t() => String.t()}
  def values(nil), do: blank()

  def values(%HomeConfig{system: system}) do
    settings = Map.from_struct(system)

    Map.new(System.schema(), fn {key, _spec} ->
      {Atom.to_string(key), box(Map.get(settings, key))}
    end)
  end

  @doc """
  The boxes, as the browser last had them.

  Keyed by the schema and not by what arrived, so a field the browser did not
  send is an empty box rather than a missing one.
  """
  @spec entered(map()) :: %{String.t() => String.t()}
  def entered(params) do
    Map.new(System.schema(), fn {key, _spec} ->
      name = Atom.to_string(key)
      {name, to_string(Map.get(params, name, ""))}
    end)
  end

  defp blank, do: Map.new(System.schema(), fn {key, _spec} -> {Atom.to_string(key), ""} end)

  @doc """
  Writes what was typed, through the one writer.

  Validation is the section's own — this casts the browser's strings to the
  types the schema declares and hands the result to `Dobby.HomeConfig.System`,
  so a refused value is refused in the words the file would be refused in,
  naming the field. Nothing here writes a second message for the same mistake.
  """
  @spec save(HomeConfig.t(), map()) :: {:ok, Applied.t()} | {:error, String.t()}
  def save(%HomeConfig{} = config, params) do
    with {:ok, system} <- section(params) do
      Writer.update(Writer.server(), fn current ->
        if current.system == config.system do
          {:ok, %{current | system: system}}
        else
          {:error, "system settings changed while this form was open; review them and try again"}
        end
      end)
    end
  end

  defp section(params) do
    System.schema()
    |> Enum.reduce(%{}, fn {key, spec}, acc ->
      name = Atom.to_string(key)

      case cast(Map.get(params, name), spec[:type]) do
        :unmentioned -> acc
        {:ok, value} -> Map.put(acc, name, value)
      end
    end)
    |> System.load()
  end

  # An empty box is not a value. A field somebody cleared is a field the file
  # should stop mentioning, so the built-in default comes back rather than an
  # empty string being written down as though somebody had chosen one.
  defp cast(nil, _type), do: :unmentioned
  defp cast("", _type), do: :unmentioned
  defp cast(raw, :boolean), do: {:ok, raw in ["true", "yes", "on"]}

  defp cast(raw, type) when type in [:integer, :pos_integer, :non_neg_integer] do
    case Integer.parse(raw) do
      {number, ""} -> {:ok, number}
      # Left exactly as it was typed, so the schema refuses it by name.
      _unparseable -> {:ok, raw}
    end
  end

  defp cast(raw, _type), do: {:ok, raw}

  @doc """
  What the saves so far did, field by field.

  A debt rather than a receipt: a port written down stays written down and
  waiting until the box restarts, so it survives the next save of some other
  field. `:house` is dropped — it is a change to the house, and the house is
  not what this panel is about.
  """
  @spec effects(map(), Applied.t()) :: map()
  def effects(previous, %Applied{applied: applied, on_restart: later, overridden: overridden}) do
    # An override arrives with its own sentence, because a field that says only
    # "overridden" asks the person to guess what outranked them.
    overridden = Enum.map(overridden, fn {field, reason} -> {field, {:overridden, reason}} end)

    previous
    |> Map.drop(applied ++ later ++ Enum.map(overridden, &elem(&1, 0)))
    |> Map.merge(mark(applied, :applied))
    |> Map.merge(mark(later, :on_restart))
    |> Map.merge(ours(overridden))
  end

  defp mark(fields, effect), do: fields |> Enum.map(&{&1, effect}) |> ours()

  defp ours(pairs) do
    keys = Enum.map(System.schema(), fn {key, _spec} -> key end)

    pairs |> Enum.filter(fn {field, _effect} -> field in keys end) |> Map.new()
  end

  defp editable?(nil), do: false
  defp editable?(%HomeConfig{} = config), do: Writer.writable?(config)

  defp fields(nil, _form, _effects), do: []

  defp fields(%HomeConfig{system: system}, form, effects) do
    settings = Map.from_struct(system)

    Enum.map(System.schema(), fn {key, spec} ->
      name = Atom.to_string(key)
      value = Map.get(settings, key)

      %{
        name: name,
        type: spec[:type],
        ask: Fields.ask(spec[:doc]),
        input: Fields.input_type(spec[:type]),
        choices: choices(spec[:type]),
        value: Map.get(form, name, ""),
        reading: reading(value),
        set?: value != nil,
        effect: Map.get(effects, key)
      }
    end)
  end

  # A boolean is two words. A closed set of words offers each of them, and a
  # blank first: the knob the file does not mention is a knob at Dobby's own
  # default, and choosing the blank is how the file stops mentioning it.
  defp choices(:boolean), do: [{"false", "no"}, {"true", "yes"}]
  defp choices({:in, words}), do: [{"", "default"} | Enum.map(words, &{&1, &1})]
  defp choices(_type), do: nil

  # -- rendering -------------------------------------------------------------

  # A knob the file does not mention is a knob at Dobby's own default, and that
  # is a reading. Not `NOT SET`: in capitals it would read as a ninth word on a
  # board with eight, one letter away from `NOT KNOWN`, which means something
  # else entirely — nobody has told us. Here somebody has: the file says
  # nothing, and saying nothing is a choice with a known consequence.
  defp reading(nil), do: "default"
  defp reading(true), do: "yes"
  defp reading(false), do: "no"
  defp reading(value), do: to_string(value)

  defp box(nil), do: ""
  defp box(value), do: to_string(value)

  # None of the eight words means "written down and waiting for a restart", and
  # a ninth is a design decision rather than a CSS change. So this is not a flap
  # and not a state colour — it is the record voice, on the field it is about.
  defp effect(:applied), do: "In effect now"
  defp effect(:on_restart), do: "Waiting for a restart"

  # The writer's own sentence, printed as it was written. It says what is in
  # force and who chose it, which is the half a person cannot see from here:
  # the thing outranking the file is an export in somebody's shell, and the
  # panel that only said "the environment override is in effect" left them to
  # find that out.
  defp effect({:overridden, reason}), do: reason

  defp waiting?(:on_restart), do: true
  defp waiting?({:overridden, _reason}), do: true
  defp waiting?(_effect), do: false
end
