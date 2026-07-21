defmodule Mafia.WriteGate do
  @moduledoc "Cutover switch that keeps the standalone site read-only until data verification finishes."

  def enabled?, do: Application.get_env(:mafia, :writes_enabled, true)

  def ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :writes_frozen}
  end
end
