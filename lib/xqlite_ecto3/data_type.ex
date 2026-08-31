defmodule XqliteEcto3.DataType do
  @moduledoc false

  # SQLite column type mapping. SQLite has no exact-decimal storage class:
  # a DECIMAL column carries NUMERIC affinity, so numeric values are coerced
  # to INTEGER or REAL (float64) at write time. Decimals beyond float64's
  # exact precision (~15 significant digits) are refused at the binding
  # boundary rather than silently rounded (see the adapter moduledoc).
  # Declared sizes/precision are otherwise ignored, so most types map to
  # simple keywords.

  @spec column_type(atom() | {:array, term()} | {:map, term()}, term()) :: String.t()
  def column_type(:id, _opts), do: "INTEGER"
  def column_type(:serial, _opts), do: "INTEGER"
  def column_type(:bigserial, _opts), do: "INTEGER"
  def column_type(:boolean, _opts), do: "INTEGER"
  def column_type(:integer, _opts), do: "INTEGER"
  def column_type(:bigint, _opts), do: "INTEGER"
  def column_type(:string, _opts), do: "TEXT"
  def column_type(:float, _opts), do: "NUMERIC"
  # Every float-flavored spelling maps to NUMERIC, not to a REAL-affinity
  # keyword: a REAL column would round an integer-exact `:decimal` value
  # past 2^53 to its nearest float64 on the way in.
  def column_type(:real, _opts), do: "NUMERIC"
  def column_type(:double, _opts), do: "NUMERIC"
  def column_type(:double_precision, _opts), do: "NUMERIC"
  def column_type(:binary, _opts), do: "BLOB"
  def column_type(:date, _opts), do: "TEXT"
  def column_type(:utc_datetime, _opts), do: "TEXT"
  def column_type(:utc_datetime_usec, _opts), do: "TEXT"
  def column_type(:naive_datetime, _opts), do: "TEXT"
  def column_type(:naive_datetime_usec, _opts), do: "TEXT"
  def column_type(:time, _opts), do: "TEXT"
  def column_type(:time_usec, _opts), do: "TEXT"
  def column_type(:timestamp, _opts), do: "TEXT"
  def column_type(:decimal, nil), do: "DECIMAL"

  def column_type(:decimal, opts) do
    precision = Keyword.get(opts, :precision)
    scale = Keyword.get(opts, :scale, 0)

    if precision do
      "DECIMAL(#{precision},#{scale})"
    else
      "DECIMAL"
    end
  end

  def column_type(:array, _opts), do: "TEXT"
  def column_type({:array, _}, _opts), do: "TEXT"
  def column_type(:binary_id, _opts), do: binary_id_column_type()
  def column_type(:map, _opts), do: "TEXT"
  def column_type({:map, _}, _opts), do: "TEXT"
  def column_type(:uuid, _opts), do: binary_id_column_type()

  # DB-specific spellings the adapter knows carry text or bytes get that
  # affinity directly. Left to the affinity rule below they would land on
  # NUMERIC, which rewrites numeric-looking text on the way in ("007"
  # becomes the integer 7) and the loss is silent and irreversible.
  def column_type(:json, _opts), do: "TEXT"
  def column_type(:jsonb, _opts), do: "TEXT"
  def column_type(:xml, _opts), do: "TEXT"
  def column_type(:inet, _opts), do: "TEXT"
  def column_type(:cidr, _opts), do: "TEXT"
  def column_type(:macaddr, _opts), do: "TEXT"
  def column_type(:tsvector, _opts), do: "TEXT"
  def column_type(:bytea, _opts), do: "BLOB"

  # Unrecognized atoms pass through upcased so DB-specific spellings keep
  # working — except any spelling SQLite would give REAL affinity, which
  # becomes NUMERIC for the same reason :real does above. SQLite's affinity
  # rules decide in order: INT wins first, then CHAR/CLOB/TEXT, then BLOB,
  # and only then REAL/FLOA/DOUB — so a marker from an earlier rule keeps
  # the spelling out of the rewrite. The spelling must render safely bare
  # (SQLite's typename grammar, no keywords); anything else would splice
  # extra tokens into the rendered DDL or die as a raw syntax error.
  def column_type(type, _) when is_atom(type) do
    declared =
      type
      |> Atom.to_string()
      |> String.upcase()

    cond do
      not bare_typename?(declared) ->
        raise XqliteEcto3.UnsupportedTypeError, type: type

      real_affinity?(declared) ->
        "NUMERIC"

      true ->
        declared
    end
  end

  def column_type(type, _) do
    raise XqliteEcto3.UnsupportedTypeError, type: type
  end

  # SQLite's typename grammar: identifier words, then an optional (N) or
  # (N,M) size suffix, whitespace tolerated around the numbers.
  @typename_grammar ~r/^[A-Z_][A-Z0-9_]*(?:\s+[A-Z_][A-Z0-9_]*)*\s*(?:\(\s*[+-]?\d+\s*(?:,\s*[+-]?\d+\s*)?\))?$/

  # www.sqlite.org/lang_keywords.html — the full list. A bare word from it
  # in type position is a syntax error for the reserved ones and a
  # different token for the rest, so no keyword ever renders bare.
  @sqlite_keywords ~w(
    ABORT ACTION ADD AFTER ALL ALTER ALWAYS ANALYZE AND AS ASC ATTACH
    AUTOINCREMENT BEFORE BEGIN BETWEEN BY CASCADE CASE CAST CHECK COLLATE
    COLUMN COMMIT CONFLICT CONSTRAINT CREATE CROSS CURRENT CURRENT_DATE
    CURRENT_TIME CURRENT_TIMESTAMP DATABASE DEFAULT DEFERRABLE DEFERRED
    DELETE DESC DETACH DISTINCT DO DROP EACH ELSE END ESCAPE EXCEPT
    EXCLUDE EXCLUSIVE EXISTS EXPLAIN FAIL FILTER FIRST FOLLOWING FOR
    FOREIGN FROM FULL GENERATED GLOB GROUP GROUPS HAVING IF IGNORE
    IMMEDIATE IN INDEX INDEXED INITIALLY INNER INSERT INSTEAD INTERSECT
    INTO IS ISNULL JOIN KEY LAST LEFT LIKE LIMIT MATCH MATERIALIZED NATURAL
    NO NOT NOTHING NOTNULL NULL NULLS OF OFFSET ON OR ORDER OTHERS OUTER
    OVER PARTITION PLAN PRAGMA PRECEDING PRIMARY QUERY RAISE RANGE RECURSIVE
    REFERENCES REGEXP REINDEX RELEASE RENAME REPLACE RESTRICT RETURNING
    RIGHT ROLLBACK ROW ROWS SAVEPOINT SELECT SET TABLE TEMP TEMPORARY THEN
    TIES TO TRANSACTION TRIGGER UNBOUNDED UNION UNIQUE UPDATE USING VACUUM
    VALUES VIEW VIRTUAL WHEN WHERE WINDOW WITH WITHOUT
  )
  @sqlite_keyword_set MapSet.new(@sqlite_keywords)

  @doc false
  # Whether an upcased type text renders safely bare in DDL type position:
  # it fits SQLite's typename grammar and no word of it is an SQLite
  # keyword. Shared by the migration passthrough (refuses) and the table
  # rebuild's carried-type emission (quotes).
  @spec bare_typename?(String.t()) :: boolean()
  def bare_typename?(declared) when is_binary(declared) do
    Regex.match?(@typename_grammar, declared) and
      ~r/[A-Z_][A-Z0-9_]*/
      |> Regex.scan(declared)
      |> Enum.all?(fn [word] -> not MapSet.member?(@sqlite_keyword_set, word) end)
  end

  @doc false
  # SQLite's column-affinity rule over a declared type text, in the
  # documented order: INT wins first, then CHAR/CLOB/TEXT, then BLOB (an
  # empty declaration included), then REAL/FLOA/DOUB, else NUMERIC.
  @spec sqlite_affinity(String.t()) :: :integer | :text | :blob | :real | :numeric
  def sqlite_affinity(declared) when is_binary(declared) do
    scannable = String.upcase(declared)

    cond do
      String.contains?(scannable, "INT") -> :integer
      Enum.any?(["CHAR", "CLOB", "TEXT"], &String.contains?(scannable, &1)) -> :text
      String.contains?(scannable, "BLOB") or scannable == "" -> :blob
      Enum.any?(["REAL", "FLOA", "DOUB"], &String.contains?(scannable, &1)) -> :real
      true -> :numeric
    end
  end

  defp real_affinity?(declared), do: sqlite_affinity(declared) == :real

  # A map or list given as a column `default:` is stored as JSON text. Every
  # path that writes such a column — the plain ALTER, the table rebuild, and
  # the rebuild's own prediction of what it wrote — renders it here, so one
  # migration option can only ever produce one stored default.
  #
  # `context` carries `:column` and `:type` for the refusals, either of them
  # nil when the calling path does not know it.
  @spec json_default(map() | list(), keyword()) :: String.t()
  def json_default(value, context \\ [])

  def json_default(value, context) when is_struct(value) do
    unsupported_default!(value, :unsupported_shape, context)
  end

  # `~c"abc"` and `[97, 98, 99]` are the same term, so a printable list of
  # character codes has no single meaning here: JSON-encoding it stores an
  # array of numbers for a caller who almost certainly meant the text. A
  # text default is written as a string instead.
  def json_default(value, context) when is_list(value) do
    if value != [] and List.ascii_printable?(value) do
      unsupported_default!(value, :unsupported_shape, context)
    else
      encode_default(value, context)
    end
  end

  def json_default(value, context) when is_map(value) do
    encode_default(value, context)
  end

  # The refusal every default renderer shares, so one migration option is
  # refused the same way on the plain path, on the table rebuild, and in the
  # rebuild's own prediction of what it wrote.
  @spec unsupported_default!(term(), :unsupported_shape | :unencodable, keyword()) :: no_return()
  def unsupported_default!(value, reason, context) do
    raise XqliteEcto3.UnsupportedDefaultError,
      value: value,
      reason: reason,
      column: context |> Keyword.get(:column) |> normalize_column(),
      type: Keyword.get(context, :type)
  end

  # The plain path knows the column as the atom from the migration AST; the
  # rebuild's modify leg knows it as the string from pragma_table_xinfo. One
  # error, one shape: always a string.
  defp normalize_column(nil), do: nil
  defp normalize_column(column), do: to_string(column)

  defp encode_default(value, context) do
    value
    |> Jason.encode_to_iodata!()
    |> IO.iodata_to_binary()
  rescue
    e in [Protocol.UndefinedError, Jason.EncodeError] ->
      reraise XqliteEcto3.UnsupportedDefaultError.exception(
                value: value,
                reason: :unencodable,
                column: context |> Keyword.get(:column) |> normalize_column(),
                type: Keyword.get(context, :type),
                cause: e
              ),
              __STACKTRACE__
  end

  # Reads `config :xqlite_ecto3, :binary_id_storage` (default `:string`) and
  # picks the corresponding SQLite column type for `:binary_id` / `:uuid`
  # fields in migrations. `:string` → TEXT, `:binary` → BLOB. Governs both
  # uniformly. `XqliteEcto3.Types.UUID` is a per-field escape hatch.
  defp binary_id_column_type do
    case Application.get_env(:xqlite_ecto3, :binary_id_storage, :string) do
      :string -> "TEXT"
      :binary -> "BLOB"
    end
  end
