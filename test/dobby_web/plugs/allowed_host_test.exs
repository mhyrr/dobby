defmodule DobbyWeb.Plugs.AllowedHostTest do
  # Not async: the extra-hosts and beacon cases rewrite application env that
  # every request in the suite reads.
  use DobbyWeb.ConnCase, async: false

  alias DobbyWeb.Plugs.AllowedHost

  defp through_plug(url) do
    Plug.Test.conn(:get, url) |> AllowedHost.call(AllowedHost.init([]))
  end

  defp with_env(key, value) do
    previous = Application.fetch_env(:dobby, key)
    Application.put_env(:dobby, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:dobby, key, value)
        :error -> Application.delete_env(:dobby, key)
      end
    end)
  end

  describe "a name the house goes by" do
    test "localhost and the endpoint's url host pass untouched" do
      for url <- ["http://localhost/", "http://LOCALHOST./admin"] do
        conn = through_plug(url)
        refute conn.halted, url
        assert conn.status == nil
      end
    end

    test "the advertised mDNS name passes while the beacon runs" do
      refute AllowedHost.allowed?("dobby.local")

      with_env(:lan_beacon, hostname: "dobby.local")

      refute through_plug("http://dobby.local/admin").halted
    end

    test "a port on the Host changes nothing" do
      with_env(:lan_beacon, hostname: "dobby.local")

      refute through_plug("http://dobby.local:4000/").halted
      refute through_plug("http://localhost:4000/").halted
      assert AllowedHost.allowed?("dobby.local:4000")
      assert AllowedHost.allowed?("[::1]:4000")
      refute AllowedHost.allowed?("evil.example:4000")
    end
  end

  describe "a LAN address" do
    test "private, link-local, CGNAT and loopback literals pass" do
      for url <- [
            "http://192.168.1.20:4000/",
            "http://10.0.0.5/",
            "http://172.16.0.1/",
            "http://172.31.255.254/",
            "http://169.254.10.10/",
            "http://100.64.0.1/",
            "http://100.127.255.254/",
            "http://127.0.0.1:4000/",
            "http://[::1]:4000/",
            "http://[fd12:3456::1]/",
            "http://[fe80::1]/",
            "http://[::ffff:192.168.1.20]/"
          ] do
        refute through_plug(url).halted, url
      end
    end

    test "a public address, or one just outside a range, is refused" do
      for host <- [
            "8.8.8.8",
            "172.32.0.1",
            "100.128.0.1",
            "192.169.0.1",
            "2001:db8::1",
            "::ffff:8.8.8.8",
            "192.168.1",
            "0x7f.0.0.1"
          ] do
        refute AllowedHost.allowed?(host), host
      end
    end
  end

  describe "a foreign name" do
    test "is refused with a plain 400 before anything else runs" do
      conn = through_plug("http://evil.example/admin")

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body =~ "DOBBY_ALLOWED_HOSTS"
      assert ["text/plain" <> _charset] = get_resp_header(conn, "content-type")
    end

    test "is refused by the endpoint itself, ahead of the router", %{conn: conn} do
      conn = get(conn, "http://evil.example/admin")

      assert conn.status == 400
      assert conn.resp_body =~ "does not answer"
    end

    test "a name that merely contains an allowed one is still foreign" do
      foreign = ["localhost.evil.example", "dobby.local.evil.example", "192.168.1.20.nip.io"]

      for host <- foreign do
        refute AllowedHost.allowed?(host), host
      end

      refute AllowedHost.allowed?(nil)
      refute AllowedHost.allowed?("")
    end
  end

  describe "extra names from config" do
    test "DOBBY_ALLOWED_HOSTS's names pass, and only those" do
      refute AllowedHost.allowed?("dobby.lan")

      with_env(:allowed_hosts, ["dobby.lan", "House.Example.net"])

      refute through_plug("http://dobby.lan:8080/").halted
      refute through_plug("http://house.example.net/").halted
      assert through_plug("http://evil.example/").status == 400
    end
  end

  describe "the socket's origin check" do
    test "holds the Origin to the same list" do
      assert AllowedHost.origin_allowed?(URI.parse("http://localhost:4000"))
      assert AllowedHost.origin_allowed?(URI.parse("http://192.168.1.20:4000"))
      assert AllowedHost.origin_allowed?(URI.parse("http://[fd00::20]:4000"))
      refute AllowedHost.origin_allowed?(URI.parse("http://evil.example:4000"))
      refute AllowedHost.origin_allowed?(URI.parse("null"))
    end

    test "is what the endpoint's sockets are configured with" do
      assert DobbyWeb.Endpoint.config(:check_origin) == {AllowedHost, :origin_allowed?, []}
    end
  end
end
