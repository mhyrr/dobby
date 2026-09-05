defmodule Dobby.Tools.ConfirmRule do
  @moduledoc """
  Applies a previously shown rule through the same writer as a household form.
  Trusted turn context supplies the confirmation boundary, not a model flag.
  """
  use Jido.Action,
    name: "confirm_rule",
    description:
      "Confirm a rule proposal only after the household agrees to its exact description in a later message. Starts observing; never commands a device.",
    schema: [id: [type: :integer, required: true, doc: "Proposal id returned by propose_rule."]]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "starting the watch"
  @impl true
  def on_before_validate_params(params),
    do: {:ok, Dobby.HomeConfig.Proposals.coerce_id_param(params)}

  @impl true
  def run(params, context) do
    case Dobby.Rules.confirm(params.id,
           actor: context[:speaker] || "the household",
           request_id: context[:request_id],
           via: context[:via] || :conversation
         ) do
      {:ok, _} ->
        {:ok,
         %{applied: true, note: "The rule is written and watching. No device was commanded."}}

      error ->
        error
    end
  end
end
