defmodule Dobby.DeviceAgents.Validation do
  @moduledoc """
  The manifest checks common to the device-agent library.

  This is shared only where the shape is already exact: required and optional
  HA bindings plus a settings map. Domain rules still live in the device type
  that owns them.
  """

  @spec device(map(), [atom()], [atom()]) :: :ok | {:error, String.t()}
  def device(%{bindings: bindings, settings: settings}, required, optional \\ []) do
    with :ok <- bindings(bindings, required, optional) do
      if is_map(settings),
        do: :ok,
        else: {:error, "settings must be a map, got #{inspect(settings)}"}
    end
  end

  @spec bindings(term(), [atom()], [atom()]) :: :ok | {:error, String.t()}
  def bindings(bindings, required, optional) when is_map(bindings) do
    allowed = required ++ optional

    with :ok <- required_bindings(bindings, required) do
      Enum.reduce_while(bindings, :ok, fn {key, value}, :ok ->
        cond do
          key not in allowed ->
            {:halt, {:error, "unknown binding #{inspect(key)}"}}

          not is_binary(value) ->
            {:halt,
             {:error, "bindings.#{key} must be an entity id string, got #{inspect(value)}"}}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end

  def bindings(other, _required, _optional),
    do: {:error, "bindings must be a map, got #{inspect(other)}"}

  defp required_bindings(bindings, required) do
    case Enum.find(required, &(not Map.has_key?(bindings, &1))) do
      nil -> :ok
      missing -> {:error, "missing required binding #{inspect(missing)}"}
    end
  end
end
