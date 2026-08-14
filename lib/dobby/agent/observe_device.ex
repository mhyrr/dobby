defmodule Dobby.DobbyAgent.ObserveDevice do
  @moduledoc """
  Folds a `dobby.device.state_changed` into DobbyAgent's world model.

  This is the awareness seam (design §6.3). The signal already arrives on
  every meaningful device change; v1 does nothing with it beyond knowing. When
  proactive behavior gets built, it attaches here.
  """

  use Jido.Action,
    name: "dobby_observe_device",
    description: "Records the latest known state of a device in the world model",
    schema: [
      device: [type: :string, required: true],
      snapshot: [type: :map, required: true]
    ]

  @impl true
  def run(%{device: device, snapshot: snapshot}, context) do
    world_model = Map.get(context.state, :world_model) || %{}
    {:ok, %{world_model: Map.put(world_model, device, snapshot)}}
  end
end
