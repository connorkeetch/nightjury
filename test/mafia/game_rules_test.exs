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
