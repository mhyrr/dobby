defmodule Dobby.HomeConfig.Discovery do
  @moduledoc """
  What Home Assistant has that this house has not been told to manage (TK-010).

  The removable half of the double-entry problem. Every device is configured
  twice today — once in Home Assistant, where the integration and the
  credentials live, and once in Dobby, where the id, the household's own words
  for it, and its policy live. The first half is unavoidably HA's job. The
  second half is load-bearing and stays. What is neither is the *retyping*:
  copying `climate.dining_room` out of one screen and into a file, and
  deciding again that a climate entity is a thermostat.

  So this proposes and never installs. A device nobody blessed must not appear
  in the roster — the roster staying curated is a design invariant (§6.2), not
  an inconvenience — which is why the output of this module is a list of
  candidates and the only way one becomes a device is
  `Dobby.HomeConfig.Proposals`.

  ## Where the answer comes from

  `Dobby.HomeAssistant.entities/0`, which is the client's own memory of its
  state sync. Nothing here makes a request of Home Assistant, and nothing above
  the boundary could: design §7 puts one process in charge of that connection
  and this reads what that process already learned. The consequence worth
  stating is that a client which has never connected reports nothing, and
  "nothing" is then the honest answer rather than a spinner.

  ## What is left out

  Two filters, both narrowing.

  *Bound* entities — anything a manifest binding already claims — because
  discovery is for what is missing.

  *Unrecognized* entities, meaning every entity no device type says it could
  manage. A household Home Assistant has hundreds of entities and Dobby has
  four device types; offering the other several hundred would bury the four
  that matter. Each type answers for itself
  (`c:Dobby.DeviceAgent.matches_entity?/1`), so a new device type widens this
  by existing.
  """

  alias Dobby.HomeAssistant
  alias Dobby.HomeAssistant.Entity
  alias Dobby.HomeConfig.Types

  @typedoc """
  One entity Dobby could manage and does not, with the type it looks like.
  """
  @type candidate :: %{
          entity_id: String.t(),
          type: String.t(),
          binding: String.t(),
          suggested_name: String.t(),
          state: String.t() | nil
        }

  @doc """
  Every unbound entity a device type recognizes, oldest question first.

  `:type` narrows to one device type's candidates, and is closed by
  `Dobby.HomeConfig.Types` — the same closure a home file is held to, applied
  to a tool argument.
  """
  @spec candidates(keyword()) :: {:ok, [candidate()]} | {:error, String.t()}
  def candidates(opts \\ []) do
    with {:ok, modules} <- wanted_types(Keyword.get(opts, :type)) do
      bound = bound_entities()

      candidates =
        HomeAssistant.entities()
        |> Enum.reject(&MapSet.member?(bound, &1.entity_id))
        |> Enum.flat_map(&describe(&1, modules))

      {:ok, candidates}
    end
  end

  @doc """
  Whether a manifest binding already claims this entity.

  The question the propose path asks a second time, because a house can change
  between somebody being shown a candidate and somebody saying yes to it.
  """
  @spec bound?(String.t()) :: boolean()
  def bound?(entity_id) when is_binary(entity_id),
    do: MapSet.member?(bound_entities(), entity_id)

  # Every entity id any device points at, not merely the routed ones. A binding
  # a device type does not subscribe to is still a claim on that entity, and
  # offering it as unmanaged would invite two devices onto one entity.
  defp bound_entities do
    Dobby.Home.devices()
    |> Enum.flat_map(&Map.values(&1.bindings))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  rescue
    # No manifest means no house yet, and a house that knows nothing binds
    # nothing. Better than a discovery read that raises during a restart.
    ArgumentError -> MapSet.new()
  end

  defp wanted_types(nil), do: {:ok, Types.modules()}

  defp wanted_types(name) when is_binary(name) do
    case Types.fetch(name) do
      {:ok, module} -> {:ok, [module]}
      :error -> {:error, "unknown device type #{inspect(name)}; #{Types.roll_call()}"}
    end
  end

  defp wanted_types(other),
    do: {:error, "type must be a device type name, got #{inspect(other)}"}

  # The first type that claims an entity wins. Today the four are disjoint, and
  # if two ever overlap, a candidate offered once under one name is a better
  # answer than the same entity offered twice.
  defp describe(%Entity{} = entity, modules) do
    case Enum.find(modules, & &1.matches_entity?(entity)) do
      nil ->
        []

      module ->
        [
          %{
            entity_id: entity.entity_id,
            type: module.config_type(),
            binding: binding_for(module),
            suggested_name: Entity.label(entity),
            state: entity.state
          }
        ]
    end
  end

  # Which binding key the entity id belongs under, so the model copies an id
  # rather than guessing a keyword. Every type Dobby has subscribes to exactly
  # one binding; a future type with two would have to be told apart by more
  # than its domain, and this says so rather than picking one.
  defp binding_for(module) do
    case module.subscribed_bindings() do
      [only] -> Atom.to_string(only)
      _several -> nil
    end
  end
end
