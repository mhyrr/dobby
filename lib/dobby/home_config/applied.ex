defmodule Dobby.HomeConfig.Applied do
  @moduledoc """
  What a save actually did (TK-018).

  Some of the home file can be changed while Dobby is running and some of it
  cannot, and the difference is not something a person should have to know. A
  changed house restarts the house. A changed model alias is one
  `Application.put_env` away. A port and a LAN binding belong to a listening
  socket that was opened at boot, and no amount of writing the file moves them.

  So the writer reports both halves rather than claiming the whole thing worked:
  `applied` is in effect now, `on_restart` is written down and waiting. This is
  the same honesty rule the board already keeps about devices — WOULDN'T means
  the device refused, not that Dobby failed — carried into configuration.
  """

  alias Dobby.HomeConfig

  @enforce_keys [:config]
  defstruct [:config, applied: [], on_restart: []]

  @type field :: :house | :model | :port | :lan | :hostname

  @type t :: %__MODULE__{
          config: HomeConfig.t(),
          applied: [field()],
          on_restart: [field()]
        }

  @doc """
  Whether anything at all changed.
  """
  @spec changed?(t()) :: boolean()
  def changed?(%__MODULE__{applied: [], on_restart: []}), do: false
  def changed?(%__MODULE__{}), do: true
end
