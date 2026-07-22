defmodule MafiaWeb.GameComponents do
  @moduledoc "Shared navigation for the split game workspace."

  use MafiaWeb, :html

  attr :game, :map, required: true
  attr :current, :atom, required: true
  attr :show_notes, :boolean, default: false
  attr :show_settings, :boolean, default: false

  def game_nav(assigns) do
    ~H"""
    <nav class="flex flex-wrap gap-2" aria-label="Game workspace">
      <.link
        navigate={~p"/mafia/#{@game.id}"}
        class={nav_class(@current == :overview)}
        aria-current={if @current == :overview, do: "page"}
      >
        <.icon name="hero-squares-2x2" class="size-4" /> Overview
      </.link>
      <.link
        navigate={~p"/mafia/#{@game.id}/rules"}
        class={nav_class(@current == :rules)}
        aria-current={if @current == :rules, do: "page"}
      >
        <.icon name="hero-document-text" class="size-4" /> Rules
      </.link>
      <.link
        :if={@show_notes}
        navigate={~p"/mafia/#{@game.id}/notes"}
        class={nav_class(@current == :notes)}
        aria-current={if @current == :notes, do: "page"}
      >
        <.icon name="hero-pencil-square" class="size-4" /> Notebook
      </.link>
      <.link
        :if={@show_settings}
        navigate={~p"/mafia/#{@game.id}/settings"}
        class={nav_class(@current == :settings)}
        aria-current={if @current == :settings, do: "page"}
      >
        <.icon name="hero-adjustments-horizontal" class="size-4" /> Settings
      </.link>
    </nav>
    """
  end

  defp nav_class(true), do: "btn btn-primary text-sm"
  defp nav_class(false), do: "btn btn-secondary text-sm"
end
