defmodule DobbyWeb.AdminLive.TokensPanel do
  @moduledoc """
  The keys to the MCP door, on the page a maintainer opens (TK-022 layer B).

  Lives in the System section because a token is the box's business, not the
  house's: it decides who may talk to Dobby's tools over the network, the way
  the port decides where. Unlike the system fields it is not schema-rendered —
  a token is a row, not a setting, and the panel is a list and one small form.

  ## The plaintext is shown once

  `Dobby.MCP.mint/1` returns the token's plaintext exactly once and stores
  only the digest, so this panel is the one place the secret ever appears —
  held in an assign for as long as the browser keeps it on screen, gone when
  the page is. The sentence beside it says so, because a person who navigates
  away expecting to come back for it deserves the warning before, not after.

  ## Who these rows are

  The label is attribution, never permission (design §10.4's rule, carried to
  a new door): every token opens the whole roster, and what a label buys is
  an honest activity feed — "Ann's laptop confirmed the dining room
  thermostat", not "somebody with a token did".
  """

  use DobbyWeb, :html

  import DobbyWeb.Fields

  alias Dobby.MCP

  @doc """
  The panel: the tokens that exist, the one just minted, and the mint form.
  """
  attr :tokens, :list, required: true
  attr :minted, :any, default: nil, doc: "%{label: ..., token: plaintext} shown exactly once"
  attr :label, :string, default: ""
  attr :error, :string, default: nil

  def tokens(assigns) do
    ~H"""
    <section class="panel tokens">
      <%!-- Not a heading over a void: an empty list says what it means — the
            only agent that can reach the house's tools is Dobby's own. --%>
      <p :if={@tokens == []} class="note">
        No tokens; no agent but Dobby can use the house's tools.
      </p>

      <div :for={token <- @tokens} class="sched">
        <div class="row">
          <span class="name">{token.label}</span>
          <span class="val">minted {minted_on(token)}</span>
        </div>
        <div class="acts">
          <button type="button" class="takes" phx-click="revoke" phx-value-id={token.id}>
            revoke
          </button>
        </div>
      </div>

      <%!-- The one time the secret exists outside the agent it is for. The
            label leads, because by the time this shows the person is holding
            two tokens' worth of instructions in their head at most. --%>
      <div :if={@minted} class="note confirm">
        The token for {@minted.label} is <span class="arg">{@minted.token}</span> —
        copy it now. Dobby keeps only a fingerprint, so it will not be shown again.
      </div>

      <form id="new-token" class="fields" phx-change="token" phx-submit="mint">
        <.head>A new token</.head>

        <%!-- The question in the household's words, the schema key beside it —
              the same two registers every form on this board asks in. --%>
        <.field ask="Whose agent will hold it" key="label">
          <input
            type="text"
            name="token[label]"
            value={@label}
            autocomplete="off"
            placeholder="Ann's laptop"
          />
        </.field>

        <div :if={@error} class="why">{@error}</div>

        <%!-- Lower case, like every other quiet control on this board: a verb,
              and capitals here mean a state, a name or a time. --%>
        <button type="submit">mint</button>
      </form>
    </section>
    """
  end

  @doc """
  The rows, oldest first — mint order is the story of who was let in when.
  """
  @spec list() :: [MCP.Token.t()]
  def list, do: MCP.list()

  # A date, not a time: what a maintainer asks a key is "how long has this
  # been out there", and the household's own clock answers it (design §10.2's
  # one-clock rule).
  defp minted_on(token) do
    token.inserted_at |> Dobby.Home.local() |> Calendar.strftime("%b %-d, %Y")
  end
end
