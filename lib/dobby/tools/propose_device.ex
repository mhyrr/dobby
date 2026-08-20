defmodule Dobby.Tools.ProposeDevice do
  @moduledoc """
  Tool: write down a device the household says it wants (TK-010).

  The extraction half of the config chat path, and the split is the whole
  design. "Add this Nest as the dining room thermostat, and don't let anyone
  cook the room" is a sentence; what has to come out of it is an id, a name,
  the words the household will actually say, an entity to bind, and a policy
  number. Reading a sentence into fields is what a language model is for.
  Deciding whether those fields describe a house is not, and nothing in this
  module asks it to — `Dobby.HomeConfig.Proposals` puts the entry through the
  same validation a hand-typed `home.yaml` gets, and a refusal comes back in
  that validation's own words with the field named.

  ## What the model does not supply

  **The binding key.** The model gives an entity id — copied from
  `discover_entities`, never invented — and the device type says which binding
  that id belongs under. `climate` is an atom because `Thermostat` declares one,
  not because a model wrote the word down (`Dobby.HomeConfig.Types` is the
  closure; this is it applied to a tool).

  **Who asked.** Attribution rides on the request context (§6.4), the same way
  `create_schedule` learns it.

  ## What this returns

  A proposal, and only a proposal. No file is written, no agent starts, and the
  house does not have this device. Doctrine holds Dobby to saying exactly that
  — `confirm_device` is what turns it into a house, and only after somebody has
  said yes.
  """

  use Jido.Action,
    name: "propose_device",
    description: """
    Propose adding a device to the house. Writes nothing and changes nothing — \
    it returns a proposal with an id, which somebody must agree to before \
    confirm_device can apply it. Report it as proposed, never as done.\
    """,
    schema: [
      id: [
        type: :string,
        required: true,
        doc:
          "The id Dobby will use for this device forever. Convention is type:place, e.g. thermostat:dining_room."
      ],
      type: [
        type: :string,
        required: true,
        doc: "The kind of device. Use the type discover_entities reported for this entity."
      ],
      name: [
        type: :string,
        required: true,
        doc: "What the household calls it, in the words they actually use."
      ],
      entity_id: [
        type: :string,
        required: true,
        doc:
          "The Home Assistant entity this device is, copied exactly from discover_entities. Never invent one."
      ],
      aliases: [
        type: {:list, :string},
        doc: "Other words the household uses for the same thing."
      ],
      settings: [
        type: :map,
        doc:
          "Household policy for this device type, if they stated any, e.g. {\"max_temperature_f\": 76}. Omit it when they did not."
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.HomeConfig.Proposals
  alias Dobby.HomeConfig.Types

  @impl Dobby.Tools
  def label(%{"name" => name}) when is_binary(name), do: "writing down #{name}"
  def label(_arguments), do: "writing down the device"

  # Runs before the schema does, which makes it the right place for both jobs
  # below — a model that named a type this house does not have gets a sentence
  # it can say back to a person, rather than a NimbleOptions complaint.
  #
  # `settings` arrives as a JSON object with string keys, and NimbleOptions
  # reads a `:map` schema as `{:map, :atom, :any}` — the self-contradicting
  # contract §6.2 records. The keys are matched against the ones the device type
  # declares rather than converted, because `String.to_atom/1` on anything a
  # model wrote is a way to exhaust the atom table from outside.
  @impl true
  def on_before_validate_params(params) do
    with {:ok, module} <- fetch_type(params[:type]),
         {:ok, settings} <- known_settings(module, params[:settings] || %{}) do
      {:ok, Map.put(params, :settings, settings)}
    end
  end

  @impl true
  def run(params, context) do
    with {:ok, module} <- fetch_type(params.type),
         {:ok, binding} <- binding_for(module) do
      entry = entry(params, binding)

      case Proposals.propose(entry, proposed_by: speaker(context)) do
        {:ok, proposal} ->
          {:ok, %{proposal: Proposals.describe(proposal), applied: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The mapping a home file would hold: string keys, string values, `type` and
  # never a module name. One shape, whether it came from an editor or a
  # sentence.
  defp entry(params, binding) do
    %{
      "id" => params.id,
      "type" => params.type,
      "name" => params.name,
      "bindings" => %{binding => params.entity_id}
    }
    |> put_present("aliases", Map.get(params, :aliases))
    |> put_present("settings", stringify(Map.get(params, :settings) || %{}))
  end

  defp put_present(entry, _key, nil), do: entry
  defp put_present(entry, _key, empty) when empty in [[], %{}], do: entry
  defp put_present(entry, key, value), do: Map.put(entry, key, value)

  defp stringify(settings),
    do: Map.new(settings, fn {key, value} -> {Atom.to_string(key), value} end)

  defp fetch_type(name) when is_binary(name) do
    case Types.fetch(name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown device type #{inspect(name)}; #{Types.roll_call()}"}
    end
  end

  defp fetch_type(other),
    do: {:error, "type must be a device type name, got #{inspect(other)}"}

  # Every type Dobby has binds exactly one entity, so the model supplies an id
  # and the registry supplies the word it goes under. A future type that bound
  # two would need a wider tool, and this says so instead of picking one.
  defp binding_for(module) do
    case module.subscribed_bindings() do
      [only] ->
        {:ok, Atom.to_string(only)}

      several ->
        {:error,
         "a #{module.config_type()} binds more than one entity (#{Enum.map_join(several, ", ", &Atom.to_string/1)}); add it by editing the house file"}
    end
  end

  defp known_settings(module, raw) when is_map(raw) do
    declared = Keyword.keys(module.config_schema())

    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Enum.find(declared, &(Atom.to_string(&1) == to_string(key))) do
        nil -> {:halt, {:error, unknown_setting(module, declared, key)}}
        name -> {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp known_settings(_module, other),
    do: {:error, "settings must be an object, got #{inspect(other)}"}

  defp unknown_setting(module, [], key),
    do: "a #{module.config_type()} takes no settings, so #{inspect(to_string(key))} is not one"

  defp unknown_setting(module, declared, key) do
    "a #{module.config_type()} takes no setting #{inspect(to_string(key))}; it takes: " <>
      Enum.map_join(declared, ", ", &Atom.to_string/1)
  end

  defp speaker(context) do
    case Map.get(context || %{}, :speaker) do
      speaker when is_binary(speaker) and speaker != "" -> speaker
      _other -> "the household"
    end
  end
end
