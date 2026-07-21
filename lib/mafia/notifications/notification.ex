defmodule Mafia.Notifications.Notification do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "notifications" do
    field :type, :string
    field :title, :string
    field :body, :string
    field :read_at, :utc_datetime_usec
    field :related_user_id, Ecto.UUID
    field :metadata, :map, default: %{}
    field :user_id, Ecto.UUID
    field :created_at, :utc_datetime_usec
    field :game_id, Ecto.UUID
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:type, :title, :body, :read_at, :related_user_id, :metadata, :user_id])
    |> validate_required([:type, :title, :user_id])
  end
end
