defmodule Dobby.HomeConfig.Resolver do
  @moduledoc """
  Where a credential is, said once (TK-018).

  A home file says `token: env:DOBBY_HA_TOKEN`. That is a *declaration* — the
  name of a variable, never its value — which is the whole reason the file can
  be committed, copied, and handed to somebody setting up their own house.

  Before this module the raise lived inside `config/homes/local.exs`: every
  home file wanting a token re-invented the same `System.get_env(…) || raise`
  block, and describing a house and locating a credential are two jobs. One
  resolver, one raise, one message.

  An empty variable counts as missing, deliberately. `.env.example` ships
  `DOBBY_HA_TOKEN=` with nothing after it, and `||` reads that as set — which
  fails later and further away, as an authentication failure against Home
  Assistant rather than a sentence naming the variable.
  """

  @prefix "env:"

  @doc """
  Whether this value names a variable rather than holding one's value.
  """
  @spec reference?(term()) :: boolean()
  def reference?(<<@prefix, rest::binary>>), do: rest != ""
  def reference?(_other), do: false

  @doc """
  The reference a home file writes for the given variable name.
  """
  @spec reference(String.t()) :: String.t()
  def reference(name) when is_binary(name), do: @prefix <> name

  @doc """
  The variable a reference names.
  """
  @spec variable(String.t()) :: String.t()
  def variable(<<@prefix, name::binary>>), do: name

  @doc """
  Resolves every `env:` reference in a loaded home configuration.

  Walks the whole structure rather than a known list of fields, because which
  values are secret is the household's business: an SSID, a URL on a private
  network and a token are all things somebody may not want in a file they
  share.

  Raises when a referenced variable is unset or empty. That is the right shape:
  a missing credential is not a malformed file, it is a machine that has not
  been told something, and Dobby should say which thing and stop.
  """
  @spec resolve!(term()) :: term()
  def resolve!(value) when is_binary(value) do
    if reference?(value), do: fetch!(variable(value)), else: value
  end

  def resolve!(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, resolve!(value)} end)
  end

  def resolve!(list) when is_list(list), do: Enum.map(list, &resolve!/1)

  def resolve!(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&resolve!/1) |> List.to_tuple()
  end

  def resolve!(other), do: other

  defp fetch!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        value

      _unset_or_empty ->
        raise """
        #{name} is not set.

        The home file asks for this value with `env:#{name}`, which is how a
        credential stays out of a file meant to be shared. Export the variable
        and start Dobby again — in development .env is read for you, see
        .env.example.
        """
    end
  end
end
