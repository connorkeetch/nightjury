defmodule Mafia.Notifications do
  @moduledoc "Small in-app notification inbox for Mafia phases and chat mentions."

  import Ecto.Query

  alias Mafia.Notifications.Notification
  alias Mafia.Repo

  def notify_mafia_phase(user_ids, game_id, title, body) do
    with :ok <- Mafia.WriteGate.ensure_enabled() do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows =
        user_ids
        |> Enum.uniq()
        |> Enum.map(fn user_id ->
          %{
            id: Ecto.UUID.generate(),
            type: "mafia_phase",
            title: title,
            body: body,
            user_id: user_id,
            metadata: %{"mafia_game_id" => game_id},
            created_at: now
          }
        end)

      case Repo.insert_all(Notification, rows) do
        {count, _} ->
          Enum.each(user_ids, &broadcast/1)
          {:ok, count}
      end
    end
  end

  def list_for_user(user_id) do
    Repo.all(
      from n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.created_at],
        limit: 100
    )
  end

  def unread_count(user_id) do
    Repo.aggregate(
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at)),
      :count
    )
  end

  def mark_read(id, user_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled() do
      case Repo.one(from n in Notification, where: n.id == ^id and n.user_id == ^user_id) do
        nil ->
          {:error, :not_found}

        notification ->
          case notification
               |> Notification.changeset(%{read_at: DateTime.utc_now()})
               |> Repo.update() do
            {:ok, updated} ->
              broadcast(user_id)
              {:ok, updated}

            {:error, _changeset} = error ->
              error
          end
      end
    end
  end

  def mark_all_read(user_id) do
    with :ok <- Mafia.WriteGate.ensure_enabled() do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      result =
        Repo.update_all(
          from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at)),
          set: [read_at: now]
        )

      broadcast(user_id)
      result
    end
  end

  def subscribe(user_id),
    do: Phoenix.PubSub.subscribe(Mafia.PubSub, "notifications:#{user_id}")

  @doc "Publishes a refresh without creating another notification row."
  def refresh_users(user_ids) do
    user_ids |> Enum.uniq() |> Enum.each(&broadcast/1)
    :ok
  end

  defp broadcast(user_id),
    do: Phoenix.PubSub.broadcast(Mafia.PubSub, "notifications:#{user_id}", :notifications_changed)
end
