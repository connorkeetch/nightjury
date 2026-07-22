defmodule MafiaWeb.Router do
  use MafiaWeb, :router

  import MafiaWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MafiaWeb.Layouts, :root}
    plug :fetch_current_user
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline'; " <>
          "style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; " <>
          "font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';"
    }
  end

  pipeline :authenticated do
    plug :require_authenticated_user
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/", MafiaWeb do
    pipe_through :browser

    live_session :public,
      on_mount: [
        {MafiaWeb.UserAuth, :mount_current_user},
        {MafiaWeb.UserAuth, :write_gate}
      ],
      layout: {MafiaWeb.Layouts, :app} do
      live "/", MafiaLive, :index
      live "/mafia", MafiaLive, :index
      live "/mafia/:id", MafiaRoomLive, :show
      live "/mafia/:id/rules", GameRulesLive, :show
      live "/forums", ForumLive, :index
      live "/forums/:id", ForumLive, :show
      live "/users/log-in", AuthLive, :login
      live "/users/register", AuthLive, :register
      live "/users/:username", ProfileLive, :show
    end

    post "/users/log-in", UserSessionController, :create
    post "/users/register", UserSessionController, :register
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", MafiaWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [
        {MafiaWeb.UserAuth, :require_authenticated_user},
        {MafiaWeb.UserAuth, :write_gate}
      ],
      layout: {MafiaWeb.Layouts, :app} do
      live "/profile", ProfileLive, :edit
      live "/mafia/:id/settings", GameSettingsLive, :edit
      live "/mafia/:id/notes", GameNotesLive, :edit
      live "/messages", MessagesLive, :index
      live "/messages/:conversation_id", ChatLive, :show
      live "/notifications", NotificationsLive, :index
    end
  end

  scope "/", MafiaWeb do
    pipe_through :health
    get "/health", HealthController, :show
  end
end
