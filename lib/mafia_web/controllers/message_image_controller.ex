defmodule MafiaWeb.MessageImageController do
  use MafiaWeb, :controller

  alias Mafia.Chat

  def show(conn, %{"message_id" => message_id}) do
    case Chat.get_message_image(message_id, conn.assigns.current_user.id) do
      {:ok, image} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type(image.content_type, nil)
        |> send_resp(200, image.data)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
