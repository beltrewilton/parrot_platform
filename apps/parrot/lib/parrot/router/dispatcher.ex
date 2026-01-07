defmodule Parrot.Router.Dispatcher do
  @moduledoc """
  Handles dispatching SIP messages to the appropriate handler based on router configuration.
  """

  import Bitwise

  alias ParrotSip.Message

  @doc """
  Dispatches a SIP message to the appropriate handler.

  Returns `{:ok, handler, opts}` for a matching route, or
  `{:no_match, reason}` if no route matches.
  """
  def dispatch(router, %Message{method: :invite} = message) do
    routes = router.__routes__()
    to_user = extract_to_user(message)

    case find_matching_route(routes, message, to_user) do
      {:ok, route} ->
        {:ok, route.handler,
         pipelines: route.pipelines, assigns: %{matched_pattern: route.pattern}}

      :no_match ->
        {:no_match, :no_matching_route}
    end
  end

  def dispatch(_router, %Message{}) do
    {:no_match, :method_not_routed}
  end

  # Find the first route that matches all conditions
  defp find_matching_route(routes, message, to_user) do
    Enum.find_value(routes, :no_match, fn route ->
      if matches_route?(route, message, to_user) do
        {:ok, route}
      else
        nil
      end
    end)
  end

  # Check if a route matches the message
  defp matches_route?(route, message, to_user) do
    matches_scope?(route.scope, message) and matches_pattern?(route.pattern, to_user)
  end

  # Check all scope conditions
  defp matches_scope?(scope, _message) when map_size(scope) == 0, do: true

  defp matches_scope?(scope, message) do
    Enum.all?(scope, fn {key, value} ->
      matches_scope_condition?(key, value, message)
    end)
  end

  defp matches_scope_condition?(:from_ip, value, message) do
    case message.source do
      %{ip: source_ip} when source_ip != nil ->
        matches_ip?(value, source_ip)

      _ ->
        false
    end
  end

  defp matches_scope_condition?(:header, {header_name, header_value}, message) do
    # Headers are stored in other_headers, normalize header name to lowercase
    headers = message.other_headers || %{}
    normalized_name = String.downcase(header_name)

    case Map.get(headers, normalized_name) do
      ^header_value -> true
      _ -> false
    end
  end

  defp matches_scope_condition?(:from, pattern, message) do
    from_uri = extract_from_uri(message)
    matches_uri_pattern?(pattern, from_uri)
  end

  defp matches_scope_condition?(:to, pattern, message) do
    to_uri = extract_to_uri(message)
    matches_uri_pattern?(pattern, to_uri)
  end

  defp matches_scope_condition?(_key, _value, _message), do: true

  # IP matching with CIDR support
  defp matches_ip?(cidr_or_ip, source_ip) when is_binary(cidr_or_ip) do
    cond do
      String.contains?(cidr_or_ip, "/") ->
        matches_cidr?(cidr_or_ip, source_ip)

      true ->
        # Exact IP match (implicit /32)
        parse_ip(cidr_or_ip) == source_ip
    end
  end

  defp matches_ip?(ip_list, source_ip) when is_list(ip_list) do
    Enum.any?(ip_list, fn ip -> matches_ip?(ip, source_ip) end)
  end

  defp matches_ip?(_, _), do: false

  # Parse CIDR and check if IP is in range
  defp matches_cidr?(cidr, source_ip) do
    case String.split(cidr, "/") do
      [network_str, prefix_len_str] ->
        case {parse_ip(network_str), Integer.parse(prefix_len_str)} do
          {network_ip, {prefix_len, ""}} when is_tuple(network_ip) ->
            ip_in_cidr?(source_ip, network_ip, prefix_len)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp ip_in_cidr?(ip, network, prefix_len)
       when tuple_size(ip) == 4 and tuple_size(network) == 4 do
    # Convert tuples to integers for bitwise operations
    ip_int = ip_to_int(ip)
    network_int = ip_to_int(network)
    mask = bsl(0xFFFFFFFF, 32 - prefix_len) &&& 0xFFFFFFFF

    (ip_int &&& mask) == (network_int &&& mask)
  end

  defp ip_in_cidr?(_, _, _), do: false

  defp ip_to_int({a, b, c, d}) do
    bsl(a, 24) ||| bsl(b, 16) ||| bsl(c, 8) ||| d
  end

  # URI pattern matching
  # Pattern is in format "user@domain" and uri is full SIP URI "sip:user@domain"
  defp matches_uri_pattern?(pattern, uri) when is_binary(pattern) and is_binary(uri) do
    # Extract user@domain from the SIP URI
    user_at_domain = extract_user_at_domain(uri)

    # Pattern can have * as wildcard for user or domain part
    # e.g., "*@partner.com" or "admin@*"
    pattern_regex = pattern_to_regex(pattern)

    case Regex.compile(pattern_regex) do
      {:ok, regex} -> Regex.match?(regex, user_at_domain)
      _ -> false
    end
  end

  defp matches_uri_pattern?(_, _), do: false

  # Extract "user@domain" from "sip:user@domain" or "sip:user@domain:5060;params"
  defp extract_user_at_domain(uri) when is_binary(uri) do
    case Regex.run(~r/^sips?:([^@]+@[^;:>]+)/, uri) do
      [_, user_at_domain] -> user_at_domain
      _ -> uri
    end
  end

  defp pattern_to_regex(pattern) do
    # Escape regex special chars except * which becomes .*
    pattern
    |> String.replace(~r/([.+^${}()|[\]\\])/, "\\\\\\1")
    |> String.replace("*", ".*")
    |> then(&"^#{&1}$")
  end

  # Pattern matching for dial strings
  defp matches_pattern?("*", _to_user), do: true

  defp matches_pattern?(pattern, to_user) when is_binary(pattern) and is_binary(to_user) do
    cond do
      # Pattern with ~ (any length wildcard)
      String.contains?(pattern, "~") ->
        matches_tilde_pattern?(pattern, to_user)

      # Pattern with x (single digit wildcard)
      String.contains?(pattern, "x") ->
        matches_x_pattern?(pattern, to_user)

      # Exact match
      true ->
        pattern == to_user
    end
  end

  defp matches_pattern?(_, _), do: false

  # Match pattern with ~ (any length suffix)
  defp matches_tilde_pattern?(pattern, to_user) do
    case String.split(pattern, "~", parts: 2) do
      [prefix, ""] ->
        String.starts_with?(to_user, prefix)

      _ ->
        false
    end
  end

  # Match pattern with x (single digit placeholders)
  defp matches_x_pattern?(pattern, to_user) do
    # Pattern like "1xxx" means first char is "1", followed by exactly 3 digits
    if String.length(pattern) != String.length(to_user) do
      false
    else
      pattern_chars = String.graphemes(pattern)
      user_chars = String.graphemes(to_user)

      Enum.zip(pattern_chars, user_chars)
      |> Enum.all?(fn {p, u} ->
        case p do
          "x" -> u =~ ~r/^\d$/
          char -> char == u
        end
      end)
    end
  end

  # Extract the user part from the To header
  defp extract_to_user(%Message{to: to}) when not is_nil(to) do
    case to do
      %{uri: %{user: user}} when is_binary(user) -> user
      %{uri: uri} when is_binary(uri) -> extract_user_from_uri_string(uri)
      _ -> ""
    end
  end

  defp extract_to_user(_), do: ""

  # Extract full URI string from From header
  defp extract_from_uri(%Message{from: from}) when not is_nil(from) do
    case from do
      %{uri: %ParrotSip.Uri{} = uri} ->
        ParrotSip.Uri.to_string(uri)

      %{uri: uri} when is_binary(uri) ->
        uri

      _ ->
        ""
    end
  end

  defp extract_from_uri(_), do: ""

  # Extract full URI string from To header
  defp extract_to_uri(%Message{to: to}) when not is_nil(to) do
    case to do
      %{uri: %ParrotSip.Uri{} = uri} ->
        ParrotSip.Uri.to_string(uri)

      %{uri: uri} when is_binary(uri) ->
        uri

      _ ->
        ""
    end
  end

  defp extract_to_uri(_), do: ""

  # Extract user from a SIP URI string like "sip:user@domain"
  defp extract_user_from_uri_string(uri) when is_binary(uri) do
    case Regex.run(~r/^sips?:([^@]+)@/, uri) do
      [_, user] -> user
      _ -> ""
    end
  end

  defp extract_user_from_uri_string(_), do: ""
end
