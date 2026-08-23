defmodule Dobby.HomeAssistant do
  @moduledoc """
  The one honest boundary (design §12).

  Everything above this module is real in every environment — real device
  agents, a real `DobbyAgent`, a real manifest bootstrap. Only the
  implementation behind this behaviour is swapped, which is what lets the
  whole application boot and be exercised with no hardware, no HAOS, and no
  network.
  """

  alias Dobby.Directive.HACall
  alias Dobby.HomeAssistant.Entity

  @doc """
  Performs a service call against Home Assistant.

  Returns `:ok` once HA has *accepted* the call. Physical confirmation arrives
  later and separately, as an inbound state change.
  """
  @callback execute(HACall.t()) :: :ok | {:error, term()}

  @doc """
  Every entity this client currently knows Home Assistant has.

  A read of what the deterministic layer already learned, and never a fresh
  request: the client subscribes and fetches current states on every
  authenticated connection, so by the time anybody asks, the answer is sitting
  in a process. That is what keeps design §7's boundary intact when the
  household thread wants to know what Home Assistant has — nothing above this
  module gets to talk to Home Assistant, including by asking it a question.

  Empty is a real answer: a client that has not connected yet knows nothing,
  and saying so is better than blocking a conversation on a house that is down.
  """
  @callback entities() :: [Entity.t()]

  @doc """
  Installs the entity-to-agent routing table built from the manifest bindings.

  The client fans inbound `state_changed` events out to whichever device agent
  owns the entity, so it needs to know the mapping before events start.
  """
  @callback configure_routing(%{String.t() => String.t()}) :: :ok

  @doc """
  Dispatches to the configured client implementation.
  """
  @spec execute(HACall.t()) :: :ok | {:error, term()}
  def execute(%HACall{} = call), do: impl().execute(call)

  @spec configure_routing(%{String.t() => String.t()}) :: :ok
  def configure_routing(routing_table), do: impl().configure_routing(routing_table)

  @doc """
  Every entity the configured client knows about, sorted by id.

  Sorted here rather than in each client, because two implementations that
  agree on the contents and disagree on the order are two implementations.
  """
  @spec entities() :: [Entity.t()]
  def entities, do: Enum.sort_by(impl().entities(), & &1.entity_id)

  @doc """
  The configured client module.

  Set per home in the manifest's `home_assistant[:client]`; defaults to the
  fake so that a misconfigured environment fails loudly against nothing rather
  than quietly against the real house.
  """
  @spec impl() :: module()
  def impl, do: Keyword.get(options(), :client, Dobby.HomeAssistant.Fake)

  @doc """
  Delivers one entity's state to whichever device agent owns it.

  Both implementations dispatch inbound state through here — the fake when it
  confirms a service call or injects a change, the real client when Home
  Assistant reports one. The signal shape is the contract every device agent's
  `signal_routes` matches on, so it is produced in exactly one place rather
  than two that drift.

  An entity nobody owns is dropped, as is one whose agent is not running:
  the world moving is not an error, even when nobody is listening.

  Attribute keys are normalized to strings here, because that is what they
  are on the wire — real HA speaks JSON. The fake's seeds and the rig's test
  entities write them as atoms for convenience, and letting that shape leak
  through would mean agents pass on the rig and fail on the house, which was
  a bug this normalization retired. (Never the other direction: atomizing
  keys Home Assistant controls would let the house leak atoms.)
  """
  @spec dispatch_state_changed(%{String.t() => String.t()}, String.t(), String.t() | nil, map()) ::
          :ok
  def dispatch_state_changed(routing, entity_id, state, attributes) do
    with agent_id when is_binary(agent_id) <- Map.get(routing, entity_id),
         pid when is_pid(pid) <- Dobby.Jido.whereis(agent_id) do
      signal =
        Jido.Signal.new!("ha.state_changed", %{
          entity_id: entity_id,
          state: state,
          attributes: Map.new(attributes, fn {key, value} -> {to_string(key), value} end)
        })

      Jido.AgentServer.cast(pid, signal)
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  The manifest's `home_assistant` block, as the client's start options.

  The client is told where its Home Assistant is by the same file that
  describes the house, because they are the same fact. For the fake that block
  also carries the starting state of the world, which is what makes
  `mix phx.server` boot a house somebody can actually look at rather than one
  that knows nothing about itself.
  """
  @spec options() :: keyword()
  def options do
    :dobby
    |> Application.get_env(Dobby.Home, [])
    |> Keyword.get(:home_assistant, [])
  end
end
