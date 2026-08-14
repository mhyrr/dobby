defmodule Dobby.Soul do
  @moduledoc """
  Who Dobby is, read from a file at boot rather than compiled in.

  The soul lives beside the home manifest in `/opt/dobby/config/` and is read
  the same way and for the same reason (design §2.4): changing who Dobby is
  should cost a restart, not a rebuild. Editing the personality of the thing
  you live with should not require a release.

  ## Soul and doctrine are different things

  This file is the **voice** — tone, brevity, how Dobby talks about itself. It
  is meant to be edited freely, and a bad edit produces an annoying housemate.

  The **doctrine** — never invent a device, never act on a guess, report what
  you commanded rather than what you observed — stays in
  `Dobby.DobbyAgent`, in code, under review. A bad edit there produces a house
  that lies about whether the heat is on.

  Keeping them apart means rewriting the personality cannot quietly delete a
  safety rule. The composed prompt is always soul first, doctrine second, and
  the doctrine always wins on conflict.
  """

  @doc """
  The soul text as written on this box.
  """
  @spec read!() :: String.t()
  def read! do
    path = path()

    case File.read(path) do
      {:ok, contents} ->
        strip_front_matter(contents)

      {:error, reason} ->
        raise """
        could not read Dobby's soul at #{path}: #{:file.format_error(reason)}

        The soul file is required. A Dobby with no soul would still run the
        house correctly and would sound like nobody in particular, which is a
        failure that is easy to ship and hard to notice — so it fails here
        instead. Set DOBBY_SOUL to point somewhere else.
        """
    end
  end

  @doc """
  The full system prompt: who Dobby is, then the rules he cannot bend.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    read!() <> "\n" <> Dobby.DobbyAgent.doctrine()
  end

  @doc """
  Where the soul is being read from.
  """
  @spec path() :: String.t()
  def path do
    Application.get_env(:dobby, :soul_path) || "config/soul.md"
  end

  # The file is Markdown so it reads well in an editor and in a PR. A leading
  # `# Title` line is for humans; the model does not need to be told it is
  # reading a document.
  defp strip_front_matter(contents) do
    contents
    |> String.split("\n")
    |> Enum.drop_while(&(&1 == "" or String.starts_with?(&1, "# ")))
    |> Enum.join("\n")
    |> String.trim()
  end
end
