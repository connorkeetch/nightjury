defmodule Mafia.Accounts.Resources.User do
  @moduledoc "Account identity and the small public profile used by Mafia."

  use Ash.Resource,
    domain: Mafia.AccountsDomain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("users")
    repo(Mafia.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :username, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 3, max_length: 20, match: ~r/^[a-zA-Z0-9_-]+$/)
    end

    attribute :email, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :hashed_password, :string do
      allow_nil?(true)
      sensitive?(true)
    end

    attribute :is_admin, :boolean do
      allow_nil?(false)
      default(false)
    end

    attribute :email_verified, :boolean do
      allow_nil?(false)
      default(false)
    end

    attribute :bio, :string do
      public?(true)
      allow_nil?(true)
      constraints(max_length: 500)
    end

    attribute :tagline, :string do
      public?(true)
      allow_nil?(true)
      constraints(max_length: 255)
    end

    attribute :avatar_url, :string do
      public?(true)
      allow_nil?(true)
      constraints(max_length: 500, match: ~r/^https?:\/\//)
    end

    attribute :signature, :string do
      public?(true)
      allow_nil?(true)
      constraints(max_length: 500)
    end

    attribute :deleted_at, :utc_datetime_usec do
      allow_nil?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_username, [:username])
    identity(:unique_email, [:email])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:username, :email, :hashed_password, :email_verified])
    end

    update :update_profile do
      primary?(true)
      accept([:bio, :tagline, :avatar_url, :signature])
      require_atomic?(false)
    end
  end
end
