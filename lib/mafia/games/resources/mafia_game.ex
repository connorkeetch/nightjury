defmodule Mafia.Games.Resources.MafiaGame do
  @moduledoc """
  A single game of Mafia.

  Status is the phase machine: `:setup` (lobby/role assignment) → `:day` →
  `:night` → … → `:finished`. `phase_number` increments on every phase change;
  `phase_ends_at` is the live deadline the `MafiaPhaseWorker` (and the hourly
  reconciler) act on.

  All per-game customization lives in `ruleset` (a JSONB map), read as plain map
  lookups — there is deliberately no rules engine. See
  `docs/planning/mafia-side-game.md`.
  """
  use Ash.Resource,
    domain: Mafia.GamesDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("mafia_games")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(true)
      constraints(max_length: 120)
    end

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:setup, :day, :night, :finished])
      default(:setup)
    end

    attribute :phase_number, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute :phase_ends_at, :utc_datetime do
      allow_nil?(true)
      description("Deadline for the current phase; nil during :setup/:finished")
    end

    # The reused chat conversations. The day thread is the public discussion
    # surface; mafia_chat_conversation_id preserves the classic faction-room shortcut.
    attribute(:day_thread_conversation_id, :uuid, allow_nil?: true)
    attribute(:mafia_chat_conversation_id, :uuid, allow_nil?: true)

    attribute :ruleset, :map do
      allow_nil?(false)
      default(%{})

      description(
        "Reusable game configuration: phases, ballots, statuses, capabilities, chats, and rules"
      )
    end

    attribute :rules_revision, :integer do
      allow_nil?(false)
      default(1)
      constraints(min: 1)
    end

    attribute :winner_faction, :string do
      allow_nil?(true)
      constraints(max_length: 100)
      description("Winning faction label; free-form when the moderator declares the result")
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :host, Mafia.Accounts.Resources.User do
      allow_nil?(false)
      attribute_writable?(true)
    end

    has_many :players, Mafia.Games.Resources.MafiaPlayer do
      destination_attribute(:mafia_game_id)
    end

    has_many :votes, Mafia.Games.Resources.MafiaVote do
      destination_attribute(:mafia_game_id)
    end

    has_many :night_actions, Mafia.Games.Resources.MafiaNightAction do
      destination_attribute(:mafia_game_id)
    end

    has_many :rule_revisions, Mafia.Games.Resources.MafiaRuleRevision do
      destination_attribute(:mafia_game_id)
    end

    has_many :notebooks, Mafia.Games.Resources.MafiaNotebook do
      destination_attribute(:mafia_game_id)
    end
  end

  policies do
    bypass actor_attribute_equals(:is_admin, true) do
      authorize_if(always())
    end

    # Anyone may read (browse the open-games list, spectate a finished game).
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(actor_present())
    end

    # Only the host runs the game. System/worker callers use `authorize?: false`.
    policy action_type([:update, :destroy]) do
      authorize_if(expr(host_id == ^actor(:id)))
      authorize_if(expr(is_nil(^actor(:id))))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      description("Create a Mafia game in :setup")
      accept([:title, :host_id, :ruleset, :status])
    end

    update :update do
      description("Generic update (phase transitions, conversation wiring, ruleset edits)")

      accept([
        :title,
        :status,
        :phase_number,
        :phase_ends_at,
        :day_thread_conversation_id,
        :mafia_chat_conversation_id,
        :ruleset,
        :rules_revision,
        :winner_faction
      ])
    end
  end
end
