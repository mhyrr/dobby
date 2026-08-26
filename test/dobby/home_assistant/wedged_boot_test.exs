defmodule Dobby.HomeAssistant.WedgedBootTest do
  @moduledoc """
  The house comes up against a Home Assistant that never answers (TK-017).

  The rig's other scenarios boot against `Dobby.HomeAssistant.Fake`, which is
  always reachable — so the one thing they cannot ask is what happens when the
  house is not. This one puts the *real* client in the tree, under the name
  production registers it with, pointed at a listener that accepts the
  connection and then says nothing, and then boots the real bootstrap on top of
  it.

  What it is watching for is not that the client fails. It is that
  `Dobby.Home.init/1` gets its answer at once: the house is a household's
  console, and a console that will not come up because the thermostat's server
  is wedged is a worse failure than the wedged server.
  """

  use Dobby.RigCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Dobby.HomeAssistant.Client
  alias Dobby.StalledHost

  @endpoint DobbyWeb.Endpoint

  @thermostat "thermostat:main"
  @light "light:living_room"

  test "the house boots, and every card says nobody has told it anything" do
    host = StalledHost.start!(owner: self())

    # The real client, under the name `Dobby.HomeAssistant.impl/0` resolves to,
    # so `Dobby.Home.init/1` reaches this process and not the fake.
    start_supervised!({Client, url: host.https, token: "wedged-token", name: Client, backoff: 50})

    # It is inside a connect that will never complete before the house starts
    # coming up, which is the ordering production has too: the client is the
    # supervisor child before `Dobby.Home`. Generous, because the first
    # `:https` connect in a VM loads the trust store before it opens a socket.
    assert_receive {:stalled_host, :accepted}, 15_000

    devices = [
      thermostat_device(@thermostat, "main thermostat"),
      light_device(@light, "living room light")
    ]

    Application.put_env(
      :dobby,
      Dobby.Home,
      Keyword.put(rig_manifest(devices), :home_assistant,
        client: Client,
        url: host.https,
        token: "wedged-token"
      )
    )

    started = System.monotonic_time(:millisecond)
    result = Dobby.Home.restart()
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:ok, pid} = result
    assert Process.alive?(pid)

    # The bound is the point, not decoration. `Dobby.Home.init/1` asks the
    # client for one thing with a five second deadline, and a boot that spends
    # any of it waiting on the network is one scheduling accident away from
    # spending all of it.
    assert elapsed < 3_000, "the house took #{elapsed}ms to boot against a wedged house"

    {:ok, view, _html} = live(build_conn(), "/house")

    # NOT KNOWN across the board: the agents exist, and Home Assistant has told
    # them nothing. Not QUIET — nothing has said these devices stopped
    # answering, because nothing has said anything at all.
    assert has_element?(view, "#card-thermostat\\:main .flap[data-st=silent]", "Not known")
    assert has_element?(view, "#card-light\\:living_room .flap[data-st=silent]", "Not known")

    # And no control to turn, which is what a card with nothing to say offers.
    refute has_element?(view, "#set-thermostat\\:main")
  end
end
