defmodule DobbyWeb.Fields do
  @moduledoc """
  The board's one form, wherever a form appears (TK-021).

  Three forms had three drawings — the device on `/house`, the schedule and the
  system panel on `/admin` — and one of them printed its labels in three
  different voices on a single screen. They are one form now, and the reason
  they can be is that the question of *what a field is called* has one answer.

  ## The two registers

  A field asks its question in the household's words and carries its schema key
  beside the question, small, as a receipt. A field with no question — an id, a
  Home Assistant entity, a schema key nobody documented — has nothing to ask,
  so its key *is* its label, and it sits with the others like it under the
  form's own rule.

  The register is derived and never assigned per form: writing a `:doc` moves a
  field out of the second group and into the first. That is what keeps a new
  device type costing one module and no form code, which is the whole reason
  `c:Dobby.DeviceAgent.config_schema/0` is declared rather than listed
  centrally — a form that had to be told which of its fields were friendly
  would have to be edited every time one was added.

  It also puts a missing `:doc` somewhere a person will see it: an undocumented
  argument falls into the maintainer's group on the surface rather than staying
  invisible in a schema nobody opens.

  This is about the deterministic layer only. The model's tools are
  `Dobby.Tools.*` (`Dobby.Agent`, `Dobby.Home`), and a device agent's own
  actions are what those dispatch *into* — so a `:doc` here has two readers,
  whoever edits the schema and this form, and never the model. The tool
  schemas carry their own descriptions and are documented in their own right.

  ## The sentence is the label

  The sentence used to sit under the input as a hint while the key stood above
  it as the label: the answer printed beneath the question, and the answer
  called a footnote. Promoting it took a field from three lines to two and left
  nothing out — the key is still on the label line, at the other end of it.

  A sentence-label is set in sentence case. Capitals on this board mean a label
  — a state, a name, a time — and DESIGN.md already grants the exception to the
  one other sentence a form carries, a refusal's reason.
  """

  use DobbyWeb, :html

  @doc """
  The form's nameplate: what is being made, and the one choice that decides
  which fields it has.

  A form that opens at the foot of a list, under somebody else's card, reads as
  that card's fine print without one. A form that opens inside the thing it is
  about needs none.
  """
  attr :rest, :global
  slot :inner_block, required: true, doc: "what this form makes"
  slot :choice, doc: "the one control that decides which fields follow"

  def head(assigns) do
    ~H"""
    <div class="fields-head" {@rest}>
      <span>{render_slot(@inner_block)}</span>
      {render_slot(@choice)}
    </div>
    """
  end

  @doc """
  One field: its label, and the control under it.

  The label is the question when the field has one, and the key when it does
  not — see the two registers above. The control is the caller's, because a
  select over a device roster and a number box over a schema type are not the
  same thing and pretending otherwise would put the roster in here.
  """
  attr :ask, :string, default: nil, doc: "the question, out of the schema's :doc"
  attr :key, :string, required: true, doc: "the schema key, as the identifier it is"
  slot :inner_block, required: true, doc: "the control"
  slot :note, doc: "what a save did, or anything else true of this field alone"

  def field(assigns) do
    ~H"""
    <div class="field">
      <label>
        <span class="asks">
          <%!-- With a question the key falls to the far end of the line as a
                receipt. Without one it is the only thing here, and a flex row
                leaves it at the left, where a label belongs. --%>
          <span :if={@ask} class="ask">{@ask}</span>
          <span class="arg">{@key}</span>
        </span>
        {render_slot(@inner_block)}
      </label>
      {render_slot(@note)}
    </div>
    """
  end

  @doc """
  The rule the second register sits under.

  `Identifiers` is the word DESIGN.md's Identifier Rule already uses, and
  jargon is the right register here — this is the half of the form a
  maintainer fills in, and calling it something friendlier would be the form
  pretending these are questions when they are names.
  """
  attr :say, :string, default: nil, doc: "one line about what these names are"

  def named(assigns) do
    ~H"""
    <div class="named">
      <span class="named-head">Identifiers</span>
      <span :if={@say} class="hint">{@say}</span>
    </div>
    """
  end

  @doc """
  A schema's `:doc` as the question a form asks, or `nil` when it has none.

  Two marks come off it. A backtick painted on this board is a stray one: what
  it marks off — an alias, an entity, a model name — is already told apart by
  being one. And the full stop at the end is punctuation for a doc block, not
  for a label; leaving it in put a period on every generated label and none on
  any written one, three lines apart on the same form.

  A `:doc` long enough for the strip to read oddly is a `:doc` that is too long
  to be a label, and the fix for that is a shorter sentence in the schema.
  """
  @spec ask(String.t() | nil) :: String.t() | nil
  def ask(nil), do: nil

  def ask(text) do
    text |> String.replace("`", "") |> String.trim_trailing(".")
  end

  @doc """
  Fields in two groups: the ones that can ask, and the ones that can only name.
  """
  @spec registers([map()]) :: {[map()], [map()]}
  def registers(fields), do: Enum.split_with(fields, &(&1.ask != nil))

  @doc """
  The input a declared type wants.

  A boolean is two words in a select and never a tick: a tick is an icon, and
  this board says things in words. A closed set of words is a select of those
  words, so the board offers what the file would accept instead of refusing
  what was typed.
  """
  @spec input_type(term()) :: String.t()
  def input_type(type) do
    cond do
      type == :boolean -> "select"
      match?({:in, _words}, type) -> "select"
      numeric?(type) -> "number"
      true -> "text"
    end
  end

  defp numeric?({:or, types}), do: Enum.any?(types, &numeric?/1)
  defp numeric?(type), do: type in [:integer, :float, :number, :pos_integer, :non_neg_integer]
end
