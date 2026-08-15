defmodule DobbyWeb.Layouts do
  @moduledoc """
  The page skeleton.

  There is no app layout wrapping the surface in navigation and chrome. Each
  route *is* a board — header, thread, set line — and a shell around it would
  be a second visual language arguing with the first. The root template is the
  document, and the LiveView is the board inside it.
  """

  use DobbyWeb, :html

  embed_templates "layouts/*"
end
