defmodule MafiaWeb.CoreComponents do
  @moduledoc """
  Shared form, feedback, and icon primitives for the Mafia UI.
  """

  use Phoenix.Component
  use Gettext, backend: MafiaWeb.Gettext
  use MafiaWeb, :verified_routes

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  attr :id, :string, default: nil
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :warning, :error]
  attr :rest, :global

  slot :inner_block

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={message = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class="fixed left-1/2 top-20 z-50 w-[min(24rem,calc(100%-2rem))] -translate-x-1/2"
      {@rest}
    >
      <div class={["alert", "alert-#{@kind}"]}>
        <.icon
          name={if @kind == :info, do: "hero-information-circle", else: "hero-exclamation-circle"}
          class="size-5 shrink-0"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{message}</p>
        </div>
        <button
          type="button"
          class="min-h-11 min-w-11 rounded-md p-2"
          aria-label={gettext("close")}
          phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil
  attr :variant, :string, default: "secondary"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns = assign(assigns, :class, assigns.class || ["btn", "btn-#{assigns.variant}"])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :checked, :boolean
  attr :prompt, :string, default: nil
  attr :options, :list, default: []
  attr :multiple, :boolean, default: false
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn -> Form.normalize_value("checkbox", assigns[:value]) end)

    ~H"""
    <div class="space-y-1.5">
      <label class="flex min-h-11 items-center gap-3">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={
            @class || "size-5 rounded border-[color:var(--border)] accent-[var(--color-primary)]"
          }
          {@rest}
        />
        <span :if={@label}>{@label}</span>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label>
        <span :if={@label} class="mb-1.5 block text-sm font-medium">{@label}</span>
        <select id={@id} name={@name} class={@class || "input"} multiple={@multiple} {@rest}>
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label>
        <span :if={@label} class="mb-1.5 block text-sm font-medium">{@label}</span>
        <textarea id={@id} name={@name} class={@class || "input"} {@rest}>{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label>
        <span :if={@label} class="mb-1.5 block text-sm font-medium">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={@class || "input"}
          {@rest}
        />
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <p class="flex items-center gap-2 text-sm text-[color:var(--color-danger-text)]">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["pb-6", @actions != [] && "flex items-center justify-between gap-6"]}>
      <div class="min-w-0">
        <h1 class="page-heading">{render_slot(@inner_block)}</h1>
        <p
          :if={@subtitle != []}
          class="mt-2 max-w-2xl text-sm leading-6 text-[color:var(--text-muted)]"
        >
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def show(js \\ %JS{}, selector), do: JS.show(js, to: selector)
  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  def translate_error({message, options}) do
    if count = options[:count] do
      Gettext.dngettext(MafiaWeb.Gettext, "errors", message, message, count, options)
    else
      Gettext.dgettext(MafiaWeb.Gettext, "errors", message, options)
    end
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {message, options}} <- errors, do: translate_error({message, options})
  end
end
