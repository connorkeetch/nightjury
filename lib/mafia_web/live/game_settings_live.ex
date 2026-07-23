defmodule MafiaWeb.GameSettingsLive do
  use MafiaWeb, :live_view

  alias Mafia.{GameRules, Games}
  import MafiaWeb.GameComponents

  @max_additional_factions 20

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game_for_view(id) do
      {:ok, game} when game.host_id == socket.assigns.current_user.id ->
        rules = GameRules.normalize(game.ruleset)

        {:ok,
         socket
         |> assign(:page_title, "Settings · #{game.title || "Untitled game"}")
         |> assign(:game, game)
         |> assign(:saved_rules, rules)
         |> assign(:draft_rules, rules)
         |> assign(:change_summary, "")
         |> assign(:statuses, GameRules.statuses())
         |> assign(:capabilities, GameRules.capabilities())}

      {:ok, game} ->
        {:ok,
         socket
         |> put_flash(:error, "Only this game's moderator can change its settings.")
         |> push_navigate(to: ~p"/mafia/#{game.id}")}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "That game doesn't exist.")
         |> push_navigate(to: ~p"/mafia")}
    end
  end

  @impl true
  def handle_event("validate", %{"rules" => params} = form, socket) do
    {:noreply,
     socket
     |> assign(:draft_rules, GameRules.from_form(params, socket.assigns.saved_rules))
     |> assign(:change_summary, Map.get(form, "change_summary", ""))}
  end

  def handle_event("add_ballot", _params, socket) do
    ballot = blank_ballot()

    rules =
      Map.update!(socket.assigns.draft_rules, "ballots", fn ballots -> ballots ++ [ballot] end)

    {:noreply, assign(socket, :draft_rules, rules)}
  end

  def handle_event("remove_ballot", %{"index" => index}, socket) do
    ballots = GameRules.ballots(socket.assigns.draft_rules)

    rules =
      if length(ballots) > 1 do
        Map.put(
          socket.assigns.draft_rules,
          "ballots",
          List.delete_at(ballots, parse_index(index))
        )
      else
        socket.assigns.draft_rules
      end

    {:noreply, assign(socket, :draft_rules, rules)}
  end

  def handle_event("add_faction", _params, socket) do
    rules = socket.assigns.draft_rules

    rules =
      if additional_faction_count(rules) < @max_additional_factions do
        Map.update!(rules, "factions", &(&1 ++ [blank_faction()]))
      else
        rules
      end

    {:noreply, assign(socket, :draft_rules, rules)}
  end

  def handle_event("remove_faction", %{"index" => index}, socket) do
    factions = GameRules.factions(socket.assigns.draft_rules)

    rules =
      if length(factions) > 1 do
        Map.put(
          socket.assigns.draft_rules,
          "factions",
          List.delete_at(factions, parse_index(index))
        )
      else
        socket.assigns.draft_rules
      end

    {:noreply, assign(socket, :draft_rules, rules)}
  end

  def handle_event("save_rules", %{"rules" => params} = form, socket) do
    rules = GameRules.from_form(params, socket.assigns.saved_rules)
    summary = change_summary(Map.get(form, "change_summary"), rules)
    game = socket.assigns.game

    case Games.update_rules(game, socket.assigns.current_user.id, rules, summary) do
      {:ok, _updated} -> reload_after_save(socket)
      {:error, reason} -> {:noreply, put_flash(socket, :error, humanize(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-6">
      <header class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="eyebrow">Moderator's desk</p>
          <h1 class="page-heading mt-2">Game settings</h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 text-[color:var(--text-muted)]">
            Configure reusable rules instead of choosing a named mode. Changes remain available
            after play begins and are recorded in the public rulebook.
          </p>
        </div>
        <.game_nav game={@game} current={:settings} show_settings={true} />
      </header>

      <section class="phase-banner" aria-label="Settings summary">
        <span class="phase-icon" aria-hidden="true">
          <.icon name="hero-adjustments-horizontal" class="size-5" />
        </span>
        <div class="min-w-0">
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--text-muted)]">
            Current draft
          </p>
          <p class="mt-1 text-sm font-semibold text-[color:var(--text)]">
            {GameRules.summary(@draft_rules)}
          </p>
        </div>
        <span class={[
          "status-chip",
          @draft_rules != @saved_rules && "status-chip-wax"
        ]}>
          {if @draft_rules == @saved_rules, do: "Saved", else: "Unsaved changes"}
        </span>
      </section>

      <form
        id="game-settings-form"
        phx-change="validate"
        phx-submit="save_rules"
        class="space-y-6"
      >
        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Game and roster
          </summary>
          <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
            Public context and the broad limits for who may take a seat.
          </p>
          <div class="mt-5 grid gap-4 sm:grid-cols-2">
            <div class="sm:col-span-2">
              <.input
                type="textarea"
                name="rules[description]"
                label="Game description"
                value={@draft_rules["description"]}
                rows="4"
                maxlength="10000"
                phx-debounce="300"
                placeholder="Describe the setup, theme, and what players should expect."
              />
            </div>
            <.input
              type="select"
              name="rules[lobby_type]"
              label="Joining"
              value={@draft_rules["lobby_type"]}
              options={[{"Open lobby", "open"}, {"Moderator invitation", "invite"}]}
            />
            <div class="grid grid-cols-2 gap-3">
              <.input
                type="number"
                name="rules[min_players]"
                label="Minimum players"
                value={@draft_rules["min_players"]}
                min="1"
                max="100"
              />
              <.input
                type="number"
                name="rules[max_players]"
                label="Maximum"
                value={@draft_rules["max_players"]}
                min="0"
                max="100"
              />
            </div>
          </div>
          <p class="mt-2 text-xs text-[color:var(--text-muted)]">
            Set maximum to 0 when the moderator does not want a cap.
          </p>
        </details>

        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Phase timing and automation
          </summary>
          <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
            Durations apply when a new phase opens. Changing them does not silently move the
            current deadline.
          </p>
          <div class="mt-5 grid gap-4 sm:grid-cols-2">
            <.input
              type="number"
              name="rules[day_length_hours]"
              label="Day length in hours"
              value={hours(@draft_rules["day_length_seconds"])}
              min="0.25"
              max="720"
              step="0.25"
            />
            <.input
              type="number"
              name="rules[night_length_hours]"
              label="Night length in hours"
              value={hours(@draft_rules["night_length_seconds"])}
              min="0.25"
              max="720"
              step="0.25"
            />
          </div>
          <div class="mt-4 grid gap-3 sm:grid-cols-2">
            <div class="surface-card p-3">
              <.input
                type="checkbox"
                name="rules[auto_resolve_day]"
                label="Resolve the day automatically at its deadline"
                checked={@draft_rules["auto_resolve_day"]}
              />
              <p class="pl-8 text-xs leading-5 text-[color:var(--text-muted)]">
                Turn this off when the moderator should decide when and how the result is applied.
              </p>
            </div>
            <div class="surface-card p-3">
              <.input
                type="checkbox"
                name="rules[day_thread_open_at_night]"
                label="Keep the public thread open at night"
                checked={@draft_rules["day_thread_open_at_night"]}
              />
              <p class="pl-8 text-xs leading-5 text-[color:var(--text-muted)]">
                Posting permissions still follow each player's status.
              </p>
            </div>
          </div>
        </details>

        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Ballots and voting
          </summary>
          <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
            A ballot can represent an elimination, election, nomination, or any moderator-run
            decision. Availability comes from its phase and player statuses. One day ballot may
            automate elimination; every other result stays in the moderator's hands.
          </p>

          <div class="mt-5 space-y-4">
            <section
              :for={{ballot, index} <- Enum.with_index(GameRules.ballots(@draft_rules))}
              class="surface-card p-4 sm:p-5"
            >
              <input type="hidden" name={"rules[ballots][#{index}][key]"} value={ballot["key"]} />
              <div class="flex flex-col gap-3 border-b border-[color:var(--border)] pb-4 sm:flex-row sm:items-center sm:justify-between">
                <h3 class="font-semibold text-[color:var(--text)]">
                  Ballot {index + 1}: {ballot["title"]}
                </h3>
                <button
                  :if={length(GameRules.ballots(@draft_rules)) > 1}
                  type="button"
                  phx-click="remove_ballot"
                  phx-value-index={index}
                  class="btn btn-quiet self-start text-xs hover:text-[color:var(--color-danger-text)] sm:self-auto"
                >
                  <.icon name="hero-trash" class="size-4" /> Remove ballot
                </button>
              </div>

              <div class="mt-4 grid gap-4 sm:grid-cols-2">
                <.input
                  name={"rules[ballots][#{index}][title]"}
                  label="Ballot title"
                  value={ballot["title"]}
                  maxlength="100"
                />
                <.input
                  type="select"
                  name={"rules[ballots][#{index}][phase]"}
                  label="Open during"
                  value={ballot["phase"]}
                  options={[{"Day", "day"}, {"Night", "night"}]}
                />
                <div class="sm:col-span-2">
                  <.input
                    type="textarea"
                    name={"rules[ballots][#{index}][description]"}
                    label="Player instructions"
                    value={ballot["description"]}
                    rows="2"
                    maxlength="500"
                    phx-debounce="300"
                  />
                </div>
                <.input
                  type="select"
                  name={"rules[ballots][#{index}][method]"}
                  label="Result method"
                  value={ballot["method"]}
                  options={[
                    {"Majority with hammer", "majority"},
                    {"Plurality at deadline", "plurality"},
                    {"Moderator resolves", "moderator"}
                  ]}
                />
                <.input
                  type="select"
                  name={"rules[ballots][#{index}][visibility]"}
                  label="What players see"
                  value={ballot["visibility"]}
                  options={[
                    {"Live totals", "live"},
                    {"Turnout only", "totals"},
                    {"Secret until resolved", "secret"}
                  ]}
                />
                <.input
                  type="select"
                  name={"rules[ballots][#{index}][effect]"}
                  label="Result effect"
                  value={ballot["effect"]}
                  options={ballot_effect_options(@draft_rules, index, ballot)}
                />
                <.input
                  name={"rules[ballots][#{index}][no_result_label]"}
                  label="No-result option label"
                  value={ballot["no_result_label"]}
                  maxlength="60"
                />
              </div>

              <div class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                <.input
                  type="checkbox"
                  name={"rules[ballots][#{index}][enabled]"}
                  label="Ballot enabled"
                  checked={ballot["enabled"]}
                />
                <.input
                  type="checkbox"
                  name={"rules[ballots][#{index}][show_voters]"}
                  label="Show voter names"
                  checked={ballot["show_voters"]}
                />
                <.input
                  type="checkbox"
                  name={"rules[ballots][#{index}][allow_self]"}
                  label="Allow voting for yourself"
                  checked={ballot["allow_self"]}
                />
                <.input
                  type="checkbox"
                  name={"rules[ballots][#{index}][allow_no_result]"}
                  label="Offer the no-result choice"
                  checked={ballot["allow_no_result"]}
                />
              </div>

              <div class="mt-4 grid gap-4 border-t border-[color:var(--border)] pt-4 sm:grid-cols-2">
                <fieldset>
                  <legend class="text-sm font-semibold text-[color:var(--text)]">
                    Who may vote
                  </legend>
                  <div class="mt-2 grid grid-cols-2 gap-1">
                    <label
                      :for={status <- @statuses}
                      class="flex min-h-11 items-center gap-2 rounded-md px-2 text-sm"
                    >
                      <input
                        type="checkbox"
                        name={"rules[ballots][#{index}][eligible_statuses][]"}
                        value={status}
                        checked={status in ballot["eligible_statuses"]}
                        class="size-5 rounded accent-[var(--color-primary)]"
                      />
                      {status_label(status)}
                    </label>
                  </div>
                </fieldset>
                <fieldset>
                  <legend class="text-sm font-semibold text-[color:var(--text)]">
                    Who may be a candidate
                  </legend>
                  <div class="mt-2 grid grid-cols-2 gap-1">
                    <label
                      :for={status <- @statuses}
                      class="flex min-h-11 items-center gap-2 rounded-md px-2 text-sm"
                    >
                      <input
                        type="checkbox"
                        name={"rules[ballots][#{index}][candidate_statuses][]"}
                        value={status}
                        checked={status in ballot["candidate_statuses"]}
                        class="size-5 rounded accent-[var(--color-primary)]"
                      />
                      {status_label(status)}
                    </label>
                  </div>
                </fieldset>
              </div>
            </section>
          </div>

          <button type="button" phx-click="add_ballot" class="btn btn-secondary mt-4">
            <.icon name="hero-plus" class="size-4" /> Add another ballot
          </button>
        </details>

        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Player status permissions
          </summary>
          <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
            Status is the reusable gate. A player can be dead and still speak or vote when this
            game permits it.
          </p>
          <div class="mt-5 grid gap-4 md:grid-cols-2">
            <fieldset :for={status <- @statuses} class="surface-card p-4">
              <legend class="section-heading px-1">{status_label(status)}</legend>
              <p class="mb-3 mt-1 text-xs leading-5 text-[color:var(--text-muted)]">
                {status_description(status)}
              </p>
              <div class="grid gap-1 sm:grid-cols-2">
                <.input
                  :for={capability <- @capabilities}
                  type="checkbox"
                  name={"rules[status_capabilities][#{status}][#{capability}]"}
                  label={capability_label(capability)}
                  checked={capability in @draft_rules["status_capabilities"][status]}
                />
              </div>
            </fieldset>
          </div>
        </details>

        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Factions and private conversations
          </summary>
          <p class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]">
            Define the factions first. They become the choices when assigning players, and each
            faction can have its own private-room schedule.
          </p>

          <div class="mt-5 space-y-3">
            <fieldset
              :for={{faction, index} <- Enum.with_index(@draft_rules["factions"])}
              class="surface-card grid gap-3 p-4 sm:grid-cols-[1fr_13rem_auto] sm:items-end"
            >
              <legend class="sr-only">Faction {index + 1}</legend>
              <input
                type="hidden"
                name={"rules[factions][#{index}][key]"}
                value={faction["key"]}
              />
              <.input
                name={"rules[factions][#{index}][name]"}
                label="Faction name"
                value={faction["name"]}
                maxlength="80"
                required
              />
              <.input
                type="select"
                name={"rules[factions][#{index}][chat_policy]"}
                label="Private faction room"
                value={faction["chat_policy"]}
                options={chat_policy_options()}
              />
              <button
                type="button"
                phx-click="remove_faction"
                phx-value-index={index}
                disabled={
                  length(@draft_rules["factions"]) == 1 or
                    (@draft_rules["win_mode"] == "classic" and faction["key"] in ["town", "mafia"])
                }
                class="btn btn-quiet min-h-11 text-xs"
                aria-label={"Remove #{faction["name"]} faction"}
              >
                <.icon name="hero-trash" class="size-4" /> Remove
              </button>
            </fieldset>

            <button
              type="button"
              phx-click="add_faction"
              disabled={additional_faction_count(@draft_rules) >= @max_additional_factions}
              class="btn btn-secondary text-sm"
            >
              <.icon name="hero-plus" class="size-4" /> Add faction
            </button>

            <p class="text-xs leading-5 text-[color:var(--text-muted)]">
              Classic victory always keeps Town and Mafia available. Use moderator-declared victory
              for custom faction structures. Up to 20 additional factions may be configured.
            </p>
          </div>

          <div class="mt-6 grid gap-4 border-t border-[color:var(--border)] pt-5 sm:grid-cols-2">
            <.input
              type="select"
              name="rules[private_chat_policy]"
              label="Player-created private chats"
              value={@draft_rules["private_chat_policy"]}
              options={chat_policy_options()}
            />
            <.input
              type="number"
              name="rules[night_conversation_cap]"
              label="Player-created chats per player"
              value={@draft_rules["night_conversation_cap"]}
              min="0"
              max="20"
            />
            <.input
              type="number"
              name="rules[private_chat_participant_cap]"
              label="Players per private chat"
              value={@draft_rules["private_chat_participant_cap"]}
              min="2"
              max="100"
            />
            <div class="surface-card p-3 sm:col-span-2">
              <.input
                type="checkbox"
                name="rules[private_chat_include_moderator]"
                label="Automatically include the moderator in private chats"
                checked={@draft_rules["private_chat_include_moderator"]}
              />
            </div>
          </div>
        </details>

        <details class="panel" open>
          <summary class="cursor-pointer text-lg font-semibold text-[color:var(--text)]">
            Information, victory, and house rules
          </summary>
          <div class="mt-5 grid gap-4 sm:grid-cols-2">
            <.input
              type="select"
              name="rules[reveal_on_death]"
              label="Reveal when a player dies"
              value={@draft_rules["reveal_on_death"]}
              options={[
                {"Full role and faction", "full"},
                {"Faction only", "alignment"},
                {"Nothing", "none"}
              ]}
            />
            <.input
              type="select"
              name="rules[win_mode]"
              label="Victory handling"
              value={@draft_rules["win_mode"]}
              options={[
                {"Classic town-versus-mafia parity", "classic"},
                {"Moderator declares the result", "moderator"}
              ]}
            />
            <div class="sm:col-span-2">
              <.input
                type="textarea"
                name="rules[house_rules]"
                label="House rules"
                value={@draft_rules["house_rules"]}
                rows="10"
                maxlength="20000"
                phx-debounce="300"
                placeholder="Outside communication, post editing, special mechanics, resolution order…"
              />
            </div>
          </div>
        </details>

        <footer class="panel moderator-panel flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0 flex-1">
            <p class="font-semibold text-[color:var(--text)]">
              {if @draft_rules == @saved_rules,
                do: "Everything is saved",
                else: "Review and publish these changes"}
            </p>
            <p class="mt-1 text-xs leading-5 text-[color:var(--text-muted)]">
              {GameRules.summary(@draft_rules)}
            </p>
            <div class="mt-3 max-w-xl">
              <.input
                name="change_summary"
                label="Public change summary"
                value={@change_summary}
                maxlength="240"
                phx-debounce="300"
                placeholder="For example, eliminated players may now post at night"
              />
              <p class="mt-1 text-xs leading-5 text-[color:var(--text-muted)]">
                Especially useful after setup. If left blank, the at-a-glance summary is recorded.
              </p>
            </div>
          </div>
          <button
            type="submit"
            class="btn btn-primary shrink-0"
            disabled={@draft_rules == @saved_rules}
            phx-disable-with="Saving rules…"
          >
            <.icon name="hero-check" class="size-4" /> Save rules
          </button>
        </footer>
      </form>
    </div>
    """
  end

  defp reload_after_save(socket) do
    case Games.get_game_for_view(socket.assigns.game.id) do
      {:ok, game} ->
        rules = GameRules.normalize(game.ruleset)

        {:noreply,
         socket
         |> put_flash(:info, "Rules updated.")
         |> assign(:game, game)
         |> assign(:saved_rules, rules)
         |> assign(:draft_rules, rules)
         |> assign(:change_summary, "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize(reason))}
    end
  end

  defp blank_ballot do
    %{
      "key" => "ballot-#{System.unique_integer([:positive])}",
      "title" => "New ballot",
      "description" => "",
      "phase" => "day",
      "method" => "plurality",
      "visibility" => "live",
      "show_voters" => true,
      "allow_self" => true,
      "allow_no_result" => false,
      "no_result_label" => "No result",
      "eligible_statuses" => ["active"],
      "candidate_statuses" => ["active"],
      "effect" => "moderator",
      "enabled" => true
    }
  end

  defp blank_faction do
    %{
      "key" => "faction-#{Ecto.UUID.generate()}",
      "name" => "New faction",
      "chat_policy" => "disabled"
    }
  end

  defp additional_faction_count(rules) do
    rules
    |> GameRules.factions()
    |> Enum.count(&(&1["key"] not in ["town", "mafia"]))
  end

  defp parse_index(index) do
    case Integer.parse(to_string(index)) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp hours(seconds) when is_integer(seconds), do: seconds / 3600
  defp hours(_seconds), do: 24

  defp change_summary(summary, rules) do
    case summary |> to_string() |> String.trim() do
      "" -> GameRules.summary(rules)
      text -> String.slice(text, 0, 240)
    end
  end

  defp chat_policy_options do
    [
      {"No private room", "disabled"},
      {"Day only", "day"},
      {"Night only", "night"},
      {"Always open (24/7)", "always"}
    ]
  end

  defp ballot_effect_options(rules, index, ballot) do
    another_elimination? =
      rules
      |> GameRules.ballots()
      |> List.delete_at(index)
      |> Enum.any?(&(&1["effect"] == "eliminate"))

    if ballot["phase"] == "day" and not another_elimination?,
      do: [{"Eliminate the winner", "eliminate"}, {"Moderator handles it", "moderator"}],
      else: [{"Moderator handles it", "moderator"}]
  end

  defp status_label("active"), do: "Active"
  defp status_label("dead"), do: "Eliminated"
  defp status_label("removed"), do: "Removed"
  defp status_label("spectator"), do: "Spectator"
  defp status_label(status), do: String.capitalize(status)

  defp status_description("active"), do: "Players currently participating in the game."
  defp status_description("dead"), do: "Eliminated players who remain part of the game record."
  defp status_description("removed"), do: "Players removed by the moderator."
  defp status_description("spectator"), do: "Observers who have not taken a player seat."
  defp status_description(_status), do: "A reusable participation state."

  defp capability_label("post_public"), do: "Post publicly"
  defp capability_label("vote"), do: "Cast ballots"
  defp capability_label("act"), do: "Submit actions"
  defp capability_label("private_chat"), do: "Use private chats"
  defp capability_label("react"), do: "React to posts"
  defp capability_label("targetable"), do: "May be targeted"
  defp capability_label("candidate"), do: "May be a candidate"
  defp capability_label(capability), do: String.replace(capability, "_", " ")

  defp humanize(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp humanize(reason), do: inspect(reason)
end
