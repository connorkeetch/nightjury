defmodule Mafia.GameRulesTest do
  use ExUnit.Case, async: true

  alias Mafia.GameRules

  test "normalizes nested status capabilities without losing defaults" do
    rules =
      GameRules.normalize(%{
        "status_capabilities" => %{"dead" => ["post_public", "vote", "unknown"]}
      })

    assert rules["status_capabilities"]["dead"] == ["post_public", "vote"]
    assert "act" in rules["status_capabilities"]["active"]
  end

  test "a per-player capability override wins over the status policy" do
    rules = GameRules.normalize(%{})
    player = %{status: "dead", is_alive: false, capability_overrides: %{"vote" => true}}

    assert GameRules.capability?(rules, player, "vote")
    refute GameRules.capability?(rules, player, "act")
  end

  test "form ballots are normalized into reusable phase policies" do
    rules =
      GameRules.from_form(
        %{
          "ballots" => %{
            "0" => %{
              "key" => "Night President",
              "title" => "Elect a president",
              "phase" => "night",
              "method" => "plurality",
              "visibility" => "totals",
              "eligible_statuses" => ["active", "dead"],
              "candidate_statuses" => ["active"],
              "enabled" => "true"
            }
          }
        },
        GameRules.default()
      )

    assert [ballot] = GameRules.ballots(rules, :night)
    assert ballot["key"] == "night-president"
    assert ballot["eligible_statuses"] == ["active", "dead"]
  end

  test "legacy voting settings are carried into the elimination ballot" do
    rules = GameRules.normalize(%{"vote_type" => "plurality", "allow_no_lynch" => false})

    assert [ballot] = GameRules.ballots(rules)
    assert ballot["method"] == "plurality"
    refute ballot["allow_no_result"]
  end

  test "malformed ballot entries fall back instead of crashing rule reads" do
    rules = GameRules.normalize(%{"ballots" => ["not a ballot", nil]})

    assert Enum.all?(GameRules.ballots(rules), &is_map/1)
    assert Enum.all?(GameRules.ballots(rules), &is_binary(&1["key"]))
  end

  test "malformed nested rule values normalize without string conversion crashes" do
    rules =
      GameRules.normalize(%{
        "description" => %{"unexpected" => "map"},
        "private_factions" => %{"unexpected" => "map"},
        "status_capabilities" => "not a map",
        "day_length_seconds" => [86_400]
      })

    assert rules["description"] == ""
    assert rules["private_factions"] == []
    assert rules["status_capabilities"]["active"] == GameRules.capabilities()
    assert rules["day_length_seconds"] == 86_400
  end

  test "factions normalize into stable assignment options with independent room schedules" do
    rules =
      GameRules.from_form(
        %{
          "factions" => %{
            "0" => %{"key" => "town", "name" => "The Village", "chat_policy" => "disabled"},
            "1" => %{"key" => "mafia", "name" => "The Family", "chat_policy" => "always"},
            "2" => %{"key" => "mafia", "name" => "Duplicate", "chat_policy" => "day"}
          }
        },
        GameRules.default()
      )

    assert GameRules.faction_options(rules) == [
             {"The Village", "town"},
             {"The Family", "mafia"}
           ]

    assert rules["private_factions"] == ["mafia"]
    assert GameRules.faction_name(rules, "mafia") == "The Family"
    assert GameRules.faction_chat_allowed?(rules, "mafia", :day)
    assert GameRules.faction_chat_allowed?(rules, "mafia", :night)
    refute GameRules.faction_chat_allowed?(rules, "town", :night)
  end

  test "legacy faction room settings upgrade idempotently" do
    legacy = %{
      "schema_version" => 2,
      "private_factions" => ["mafia", "pale horse"],
      "private_chat_policy" => "night"
    }

    rules = GameRules.normalize(legacy)

    assert rules["schema_version"] == 3
    assert GameRules.faction_name(rules, "Pale Horse") == "Pale Horse"
    assert GameRules.faction_chat_allowed?(rules, "pale horse", :night)
    refute GameRules.faction_chat_allowed?(rules, "pale horse", :day)
    assert GameRules.normalize(rules) == rules
  end

  test "partial version two rules retain the legacy Mafia room policy" do
    rules =
      GameRules.normalize(%{
        "schema_version" => 2,
        "private_chat_policy" => "disabled"
      })

    refute GameRules.faction_chat_allowed?(rules, "mafia", :day)
    refute GameRules.faction_chat_allowed?(rules, "mafia", :night)
  end

  test "legacy faction identities do not collapse punctuation variants" do
    rules =
      GameRules.normalize(%{
        "schema_version" => 2,
        "private_factions" => ["red team", "red-team"],
        "private_chat_policy" => "always"
      })

    assert "red team" in rules["private_factions"]
    assert "red-team" in rules["private_factions"]
    assert GameRules.faction(rules, "red team")["key"] == "red team"
    assert GameRules.faction(rules, "red-team")["key"] == "red-team"
  end

  test "legacy normalization does not silently discard large faction lists" do
    private_factions = Enum.map(1..21, &"legacy faction #{&1}")

    rules =
      GameRules.normalize(%{
        "schema_version" => 2,
        "private_factions" => private_factions,
        "private_chat_policy" => "night"
      })

    assert GameRules.faction(rules, "legacy faction 21")["name"] == "Legacy Faction 21"
  end

  test "common role suggestions stay editable rather than defining mechanics" do
    roles = GameRules.common_roles()

    assert "Doctor" in roles
    assert "Investigator" in roles
    assert "Shooter" in roles
  end

  test "classic victory restores its canonical Town and Mafia factions" do
    rules =
      GameRules.normalize(%{
        "schema_version" => 3,
        "win_mode" => "classic",
        "factions" => [
          %{"key" => "cult", "name" => "Cult", "chat_policy" => "always"}
        ]
      })

    assert GameRules.faction_name(rules, "town") == "Town"
    assert GameRules.faction_name(rules, "mafia") == "Mafia"
  end

  test "classic factions preserve additional definitions and edited canonical definitions" do
    customs =
      for index <- 1..20 do
        %{
          "key" => "custom-#{index}",
          "name" => "Custom #{index}",
          "chat_policy" => "disabled"
        }
      end

    rules =
      GameRules.normalize(%{
        "schema_version" => 3,
        "win_mode" => "classic",
        "factions" =>
          customs ++
            [
              %{"key" => "town", "name" => "Village", "chat_policy" => "disabled"},
              %{"key" => "mafia", "name" => "Family", "chat_policy" => "always"}
            ]
      })

    assert length(GameRules.factions(rules)) == 22
    assert GameRules.faction_name(rules, "town") == "Village"
    assert GameRules.faction_name(rules, "mafia") == "Family"
    assert GameRules.faction_name(rules, "custom-20") == "Custom 20"
  end

  test "duplicate display names are disambiguated in assignment options" do
    rules =
      GameRules.normalize(%{
        "win_mode" => "moderator",
        "factions" => [
          %{"key" => "town", "name" => "Town"},
          %{"key" => "faction-custom", "name" => "town"}
        ]
      })

    assert GameRules.faction_options(rules) == [
             {"Town (town)", "town"},
             {"town (faction-custom)", "faction-custom"}
           ]
  end

  test "only one day ballot can claim the automatic elimination effect" do
    duplicate =
      GameRules.new_ballot()
      |> Map.merge(%{"key" => "second", "phase" => "day", "effect" => "eliminate"})

    night =
      GameRules.new_ballot()
      |> Map.merge(%{"key" => "night", "phase" => "night", "effect" => "eliminate"})

    rules = GameRules.normalize(%{"ballots" => [GameRules.new_ballot(), duplicate, night]})

    assert Enum.count(GameRules.ballots(rules), &(&1["effect"] == "eliminate")) == 1
    assert Enum.all?(Enum.drop(GameRules.ballots(rules), 1), &(&1["effect"] == "moderator"))
  end
end
