defmodule Dobby.HomeConfig.Applied do
  @moduledoc """
  What a save actually did (TK-018).

  Some of the home file can be changed while Dobby is running and some of it
  cannot, and the difference is not something a person should have to know. A
  changed house restarts the house. A changed model alias is one
  `Application.put_env` away, and so are the two settings about how the model
  answers. A port and a LAN binding belong to a listening
  socket that was opened at boot, and no amount of writing the file moves them.

  So the writer reports each outcome rather than claiming the whole thing
  worked: `applied` is in effect now, `on_restart` is written down and waiting,
  and `overridden` is written down under something that outranks the file. This
  is the same honesty rule the board already keeps about devices — WOULDN'T
  means the device refused, not that Dobby failed — carried into configuration.

  An override carries its own sentence, and the other two do not. "Waiting for
  a restart" is the whole of what there is to say about a port; "your setting
  did not take" is not the whole of anything, because the thing that outranked
  it is somewhere the person is not looking — an exported `DOBBY_MODEL` lives
  in a shell, not in the file they were just editing, and a setting the model
  in force cannot be sent (TK-037) is about a model they never chose. So the
  field arrives paired with the reason, and /admin prints the reason on the
  field rather than a word that means "ask someone".
  """

  alias Dobby.HomeConfig

  @enforce_keys [:config]
  defstruct [:config, applied: [], on_restart: [], overridden: []]

  @type field :: :house | :model | :reasoning | :routing | :port | :lan | :hostname

  @type t :: %__MODULE__{
          config: HomeConfig.t(),
          applied: [field()],
          on_restart: [field()],
          overridden: [{field(), String.t()}]
        }

  @doc """
  Whether anything at all changed.
  """
  @spec changed?(t()) :: boolean()
  def changed?(%__MODULE__{applied: [], on_restart: [], overridden: []}), do: false
  def changed?(%__MODULE__{}), do: true
end
