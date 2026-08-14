defmodule Dobby.Jido do
  @moduledoc """
  Dobby's Jido instance: the registry and supervisors every agent runs under.

  Started before `Dobby.Home` so the bootstrap has somewhere to put agents
  (design §5). Device agents register here under their stable Dobby ID —
  `thermostat:main`, not a pid and not an HA entity ID.
  """

  use Jido, otp_app: :dobby
end
