defmodule XqliteEcto3.URLError do
  @moduledoc """
  Raised or returned when `XqliteEcto3.parse_url/1` cannot parse a
  database URL.

  ## Fields

    * `:url` — the offending URL string, verbatim.
    * `:reason` — one of:
      * `:malformed` — `URI.new/1` refused the input.
      * `:missing_scheme` — no scheme component (e.g. raw path without
        `sqlite://`).
      * `{:unsupported_scheme, scheme}` — scheme is not one of
        `"sqlite"`, `"sqlite3"`, `"file"`.
      * `{:unsupported_host, host}` — URL carries a host component.
        SQLite has no hosts; xqlite_ecto3 rejects these to avoid
        silently ignoring part of the user's config.
      * `:missing_database` — URL has no path / database component.
      * `{:unknown_option, key}` — a query-string parameter not in the
        accepted set.
      * `{:invalid_option, key, inner_reason}` — query-string parameter
        value failed coercion. `inner_reason` is one of
        `{:not_in_enum, [atom()]}`, `:not_a_boolean`, `:not_an_integer`,
        `:negative_value`.
  """

  defexception [:url, :reason]

  @type reason ::
          :malformed
          | :missing_scheme
          | {:unsupported_scheme, String.t()}
          | {:unsupported_host, String.t()}
          | :missing_database
          | {:unknown_option, String.t()}
          | {:invalid_option, String.t(), term()}

  @type t :: %__MODULE__{url: String.t(), reason: reason()}

  @impl true
  def message(%__MODULE__{url: url, reason: reason}) do
    "could not parse xqlite_ecto3 URL #{inspect(url)}: #{format_reason(reason)}"
  end

  defp format_reason(:malformed), do: "malformed URI"
  defp format_reason(:missing_scheme), do: "no URL scheme (expected `sqlite://…`)"
  defp format_reason(:missing_database), do: "no database path in URL"

  defp format_reason({:unsupported_scheme, s}),
    do: "unsupported scheme #{inspect(s)} (expected one of \"sqlite\", \"sqlite3\", \"file\")"

  defp format_reason({:unsupported_host, h}),
    do:
      "URL carries a host component #{inspect(h)}; SQLite is embedded and xqlite_ecto3 URLs must not declare a host"

  defp format_reason({:unknown_option, key}), do: "unknown query parameter #{inspect(key)}"

  defp format_reason({:invalid_option, key, inner}),
    do: "invalid value for #{inspect(key)}: #{inspect(inner)}"
end
