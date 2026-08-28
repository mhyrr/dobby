defmodule Dobby.HomeConfig.System do
  @moduledoc """
  The `system` half of the home file: the box, rather than the house (TK-018).

  Four of these settings are here because `config/runtime.exs` used to gate
  three of them behind `config_env() == :dev` — a household running a release
  could not choose a model or reach the box from the kitchen without a rebuild,
  which is exactly the swap the `:capable` alias exists to make (broken items 1
  and 3 in the ticket).

  Two more say how the model answers rather than which one does. `reasoning`
  is how hard a reasoning model thinks before it replies; `routing` is what
  OpenRouter optimizes for when it picks the endpoint that serves the model.
  Both are the household's business: between them they decide what a reply
  costs and how long the thread waits for its first word, and a model chosen
  for speed (GLM 5.3 Flash, TK-034) is only fast with both set. They live here
  and not in `config/config.exs` for the reason the model does — changing them
  is a file edit, never a release.

  What is *not* here is as deliberate. `DATABASE_URL` and `SECRET_KEY_BASE` are
  an operator's business and stay environment-only: household-facing knobs go
  in the file a household owns, and nothing else does.

  Three of the six can be changed while Dobby is running — the model and the
  two about how it answers, all read at the moment of use — and three cannot.
  See `Dobby.HomeConfig.Writer`, which says so out loud rather than pretending.
  """

  @reasoning_levels ["low", "medium", "high"]
  @reasoning_effort %{"low" => :low, "medium" => :medium, "high" => :high}
  @routing_goals ["latency", "throughput", "price"]

  @schema [
    model: [
      type: :string,
      doc: "What the `:capable` alias resolves to, e.g. `openrouter:openai/gpt-5.6-luna`."
    ],
    reasoning: [
      type: {:in, @reasoning_levels},
      doc:
        "How hard a reasoning model thinks before it answers: low, medium or high, with unset leaving the provider's default."
    ],
    routing: [
      type: {:in, @routing_goals},
      doc:
        "What OpenRouter optimizes for when it picks the endpoint that serves the model: latency, throughput or price."
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

  @mdns_hostname ~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.local\z/

  defstruct model: nil, reasoning: nil, routing: nil, port: nil, lan: false, hostname: nil

  @type t :: %__MODULE__{
          model: String.t() | nil,
          reasoning: String.t() | nil,
          routing: String.t() | nil,
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
  What the section tells the model on every request.

  The file's words become the provider's here and nowhere else: `reasoning: low`
  is ReqLLM's `reasoning_effort`, and `routing: latency` is OpenRouter's
  `provider.sort`. `Dobby.DobbyAgent` reads the result at the moment of each
  request, the way it reads the alias, so a change the writer applies is in
  effect at the next reply and a restart is never part of trying a setting.

  `routing` is an OpenRouter field and is documented as one. OpenRouter is
  Dobby's provider (TK-034); a model reached some other way would be sent an
  option it does not know, and that is the file's mistake to make, named.
  """
  @spec llm_opts(t()) :: keyword()
  def llm_opts(%__MODULE__{reasoning: reasoning, routing: routing}) do
    Enum.reject(
      [
        reasoning_effort: reasoning && Map.fetch!(@reasoning_effort, reasoning),
        openrouter_provider: routing && %{sort: routing}
      ],
      fn {_option, value} -> is_nil(value) end
    )
  end

  @doc """
  Builds the section from the file's raw `system:` map.

  Errors name the field, matching the posture `Dobby.Home.Manifest` takes about
  devices: a typo should fail at boot saying which word was wrong.
  """
  @spec load(map()) :: {:ok, t()} | {:error, String.t()}
  def load(raw) when is_map(raw) do
    known = Map.new(@schema, fn {key, _spec} -> {Atom.to_string(key), key} end)

    with {:ok, pairs} <- known_pairs(raw, known),
         {:ok, options} <- validate(pairs),
         :ok <- validate_hostname(options[:hostname]) do
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

  defp validate_hostname(nil), do: :ok

  defp validate_hostname(hostname) do
    if Regex.match?(@mdns_hostname, hostname) do
      :ok
    else
      {:error,
       "system.hostname must be one DNS label followed by .local, for example dobby.local"}
    end
  end

  defp known do
    "the system section holds: " <> Enum.map_join(@schema, ", ", fn {key, _spec} -> key end)
  end
end
