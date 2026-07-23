defmodule Mafia.GameRules do
  @moduledoc """
  Normalizes the reusable, data-only rules for a game.

  Rules describe permissions and mechanical policy; they never contain executable
  role scripts. Named variants are presets over this vocabulary, not code paths.
  """

  @statuses ~w(active dead removed spectator)
  @capabilities ~w(post_public vote act private_chat react targetable candidate)
  @phases ~w(day night)
  @methods ~w(majority plurality moderator)
  @visibilities ~w(live totals secret)
  @chat_policies ~w(disabled day night always)

  @common_roles [
    "Vanilla Townie",
    "Mafia Goon",
    "Doctor",
    "Investigator",
    "Shooter",
    "Roleblocker",
    "Tracker",
    "Watcher",
    "Bodyguard",
    "Jailkeeper",
    "Mason",
    "Neighbor",
    "Miller",
    "Godfather",
    "Serial Killer",
    "Survivor"
  ]

  @default_factions [
    %{"key" => "town", "name" => "Town", "chat_policy" => "disabled"},
    %{"key" => "mafia", "name" => "Mafia", "chat_policy" => "night"}
  ]

  @default_status_capabilities %{
    "active" => @capabilities,
    "dead" => [],
    "removed" => [],
    "spectator" => []
  }

  @default_ballot %{
    "key" => "elimination",
    "title" => "Elimination vote",
    "description" => "Choose who leaves the game at the end of the phase.",
    "phase" => "day",
    "method" => "majority",
    "visibility" => "live",
    "show_voters" => true,
    "allow_self" => true,
    "allow_no_result" => true,
    "no_result_label" => "No elimination",
    "eligible_statuses" => ["active"],
    "candidate_statuses" => ["active"],
    "effect" => "eliminate",
    "enabled" => true
  }

  @defaults %{
    "schema_version" => 3,
    "_legacy_unconfigured_alignments" => false,
    "description" => "",
    "house_rules" => "",
    "lobby_type" => "open",
    "min_players" => 3,
    "max_players" => 0,
    "day_length_seconds" => 86_400,
    "night_length_seconds" => 86_400,
    "auto_resolve_day" => true,
    "day_thread_open_at_night" => false,
    "reveal_on_death" => "full",
    "win_mode" => "classic",
    "factions" => @default_factions,
    "private_factions" => ["mafia"],
    "private_chat_policy" => "night",
    "night_conversation_cap" => 3,
    "private_chat_participant_cap" => 8,
    "private_chat_include_moderator" => true,
    "status_capabilities" => @default_status_capabilities,
    "ballots" => [@default_ballot]
  }

  def default, do: @defaults
  def statuses, do: @statuses
  def capabilities, do: @capabilities
  def common_roles, do: @common_roles
  def new_ballot, do: Map.put(@default_ballot, "key", "ballot")

  def normalize(nil), do: @defaults

  def normalize(ruleset) when is_map(ruleset) do
    source = stringify_keys(ruleset)
    merged = Map.merge(@defaults, source)
    win_mode = one_of(merged["win_mode"], ~w(classic moderator), "classic")

    legacy_unconfigured_alignments =
      if Map.has_key?(source, "_legacy_unconfigured_alignments"),
        do: boolean(source["_legacy_unconfigured_alignments"], false),
        else: legacy_rules?(source)

    factions =
      source
      |> normalize_factions(merged)
      |> ensure_classic_factions(win_mode)

    merged
    |> Map.put("schema_version", 3)
    |> Map.put("_legacy_unconfigured_alignments", legacy_unconfigured_alignments)
    |> Map.put("description", text(merged["description"], 10_000))
    |> Map.put("house_rules", text(merged["house_rules"], 20_000))
    |> Map.put("lobby_type", one_of(merged["lobby_type"], ~w(open invite), "open"))
    |> Map.put("min_players", integer(merged["min_players"], 3, 1, 100))
    |> Map.put("max_players", integer(merged["max_players"], 0, 0, 100))
    |> Map.put(
      "day_length_seconds",
      integer(merged["day_length_seconds"], 86_400, 60, 2_592_000)
    )
    |> Map.put(
      "night_length_seconds",
      integer(merged["night_length_seconds"], 86_400, 60, 2_592_000)
    )
    |> Map.put("auto_resolve_day", boolean(merged["auto_resolve_day"], true))
    |> Map.put(
      "day_thread_open_at_night",
      boolean(merged["day_thread_open_at_night"], false)
    )
    |> Map.put(
      "reveal_on_death",
      one_of(merged["reveal_on_death"], ~w(full alignment none), "full")
    )
    |> Map.put("win_mode", win_mode)
    |> Map.put("factions", factions)
    |> Map.put(
      "private_factions",
      for(faction <- factions, faction["chat_policy"] != "disabled", do: faction["key"])
    )
    |> Map.put(
      "private_chat_policy",
      one_of(merged["private_chat_policy"], ~w(disabled day night always), "night")
    )
    |> Map.put(
      "night_conversation_cap",
      integer(merged["night_conversation_cap"], 3, 0, 20)
    )
    |> Map.put(
      "private_chat_participant_cap",
      integer(merged["private_chat_participant_cap"], 8, 2, 100)
    )
    |> Map.put(
      "private_chat_include_moderator",
      boolean(merged["private_chat_include_moderator"], true)
    )
    |> Map.put(
      "status_capabilities",
      normalize_status_capabilities(merged["status_capabilities"])
    )
    |> Map.put("ballots", normalize_ballots(source, merged))
  end

  @doc "Converts the settings form payload into a canonical ruleset."
  def from_form(params, existing \\ %{}) when is_map(params) do
    params = stringify_keys(params)
    current = normalize(existing)

    rules = %{
      "description" => Map.get(params, "description", current["description"]),
      "house_rules" => Map.get(params, "house_rules", current["house_rules"]),
      "lobby_type" => Map.get(params, "lobby_type", current["lobby_type"]),
      "min_players" => Map.get(params, "min_players", current["min_players"]),
      "max_players" => Map.get(params, "max_players", current["max_players"]),
      "day_length_seconds" =>
        hours_to_seconds(Map.get(params, "day_length_hours"), current["day_length_seconds"]),
      "night_length_seconds" =>
        hours_to_seconds(Map.get(params, "night_length_hours"), current["night_length_seconds"]),
      "auto_resolve_day" => Map.get(params, "auto_resolve_day", false),
      "day_thread_open_at_night" => Map.get(params, "day_thread_open_at_night", false),
      "reveal_on_death" => Map.get(params, "reveal_on_death", current["reveal_on_death"]),
      "win_mode" => Map.get(params, "win_mode", current["win_mode"]),
      "factions" => form_factions(Map.get(params, "factions", current["factions"])),
      "private_chat_policy" =>
        Map.get(params, "private_chat_policy", current["private_chat_policy"]),
      "night_conversation_cap" =>
        Map.get(params, "night_conversation_cap", current["night_conversation_cap"]),
      "private_chat_participant_cap" =>
        Map.get(
          params,
          "private_chat_participant_cap",
          current["private_chat_participant_cap"]
        ),
      "private_chat_include_moderator" =>
        Map.get(params, "private_chat_include_moderator", false),
      "status_capabilities" =>
        form_status_capabilities(Map.get(params, "status_capabilities", %{})),
      "ballots" => form_ballots(Map.get(params, "ballots", %{}))
    }

    normalize(Map.merge(current, rules))
  end

  def ballots(ruleset), do: normalize(ruleset)["ballots"]

  def ballots(ruleset, phase) do
    phase = to_string(phase)
    Enum.filter(ballots(ruleset), &(&1["enabled"] and &1["phase"] == phase))
  end

  def ballot(ruleset, key) do
    Enum.find(ballots(ruleset), &(&1["key"] == to_string(key)))
  end

  def factions(ruleset), do: normalize(ruleset)["factions"]

  def canonical_faction_key(value), do: value |> text(100) |> String.downcase()

  def faction(ruleset, key) do
    key = canonical_faction_key(key)
    Enum.find(factions(ruleset), &(canonical_faction_key(&1["key"]) == key))
  end

  def faction_name(_ruleset, nil), do: nil

  def faction_name(ruleset, key) do
    case faction(ruleset, key) do
      nil -> text(key, 100)
      faction -> faction["name"]
    end
  end

  def faction_options(ruleset) do
    factions = factions(ruleset)
    name_counts = Enum.frequencies_by(factions, &String.downcase(&1["name"]))

    Enum.map(factions, fn faction ->
      label =
        if name_counts[String.downcase(faction["name"])] > 1,
          do: "#{faction["name"]} (#{faction["key"]})",
          else: faction["name"]

      {label, faction["key"]}
    end)
  end

  def capability?(ruleset, player, capability) do
    capability = to_string(capability)
    status = player_status(player)
    base = capability in get_in(normalize(ruleset), ["status_capabilities", status])
    overrides = stringify_keys(Map.get(player, :capability_overrides) || %{})

    case Map.get(overrides, capability) do
      value when is_boolean(value) -> value
      _ -> base
    end
  end

  def player_status(%{status: status}) when status in @statuses, do: status
  def player_status(%{is_alive: true}), do: "active"
  def player_status(_), do: "dead"

  def phase_duration(ruleset, phase) when phase in [:day, "day"],
    do: normalize(ruleset)["day_length_seconds"]

  def phase_duration(ruleset, _phase), do: normalize(ruleset)["night_length_seconds"]

  def auto_resolve_day?(ruleset), do: normalize(ruleset)["auto_resolve_day"]

  def day_thread_open?(_ruleset, phase) when phase in [:day, "day"], do: true

  def day_thread_open?(ruleset, _phase),
    do: normalize(ruleset)["day_thread_open_at_night"]

  def private_chat_allowed?(ruleset, phase) do
    case normalize(ruleset)["private_chat_policy"] do
      "always" -> true
      policy -> policy == to_string(phase)
    end
  end

  def faction_chat_allowed?(ruleset, faction_key, phase) do
    case faction(ruleset, faction_key) do
      %{"chat_policy" => "always"} -> true
      %{"chat_policy" => policy} -> policy == to_string(phase)
      nil -> false
    end
  end

  def summary(ruleset) do
    rules = normalize(ruleset)
    primary = List.first(rules["ballots"]) || @default_ballot
    dead = rules["status_capabilities"]["dead"]

    [
      duration_label(rules["day_length_seconds"]) <> " days",
      primary["method"],
      visibility_label(primary["visibility"]),
      if("post_public" in dead, do: "dead may post", else: "dead read only")
    ]
    |> Enum.join(" · ")
  end

  defp normalize_ballots(source, merged) do
    raw =
      cond do
        is_list(source["ballots"]) and source["ballots"] != [] ->
          source["ballots"]

        Map.has_key?(source, "vote_type") or Map.has_key?(source, "allow_no_lynch") ->
          [
            @default_ballot
            |> Map.put("method", one_of(source["vote_type"], @methods, "majority"))
            |> Map.put("allow_no_result", boolean(source["allow_no_lynch"], true))
          ]

        true ->
          merged["ballots"]
      end

    raw
    |> Enum.with_index()
    |> Enum.map(fn {ballot, index} -> normalize_ballot(ballot, index) end)
    |> Enum.uniq_by(& &1["key"])
    |> normalize_elimination_effects()
  end

  defp normalize_elimination_effects(ballots) do
    {normalized, _seen?} =
      Enum.map_reduce(ballots, false, fn ballot, seen? ->
        automatic? = ballot["effect"] == "eliminate" and ballot["phase"] == "day"

        cond do
          automatic? and not seen? -> {ballot, true}
          ballot["effect"] == "eliminate" -> {Map.put(ballot, "effect", "moderator"), seen?}
          true -> {ballot, seen?}
        end
      end)

    normalized
  end

  defp normalize_ballot(ballot, index) do
    ballot =
      if is_map(ballot),
        do: Map.merge(@default_ballot, stringify_keys(ballot)),
        else: @default_ballot

    fallback_key = if index == 0, do: "elimination", else: "ballot-#{index + 1}"

    ballot
    |> Map.put("key", slug(ballot["key"], fallback_key))
    |> Map.put("title", nonempty_text(ballot["title"], "Ballot #{index + 1}", 100))
    |> Map.put("description", text(ballot["description"], 500))
    |> Map.put("phase", one_of(ballot["phase"], @phases, "day"))
    |> Map.put("method", one_of(ballot["method"], @methods, "plurality"))
    |> Map.put("visibility", one_of(ballot["visibility"], @visibilities, "live"))
    |> Map.put("show_voters", boolean(ballot["show_voters"], false))
    |> Map.put("allow_self", boolean(ballot["allow_self"], true))
    |> Map.put("allow_no_result", boolean(ballot["allow_no_result"], false))
    |> Map.put(
      "no_result_label",
      nonempty_text(ballot["no_result_label"], "No result", 60)
    )
    |> Map.put("eligible_statuses", status_list(ballot["eligible_statuses"], ["active"]))
    |> Map.put("candidate_statuses", status_list(ballot["candidate_statuses"], ["active"]))
    |> Map.put("effect", one_of(ballot["effect"], ~w(eliminate moderator), "moderator"))
    |> Map.put("enabled", boolean(ballot["enabled"], true))
  end

  defp normalize_status_capabilities(raw) do
    raw = stringify_keys(raw)

    Map.new(@statuses, fn status ->
      fallback = @default_status_capabilities[status]
      values = Map.get(raw, status, fallback)

      {status,
       values
       |> List.wrap()
       |> Enum.map(&safe_string/1)
       |> Enum.filter(&(&1 in @capabilities))}
    end)
  end

  defp form_status_capabilities(raw) do
    raw = stringify_keys(raw)

    Map.new(@statuses, fn status ->
      selected = stringify_keys(Map.get(raw, status, %{}))
      {status, Enum.filter(@capabilities, &boolean(Map.get(selected, &1), false))}
    end)
  end

  defp form_ballots(raw) when is_list(raw), do: raw

  defp form_ballots(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {key, _value} -> integer(key, 0, 0, 1_000) end)
    |> Enum.map(fn {_key, value} ->
      value = stringify_keys(value || %{})

      value
      |> Map.put("show_voters", Map.get(value, "show_voters", false))
      |> Map.put("allow_self", Map.get(value, "allow_self", false))
      |> Map.put("allow_no_result", Map.get(value, "allow_no_result", false))
      |> Map.put("enabled", Map.get(value, "enabled", false))
    end)
  end

  defp form_ballots(_), do: []

  defp normalize_factions(source, merged) do
    raw =
      cond do
        is_list(source["factions"]) -> source["factions"]
        Map.has_key?(source, "factions") -> []
        legacy_rules?(source) -> legacy_factions(source, merged)
        true -> merged["factions"]
      end

    factions =
      raw
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {faction, index} -> normalize_faction(faction, index) end)
      |> Enum.uniq_by(& &1["key"])

    if factions == [], do: @default_factions, else: factions
  end

  defp normalize_faction(faction, index) do
    faction = if is_map(faction), do: stringify_keys(faction), else: %{}
    fallback_name = "Faction #{index + 1}"
    name = nonempty_text(faction["name"], fallback_name, 80)
    key = canonical_faction_key(faction["key"])

    %{
      "key" => if(key == "", do: slug(name, "faction-#{index + 1}"), else: key),
      "name" => name,
      "chat_policy" => one_of(faction["chat_policy"], @chat_policies, "disabled")
    }
  end

  defp ensure_classic_factions(factions, "classic") do
    required =
      Enum.map(@default_factions, fn default ->
        Enum.find(factions, &(&1["key"] == default["key"])) || default
      end)

    extras = Enum.reject(factions, &(&1["key"] in ["town", "mafia"]))
    required ++ extras
  end

  defp ensure_classic_factions(factions, _win_mode), do: factions

  defp legacy_factions(source, merged) do
    private = labels(Map.get(source, "private_factions", merged["private_factions"]))
    fallback_policy = one_of(merged["private_chat_policy"], @chat_policies, "night")
    policy = one_of(source["private_chat_policy"], @chat_policies, fallback_policy)
    defaults = Enum.map(@default_factions, &Map.put(&1, "chat_policy", "disabled"))

    (defaults ++
       Enum.map(private, &%{"key" => &1, "name" => titleize(&1), "chat_policy" => policy}))
    |> Enum.map(fn faction ->
      if faction["key"] in private, do: Map.put(faction, "chat_policy", policy), else: faction
    end)
    |> Enum.uniq_by(& &1["key"])
  end

  defp legacy_rules?(source) do
    Map.has_key?(source, "private_factions") or source["schema_version"] in [1, 2, "1", "2"]
  end

  defp form_factions(raw) when is_list(raw), do: raw

  defp form_factions(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {key, _value} -> integer(key, 0, 0, 1_000) end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp form_factions(_), do: []

  defp hours_to_seconds(nil, fallback), do: fallback

  defp hours_to_seconds(value, fallback) do
    case Float.parse(safe_string(value)) do
      {hours, ""} -> round(hours * 3600)
      _ -> fallback
    end
  end

  defp status_list(value, fallback) do
    list =
      value
      |> List.wrap()
      |> Enum.map(&safe_string/1)
      |> Enum.filter(&(&1 in @statuses))

    if list == [], do: fallback, else: Enum.uniq(list)
  end

  defp labels(value) when is_binary(value), do: value |> String.split(",") |> labels()

  defp labels(value) when is_list(value) do
    value
    |> Enum.map(&(&1 |> safe_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp labels(_value), do: []

  defp titleize(value) do
    value
    |> safe_string()
    |> String.replace(~r/[-_]+/u, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp slug(value, fallback) do
    slug =
      value
      |> safe_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    if slug == "", do: fallback, else: slug
  end

  defp text(nil, _limit), do: ""

  defp text(value, limit),
    do: value |> safe_string() |> String.trim() |> String.slice(0, limit)

  defp nonempty_text(value, fallback, limit) do
    case text(value, limit) do
      "" -> fallback
      result -> result
    end
  end

  defp integer(value, _fallback, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp integer(value, fallback, min, max) do
    case Integer.parse(safe_string(value)) do
      {parsed, ""} -> parsed |> Kernel.max(min) |> Kernel.min(max)
      _ -> fallback
    end
  end

  defp boolean(value, _fallback) when value in [true, "true", "1", 1, "on", "yes"], do: true
  defp boolean(value, _fallback) when value in [false, "false", "0", 0, "off", "no"], do: false
  defp boolean(_value, fallback), do: fallback

  defp one_of(value, allowed, fallback) do
    value = safe_string(value)
    if value in allowed, do: value, else: fallback
  end

  defp duration_label(seconds) when rem(seconds, 3600) == 0, do: "#{div(seconds, 3600)}h"
  defp duration_label(seconds), do: "#{div(seconds, 60)}m"

  defp visibility_label("live"), do: "live totals"
  defp visibility_label("totals"), do: "turnout only"
  defp visibility_label(_), do: "secret ballot"

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {safe_string(key), value} end)
  end

  defp stringify_keys(_value), do: %{}

  defp safe_string(nil), do: ""
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(value) when is_float(value), do: Float.to_string(value)
  defp safe_string(_value), do: ""
end
