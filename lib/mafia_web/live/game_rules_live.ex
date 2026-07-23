defmodule MafiaWeb.GameRulesLive do
  use MafiaWeb, :live_view

  alias Mafia.{GameRules, Games}
  import MafiaWeb.GameComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Games.subscribe(id)

    {:ok, socket |> assign(:game_id, id) |> load_game()}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, load_game(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-6">
      <header class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="eyebrow">Public record</p>
          <h1 class="page-heading mt-2">{@game.title || "Untitled game"} rules</h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 text-[color:var(--text-muted)]">
            The current rules take precedence. Moderator changes made during play remain visible
            in the revision record below.
          </p>
        </div>
        <.game_nav
          game={@game}
          current={:rules}
          show_notes={@is_player}
          show_settings={@is_host}
        />
      </header>

      <section class="phase-banner" aria-label="Rule summary">
        <span class="phase-icon" aria-hidden="true">
          <.icon name="hero-document-text" class="size-5" />
        </span>
        <div class="min-w-0">
          <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-[color:var(--text-muted)]">
            At a glance
          </p>
          <p class="mt-1 text-sm font-semibold text-[color:var(--text)]">
            {GameRules.summary(@rules)}
          </p>
        </div>
        <span class="status-chip">Revision {@revision_number}</span>
      </section>

      <section :if={@rules["description"] != ""} class="panel">
        <p class="eyebrow">Moderator's brief</p>
        <p class="mt-4 whitespace-pre-wrap leading-7 text-[color:var(--text-soft)]">
          {@rules["description"]}
        </p>
      </section>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="panel">
          <div class="flex items-start gap-3">
            <span class="phase-icon shrink-0" aria-hidden="true">
              <.icon name="hero-clock" class="size-5" />
            </span>
            <div>
              <p class="eyebrow">Cadence</p>
              <h2 class="section-heading mt-2">Phases and resolution</h2>
            </div>
          </div>
          <dl class="mt-5 divide-y divide-[color:var(--border)] text-sm">
            <.rule_row term="Day length" value={duration(@rules["day_length_seconds"])} />
            <.rule_row term="Night length" value={duration(@rules["night_length_seconds"])} />
            <.rule_row
              term="Day deadline"
              value={
                if @rules["auto_resolve_day"],
                  do: "Resolves automatically",
                  else: "Moderator resolves"
              }
            />
            <.rule_row
              term="Public thread at night"
              value={if @rules["day_thread_open_at_night"], do: "Open", else: "Closed"}
            />
          </dl>
        </section>

        <section class="panel">
          <div class="flex items-start gap-3">
            <span class="phase-icon shrink-0" aria-hidden="true">
              <.icon name="hero-eye" class="size-5" />
            </span>
            <div>
              <p class="eyebrow">Information</p>
              <h2 class="section-heading mt-2">Reveals and victory</h2>
            </div>
          </div>
          <dl class="mt-5 divide-y divide-[color:var(--border)] text-sm">
            <.rule_row term="On death" value={reveal_label(@rules["reveal_on_death"])} />
            <.rule_row term="Victory" value={win_label(@rules["win_mode"])} />
            <.rule_row term="Joining" value={lobby_label(@rules["lobby_type"])} />
            <.rule_row term="Player range" value={player_range(@rules)} />
          </dl>
        </section>
      </div>

      <section class="panel">
        <div class="flex items-start gap-3">
          <span class="phase-icon shrink-0" aria-hidden="true">
            <.icon name="hero-scale" class="size-5" />
          </span>
          <div>
            <p class="eyebrow">Decision docket</p>
            <h2 class="section-heading mt-2">Ballots</h2>
          </div>
        </div>

        <div class="mt-5 grid gap-4 md:grid-cols-2">
          <article :for={ballot <- GameRules.ballots(@rules)} class="surface-card p-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h3 class="font-semibold text-[color:var(--text)]">{ballot["title"]}</h3>
              <span class={[
                "status-chip",
                ballot["enabled"] && "status-chip-wax"
              ]}>
                {if ballot["enabled"], do: ballot["phase"], else: "disabled"}
              </span>
            </div>
            <p
              :if={ballot["description"] != ""}
              class="mt-2 text-sm leading-6 text-[color:var(--text-muted)]"
            >
              {ballot["description"]}
            </p>
            <dl class="mt-4 divide-y divide-[color:var(--border)] text-sm">
              <.rule_row term="Method" value={method_label(ballot["method"])} />
              <.rule_row term="Result" value={effect_label(ballot["effect"])} />
              <.rule_row term="Visibility" value={visibility_label(ballot)} />
              <.rule_row term="May vote" value={status_list(ballot["eligible_statuses"])} />
              <.rule_row term="Candidates" value={status_list(ballot["candidate_statuses"])} />
              <.rule_row
                term="No-result choice"
                value={
                  if ballot["allow_no_result"], do: ballot["no_result_label"], else: "Not offered"
                }
              />
              <.rule_row term="Self vote" value={yes_no(ballot["allow_self"])} />
            </dl>
          </article>
        </div>
      </section>

      <section class="panel">
        <div class="flex items-start gap-3">
          <span class="phase-icon shrink-0" aria-hidden="true">
            <.icon name="hero-user-group" class="size-5" />
          </span>
          <div>
            <p class="eyebrow">Participation</p>
            <h2 class="section-heading mt-2">What each player status can do</h2>
          </div>
        </div>
        <div class="mt-5 grid gap-3 sm:grid-cols-2">
          <article :for={status <- GameRules.statuses()} class="surface-card p-4">
            <h3 class="font-semibold text-[color:var(--text)]">{status_label(status)}</h3>
            <div class="mt-3 flex flex-wrap gap-2">
              <span
                :for={capability <- @rules["status_capabilities"][status]}
                class="status-chip"
              >
                {capability_label(capability)}
              </span>
              <span
                :if={@rules["status_capabilities"][status] == []}
                class="text-sm text-[color:var(--text-muted)]"
              >
                No game actions
              </span>
            </div>
          </article>
        </div>
      </section>

      <section class="panel">
        <div class="flex items-start gap-3">
          <span class="phase-icon shrink-0" aria-hidden="true">
            <.icon name="hero-chat-bubble-left-right" class="size-5" />
          </span>
          <div>
            <p class="eyebrow">Communications</p>
            <h2 class="section-heading mt-2">Private conversation policy</h2>
          </div>
        </div>
        <dl class="mt-5 divide-y divide-[color:var(--border)] text-sm">
          <.rule_row
            term="Player-created chats"
            value={chat_policy_label(@rules["private_chat_policy"])}
          />
          <.rule_row term="Factions" value={faction_list(@rules["factions"])} />
          <.rule_row term="Chats per player" value={to_string(@rules["night_conversation_cap"])} />
          <.rule_row
            term="Players per chat"
            value={to_string(@rules["private_chat_participant_cap"])}
          />
          <.rule_row
            term="Moderator included"
            value={yes_no(@rules["private_chat_include_moderator"])}
          />
        </dl>
      </section>

      <section class="panel">
        <p class="eyebrow">House record</p>
        <h2 class="section-heading mt-2">House rules</h2>
        <p
          :if={@rules["house_rules"] != ""}
          class="mt-4 whitespace-pre-wrap leading-7 text-[color:var(--text-soft)]"
        >
          {@rules["house_rules"]}
        </p>
        <p :if={@rules["house_rules"] == ""} class="mt-3 text-sm text-[color:var(--text-muted)]">
          The moderator has not added any extra house rules.
        </p>
      </section>

      <section class="panel" aria-labelledby="rule-history-heading">
        <p class="eyebrow">Audit trail</p>
        <h2 id="rule-history-heading" class="section-heading mt-2">Rule changes</h2>
        <p class="mt-1 text-sm text-[color:var(--text-muted)]">
          Newest revision first. Secret role information is never included here.
        </p>

        <div :if={@revisions == []} class="empty-state mt-5 min-h-36">
          <div>
            <span class="empty-state-icon" aria-hidden="true">
              <.icon name="hero-document-check" class="size-6" />
            </span>
            <p class="font-semibold text-[color:var(--text)]">No mid-game changes</p>
            <p class="mt-1 text-sm">This is the original rule set.</p>
          </div>
        </div>

        <ol :if={@revisions != []} class="mt-5 divide-y divide-[color:var(--border)]">
          <li :for={revision <- @revisions} class="flex gap-3 py-4 first:pt-0 last:pb-0">
            <span class="phase-icon size-9 shrink-0" aria-hidden="true">
              <.icon name="hero-pencil" class="size-4" />
            </span>
            <div class="min-w-0">
              <p class="font-semibold text-[color:var(--text)]">{revision_summary(revision)}</p>
              <div class="mt-2 flex flex-wrap gap-2">
                <span class="status-chip">{revision_phase(revision)}</span>
                <span class="status-chip">{revision_status(revision)}</span>
              </div>
              <p class="mt-1 text-xs text-[color:var(--text-muted)]">
                {revision_actor(revision)}{revision_time(revision)}
              </p>
            </div>
          </li>
        </ol>
      </section>
    </div>
    """
  end

  attr :term, :string, required: true
  attr :value, :string, required: true

  defp rule_row(assigns) do
    ~H"""
    <div class="flex min-h-12 items-center justify-between gap-4 py-2">
      <dt class="text-[color:var(--text-muted)]">{@term}</dt>
      <dd class="text-right font-semibold text-[color:var(--text)]">{@value}</dd>
    </div>
    """
  end

  defp load_game(socket) do
    case Games.get_game_for_view(socket.assigns.game_id) do
      {:ok, game} ->
        user = socket.assigns[:current_user]

        socket
        |> assign(:page_title, "Rules · #{game.title || "Untitled game"}")
        |> assign(:game, game)
        |> assign(:rules, GameRules.normalize(game.ruleset))
        |> assign(:revisions, normalize_revisions(Games.list_rule_revisions(game)))
        |> assign(:revision_number, Map.get(game, :rules_revision, 1))
        |> assign(:is_host, !!(user && game.host_id == user.id))
        |> assign(:is_player, !!(user && Enum.any?(game.players, &(&1.user_id == user.id))))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "That game doesn't exist.")
        |> push_navigate(to: ~p"/mafia")
    end
  end

  defp normalize_revisions({:ok, revisions}) when is_list(revisions), do: revisions
  defp normalize_revisions(revisions) when is_list(revisions), do: revisions
  defp normalize_revisions(_), do: []

  defp revision_summary(revision) do
    Map.get(revision, :summary) || Map.get(revision, "summary") || "Rules updated"
  end

  defp revision_actor(revision) do
    actor = Map.get(revision, :changed_by) || Map.get(revision, "changed_by")
    name = actor && (Map.get(actor, :username) || Map.get(actor, "username"))
    if name, do: "#{name} · ", else: "Moderator · "
  end

  defp revision_phase(revision) do
    case Map.get(revision, :phase_number) || Map.get(revision, "phase_number") do
      phase when is_integer(phase) and phase > 0 -> "Phase #{phase}"
      _ -> "Setup"
    end
  end

  defp revision_status(revision) do
    revision
    |> then(
      &(Map.get(&1, :game_status) || Map.get(&1, "game_status") || Map.get(&1, :status) ||
          Map.get(&1, "status") || "setup")
    )
    |> to_string()
    |> String.capitalize()
  end

  defp revision_time(revision) do
    case Map.get(revision, :created_at) || Map.get(revision, "created_at") do
      %DateTime{} = time -> Calendar.strftime(time, "%b %-d, %Y at %H:%M UTC")
      %NaiveDateTime{} = time -> Calendar.strftime(time, "%b %-d, %Y at %H:%M UTC")
      _ -> "Time unavailable"
    end
  end

  defp duration(seconds) when is_integer(seconds) and rem(seconds, 3600) == 0,
    do: "#{div(seconds, 3600)} hours"

  defp duration(seconds) when is_integer(seconds), do: "#{div(seconds, 60)} minutes"
  defp duration(_seconds), do: "Not set"

  defp reveal_label("full"), do: "Full role and faction"
  defp reveal_label("alignment"), do: "Faction only"
  defp reveal_label(_), do: "No reveal"

  defp win_label("classic"), do: "Classic town-versus-mafia parity"
  defp win_label(_), do: "Moderator declares the result"

  defp lobby_label("invite"), do: "Moderator invitation"
  defp lobby_label(_), do: "Open lobby"

  defp player_range(%{"min_players" => minimum, "max_players" => 0}),
    do: "#{minimum}+ players"

  defp player_range(%{"min_players" => minimum, "max_players" => maximum}),
    do: "#{minimum}–#{maximum} players"

  defp method_label("majority"), do: "Majority with hammer"
  defp method_label("plurality"), do: "Plurality at deadline"
  defp method_label(_), do: "Moderator resolves"

  defp effect_label("eliminate"), do: "Winner is eliminated automatically"
  defp effect_label(_), do: "Moderator applies the result"

  defp visibility_label(%{"visibility" => "live", "show_voters" => true}),
    do: "Live totals and voter names"

  defp visibility_label(%{"visibility" => "live"}), do: "Live totals"
  defp visibility_label(%{"visibility" => "totals"}), do: "Turnout only"
  defp visibility_label(_), do: "Secret until resolved"

  defp status_list(statuses), do: statuses |> Enum.map(&status_label/1) |> Enum.join(", ")

  defp status_label("active"), do: "Active"
  defp status_label("dead"), do: "Eliminated"
  defp status_label("removed"), do: "Removed"
  defp status_label("spectator"), do: "Spectator"
  defp status_label(status), do: String.capitalize(status)

  defp capability_label("post_public"), do: "Post publicly"
  defp capability_label("vote"), do: "Vote"
  defp capability_label("act"), do: "Submit actions"
  defp capability_label("private_chat"), do: "Private chat"
  defp capability_label("react"), do: "React"
  defp capability_label("targetable"), do: "Targetable"
  defp capability_label("candidate"), do: "Candidate"
  defp capability_label(capability), do: String.replace(capability, "_", " ")

  defp chat_policy_label("disabled"), do: "Disabled"
  defp chat_policy_label("day"), do: "Day phases only"
  defp chat_policy_label("night"), do: "Night phases only"
  defp chat_policy_label(_), do: "Always available"

  defp faction_list([]), do: "No factions configured"

  defp faction_list(factions) do
    Enum.map_join(factions, " · ", fn faction ->
      "#{faction["name"]}: #{chat_policy_label(faction["chat_policy"])}"
    end)
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(_), do: "No"
end
