defmodule XqliteEcto3.RebuildVerificationError do
  @moduledoc """
  Raised when a table rebuild ran to completion but the rebuilt table does
  not carry every structural fact the original one had.

  The rebuild reads the table's structure before it starts and again after
  its statements succeed, and compares the second reading against what the
  migration's changes predict from the first. This error is the report of the
  first construct that did not match, and it always means a defect in the
  rebuild engine rather than a mistake in the migration.

  Fields:

    * `table` — the table being rebuilt.
    * `construct` — what did not match: `:columns` (the column list itself),
      `:column_type`, `:column_null`, `:column_default`, `:primary_key`,
      `:primary_key_sort_order`, `:foreign_keys`, `:unique_constraints`,
      `:indexes`, `:triggers`, `:table_options`, `:autoincrement`, `:rowid`
      or `:sequence`.
    * `column` — the column involved, for the per-column constructs.
    * `expected` / `actual` — the predicted and observed values.
  """

  defexception [:table, :construct, :column, :expected, :actual]

  @type t :: %__MODULE__{
          table: String.t() | nil,
          construct: atom() | nil,
          column: String.t() | nil,
          expected: term(),
          actual: term()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    "rebuilding table #{inspect(error.table)} did not reproduce its structure" <>
      location(error) <>
      ": expected #{inspect(error.expected)}, got #{inspect(error.actual)}. " <>
      "The rebuild is aborted before it commits, so the table keeps the structure " <>
      "it had. This is a bug in xqlite_ecto3's table rebuild, not in your migration — " <>
      "please report it with the migration and the table's CREATE statement."
  end

  defp location(%__MODULE__{construct: construct, column: nil}), do: " (#{construct})"

  defp location(%__MODULE__{construct: construct, column: column}),
    do: " (#{construct} of column #{inspect(column)})"
end

defmodule XqliteEcto3.RebuildVerification do
  @moduledoc false

  # The table rebuild reconstructs a table from what the structural pragmas
  # report. Anything the reconstruction forgets to re-emit would disappear
  # without a trace, so the rebuild reads the table's structure once before it
  # starts and once after it finishes, and hands both readings here together
  # with the migration's column changes. This module predicts what the second
  # reading must look like and reports the first construct that does not match.
  #
  # Nothing here touches a database: both readings arrive as plain maps
  # produced by the same reader, so a difference between them is a real
  # difference in the table.
  #
  # What the prediction says about each construct:
  #
  #   * columns — order is the declared order; `add` appends, `remove` deletes
  #     by name, `modify` replaces in place. A column declared without a type
  #     comes back as BLOB.
  #   * a modified column's aspects merge OVER the declaration the table
  #     already stores: an option the migration does not give (`:null`,
  #     `:default`, `:primary_key`) leaves that aspect as it was, and
  #     AUTOINCREMENT rides along as long as the column keeps its
  #     single-column primary key. Two modifies of the same column in one
  #     alter block each merge against that same stored declaration, so the
  #     last one wins outright.
  #   * a column added earlier in the same alter block has no stored
  #     declaration, so a later `modify` of it is written from the options
  #     alone.
  #   * primary key — a single-member key rides inline on its column. A key
  #     with several members is re-emitted over the members the change set
  #     leaves keyed, in declared key order: removing a member and giving it
  #     `primary_key: false` both narrow the key the same way. Leaving no
  #     member keyed at all is refused outright, and so is granting a column
  #     primary_key: true while a member is still keyed — one table, one key.
  #   * the key's sort order — the DESC a member was declared with — has to
  #     come back with it, but only while the change set leaves the key
  #     alone. A key that moves can also stop having a sort order to record:
  #     a single-column INTEGER key is the table's row id under another name
  #     and SQLite gives it no index, which is where the order is kept.
  #   * row ids — the count of rows and the lowest and highest row id. The
  #     copy has to carry them, again only while the change set leaves the
  #     key alone: a key that moves takes row identity with it, and a column
  #     named after the row id answers for it in the reading.
  #   * foreign keys, unique constraints, indexes, triggers, the WITHOUT
  #     ROWID / STRICT table options and the AUTOINCREMENT sequence value are
  #     carried over untouched.

  alias XqliteEcto3.RebuildVerificationError

  # The names SQLite answers with the row id itself unless a column takes one.
  @rowid_names ["rowid", "_rowid_", "oid"]

  @type column :: %{
          name: String.t(),
          type: String.t(),
          notnull: boolean(),
          default: String.t() | nil,
          pk: non_neg_integer()
        }

  @type foreign_key :: %{
          columns: [String.t()],
          target: String.t(),
          target_columns: [String.t() | nil],
          on_delete: String.t(),
          on_update: String.t()
        }

  @type index_column :: %{column: String.t() | nil, desc: boolean()}

  @type rowid :: %{
          present: boolean(),
          count: non_neg_integer() | nil,
          min: term(),
          max: term()
        }

  @type snapshot :: %{
          table: String.t(),
          columns: [column()],
          primary_key_order: [index_column()],
          foreign_keys: [foreign_key()],
          unique_constraints: [[index_column()]],
          indexes: %{schema: [String.t()], index_list: [String.t()]},
          triggers: [String.t()],
          table_options: %{without_rowid: boolean(), strict: boolean()},
          autoincrement: boolean(),
          rowid: rowid(),
          sequence: integer() | nil
        }

  @typedoc """
  Runs one parameterized statement and returns its rows. The rebuild passes
  its own connection in; nothing here knows how the statement gets there.
  """
  @type query :: (String.t(), [term()] -> [[term()]])

  @doc """
  Reads every structural fact a rebuild has to carry over.

  The rebuild takes one reading before its first statement and another after
  its last one, both through this function, so the two are directly
  comparable.
  """
  @spec read(String.t(), query()) :: snapshot()
  def read(table_name, query) when is_function(query, 2) do
    {unique_constraints, index_names, key_sort_order} = read_indexes(table_name, query)
    autoincrement? = read_autoincrement?(table_name, query)
    table_options = read_table_options(table_name, query)

    %{
      table: table_name,
      columns: read_columns(table_name, query),
      primary_key_order: key_sort_order,
      foreign_keys: read_foreign_keys(table_name, query),
      unique_constraints: unique_constraints,
      indexes: %{
        schema: read_schema_objects(table_name, "index", query),
        index_list: index_names
      },
      triggers: read_schema_objects(table_name, "trigger", query),
      table_options: table_options,
      autoincrement: autoincrement?,
      rowid: read_rowid(table_name, table_options, query),
      sequence: read_sequence(table_name, autoincrement?, query)
    }
  end

  @doc """
  Compares the structure read after a rebuild against the structure the
  change set predicts from the structure read before it.

  Returns `:ok` when every construct matches, or the first mismatch as an
  `XqliteEcto3.RebuildVerificationError`.
  """
  @spec verify(snapshot(), [tuple()], snapshot()) :: :ok | {:error, RebuildVerificationError.t()}
  def verify(before, changes, actual) do
    case predict(before, changes) do
      {:refused, reason} ->
        {:error, mismatch(before.table, :primary_key, nil, {:refused, reason}, :rebuilt)}

      {:ok, expected} ->
        compare(before.table, expected, actual)
    end
  end

  @doc """
  The table's primary-key columns in declared key order — `pk` in
  `pragma_table_xinfo` is the 1-based position within the key, 0 outside it.
  """
  @spec primary_key_members([column()]) :: [String.t()]
  def primary_key_members(columns) do
    columns
    |> Enum.filter(&(&1.pk > 0))
    |> Enum.sort_by(& &1.pk)
    |> Enum.map(& &1.name)
  end

  @doc """
  The primary-key columns that still exist once the change set's removals are
  applied, in declared key order. An empty result on a table that had a
  primary key means the change set takes the key away entirely.
  """
  @spec surviving_primary_key_members([column()], [tuple()]) :: [String.t()]
  def surviving_primary_key_members(columns, changes) do
    planned =
      columns
      |> initial_plan(false)
      |> apply_changes(changes)

    columns
    |> primary_key_members()
    |> surviving(planned)
  end

  # Hidden 1 is a WITHOUT ROWID table's own key column and 2 is a virtual
  # generated column; neither is part of a rebuilt table's column list.
  defp read_columns(table_name, query) do
    rows =
      query.(
        ~s|SELECT name, type, "notnull", dflt_value, pk FROM pragma_table_xinfo(?1) | <>
          "WHERE hidden NOT IN (1, 2)",
        [table_name]
      )

    Enum.map(rows, fn [name, type, notnull, default, pk] ->
      %{name: name, type: type, notnull: notnull == 1, default: default, pk: pk}
    end)
  end

  # SQLite numbers a table's foreign keys in reverse declaration order, so a
  # rebuild that re-emits them in the order it read them flips the numbering
  # every time; sorting makes the comparison about the keys themselves. The
  # target table is folded to lower case because SQLite resolves it that way
  # and the rebuild re-spells a self-reference with the table's stored name.
  # MATCH is left out: SQLite parses it, reports NONE for every declaration
  # and never acts on it.
  defp read_foreign_keys(table_name, query) do
    rows =
      query.(
        ~s(SELECT id, seq, "table", "from", "to", on_update, on_delete ) <>
          "FROM pragma_foreign_key_list(?1) ORDER BY id, seq",
        [table_name]
      )

    rows
    |> Enum.group_by(fn [id | _rest] -> id end)
    |> Enum.map(fn {_id, group} -> read_foreign_key(group) end)
    |> Enum.sort()
  end

  defp read_foreign_key(group) do
    [_id, _seq, target, _from, _to, on_update, on_delete] = hd(group)

    %{
      columns: Enum.map(group, fn [_id, _seq, _table, from | _rest] -> from end),
      target: String.downcase(target, :ascii),
      target_columns: Enum.map(group, fn [_id, _seq, _table, _from, to | _rest] -> to end),
      on_update: on_update,
      on_delete: on_delete
    }
  end

  # index_list and the per-column detail from index_xinfo in one read.
  # `key = 1` drops the trailing rowid entries index_xinfo appends.
  defp read_indexes(table_name, query) do
    rows =
      query.(
        ~s|SELECT il.name, il.origin, il."unique", xi.name, xi."desc" | <>
          "FROM pragma_index_list(?1) AS il, pragma_index_xinfo(il.name) AS xi " <>
          "WHERE xi.key = 1 ORDER BY il.name, xi.seqno",
        [table_name]
      )

    grouped =
      Enum.group_by(
        rows,
        fn [index_name, origin, unique | _rest] -> {index_name, origin, unique} end,
        fn [_name, _origin, _unique, column, desc] -> %{column: column, desc: desc == 1} end
      )

    {unique_constraint_columns(grouped), standalone_index_names(grouped),
     primary_key_columns(grouped)}
  end

  # The key's own backing index, when it has one. A single-column INTEGER key
  # with no DESC is the table's row id under another name and SQLite builds it
  # no index at all, so an empty list also says "this key is the row id".
  defp primary_key_columns(grouped) do
    grouped
    |> Enum.filter(fn {{_name, origin, _unique}, _cols} -> origin == "pk" end)
    |> Enum.flat_map(fn {_key, columns} -> columns end)
  end

  # A table-level UNIQUE is backed by an index SQLite names itself, and it
  # renumbers those names on every rebuild — so unique constraints are
  # compared by the columns they cover, as a sorted collection, never by name.
  # The primary key's own backing index is left out; the key is compared
  # through the columns' key positions instead.
  defp unique_constraint_columns(grouped) do
    grouped
    |> Enum.filter(fn {{_name, origin, unique}, _cols} ->
      unique == 1 and origin in ["u", "c"]
    end)
    |> Enum.map(fn {_key, columns} -> columns end)
    |> Enum.sort()
  end

  defp standalone_index_names(grouped) do
    grouped
    |> Enum.filter(fn {{_name, origin, _unique}, _cols} -> origin == "c" end)
    |> Enum.map(fn {{index_name, _origin, _unique}, _cols} -> index_name end)
    |> Enum.sort()
  end

  # The indexes and triggers the rebuild has to re-create, by name. The table
  # is matched case-insensitively so a differently-spelled `tbl_name` cannot
  # hide one.
  defp read_schema_objects(table_name, type, query) do
    rows =
      query.(
        "SELECT name FROM sqlite_schema WHERE type = ?1 AND lower(tbl_name) = lower(?2) " <>
          "AND sql IS NOT NULL",
        [type, table_name]
      )

    rows
    |> Enum.map(fn [object_name] -> object_name end)
    |> Enum.sort()
  end

  defp read_table_options(table_name, query) do
    rows =
      query.(
        "SELECT wr, strict FROM pragma_table_list " <>
          "WHERE schema = 'main' AND lower(name) = lower(?1)",
        [table_name]
      )

    case rows do
      [[wr, strict]] -> %{without_rowid: wr == 1, strict: strict == 1}
      _missing -> %{without_rowid: false, strict: false}
    end
  end

  # Row identity: a copy that renumbers the rows keeps every value and still
  # breaks everything keyed on the row id. A WITHOUT ROWID table has no row
  # id to read — the column list is its whole identity. The table name cannot
  # travel as a bound parameter here, so it is quoted into the statement.
  defp read_rowid(_table_name, %{without_rowid: true}, _query),
    do: %{present: false, count: nil, min: nil, max: nil}

  defp read_rowid(table_name, _table_options, query) do
    case query.("SELECT count(*), min(rowid), max(rowid) FROM " <> quoted(table_name), []) do
      [[count, min, max]] -> %{present: true, count: count, min: min, max: max}
      _missing -> %{present: true, count: nil, min: nil, max: nil}
    end
  end

  defp quoted(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  @doc """
  Whether a stored `CREATE TABLE` text declares `AUTOINCREMENT`.

  AUTOINCREMENT has no structural pragma of its own, and `sqlite_sequence`
  cannot answer the question either — its row appears only on the first
  insert, so an empty table's declaration is invisible there. The stored
  CREATE text is the one authoritative source; the rebuild engine and this
  verifier share this predicate so they can never disagree about it.
  """
  @spec autoincrement_declared?(String.t()) :: boolean()
  def autoincrement_declared?(create_sql) when is_binary(create_sql) do
    # The grammar allows a sort order and an ON CONFLICT clause between
    # KEY and AUTOINCREMENT (`PRIMARY KEY ASC AUTOINCREMENT` is legal and
    # autoincrements), so the two keywords are not always adjacent.
    scannable = without_string_literals(create_sql)

    Regex.match?(
      ~r/\bPRIMARY\s+KEY(?:\s+(?:ASC|DESC))?(?:\s+ON\s+CONFLICT\s+\w+)?\s+AUTOINCREMENT\b/i,
      scannable
    )
  end

  # Every way SQLite's own lexer quotes a piece of text: a string literal in
  # single quotes, and the three forms of quoted identifier. All four are
  # scanned in one left-to-right pass, which is what keeps the quote in
  # `"it's_v"` from opening a literal that runs to the next one.
  @quoted_text ~r/"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]|'(?:[^']|'')*'/

  @doc """
  A stored `CREATE TABLE` text with the contents of its string literals
  emptied out.

  SQLite keeps the text of a CREATE statement exactly as it was typed, so a
  scan for a keyword also reads the words inside `DEFAULT 'check pending'`
  and would take that table for one declaring a CHECK constraint. Emptying
  what sits between the quotes leaves a text with the same structure and no
  words to trip on; a literal escapes a quote by doubling it, which makes
  the boundaries unambiguous without parsing anything.

  Comments are left as they are: a keyword written inside one still counts
  as declared, which keeps the scan on the safe side.
  """
  @spec without_string_literals(String.t()) :: String.t()
  def without_string_literals(create_sql) when is_binary(create_sql) do
    Regex.replace(@quoted_text, create_sql, &blanked/1)
  end

  defp blanked(<<?', _rest::binary>>), do: "''"
  defp blanked(quoted_name), do: quoted_name

  defp read_autoincrement?(table_name, query) do
    rows =
      query.(
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND lower(name) = lower(?1)",
        [table_name]
      )

    case rows do
      [[create_sql]] when is_binary(create_sql) -> autoincrement_declared?(create_sql)
      _missing -> false
    end
  end

  # sqlite_sequence exists only once some table in the database declares
  # AUTOINCREMENT, so only a table that declares it can be looked up there.
  # The declaration is read from the stored CREATE text, which can name the
  # keyword where SQLite never created the table — so a database without one
  # answers "no sequence", exactly as the engine's own read of the same value
  # does, instead of failing the rebuild over a table that is not there.
  defp read_sequence(_table_name, false, _query), do: nil

  defp read_sequence(table_name, true, query) do
    case query.("SELECT name FROM sqlite_schema WHERE name = 'sqlite_sequence'", []) do
      [[_present]] -> read_sequence_row(table_name, query)
      _missing -> nil
    end
  end

  defp read_sequence_row(table_name, query) do
    case query.("SELECT seq FROM sqlite_sequence WHERE name = ?1", [table_name]) do
      [[seq]] -> seq
      _missing -> nil
    end
  end

  @spec predict(snapshot(), [tuple()]) :: {:ok, snapshot()} | {:refused, atom()}
  defp predict(before, changes) do
    planned =
      before.columns
      |> initial_plan(before.autoincrement)
      |> apply_changes(changes)

    members = primary_key_members(before.columns)
    survivors = surviving(members, planned)

    # A change set that de-keys every current member but grants another
    # column primary_key: true moves the key rather than removing it —
    # the engine allows it, so the prediction must too.
    granted = granted_key_columns(changes)
    granted_key? = granted != []

    cond do
      # SQLite gives a table one primary key, so a grant only works once the
      # key the table has is gone: every member removed or de-keyed. A member
      # left keyed would ask for a second key, which the engine refuses.
      granted_key? and grant_beside_kept_key?(members, survivors, granted) ->
        {:refused, :primary_key_grant_beside_kept_key}

      members != [] and survivors == [] and not granted_key? ->
        {:refused, :primary_key_fully_removed}

      true ->
        key_untouched? = not granted_key? and not names_key_member?(changes, members)
        {:ok, expected_snapshot(before, planned, members, survivors, key_untouched?)}
    end
  end

  # Whether the change set leaves the primary key alone. A change that names
  # a key member — retyping it, de-keying it, removing it — and a change that
  # grants the key to another column both move which column owns the table's
  # row ids, and with it whether SQLite records a sort order for the key at
  # all. The two facts that depend on that are only claimed when neither
  # happens.
  defp names_key_member?(changes, members) do
    Enum.any?(changes, fn change ->
      case changed_column(change) do
        nil -> false
        name -> Enum.any?(members, &same_column_name?(&1, name))
      end
    end)
  end

  defp changed_column({_op, name, _type, _opts}), do: name
  defp changed_column({_op, name, _type}), do: name
  defp changed_column({_op, name}), do: name
  defp changed_column(_change), do: nil

  # Everything the prediction does not rewrite is carried over from the
  # reading taken before the rebuild — that is the whole preservation claim.
  defp expected_snapshot(before, planned, members, survivors, key_untouched?) do
    %{
      before
      | columns: Enum.map(planned, &planned_column(&1, members, survivors)),
        autoincrement: Enum.any?(planned, & &1.autoincrement),
        primary_key_order: expected_key_sort_order(before, key_untouched?),
        rowid: expected_rowid(before, planned, key_untouched?)
    }
  end

  # An empty expectation claims nothing: the comparison below only asks that
  # no DESC went missing, so a key the change set moved is not held to the
  # sort order the old key recorded.
  defp expected_key_sort_order(before, true), do: before.primary_key_order
  defp expected_key_sort_order(_before, false), do: []

  defp expected_rowid(before, planned, key_untouched?) do
    if key_untouched? and not shadowed_rowid?(before.columns, planned) do
      before.rowid
    else
      %{before.rowid | min: :not_compared, max: :not_compared}
    end
  end

  # A column named after the row id answers `SELECT rowid` in its place, so
  # the reading is about that column's values rather than about row identity —
  # and the rebuild leaves the row ids themselves to SQLite in that case.
  defp shadowed_rowid?(columns, planned) do
    Enum.any?(columns ++ planned, fn %{name: name} ->
      String.downcase(name, :ascii) in @rowid_names
    end)
  end

  defp planned_column(col, members, survivors) do
    %{
      name: col.name,
      type: col.type,
      notnull: col.notnull,
      default: col.default,
      pk: key_position(col, members, survivors)
    }
  end

  # A key with several members is written as a table-level clause over the
  # survivors, and SQLite numbers them by their place in that clause. A
  # single-member key rides inline on its column, where the position is
  # always 1.
  # An inline key wins first: a column granted primary_key: true is the
  # key even when the change set de-keyed a composite's members.
  defp key_position(%{pk_inline: true}, _members, _survivors), do: 1

  defp key_position(col, members, survivors) when length(members) > 1 do
    case Enum.find_index(survivors, &(&1 == col.name)) do
      nil -> 0
      index -> index + 1
    end
  end

  defp key_position(_col, _members, _survivors), do: 0

  defp initial_plan(columns, autoincrement?) do
    composite? = length(primary_key_members(columns)) > 1

    Enum.map(columns, fn col ->
      inline_key? = col.pk == 1 and not composite?

      declared = %{
        notnull: col.notnull,
        default: col.default,
        pk_inline: inline_key?,
        autoincrement: autoincrement? and inline_key?
      }

      %{
        name: col.name,
        type: rebuilt_type(col.type),
        notnull: declared.notnull,
        default: declared.default,
        pk_inline: declared.pk_inline,
        autoincrement: declared.autoincrement,
        pk_removed: false,
        declared: declared
      }
    end)
  end

  # A column declared with no type at all is rebuilt as BLOB.
  defp rebuilt_type(type) when type in [nil, ""], do: "BLOB"
  defp rebuilt_type(type), do: type

  defp apply_changes(planned, changes), do: Enum.reduce(changes, planned, &apply_change(&2, &1))

  defp apply_change(planned, {:add, name, type, opts}) do
    planned ++ [added_column(name, type, opts)]
  end

  defp apply_change(planned, {:add_if_not_exists, name, type, opts}) do
    if Enum.any?(planned, &same_column_name?(&1.name, name)) do
      planned
    else
      apply_change(planned, {:add, name, type, opts})
    end
  end

  defp apply_change(planned, {:remove, name, _type, _opts}) do
    apply_change(planned, {:remove, name})
  end

  defp apply_change(planned, {:remove_if_exists, name, _type}) do
    apply_change(planned, {:remove, name})
  end

  defp apply_change(planned, {:remove_if_exists, name}) do
    apply_change(planned, {:remove, name})
  end

  defp apply_change(planned, {:remove, name}) do
    Enum.reject(planned, &same_column_name?(&1.name, name))
  end

  defp apply_change(planned, {:modify, name, type, opts}) do
    Enum.map(planned, fn col ->
      if same_column_name?(col.name, name) do
        modified_column(col, type, opts)
      else
        col
      end
    end)
  end

  defp apply_change(planned, _other), do: planned

  # SQLite resolves column names ASCII-case-insensitively; the model must
  # match a change to its column the same way the engine (and SQLite) do.
  defp same_column_name?(planned_name, change_name) do
    String.downcase(planned_name, :ascii) == String.downcase(to_string(change_name), :ascii)
  end

  defp added_column(name, type, opts) do
    %{
      name: to_string(name),
      type: XqliteEcto3.DataType.column_type(type, opts),
      notnull: Keyword.get(opts, :null) == false,
      default: added_default(Keyword.fetch(opts, :default)),
      pk_inline: Keyword.get(opts, :primary_key, false),
      autoincrement: false,
      pk_removed: false,
      declared: nil
    }
  end

  # A column added earlier in the same alter block has no stored declaration
  # to merge with, so the rebuild writes it from the options alone.
  defp modified_column(%{declared: nil} = col, type, opts) do
    added_column(col.name, type, opts)
  end

  # The merge is always against the declaration the table already stores, so
  # a second modify of the same column in one alter block starts from that
  # declaration again rather than from what the first modify produced.
  defp modified_column(%{declared: declared} = col, type, opts) do
    inline_key? = merged_primary_key(declared, opts)

    %{
      col
      | type: XqliteEcto3.DataType.column_type(type, opts),
        notnull: merged_notnull(declared, opts),
        default: merged_default(declared, opts),
        pk_inline: inline_key?,
        autoincrement: declared.autoincrement and inline_key?,
        pk_removed: Keyword.fetch(opts, :primary_key) == {:ok, false}
    }
  end

  defp merged_notnull(col, opts) do
    case Keyword.fetch(opts, :null) do
      {:ok, null?} -> !null?
      :error -> col.notnull
    end
  end

  defp merged_default(col, opts) do
    case Keyword.fetch(opts, :default) do
      {:ok, value} -> rendered_default(value)
      :error -> col.default
    end
  end

  defp merged_primary_key(col, opts) do
    case Keyword.fetch(opts, :primary_key) do
      {:ok, flag} -> flag
      :error -> col.pk_inline
    end
  end

  defp added_default(:error), do: nil
  defp added_default({:ok, value}), do: rendered_default(value)

  # The literal the rebuild writes into the new CREATE TABLE, which is also
  # the text SQLite reads back as the column's default. Every shape here is
  # rendered the way the two writing paths render it — SQLite stores `DEFAULT
  # true` as the word, not as 1, and a map or a list as quoted JSON text.
  defp rendered_default(nil), do: "NULL"

  defp rendered_default({:fragment, expression}) do
    expression |> IO.iodata_to_binary() |> strip_outer_parens()
  end

  defp rendered_default(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp rendered_default(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp rendered_default(value) when is_map(value) or is_list(value) do
    encoded = XqliteEcto3.DataType.json_default(value)

    "'" <> String.replace(encoded, "'", "''") <> "'"
  end

  # SQLite's grammar requires parentheses around an expression DEFAULT and
  # strips them before storing, so the pragma reports the inside text. A
  # miscount (parentheses inside string literals) leaves the text
  # unstripped and the comparison fails loudly — never silently.
  defp strip_outer_parens(text) do
    trimmed = String.trim(text)
    inner = String.slice(trimmed, 1..-2//1)

    if String.starts_with?(trimmed, "(") and String.ends_with?(trimmed, ")") and
         balanced?(inner) do
      inner
    else
      trimmed
    end
  end

  defp balanced?(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while(0, fn
      ?(, depth -> {:cont, depth + 1}
      ?), 0 -> {:halt, -1}
      ?), depth -> {:cont, depth - 1}
      _ch, depth -> {:cont, depth}
    end)
    |> Kernel.==(0)
  end

  # A member survives only while it is still a key member: present in the
  # plan and not de-keyed by a `modify ..., primary_key: false` (which
  # reaches the keyless end state through a different door than :remove).
  defp surviving(members, planned) do
    keyed =
      planned
      |> Enum.reject(& &1.pk_removed)
      |> MapSet.new(& &1.name)

    Enum.filter(members, &MapSet.member?(keyed, &1))
  end

  # The members whose column the change set leaves in the table, de-keyed or
  # not: what the rebuild writes a table-level key clause over.
  defp granted_key_columns(changes) do
    for {op, name, _type, opts} <- changes,
        op in [:add, :add_if_not_exists, :modify],
        Keyword.get(opts, :primary_key, false) == true,
        do: to_string(name)
  end

  # The one grant that is not a second key: a single-column key re-declared on
  # the very column it already sits on.
  defp grant_beside_kept_key?(_members, [], _granted), do: false

  defp grant_beside_kept_key?([_only], [kept], [granted]),
    do: not same_column_name?(kept, granted)

  defp grant_beside_kept_key?(_members, _survivors, _granted), do: true

  defp compare(table, expected, actual) do
    with :ok <- compare_columns(table, expected.columns, actual.columns),
         :ok <- compare_key_sort_order(table, expected, actual),
         :ok <- compare_one(table, :foreign_keys, expected, actual, :foreign_keys),
         :ok <- compare_one(table, :unique_constraints, expected, actual, :unique_constraints),
         :ok <- compare_one(table, :indexes, expected, actual, :indexes),
         :ok <- compare_one(table, :triggers, expected, actual, :triggers),
         :ok <- compare_one(table, :table_options, expected, actual, :table_options),
         :ok <- compare_one(table, :autoincrement, expected, actual, :autoincrement),
         :ok <- compare_rowid(table, expected.rowid, actual.rowid) do
      compare_sequence(table, expected.sequence, actual.sequence)
    end
  end

  # One-directional on purpose: every member the key keeps has to keep the
  # sort order the key gave it, but a key is free to lose its index entirely
  # by becoming the table's row id, which is SQLite's own doing rather than a
  # construct the rebuild dropped.
  defp compare_key_sort_order(table, expected, actual) do
    case descending(expected.primary_key_order) -- descending(actual.primary_key_order) do
      [] ->
        :ok

      _flattened ->
        {:error,
         mismatch(
           table,
           :primary_key_sort_order,
           nil,
           expected.primary_key_order,
           actual.primary_key_order
         )}
    end
  end

  defp descending(order), do: for(%{column: column, desc: true} <- order, do: column)

  defp compare_rowid(table, expected, actual) do
    case {expected, narrowed_rowid(expected, actual)} do
      {same, same} -> :ok
      {want, got} -> {:error, mismatch(table, :rowid, nil, want, got)}
    end
  end

  # The row ids themselves are only claimed when the prediction kept them;
  # the row count is the claim either way.
  defp narrowed_rowid(%{min: :not_compared}, actual),
    do: %{actual | min: :not_compared, max: :not_compared}

  defp narrowed_rowid(_expected, actual), do: actual

  # sqlite_sequence holds 0 after an insert statement that inserted no rows,
  # and no row at all before any insert ran — behaviorally identical states
  # (the next id is 1 either way), so the comparison must not tell them
  # apart: a rebuild's zero-row copy legitimately turns "no row" into 0.
  defp compare_sequence(table, expected, actual) do
    if normalized_sequence(expected) == normalized_sequence(actual) do
      :ok
    else
      {:error, mismatch(table, :sequence, nil, expected, actual)}
    end
  end

  defp normalized_sequence(nil), do: 0
  defp normalized_sequence(seq), do: seq

  defp compare_columns(table, expected, actual) do
    expected_names = Enum.map(expected, & &1.name)
    actual_names = Enum.map(actual, & &1.name)

    if expected_names == actual_names do
      compare_every_column(table, Enum.zip(expected, actual))
    else
      {:error, mismatch(table, :columns, nil, expected_names, actual_names)}
    end
  end

  defp compare_every_column(table, pairs) do
    Enum.reduce_while(pairs, :ok, fn {expected, actual}, _acc ->
      case compare_column(table, expected, actual) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp compare_column(table, expected, actual) do
    with :ok <- compare_aspect(table, :column_type, expected, actual, :type),
         :ok <- compare_aspect(table, :column_null, expected, actual, :notnull),
         :ok <- compare_aspect(table, :column_default, expected, actual, :default) do
      compare_aspect(table, :primary_key, expected, actual, :pk)
    end
  end

  defp compare_aspect(table, construct, expected, actual, key) do
    case {Map.fetch!(expected, key), Map.fetch!(actual, key)} do
      {same, same} -> :ok
      {want, got} -> {:error, mismatch(table, construct, expected.name, want, got)}
    end
  end

  defp compare_one(table, construct, expected, actual, key) do
    case {Map.fetch!(expected, key), Map.fetch!(actual, key)} do
      {same, same} -> :ok
      {want, got} -> {:error, mismatch(table, construct, nil, want, got)}
    end
  end

  defp mismatch(table, construct, column, expected, actual) do
    %RebuildVerificationError{
      table: table,
      construct: construct,
      column: column,
      expected: expected,
      actual: actual
    }
  end
end
