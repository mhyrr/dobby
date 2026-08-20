defmodule Dobby.ConfigEvents do
  @moduledoc """
  The `dobby:config` seam (TK-018).

  One topic, one publisher — `Dobby.HomeConfig.Writer`, which is the only
  process that writes the home file — and every configuration surface as the
  consumers. /admin and /house render from the *applied* configuration and
  update on this, which is why v1 needs no file watcher: a hand edit applies on
  restart, exactly today's contract, and everything Dobby itself changes is
  announced here the moment it takes effect.

  Follows `Dobby.DeviceEvents` and `Dobby.ActivityEvents`: both sides agree on
  the payload in one place rather than in two that drift.

      {:applied, %Applied{}}   the file changed, and here is what that did
  """

  alias Dobby.HomeConfig.Applied

  @topic "dobby:config"

  @doc """
  The PubSub topic carrying configuration changes.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the calling process to configuration changes.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dobby.PubSub, @topic)

  @doc """
  Announces a configuration that has just been written and applied.

  Carries what took effect and what is waiting for a restart, so a surface can
  say so rather than showing a value the running system is not using.
  """
  @spec applied(Applied.t()) :: :ok
  def applied(%Applied{} = applied) do
    Phoenix.PubSub.broadcast(Dobby.PubSub, @topic, {:applied, applied})
  end
end
