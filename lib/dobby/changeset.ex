defmodule Dobby.Changeset do
  @moduledoc """
  A changeset's errors as one sentence a person or a model can act on.

  Ecto keeps the count out of "should be at most %{count} character(s)" and
  hands it over separately, which is right for a translation layer and wrong
  for a surface that has no translation layer: a refusal that reads
  `%{count}` names nothing. This is the one place the placeholder is filled in,
  so a schedule, a proposal and a token all refuse in the same shape —
  `field: what was wrong`, joined with semicolons — and a fourth schema does
  not grow a fourth copy of the regex.

  The shape matters because the model reads these (design §6.2): it has to
  name the actual problem, and "invalid" is not a problem anyone can fix.
  """

  @doc """
  Every error on the changeset, placeholders filled, `field: message` per
  field and `; ` between fields.
  """
  @spec error_message(Ecto.Changeset.t()) :: String.t()
  def error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end
end
