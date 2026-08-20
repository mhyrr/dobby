defmodule Dobby.HomeConfig.System do
  @moduledoc """
  The `system` half of the home file: the box, rather than the house (TK-018).

  Four settings, and they are here because `config/runtime.exs` used to gate
  three of them behind `config_env() == :dev` — a household running a release
  could not choose a model or reach the box from the kitchen without a rebuild,
  which is exactly the swap the `:capable` alias exists to make (broken items 1
  and 3 in the ticket).

  What is *not* here is as deliberate. `DATABASE_URL` and `SECRET_KEY_BASE` are
  an operator's business and stay environment-only: household-facing knobs go
  in the file a household owns, and nothing else does.

  Two of the four can be changed while Dobby is running and two cannot — see
  `Dobby.HomeConfig.Writer`, which says so out loud rather than pretending.
  """

  @schema [
    model: [
      type: :string,
      doc: "What the `:capable` alias resolves to, e.g. `anthropic:claude-sonnet-4-5`."
    ],
    port: [
      type: :pos_integer,
      doc: "The port the surface is served on."
    ],
    lan: [
      type: :boolean,
      default: false,
      doc: "Bind every interface and advertise this machine on the household network."
    ],
    hostname: [
      type: :string,
      doc: "The name to answer to on the household network. Defaults to dobby.local."
    ]
  ]

  defstruct model: nil, port: nil, lan: false, hostname: nil

  @type t :: %__MODULE__{
          model: String.t() | nil,
          port: pos_integer() | nil,
          lan: boolean(),
          hostname: String.t() | nil
        }

  @doc """
  The declared shape of the section, for validation and for rendering it.

  One declaration, two readers: this module validates against it, and /admin
  builds its panel from it, so a knob added here grows a field there without a
  hand-built form.
  """
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc """
  Builds the section from the file's raw `system:` map.

  Errors name the field, matching the posture `Dobby.Home.Manifest` takes about
  devices: a typo should fail at boot saying which word was wrong.
  """
  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(raw) when is_map(raw) do
    known = Map.new(@schema, fn {key, _spec} -> {Atom.to_string(key), key} end)

    with {:ok, pairs} <- known_pairs(raw, known),
         {:ok, options} <- validate(pairs) do
      {:ok, struct!(__MODULE__, options)}
    end
  end

  def load(other), do: {:error, "system must be a mapping, got: #{inspect(other)}"}

  defp known_pairs(raw, known) do
    Enum.reduce_while(raw, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(known, to_string(key)) do
        {:ok, atom} ->
          {:cont, {:ok, [{atom, value} | acc]}}

        :error ->
          {:halt, {:error, "system: unknown setting #{inspect(to_string(key))}; #{known()}"}}
      end
    end)
  end

  defp validate(pairs) do
    case NimbleOptions.validate(pairs, @schema) do
      {:ok, options} -> {:ok, options}
      {:error, %NimbleOptions.ValidationError{message: message}} -> {:error, "system: #{message}"}
    end
  end

  defp known do
    "the system section holds: " <> Enum.map_join(@schema, ", ", fn {key, _spec} -> key end)
  end
end
