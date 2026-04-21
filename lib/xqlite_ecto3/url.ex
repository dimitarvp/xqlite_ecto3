defmodule XqliteEcto3.URL do
  @moduledoc """
  Parse database URLs into the keyword-list form `XqliteEcto3`'s
  `start_link` accepts.

  The two public entry points are re-exported from the top-level
  `XqliteEcto3` module as `parse_url/1` (tuple-returning) and
  `parse_url!/1` (raises on error). Prefer the top-level names in
  user code.

  ## Accepted URL shape

      sqlite:///<absolute_path>[?<query>]
      sqlite3:///<absolute_path>[?<query>]
      file:///<absolute_path>[?<query>]
      sqlite::memory:
      sqlite3::memory:

  - A host component is rejected — SQLite is embedded, there is no
    host to connect to.
  - Relative paths are not representable in URL form; use the
    `:database` config key directly for those.

  ## Accepted query parameters

  Each maps onto an `Xqlite.open/2` opt of the same atom name.
  Unknown parameters yield a structured error rather than being
  silently dropped.

      journal_mode = wal | delete | truncate | memory | off
      synchronous = off | normal | full | extra
      temp_store = default | file | memory
      auto_vacuum = none | full | incremental
      foreign_keys = true | false | on | off | 1 | 0
      busy_timeout = <non-negative integer ms> | infinity
      cache_size = <integer, negative = KB>
      wal_autocheckpoint = <non-negative integer pages>
      mmap_size = <non-negative integer bytes>
  """

  alias XqliteEcto3.URLError

  @allowed_schemes ["sqlite", "sqlite3", "file"]

  # {key_atom, :type, optional enum_values}
  @param_specs %{
    "journal_mode" => {:journal_mode, :atom_enum, [:wal, :delete, :truncate, :memory, :off]},
    "synchronous" => {:synchronous, :atom_enum, [:off, :normal, :full, :extra]},
    "temp_store" => {:temp_store, :atom_enum, [:default, :file, :memory]},
    "auto_vacuum" => {:auto_vacuum, :atom_enum, [:none, :full, :incremental]},
    "foreign_keys" => {:foreign_keys, :boolean, nil},
    "busy_timeout" => {:busy_timeout, :timeout, nil},
    "cache_size" => {:cache_size, :integer, nil},
    "wal_autocheckpoint" => {:wal_autocheckpoint, :non_neg_integer, nil},
    "mmap_size" => {:mmap_size, :non_neg_integer, nil}
  }

  @doc """
  Parses the given URL into a keyword list combining `:database` with
  any query-string parameters.

  Returns `{:ok, opts}` or `{:error, %XqliteEcto3.URLError{}}`.

  ## Examples

      iex> XqliteEcto3.URL.parse("sqlite:///tmp/my.db")
      {:ok, [database: "/tmp/my.db"]}

      iex> XqliteEcto3.URL.parse("sqlite:///tmp/my.db?busy_timeout=10000&journal_mode=wal")
      {:ok, [database: "/tmp/my.db", busy_timeout: 10_000, journal_mode: :wal]}

      iex> XqliteEcto3.URL.parse("sqlite::memory:")
      {:ok, [database: ":memory:"]}

      iex> {:error, err} = XqliteEcto3.URL.parse("postgres://localhost/foo")
      iex> err.reason
      {:unsupported_scheme, "postgres"}

      iex> {:error, err} = XqliteEcto3.URL.parse("sqlite://myhost/tmp/my.db")
      iex> err.reason
      {:unsupported_host, "myhost"}

      iex> {:error, err} = XqliteEcto3.URL.parse("sqlite:///tmp/my.db?not_a_real_opt=1")
      iex> err.reason
      {:unknown_option, "not_a_real_opt"}
  """
  @spec parse(String.t()) :: {:ok, keyword()} | {:error, URLError.t()}
  def parse(url) when is_binary(url) do
    with {:ok, uri} <- wrap_uri(url),
         :ok <- check_scheme(uri),
         :ok <- check_host(uri),
         {:ok, database} <- extract_database(uri),
         {:ok, query_opts} <- parse_query(uri.query) do
      {:ok, [database: database] ++ query_opts}
    else
      {:error, reason} -> {:error, %URLError{url: url, reason: reason}}
    end
  end

  @doc """
  Like `parse/1` but raises `XqliteEcto3.URLError` on failure.

  Use this in config-time call sites where a malformed URL should
  fail app boot immediately with a clear stack trace — e.g. inside
  the `start_link` chain that reads `config :my_app, MyApp.Repo,
  url: System.fetch_env!("DATABASE_URL")`.
  """
  @spec parse!(String.t()) :: keyword()
  def parse!(url) when is_binary(url) do
    case parse(url) do
      {:ok, opts} -> opts
      {:error, %URLError{} = err} -> raise err
    end
  end

  # --- internals ------------------------------------------------------------

  defp wrap_uri(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp check_scheme(%URI{scheme: nil}), do: {:error, :missing_scheme}

  defp check_scheme(%URI{scheme: scheme}) when scheme in @allowed_schemes, do: :ok

  defp check_scheme(%URI{scheme: scheme}), do: {:error, {:unsupported_scheme, scheme}}

  defp check_host(%URI{host: nil}), do: :ok
  defp check_host(%URI{host: ""}), do: :ok
  defp check_host(%URI{host: host}), do: {:error, {:unsupported_host, host}}

  # `sqlite::memory:` parses as scheme="sqlite", path=":memory:"
  # `sqlite:///path` parses as scheme="sqlite", path="/path"
  # An empty path means no database was given.
  defp extract_database(%URI{path: nil}), do: {:error, :missing_database}
  defp extract_database(%URI{path: ""}), do: {:error, :missing_database}
  defp extract_database(%URI{path: path}), do: {:ok, path}

  defp parse_query(nil), do: {:ok, []}
  defp parse_query(""), do: {:ok, []}

  defp parse_query(query) do
    query
    |> URI.decode_query()
    |> Enum.reduce_while({:ok, []}, &fold_param/2)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      error -> error
    end
  end

  defp fold_param({key, value}, {:ok, acc}) do
    case Map.fetch(@param_specs, key) do
      {:ok, {atom_key, type, enum_values}} ->
        case coerce(value, type, enum_values) do
          {:ok, coerced} ->
            {:cont, {:ok, [{atom_key, coerced} | acc]}}

          {:error, inner} ->
            {:halt, {:error, {:invalid_option, key, inner}}}
        end

      :error ->
        {:halt, {:error, {:unknown_option, key}}}
    end
  end

  defp coerce(value, :atom_enum, enum_values) do
    enum_to_map = Map.new(enum_values, fn a -> {Atom.to_string(a), a} end)

    case Map.fetch(enum_to_map, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:not_in_enum, enum_values}}
    end
  end

  defp coerce(value, :boolean, _) do
    case String.downcase(value) do
      v when v in ["true", "on", "1"] -> {:ok, true}
      v when v in ["false", "off", "0"] -> {:ok, false}
      _ -> {:error, :not_a_boolean}
    end
  end

  defp coerce("infinity", :timeout, _), do: {:ok, :infinity}
  defp coerce(value, :timeout, _), do: parse_non_neg_integer(value)

  defp coerce(value, :integer, _), do: parse_integer(value)

  defp coerce(value, :non_neg_integer, _), do: parse_non_neg_integer(value)

  defp parse_integer(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :not_an_integer}
    end
  end

  defp parse_non_neg_integer(value) do
    with {:ok, n} <- parse_integer(value) do
      if n >= 0, do: {:ok, n}, else: {:error, :negative_value}
    end
  end
end
