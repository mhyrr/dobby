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

  @doc """
  Performs a service call against Home Assistant.

  Returns `:ok` once HA has *accepted* the call. Physical confirmation arrives
  later and separately, as an inbound state change.
  """
  @callback execute(HACall.t()) :: :ok | {:error, term()}

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
  The configured client module.

  Set per home in the manifest's `home_assistant[:client]`; defaults to the
  fake so that a misconfigured environment fails loudly against nothing rather
  than quietly against the real house.
  """
  @spec impl() :: module()
  def impl, do: Keyword.get(options(), :client, Dobby.HomeAssistant.Fake)

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
