defmodule Mafia.RateLimit do
  @moduledoc """
  ETS-backed rate limiter for authentication, email, chat, and API boundaries.
  """

  use Hammer, backend: :ets
end
