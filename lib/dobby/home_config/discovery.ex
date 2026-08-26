defmodule Dobby.HomeConfig.Discovery do
  @moduledoc """
  What Home Assistant has that this house has not been told to manage (TK-010).

  The removable half of the double-entry problem. Every device is configured
  twice today — once in Home Assistant, where the integration and the
  credentials live, and once in Dobby, where the id, the household's own words
  for it, and its policy live. The first half is unavoidably HA's job. The
  second half is necessary and stays. What is neither is the *retyping*:
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
  manage. A household Home Assistant has hundreds of entities; offering every
  one would bury the curated devices that matter. Each type answers for itself
  (`c:Dobby.DeviceAgent.matches_entity?/1`), so a new device type widens this
  by existing.
  """

  alias Dobby.HomeAssistant
  alias Dobby.HomeAssistant.Entity
  alias Dobby.HomeConfig.Types

  @typedoc "One HA device Dobby could manage and does not."
  @type candidate :: %{
          entity_id: String.t(),
          type: String.t(),
          binding: String.t() | nil,
          bindings: %{String.t() => String.t()},
          suggested_name: String.t(),
          state: String.t() | nil,
          device_id: String.t() | nil,
          platform: String.t() | nil
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
        |> Enum.filter(&is_nil(&1.entity_category))
        |> Enum.group_by(&Entity.group_key/1)
        |> Enum.map(fn {key, entities} -> {key, Enum.sort_by(entities, & &1.entity_id)} end)
        |> Enum.sort_by(fn {_key, entities} ->
          Enum.min_by(entities, & &1.entity_id).entity_id
        end)
        |> Enum.flat_map(fn {_key, entities} -> describe(entities, modules, bound) end)

      {:ok, candidates}
    end
  end

  @doc """
  Proves that a proposed file entry still names a candidate HA reported.

  File validation answers whether the entry has the right shape. This answers
  the other question the proposal path must not leave to a model: whether the
  entity exists, is unbound, and belongs to the device type the entry names.
  The check runs both when the proposal is made and when it is confirmed,
  because HA and the house can change between those two moments.
  """
  @spec validate_entry(map()) :: :ok | {:error, String.t()}
  def validate_entry(entry) when is_map(entry) do
    type = Map.get(entry, "type")

    with {:ok, _module} <- fetch_type(type),
         bindings when is_map(bindings) <- Map.get(entry, "bindings"),
         {:ok, candidates} <- candidates(type: type) do
      if Enum.any?(candidates, &(&1.bindings == bindings)) do
        :ok
      else
        {:error,
         "Home Assistant does not currently report #{inspect(Map.values(bindings))} as an unbound #{type}; run discover_entities again"}
      end
    else
      {:error, reason} ->
        {:error, reason}

      _missing_or_unrecognized ->
        {:error, "the proposed device does not name the entity bindings for #{type}"}
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

  defp fetch_type(type) do
    case Types.fetch(type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown device type #{inspect(type)}; #{Types.roll_call()}"}
    end
  end

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

  # Each module chooses its anchor and, for a compound type, its related
  # bindings. A physical HA device can still yield more than one semantic
  # candidate when that is true — an AV receiver can be both a speaker and a
  # television — so de-duplication is by type and binding set, not group alone.
  defp describe(entities, modules, bound) do
    modules
    |> Enum.flat_map(fn module ->
      entities
      |> Enum.filter(&module.matches_entity?/1)
      |> Enum.flat_map(&candidate(&1, entities, module, bound))
    end)
    |> Enum.uniq_by(&{&1.type, &1.bindings})
  end

  defp candidate(anchor, entities, module, bound) do
    case Dobby.DeviceAgent.discovery_bindings(module, anchor, entities) do
      {:ok, bindings} when map_size(bindings) > 0 ->
        if Enum.any?(bindings, fn {_binding, entity_id} ->
             MapSet.member?(bound, entity_id)
           end) do
          []
        else
          string_bindings = Map.new(bindings, fn {key, value} -> {Atom.to_string(key), value} end)

          [{binding, entity_id}] =
            if map_size(string_bindings) == 1,
              do: Map.to_list(string_bindings),
              else: [{nil, anchor.entity_id}]

          [
            %{
              entity_id: entity_id,
              type: module.config_type(),
              binding: binding,
              bindings: string_bindings,
              suggested_name: Entity.label(anchor),
              state: anchor.state,
              device_id: anchor.device_id,
              platform: anchor.platform
            }
          ]
        end

      :ignore ->
        []
    end
  end
end
