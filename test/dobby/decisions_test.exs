defmodule Dobby.DecisionsTest do
  @moduledoc """
  The shape of the decision record (decision 31).

  A decision under `docs/decisions/` is a fact the code cites by number, so
  the numbers have to be what the citations say: contiguous from where the
  design record's §13 list stopped, one file each, every file carrying the
  four sections and in particular the one that names what was rejected.
  This test is the difference between a convention and a wish, which is the
  point of decision 29: the shape is executed, not described.

  Reading the markdown for headings rather than parsing it was the choice.
  A markdown parser would give a tree nobody needs; a heading on its own
  line is unambiguous and the failure names the file.
  """

  use ExUnit.Case, async: true

  @dir "docs/decisions"
  @record "docs/design/dobby-design-jido.md"
  @first 29
  @sections ["## Decision", "## Why", "## Rejected", "## Where it lives"]

  test "every decision is numbered on from the design record and carries its four sections" do
    files = decision_files()

    assert files != [], "#{@dir} holds no decisions; decision 31 says it should"

    numbers =
      for path <- files do
        name = Path.basename(path)

        assert Regex.match?(~r/^\d{4}-[a-z0-9-]+\.md$/, name),
               "#{path} is not named NNNN-a-few-words.md (docs/decisions/README.md)"

        contents = File.read!(path)

        for section <- @sections do
          assert String.contains?(contents, "\n#{section}\n"),
                 "#{path} has no `#{section}` section; every decision carries all four"
        end

        name |> String.slice(0, 4) |> String.to_integer()
      end

    expected = Enum.to_list(@first..(@first + length(numbers) - 1)//1)

    assert numbers == expected,
           "decisions are numbered #{inspect(numbers)}; expected #{inspect(expected)}, " <>
             "contiguous from where #{@record} §13 stops"
  end

  test "the design record's list stops where the directory starts" do
    [_, decisions] = @record |> File.read!() |> String.split("## 13. Current decisions", parts: 2)

    last =
      ~r/^(\d+)\. /m
      |> Regex.scan(decisions)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.max()

    assert last == @first - 1,
           "#{@record} §13 ends at decision #{last}, but files start at #{@first}; " <>
             "a new decision is a file under #{@dir}, not a line in §13"
  end

  test "every decision the code cites exists" do
    recorded = MapSet.new(decision_numbers())

    for path <- Path.wildcard("{lib,test}/**/*.{ex,exs}"),
        [_, n] <- Regex.scan(~r/decision (\d+)/, File.read!(path)),
        number = String.to_integer(n),
        number >= @first do
      assert MapSet.member?(recorded, number),
             "#{path} cites decision #{number}, and no #{@dir}/#{pad(number)}-*.md records it"
    end
  end

  defp decision_files do
    @dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "README.md"))
    |> Enum.sort()
  end

  defp decision_numbers do
    for path <- decision_files(),
        [_, n] <- Regex.scan(~r/^(\d{4})-/, Path.basename(path)),
        do: String.to_integer(n)
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(4, "0")
end
