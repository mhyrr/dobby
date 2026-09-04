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
  Refuses a house whose settings the model in force cannot be sent.

  `routing` is an OpenRouter word, and nothing upstream checks that the model
  answering is actually reached through OpenRouter. When it is not, the option
  is not merely ignored — ReqLLM rejects the whole request while building it,
  so the house boots, looks healthy, and then fails *every* turn with a line
  that tells the household nothing. That is how this shipped: a stale
  `DOBBY_MODEL` in a developer's `.env` outranked the file's own
  `openrouter:` model, the file's `routing: latency` went to OpenAI, and three
  people typing into the kitchen got "Dobby couldn't answer that".

  So the check is the same posture the manifest takes about a device typo:
  fail at boot, naming the word somebody wrote. It runs the options through
  ReqLLM's own pipeline rather than a hand-written "is this OpenRouter?" test,
  which costs no network and catches the next mismatched option as well as
  this one.

  A model this machine cannot resolve is deliberately *not* this function's
  business. The request will say so in its own words, and saying it twice in
  two voices helps nobody.
  """
  @spec check_llm_opts(t(), String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def check_llm_opts(%__MODULE__{} = system, model, exported \\ nil) do
    opts = llm_opts(system)

    with false <- opts == [],
         {:ok, resolved} <- resolve_model(model),
         {:ok, provider} <- ReqLLM.Providers.get(resolved.provider) do
      validate_llm_opts(opts, provider, resolved, model, exported)
    else
      _unresolved -> :ok
    end
  end

  defp resolve_model(model) when is_binary(model) do
    {:ok, ReqLLM.model!(model)}
  rescue
    # Broad because every way `ReqLLM.model!/1` can fail means the same thing
    # here: this machine cannot resolve that model, so there is nothing to
    # check its options against. Refusing to boot on it would be this function
    # answering a question that is not its own — the request will say so in its
    # own words, and saying it twice in two voices helps nobody.
    _error -> :error
  end

  defp resolve_model(_model), do: :error

  defp validate_llm_opts(opts, provider, resolved, model, exported) do
    ReqLLM.Provider.Options.process!(provider, :chat, resolved, opts)
    :ok
  rescue
    error in NimbleOptions.ValidationError ->
      {:error, refusal(List.wrap(error.key), opts, model, exported)}
  end

  # The file's words, not ReqLLM's. Somebody wrote `routing: latency`; being
  # told that `:openrouter_provider` is unknown asks them to work backwards
  # through a translation this module performed.
  defp refusal(keys, opts, model, exported) do
    said =
      keys
      |> Enum.filter(&Keyword.has_key?(opts, &1))
      |> Enum.map_join(", ", &said(&1, Keyword.fetch!(opts, &1)))

    "system: #{said} is a setting #{model} does not take, and #{model} is " <>
      "the model in force#{source(model, exported)}. Either drop it, or name " <>
      "a model that takes it."
  end

  # Which of the two places the model came from, because the fix is in a
  # different file depending on the answer, and an exported variable is
  # invisible to somebody reading the house file and finding it already
  # correct. Boot hands this in rather than the section reading it: what the
  # file says is this module's business, and what outranks the file is not.
  defp source(model, model) when is_binary(model), do: " (exported as DOBBY_MODEL)"
  defp source(_model, _exported), do: ""

  # The inverse of the two lines in `llm_opts/1`, and it stays beside them for
  # that reason: a word added there needs its clause here or a refusal names
  # the option instead of the setting.
  defp said(:reasoning_effort, effort), do: "reasoning: #{effort}"
  defp said(:openrouter_provider, %{sort: sort}), do: "routing: #{sort}"

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
