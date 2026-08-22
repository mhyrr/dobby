defmodule Dobby.Tools.ConfirmDevice do
  @moduledoc """
  Tool: somebody said yes, so the house gets the device (TK-010).

  The only tool in Dobby that changes what the house *is* rather than what a
  device is doing, and the whole of it is one id and a call into the one writer.
  Everything that makes it safe happened elsewhere: the entry was validated when
  it was proposed, it is validated again here against the house as it stands
  now, and `Dobby.HomeConfig.Writer` is the single author of the file.

  Re-validating is not belt-and-braces. A proposal is a sentence somebody
  remembered; between the sentence and the yes another device may have taken
  the id, or claimed the entity, or the house may have moved to a file Dobby is
  not allowed to write. The refusal in every one of those cases is the same
  refusal a home file would get, which is what makes it something a person can
  act on.

  What comes back is a change *applied*. The household thread defers the agent
  restart until its reply lands. MCP applies it inside the request because the
  endpoint survives that restart. The channel comes from trusted tool context,
  so a caller cannot choose the easier meaning of "applied."
  """

  use Jido.Action,
    name: "confirm_device",
    description: """
    Apply a device proposal that somebody in the conversation has agreed to. \
    This writes the house file and the house takes on the device. Only call it \
    after a person has said yes to that specific proposal.\
    """,
    schema: [
      id: [
        type: :integer,
        required: true,
        doc: "The proposal id from propose_device, e.g. 2."
      ]
    ]

  @behaviour Dobby.Tools

  alias Dobby.HomeConfig.Proposals

  @impl Dobby.Tools
  def label(%{"id" => id}), do: "adding proposal #{id} to the house"
  def label(_arguments), do: "adding the device to the house"

  # A model reading `id: 2` out of a propose_device result will sometimes send
  # it back as `"2"`. Meeting it there once is cheaper than a contract that
  # says integer and a model that says string (§6.2).
  @impl true
  def on_before_validate_params(params), do: {:ok, Proposals.coerce_id_param(params)}

  @impl true
  def run(params, context) do
    case Proposals.confirm(params.id,
           confirmed_by: speaker(context),
           defer_house: defer_house?(context)
         ) do
      {:ok, proposal, applied} ->
        {:ok,
         %{
           applied: true,
           device: proposal.device_id,
           name: proposal.name,
           type: proposal.type,
           note: note(applied)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The same honesty rule as the board's: say what happened, not what is
  # about to. Over MCP the restart ran inside this request and the house
  # already has the device; in the thread it runs after the reply lands.
  defp note(%{applied: applied}) when is_list(applied) do
    if :house in applied do
      "written to the house file; the house has taken it on"
    else
      "written to the house file; the house is restarting to take it on"
    end
  end

  defp speaker(context) do
    case Map.get(context || %{}, :speaker) do
      speaker when is_binary(speaker) and speaker != "" -> speaker
      _other -> "the household"
    end
  end

  defp defer_house?(context), do: Map.get(context || %{}, :via) != :mcp
end
