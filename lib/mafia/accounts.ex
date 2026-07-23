defmodule Mafia.Accounts do
  @moduledoc "Standalone accounts backed by the copied ConquestK password hashes."

  alias Mafia.Accounts.Resources.User
  alias Mafia.Repo

  require Ash.Query

  @username ~r/^[a-zA-Z0-9_-]{3,20}$/
  @email ~r/^[^\s]+@[^\s]+$/

  def get_user(id) when is_binary(id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, %User{deleted_at: nil} = user} -> if(blocked?(id), do: nil, else: user)
      _ -> nil
    end
  end

  def get_user(_), do: nil

  def get_user_by_username(username) when is_binary(username) do
    username = String.downcase(String.trim(username))

    User
    |> Ash.Query.filter(string_downcase(username) == ^username and is_nil(deleted_at))
    |> Ash.read_one(authorize?: false)
    |> unwrap_active_user()
  end

  def get_user_by_username(_), do: nil

  def get_user_by_username_or_email(identifier) when is_binary(identifier) do
    identifier = String.downcase(String.trim(identifier))

    User
    |> Ash.Query.filter(
      (string_downcase(username) == ^identifier or string_downcase(email) == ^identifier) and
        is_nil(deleted_at)
    )
    |> Ash.read_one(authorize?: false)
    |> unwrap_active_user()
  end

  def get_user_by_username_or_email(_), do: nil

  def authenticate(identifier, password) when is_binary(identifier) and is_binary(password) do
    case get_user_by_username_or_email(identifier) do
      %User{hashed_password: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash), do: {:ok, user}, else: {:error, :invalid_login}

      _ ->
        Bcrypt.no_user_verify()
        {:error, :invalid_login}
    end
  end

  def authenticate(_, _) do
    Bcrypt.no_user_verify()
    {:error, :invalid_login}
  end

  def register(attrs) when is_map(attrs) do
    username = attrs |> value(:username) |> to_string() |> String.trim()
    email = attrs |> value(:email) |> to_string() |> String.trim() |> String.downcase()
    password = attrs |> value(:password) |> to_string()
    confirmation = attrs |> value(:password_confirmation) |> to_string()

    with :ok <- Mafia.WriteGate.ensure_enabled(),
         :ok <- validate_registration(username, email, password, confirmation),
         {:ok, user} <-
           User
           |> Ash.Changeset.for_create(:create, %{
             username: username,
             email: email,
             hashed_password: Bcrypt.hash_pwd_salt(password),
             email_verified: true
           })
           |> Ash.create(authorize?: false) do
      {:ok, user}
    else
      {:error, %Ash.Error.Invalid{} = error} -> {:error, friendly_ash_error(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_profile(%User{} = user, attrs) when is_map(attrs) do
    profile = %{
      bio: blank_to_nil(value(attrs, :bio)),
      tagline: blank_to_nil(value(attrs, :tagline)),
      avatar_url: blank_to_nil(value(attrs, :avatar_url)),
      signature: blank_to_nil(value(attrs, :signature))
    }

    with :ok <- Mafia.WriteGate.ensure_enabled() do
      user
      |> Ash.Changeset.for_update(:update_profile, profile)
      |> Ash.update(authorize?: false)
    end
  end

  defp validate_registration(username, email, password, confirmation) do
    cond do
      not Regex.match?(@username, username) ->
        {:error, "Username must be 3–20 letters, numbers, dashes, or underscores."}

      not Regex.match?(@email, email) ->
        {:error, "Enter a valid email address."}

      password != confirmation ->
        {:error, "Passwords do not match."}

      String.length(password) < 12 ->
        {:error, "Password must be at least 12 characters."}

      String.length(password) > 72 ->
        {:error, "Password must be at most 72 characters."}

      true ->
        :ok
    end
  end

  defp blocked?(user_id) do
    sql = """
    SELECT status, expires_at
    FROM user_account_status
    WHERE user_id = $1::uuid
    ORDER BY status_changed_at DESC
    LIMIT 1
    """

    case Repo.query(sql, [Ecto.UUID.dump!(user_id)]) do
      {:ok, %{rows: [["banned", _]]}} ->
        true

      {:ok, %{rows: [["suspended", nil]]}} ->
        true

      {:ok, %{rows: [["suspended", %NaiveDateTime{} = expires_at]]}} ->
        NaiveDateTime.after?(expires_at, NaiveDateTime.utc_now())

      _ ->
        false
    end
  end

  defp unwrap_active_user({:ok, %User{} = user}), do: if(blocked?(user.id), do: nil, else: user)
  defp unwrap_active_user(_), do: nil

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || ""

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp friendly_ash_error(error) do
    if String.contains?(Exception.message(error), "email") do
      "That email is already registered."
    else
      "That username is already taken."
    end
  end
end
