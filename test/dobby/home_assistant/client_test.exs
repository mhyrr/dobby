defmodule Dobby.HomeAssistant.ClientTest do
  @moduledoc """
  The real client against real frames (design §12, the third verification
  layer's fast half): a `Dobby.HAServer` speaking the actual HA wire protocol
  on a loopback port, with the test scripting the server side.

  Delivery is observed through the client's dispatch seam rather than through
  live device agents — the translation *into* agent state is FakeHA-tier
  coverage, and the wire is what this file is for.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Dobby.Directive.HACall
  alias Dobby.HAServer
  alias Dobby.HomeAssistant.Client

  defp start_client!(url, opts \\ []) do
    test = self()

    dispatch = fn _routing, entity_id, state, attributes ->
      send(test, {:dispatched, entity_id, state, attributes})
      :ok
    end

    ExUnit.Callbacks.start_supervised!(
      {Client,
       Keyword.merge(
         [url: url, token: "rig-token", name: nil, backoff: 50, dispatch: dispatch],
         opts
       )}
    )
  end

  defp call(entity_id \\ "climate.hvac", temperature \\ 72) do
    %HACall{
      domain: "climate",
      service: "set_temperature",
      entity_id: entity_id,
      data: %{temperature: temperature}
    }
  end

  describe "connection and authentication" do
    test "authenticates with the token and subscribes to state_changed" do
      url = HAServer.start!(owner: self())
      start_client!(url)

      assert_receive {:ha_server, :connected, _handler}, 1_000

      assert_receive {:ha_server, :received, %{"type" => "auth", "access_token" => "rig-token"}},
                     1_000

      assert_receive {:ha_server, :received,
                      %{"type" => "subscribe_events", "event_type" => "state_changed"}},
                     1_000
    end

    test "an invalid token is retried without crashing, and never subscribes" do
      url = HAServer.start!(owner: self(), token: "some-other-token")
      client = start_client!(url)

      # Two connections means the first auth_invalid was survived and retried.
      assert_receive {:ha_server, :connected, _handler}, 1_000
      assert_receive {:ha_server, :connected, _handler}, 1_000

      assert Process.alive?(client)
      refute_received {:ha_server, :received, %{"type" => "subscribe_events"}}
    end

    test "an unreachable Home Assistant leaves the client up and answering honestly" do
      client = start_client!("http://127.0.0.1:1")

      assert Client.execute(client, call()) == {:error, :disconnected}
      assert Process.alive?(client)
    end
  end

  describe "initial state synchronization" do
    test "routing installed before connect: current states fan out on auth" do
      states = [
        %{
          "entity_id" => "climate.hvac",
          "state" => "heat",
          "attributes" => %{"temperature" => 70}
        },
        %{"entity_id" => "sun.sun", "state" => "above_horizon", "attributes" => %{}}
      ]

      url = HAServer.start!(owner: self(), states: states)
      client = start_client!(url)
      :ok = Client.configure_routing(client, %{"climate.hvac" => "thermostat:main"})

      assert_receive {:dispatched, "climate.hvac", "heat", %{"temperature" => 70}}, 1_000
      refute_received {:dispatched, "sun.sun", _state, _attributes}
    end

    test "routing installed after connect: sync happens immediately" do
      states = [
        %{"entity_id" => "climate.hvac", "state" => "cool", "attributes" => %{}}
      ]

      url = HAServer.start!(owner: self(), states: states)
      client = start_client!(url)

      # Connected and subscribed, but nothing to route yet: no get_states.
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000
      refute_received {:ha_server, :received, %{"type" => "get_states"}}

      :ok = Client.configure_routing(client, %{"climate.hvac" => "thermostat:main"})

      assert_receive {:ha_server, :received, %{"type" => "get_states"}}, 1_000
      assert_receive {:dispatched, "climate.hvac", "cool", %{}}, 1_000
    end
  end

  describe "service calls" do
    test "a successful call returns :ok" do
      url = HAServer.start!(owner: self())
      client = start_client!(url)
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000

      assert Client.execute(client, call()) == :ok

      assert_receive {:ha_server, :received,
                      %{
                        "type" => "call_service",
                        "domain" => "climate",
                        "service" => "set_temperature",
                        "service_data" => %{"temperature" => 72},
                        "target" => %{"entity_id" => "climate.hvac"}
                      }},
                     1_000
    end

    test "a refused call returns HA's error" do
      url =
        HAServer.start!(owner: self(), call_service: {:error, "not_found", "entity not found"})

      client = start_client!(url)
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000

      assert Client.execute(client, call()) == {:error, {"not_found", "entity not found"}}
    end

    test "concurrent calls are correlated by id, whatever order results arrive in" do
      url = HAServer.start!(owner: self(), call_service: :silent)
      client = start_client!(url)
      assert_receive {:ha_server, :connected, handler}, 1_000
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000

      first = Task.async(fn -> Client.execute(client, call("climate.hvac")) end)

      assert_receive {:ha_server, :received,
                      %{
                        "type" => "call_service",
                        "id" => first_id,
                        "target" => %{"entity_id" => "climate.hvac"}
                      }},
                     1_000

      second = Task.async(fn -> Client.execute(client, call("climate.heatpump")) end)

      assert_receive {:ha_server, :received,
                      %{
                        "type" => "call_service",
                        "id" => second_id,
                        "target" => %{"entity_id" => "climate.heatpump"}
                      }},
                     1_000

      # Answer the second request first. Each caller must still get its own.
      send(handler, {:push, %{id: second_id, type: "result", success: true, result: %{}}})

      send(
        handler,
        {:push,
         %{
           id: first_id,
           type: "result",
           success: false,
           error: %{code: "unknown_error", message: "the hvac is on fire"}
         }}
      )

      assert Task.await(second) == :ok
      assert Task.await(first) == {:error, {"unknown_error", "the hvac is on fire"}}
    end

    test "a call in flight when the connection drops is answered, not stranded" do
      url = HAServer.start!(owner: self(), call_service: :silent)
      client = start_client!(url)
      assert_receive {:ha_server, :connected, handler}, 1_000
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000

      in_flight = Task.async(fn -> Client.execute(client, call()) end)
      assert_receive {:ha_server, :received, %{"type" => "call_service"}}, 1_000

      send(handler, :close)

      assert Task.await(in_flight) == {:error, :disconnected}
    end
  end

  describe "state_changed events" do
    setup do
      states = [
        %{"entity_id" => "climate.hvac", "state" => "heat", "attributes" => %{}}
      ]

      url = HAServer.start!(owner: self(), states: states)
      client = start_client!(url)
      :ok = Client.configure_routing(client, %{"climate.hvac" => "thermostat:main"})
      assert_receive {:ha_server, :connected, handler}, 1_000
      assert_receive {:dispatched, "climate.hvac", _state, _attributes}, 1_000

      {:ok, handler: handler, client: client}
    end

    test "a routed entity's event reaches its agent", %{handler: handler} do
      send(
        handler,
        {:push,
         %{
           type: "event",
           event: %{
             event_type: "state_changed",
             data: %{
               entity_id: "climate.hvac",
               old_state: %{"state" => "heat", "attributes" => %{}},
               new_state: %{
                 "state" => "heat",
                 "attributes" => %{"temperature" => 68, "current_temperature" => 66.5}
               }
             }
           }
         }}
      )

      assert_receive {:dispatched, "climate.hvac", "heat",
                      %{"temperature" => 68, "current_temperature" => 66.5}},
                     1_000
    end

    test "an unrouted entity is ignored", %{handler: handler} do
      send(
        handler,
        {:push,
         %{
           type: "event",
           event: %{
             event_type: "state_changed",
             data: %{
               entity_id: "light.porch",
               old_state: nil,
               new_state: %{"state" => "on", "attributes" => %{}}
             }
           }
         }}
      )

      refute_receive {:dispatched, "light.porch", _state, _attributes}, 200
    end

    test "an entity Home Assistant removed reads as unavailable", %{handler: handler} do
      send(
        handler,
        {:push,
         %{
           type: "event",
           event: %{
             event_type: "state_changed",
             data: %{
               entity_id: "climate.hvac",
               old_state: %{"state" => "heat", "attributes" => %{}},
               new_state: nil
             }
           }
         }}
      )

      assert_receive {:dispatched, "climate.hvac", nil, %{}}, 1_000
    end
  end

  describe "reconnection" do
    test "a dropped connection comes back: re-auth, re-subscribe, re-sync" do
      states = [
        %{"entity_id" => "climate.hvac", "state" => "heat", "attributes" => %{}}
      ]

      url = HAServer.start!(owner: self(), states: states)
      client = start_client!(url)
      :ok = Client.configure_routing(client, %{"climate.hvac" => "thermostat:main"})

      assert_receive {:ha_server, :connected, handler}, 1_000
      assert_receive {:dispatched, "climate.hvac", "heat", %{}}, 1_000

      send(handler, :close)

      # The whole sequence again, unprompted — which is also what heals any
      # events the outage swallowed.
      assert_receive {:ha_server, :connected, _handler}, 1_000
      assert_receive {:ha_server, :received, %{"type" => "auth"}}, 1_000
      assert_receive {:ha_server, :received, %{"type" => "subscribe_events"}}, 1_000
      assert_receive {:ha_server, :received, %{"type" => "get_states"}}, 1_000
      assert_receive {:dispatched, "climate.hvac", "heat", %{}}, 1_000

      assert Client.execute(client, call()) == :ok
    end
  end
end
