defmodule Sentry.Scrubber do
  @default_scrubbed_param_keys [
    "auth",
    "token",
    "secret",
    "password",
    "passwd",
    "pwd",
    "key",
    "jwt",
    "bearer",
    "sso",
    "saml",
    "csrf",
    "xsrf",
    "credentials",
    "session",
    "sid",
    "identity"
  ]

  @scrubbed_value "[Filtered]"

  @moduledoc """
  Provides scrubbing of sensitive data from values before they are sent to Sentry.

  This module is used internally to redact sensitive values like passwords, tokens, and credit card
  numbers before they appear in Sentry events and breadcrumbs.

  Scrubbing follows the [Sentry Data Collection
  spec](https://develop.sentry.dev/sdk/foundations/client/data-collection/):

    * The placeholder value is `"[Filtered]"`
    * Keys are matched case-insensitively as substrings — for example, the
      term `"auth"` matches `"Authorization"`, `"X-Auth-Token"`, and
      `"oauth_token"`
    * Key names are always preserved; only values are replaced

  ## Default sensitive denylist

  The following terms are scrubbed by default:

  #{Enum.map_join(@default_scrubbed_param_keys, "\n", &"  * `\"#{&1}\"`")}
  """

  @moduledoc since: "13.1.0"

  @doc """
  Returns the list of parameter keys scrubbed by default.
  """
  @spec default_scrubbed_param_keys() :: [String.t()]
  def default_scrubbed_param_keys, do: @default_scrubbed_param_keys

  @doc """
  Returns the placeholder value used to replace scrubbed data.
  """
  @spec scrubbed_value() :: String.t()
  def scrubbed_value, do: @scrubbed_value

  @doc """
  Scrubs a map of sensitive parameter values using the default denylist.

  See `scrub_map/2` to extend the denylist with additional terms.
  """
  @spec scrub_map(map()) :: map()
  def scrub_map(map) when is_map(map) do
    scrub_map(map, [])
  end

  @doc """
  Scrubs a map of sensitive parameter values using the default denylist plus
  any `extra_terms`.

  Keys are matched case-insensitively as substrings. Values are replaced with
  `"[Filtered]"` when their key matches a denylist term or when the value
  itself looks like a credit card number. The function recurses into nested
  maps and lists.
  """
  @spec scrub_map(map(), [String.t()]) :: map()
  def scrub_map(map, extra_terms) when is_map(map) and is_list(extra_terms) do
    do_scrub_map(map, denylist(extra_terms))
  end

  @doc """
  Returns `"[Filtered]"`, used as a fallback when a value (e.g. an unparseable
  cookie or body string) cannot be inspected for sensitive keys.
  """
  @spec scrub_string(String.t()) :: String.t()
  def scrub_string(value) when is_binary(value), do: @scrubbed_value

  defp do_scrub_map(map, denylist) do
    Map.new(map, fn {key, value} ->
      value =
        cond do
          sensitive_key?(key, denylist) -> @scrubbed_value
          is_binary(value) and value =~ credit_card_regex() -> @scrubbed_value
          is_struct(value) -> value |> Map.from_struct() |> do_scrub_map(denylist)
          is_map(value) -> do_scrub_map(value, denylist)
          is_list(value) -> do_scrub_list(value, denylist)
          true -> value
        end

      {key, value}
    end)
  end

  defp do_scrub_list(list, denylist) do
    Enum.map(list, fn value ->
      cond do
        is_struct(value) -> value |> Map.from_struct() |> do_scrub_map(denylist)
        is_map(value) -> do_scrub_map(value, denylist)
        is_list(value) -> do_scrub_list(value, denylist)
        true -> value
      end
    end)
  end

  defp denylist(extra_terms) do
    Enum.map(@default_scrubbed_param_keys ++ extra_terms, &String.downcase/1)
  end

  defp sensitive_key?(key, denylist) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(denylist, &String.contains?(downcased, &1))
  end

  defp sensitive_key?(key, denylist)
       when is_atom(key) and not is_nil(key) and not is_boolean(key) do
    sensitive_key?(Atom.to_string(key), denylist)
  end

  defp sensitive_key?(_key, _denylist), do: false

  defp credit_card_regex, do: ~r/^(?:\d[ -]*?){13,16}$/
end
