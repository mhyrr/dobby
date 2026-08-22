defmodule Dobby.Tools.DiscoverEntities do
  @moduledoc """
  Tool: what Home Assistant has that this house does not manage (TK-010).

  Entirely deterministic. It runs no inference, makes no request of Home
  Assistant, and returns the same answer twice in a row — everything it says
  comes from what the client already learned on its state sync, which is what
  keeps design §7's boundary intact while the model is the one asking. The
  model's job here is to read the list and recognize which line the person
  meant, which is a language problem; deciding what is on the list is not.

  The entity ids in the result are the only ones `propose_device` should ever
  see. A model that invented one would be refused by validation, but the point
  of this tool is that it never has to guess.
  """

  use Jido.Action,
    name: "discover_entities",
    description: """
    List the Home Assistant entities this house does not manage yet, with the \
    device type each one looks like. Use this before proposing a device, and \
    copy its entity ids exactly — never guess one.\
    """,
    schema: [
      type: [
        type: :string,
        doc:
          "Optional: only entities that look like this kind of device. One of the types the house knows."
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.HomeConfig.Discovery

  @impl Dobby.Tools
  def label(%{"type" => type}) when is_binary(type),
    do: "looking for #{type}s the house hasn't been told about"

  def label(_arguments), do: "looking for what the house hasn't been told about"

  @impl true
  def run(params, _context) do
    case Discovery.candidates(type: params[:type]) do
      {:ok, candidates} -> {:ok, %{entities: candidates, count: length(candidates)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