end

defmodule XqliteEcto3.UnsupportedDefaultError do
  @moduledoc """
  Raised when a migration's `default:` value cannot be written as a SQLite
  column default.

  A default lives in the table's own DDL, so it has to be a literal SQLite
  can hold: `nil`, a string, a number, a boolean, a `fragment/1`, or a plain
  map or list, which the adapter stores as JSON text. Anything else — a
  struct (`Decimal`, `Date`, `MapSet`), an atom, a tuple that is not a
  fragment, a bitstring that is not a whole number of bytes, or a printable
  charlist — is refused here instead of being written as a quietly-wrong
  default.

  Fields:

    * `value` — the offending default
    * `reason` — `:unsupported_shape` when the value has no literal form,
      `:unencodable` when a plain map or list holds something JSON cannot
      represent
    * `column` / `type` — the column being written, when the path that
      refused knows them (`nil` otherwise)
    * `cause` — the encoder's own exception for `:unencodable`, `nil` for
      `:unsupported_shape`

  Fixes: write a struct as the string or number you want stored
  (`default: "2020-01-01"`, `default: 1.5`), write text as a string rather
  than a charlist, and use `fragment/1` for anything SQL has to evaluate.
  """

  defexception [:value, :reason, :column, :type, :cause]

  @type t :: %__MODULE__{
          value: term(),
          reason: :unsupported_shape | :unencodable,
          column: String.t() | nil,
          type: term(),
          cause: Exception.t() | nil
        }

  @impl true
  def message(%__MODULE__{reason: :unencodable} = error) do
    "default #{inspect(error.value)}#{column_part(error)} holds a value with no JSON " <>
      "form, so it cannot be stored as a column default"
  end

  def message(%__MODULE__{} = error) do
    "unsupported default #{inspect(error.value)}#{column_part(error)}. A column default " <>
      "may be nil, a string, a number, a boolean, a plain map or list (stored as JSON " <>
      "text), or a fragment(...)"
  end

  defp column_part(%__MODULE__{column: nil, type: nil}), do: ""
  defp column_part(%__MODULE__{column: nil, type: type}), do: " for type #{inspect(type)}"

  defp column_part(%__MODULE__{column: column, type: nil}), do: " for column #{inspect(column)}"

  defp column_part(%__MODULE__{column: column, type: type}),
    do: " for column #{inspect(column)} of type #{inspect(type)}"
end

defmodule XqliteEcto3.UnsupportedTypeError do
  @moduledoc """
  Raised when a migration references a type that the adapter cannot
  render as a SQLite column type — non-atom, non-tuple, or a tuple shape
  with no matching clause. Structured so callers can pattern-match on
  the `type` field instead of parsing the message.
  """

  defexception [:type]

  @impl true
  def message(%__MODULE__{type: type}) do
    "unsupported type `#{inspect(type)}`"
  end
end
