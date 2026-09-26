defmodule DobbyWeb.Plugs.AllowedHost do
  @moduledoc """
  Answers only to the names this house is actually reached by.

  Dobby has no login (design §10.1): the Wi-Fi password is the boundary, and
  `/admin` is a room rather than a privilege. That trust model has one hole a
  firewall does not close, which is DNS rebinding. A household member opens a
  page on `evil.example`; the attacker's DNS then answers `evil.example` with
  the box's LAN address, and the page's own scripts are suddenly talking to
  Dobby from what the browser still considers the page's own origin. Origin and
  Host are both `evil.example`, so an Origin-versus-Host comparison
  (`check_origin: :conn`, which is what production used to run) passes, and the
  page can mint MCP tokens, rewrite the house file, and change the model.

  The one thing the attacker cannot change is the Host header: it is the name
  the page was loaded from. So the endpoint refuses any request whose Host is
  not one of the house's own names:

    * loopback — `localhost`, and any `127.0.0.0/8` or `::1` literal;
    * the endpoint's configured `url` host (`PHX_HOST`, else the house file's
      `hostname`, else `dobby.local`);
    * the name `Dobby.LanBeacon` advertises, when it runs;
    * `:allowed_hosts` — the house file's `hostname`, plus `DOBBY_ALLOWED_HOSTS`
      for a router's DNS name or a reverse proxy (`config/runtime.exs`);
    * any IP literal in a private or link-local range: RFC 1918, 169.254/16,
      the CGNAT 100.64/10 some mesh VPNs hand out, IPv6 ULA and link-local.

  IP literals are safe to allow wholesale because rebinding needs a *name*: a
  browser sends `Host: 192.168.1.20` only for a page whose origin is
  `http://192.168.1.20`, which is the box itself. Allowing them keeps "type the
  address the boot log printed" working, which the household relies on
  whenever `.local` resolution does not (see the guide's agents page).

  ## Sockets

  `Phoenix.Endpoint` dispatches `socket` paths in a plug it inserts ahead of
  every plug the endpoint declares, so a LiveView upgrade never reaches this
  one. `origin_allowed?/1` is the same allowlist in the shape
  `check_origin: {mod, fun, args}` takes, applied to the Origin of the upgrade.
  A rebinding page's Origin is its own name, so it is refused there. The one
  thing this is looser about than `:conn` was is a page served from another
  private IP on the LAN; such a page cannot read a LiveView session or CSRF
  token cross-origin, and LiveView refuses a connect without both.

  ## Rejected alternatives

  A login. The product promises none, and a password on the kitchen tablet is
  a worse house than one that ignores strangers' names.

  A fixed list of origins in `check_origin`. It covers only the socket, and
  the HTTP routes (`/admin` included) never consult it.

  Leaving `/mcp` out. It has its own bearer token and its own Origin rule
  (`DobbyWeb.MCP.Router`), but the rule is uniform and cheap, and a door that
  answers to any name is one fewer thing to reason about. MCP clients reach it
  by the same names and addresses a browser does.

  Status 421 Misdirected Request was the other candidate. 400 was chosen
  because every client and proxy renders it plainly; the body says what to do.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{host: host} = conn, _opts) do
    if allowed?(host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(400, refusal(host))
      |> halt()
    end
  end

  @doc """
  The `check_origin` MFA for the endpoint's sockets: the Origin's host, judged
  by the same rule as a request's Host.
  """
  @spec origin_allowed?(URI.t()) :: boolean()
  def origin_allowed?(%URI{host: host}), do: allowed?(host)

  @doc """
  Whether `host` (a Host header's name, with or without a port or IPv6
  brackets) is one this house answers to.
  """
  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(host) when is_binary(host) do
    host = normalize(host)
    host != "" and (host in named_hosts() or lan_address?(host))
  end

  def allowed?(_no_host), do: false

  defp named_hosts do
    endpoint_host = DobbyWeb.Endpoint.config(:url)[:host]
    beacon_host = get_in(Application.get_env(:dobby, :lan_beacon) || [], [:hostname])
    extra = Application.get_env(:dobby, :allowed_hosts, [])

    ["localhost", endpoint_host, beacon_host | extra]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
  end

  # Case-insensitive, and blind to the trailing dot of a fully qualified name
  # and to the brackets an IPv6 literal wears in a Host header. A port, if one
  # survived the adapter, is not part of the name.
  defp normalize(host) do
    host = host |> String.trim() |> String.downcase()

    host =
      case host do
        "[" <> rest -> rest |> String.split("]", parts: 2) |> hd()
        _name_or_ipv4 -> strip_port(host)
      end

    String.trim_trailing(host, ".")
  end

  # Only a single colon is a port: two or more is a bare IPv6 literal.
  defp strip_port(host) do
    case String.split(host, ":") do
      [name, _port] -> name
      _no_port_or_ipv6 -> host
    end
  end

  defp lan_address?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> private?(address)
      {:error, _not_an_address} -> false
    end
  end

  defp private?({127, _, _, _}), do: true
  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({169, 254, _, _}), do: true
  defp private?({100, b, _, _}) when b in 64..127, do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # fc00::/7, unique local
  defp private?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  # fe80::/10, link-local
  defp private?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  # ::ffff:a.b.c.d, an IPv4 address written as IPv6
  defp private?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: private?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp private?(_public), do: false

  defp refusal(host) do
    """
    Dobby does not answer to the name #{inspect(host)}.

    Open it by the house's own name (dobby.local, or the hostname in the house
    file), by localhost, or by its LAN address. If this name is yours — a
    router's DNS name, a reverse proxy — add it to DOBBY_ALLOWED_HOSTS
    (comma separated) and restart.
    """
  end
end
