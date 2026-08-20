defmodule XqliteEcto3.EscapeRoundtripLawTest do
  @moduledoc """
  The rule every place that writes user text into SQL has to obey: what
  the adapter puts in is what SQLite gives back, byte for byte.

  The adapter builds SQL text in several independent places, and each one
  has its own escaping rule. A string literal doubles the single quote and
  leaves everything else alone. A quoted name doubles the double quote. A
  JSON object key sits inside a string literal *and* inside JSON's own
  quoted-key grammar, so it needs both. Getting any of them wrong is
  either an injection or, worse, a silently wrong answer.

  Every property here uses a live database as the judge. Nothing in this
  file re-implements an escaping rule and compares strings: text goes in
  through the adapter, and the assertion is what SQLite hands back. Where
  a name has to be read back out, the read binds it as a query parameter
  (`pragma_table_info(?)`, `sqlite_schema WHERE name = ?`) so the only
  quoting anywhere in the loop is the adapter's own.

  The laws, one per property:

    1. A string the adapter inlines into a query comes back equal to
       itself, and matches only the row that really holds it.
    2. A string written as a column DEFAULT in `CREATE TABLE` is the value
       a row gets when it does not supply one.
    3. A generated table name and column name survive `CREATE TABLE`:
       SQLite reports both back unchanged, and a query naming them finds
       the row.
    4. A table rebuild writes both a column DEFAULT and the table's own
       name into string literals; after the rebuild the default is intact
       and `sqlite_sequence` holds exactly the rows it held before, under
       the same names and with the same counters.
    5. Violating a uniquely named index reports that index's real name on
       the error, for any table name and any index name.
    6. A foreign-key violation reports the child table's own column names,
       for any table and column name.
    7. A JSON object key resolves to its value through both path forms —
       the one built when the key is known while the query is compiled,
       and the one built by SQL at run time from a column value.

  Table and column names in the rebuild law are already covered by
  `XqliteEcto3.TableRebuildLawTest`; this file covers the values that law
  does not generate.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ecto.Query

  alias Ecto.Migration.Index
  alias Ecto.Migration.Reference
  alias Ecto.Migration.Table
  alias XqliteEcto3.Connection, as: Conn
  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteEcto3.Error.FkViolation

  defmodule EscapeRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule JsonDoc do
    use Ecto.Schema

    schema "esc_json_docs" do
      field(:label, :string)
      field(:meta, :map)
    end
  end

  # Run counts are set so the whole file stays around ten seconds. The
  # cheap laws run one or two statements per case; the rebuild law runs a
  # whole table copy plus about thirty schema reads, so it gets the
  # smallest budget.
  @literal_runs 3000
  @default_runs 2000
  @identifier_runs 2000
  @rebuild_runs 2000
  @unique_runs 2000
  @fk_runs 2000
  @json_runs 3000

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_escape_law_#{System.os_time(:nanosecond)}.db"
      )

    remove_database(database)

    config = [
      adapter: XqliteEcto3,
      database: database,
      pool_size: 1,
      support_alter_via_table_rebuild: true,
      rich_fk_diagnostics: true
    ]

    Application.put_env(:xqlite_ecto3, EscapeRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({EscapeRepo, config})

    # Neither fixed table uses AUTOINCREMENT, so the only row the rebuild
    # law can ever see in sqlite_sequence is the one it made itself.
    EscapeRepo.query!("CREATE TABLE esc_literals (id INTEGER PRIMARY KEY, v TEXT)", [])

    EscapeRepo.query!(
      "CREATE TABLE esc_json_docs (id INTEGER PRIMARY KEY, label TEXT, meta TEXT)",
      []
    )

    on_exit(fn -> remove_database(database) end)

    :ok
  end

  defp remove_database(database) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
  end

  # --- 1. string literals on the query path ----------------------------------

  # Drives `XqliteEcto3.Connection`'s string-literal escaping through two
  # public query routes: `constant/1` in a fragment puts the text in the
  # select list, and comparing a column against a fragment puts it in a
  # WHERE. The second half is the one that catches over-escaping — a
  # backslash doubled on the way in still parses as SQL, it just stops
  # matching the row it was supposed to find.
  property "an inlined string literal comes back equal to itself" do
    check all(value <- exotic_text(), max_runs: @literal_runs) do
      EscapeRepo.query!("DELETE FROM esc_literals", [])
      EscapeRepo.query!("INSERT INTO esc_literals (id, v) VALUES (1, ?)", [value])
      EscapeRepo.query!("INSERT INTO esc_literals (id, v) VALUES (2, ?)", [value <> "x"])

      selected =
        EscapeRepo.one(
          from(t in "esc_literals", where: t.id == 1, select: fragment("?", constant(^value)))
        )

      assert selected == value

      matched =
        EscapeRepo.all(
          from(t in "esc_literals",
            where: t.v == fragment("?", constant(^value)),
            select: t.id
          )
        )

      assert matched == [1]
    end
  end

  # --- 2. string literals on the create-table path ---------------------------

  # Drives the same escaping through the DDL emitter, which writes column
  # defaults as literals rather than as bound parameters.
  property "a column default written into DDL is the value a row gets" do
    check all(value <- exotic_text(), max_runs: @default_runs) do
      ddl!({:drop_if_exists, %Table{name: "esc_defaults"}, :restrict})
      ddl!({:create, %Table{name: "esc_defaults"}, [{:add, :v, :string, [default: value]}]})

      EscapeRepo.query!("INSERT INTO #{quoted_table("esc_defaults")} DEFAULT VALUES", [])

      assert EscapeRepo.one(from(t in "esc_defaults", select: t.v)) == value
    end
  end

  # --- 3. identifiers on the query path --------------------------------------

  # The table is created by the adapter's own DDL, both names are read
  # back with the name bound as a parameter, and the row is fetched by a
  # real Ecto query whose source and column the adapter quotes. The insert
  # in the middle uses `quote_table/1` and `quote_name/1`, which the
  # Connection module exports.
  property "a generated table and column name survive a round trip" do
    check all(
            suffix <- exotic_identifier(),
            column <- exotic_identifier(),
            value <- exotic_text(),
            max_runs: @identifier_runs
          ) do
      table = "esc " <> suffix

      ddl!({:drop_if_exists, %Table{name: table}, :restrict})
      ddl!({:create, %Table{name: table}, [{:add, column, :string, []}]})

      assert table_names(table) == [table]
      assert column_names(table) == [column]

      EscapeRepo.query!(
        "INSERT INTO #{quoted_table(table)} (#{quoted_name(column)}) VALUES (?)",
        [value]
      )

      read_back = EscapeRepo.all(from(t in table, select: fragment("?", identifier(^column))))

      assert read_back == [value]

      ddl!({:drop, %Table{name: table}})
    end
  end

  # --- 4. string literals on the rebuild path --------------------------------

  # A rebuild writes two kinds of string literal: the new column's DEFAULT,
  # and the table's own name into the sqlite_sequence rows that carry the
  # AUTOINCREMENT counter across the copy. A mangled name literal would
  # leave the pre-rebuild row in place and add a second one, so the whole
  # table is compared, not just the counter.
  property "a rebuild writes string literals SQLite reads back unchanged" do
    check all(
            suffix <- exotic_identifier(),
            value <- exotic_text(),
            max_runs: @rebuild_runs
          ) do
      table = "esc " <> suffix

      ddl!({:drop_if_exists, %Table{name: table}, :restrict})

      ddl!(
        {:create, %Table{name: table},
         [{:add, :id, :serial, [primary_key: true]}, {:add, :note, :string, []}]}
      )

      EscapeRepo.query!(
        "INSERT INTO #{quoted_table(table)} (#{quoted_name(:note)}) VALUES (?)",
        ["seed"]
      )

      sequence_before = sequence_rows()

      assert {:ok, []} = rebuild(table, [{:modify, "note", :string, [default: value]}])

      # Same names, same counters. A mangled name literal would delete
      # nothing and add a row, so the set would grow.
      assert sequence_rows() == sequence_before

      EscapeRepo.query!("INSERT INTO #{quoted_table(table)} DEFAULT VALUES", [])

      defaulted =
        EscapeRepo.one(from(t in table, order_by: [desc: t.id], limit: 1, select: t.note))

      assert defaulted == value

      ddl!({:drop, %Table{name: table}})
    end
  end

  # --- 5. identifiers on the unique-violation path ---------------------------

  # SQLite names only the table and column in a UNIQUE violation, so the
  # adapter reads the index names back with `PRAGMA index_list` and
  # `PRAGMA index_info`, both of which take the name spliced into the
  # pragma text. Getting the real name back on the error struct is the
  # round trip.
  property "a unique violation reports the real index name" do
    check all(
            suffix <- separator_free_identifier(),
            index_name <- exotic_identifier(),
            index_name != "esc " <> suffix,
            value <- exotic_text(),
            max_runs: @unique_runs
          ) do
      table = "esc " <> suffix

      ddl!({:drop_if_exists, %Table{name: table}, :restrict})
      ddl!({:create, %Table{name: table}, [{:add, :v, :string, []}]})
      ddl!({:create, %Index{table: table, name: index_name, columns: [:v], unique: true}})

      insert = "INSERT INTO #{quoted_table(table)} (#{quoted_name(:v)}) VALUES (?)"
      EscapeRepo.query!(insert, [value])

      assert {:error, %Error{details: details}} = EscapeRepo.query(insert, [value])

      assert %Constraint{
               subtype: :constraint_unique,
               table: ^table,
               columns: ["v"],
               unique_index_names: [^index_name],
               unique_index_lookup: :ok
             } = details

      ddl!({:drop, %Table{name: table}})
    end
  end

  # --- 6. identifiers on the foreign-key-violation path ----------------------

  # The other place a name is spliced into a pragma: the child table's name
  # goes into `PRAGMA foreign_key_list` to work out which columns the
  # violated key covers. Those columns coming back on the error struct is
  # the round trip.
  property "a foreign-key violation reports the child table's own columns" do
    check all(
            parent_suffix <- exotic_identifier(),
            child_suffix <- exotic_identifier(),
            # The child table already declares its own `id` primary key, and
            # SQLite matches column names case-insensitively — a generated
            # column of that name is a duplicate column, not an escaping case.
            column <-
              filter(exotic_identifier(), fn c -> String.downcase(c, :ascii) != "id" end),
            max_runs: @fk_runs
          ) do
      parent = "esc p " <> parent_suffix
      child = "esc c " <> child_suffix

      ddl!({:drop_if_exists, %Table{name: child}, :restrict})
      ddl!({:drop_if_exists, %Table{name: parent}, :restrict})
      ddl!({:create, %Table{name: parent}, [{:add, :id, :integer, [primary_key: true]}]})

      ddl!(
        {:create, %Table{name: child},
         [
           {:add, :id, :integer, [primary_key: true]},
           {:add, column, %Reference{table: parent, column: "id", type: :integer}, []}
         ]}
      )

      result =
        EscapeRepo.query(
          "INSERT INTO #{quoted_table(child)} (id, #{quoted_name(column)}) VALUES (1, 999)",
          []
        )

      assert {:error, %Error{details: details}} = result

      assert %Constraint{
               subtype: :constraint_foreign_key,
               fk_diagnostics: :ok,
               fk_violations: [
                 %FkViolation{
                   child_table: ^child,
                   parent_table: ^parent,
                   child_columns: [^column],
                   parent_columns: ["id"]
                 }
               ]
             } = details

      ddl!({:drop, %Table{name: child}})
      ddl!({:drop, %Table{name: parent}})
    end
  end

  # --- 7. JSON object keys ---------------------------------------------------

  # Two different escapings, one law. A key known while the query is
  # compiled is escaped once, into the path literal. A key that arrives at
  # run time from a column is escaped by SQL itself, with nested
  # `replace()` calls the adapter emits. Both have to find the same value.
  # The example-based cases in `json_extract_path_test.exs` stay as they
  # are; this generalizes them.
  property "a JSON object key resolves through both path forms" do
    check all(
            key <- exotic_text(),
            value <- exotic_text(),
            max_runs: @json_runs
          ) do
      EscapeRepo.query!("DELETE FROM esc_json_docs", [])
      {:ok, _doc} = EscapeRepo.insert(%JsonDoc{label: key, meta: %{key => value}})

      assert EscapeRepo.one(from(d in JsonDoc, select: d.meta[^key])) == value
      assert EscapeRepo.one(from(d in JsonDoc, select: d.meta[d.label])) == value
    end
  end

  # --- driving the adapter ---------------------------------------------------

  defp ddl!(command) do
    command
    |> Conn.execute_ddl()
    |> Enum.each(fn statement -> EscapeRepo.query!(IO.iodata_to_binary(statement), []) end)
  end

  defp rebuild(table, changes) do
    XqliteEcto3.execute_ddl(
      Ecto.Adapter.lookup_meta(EscapeRepo),
      {:alter, %Table{name: table}, changes},
      []
    )
  end

  defp quoted_table(name) do
    name
    |> Conn.quote_table()
    |> IO.iodata_to_binary()
  end

  defp quoted_name(name) do
    name
    |> Conn.quote_name()
    |> IO.iodata_to_binary()
  end

  # --- reading names back ----------------------------------------------------

  defp table_names(table) do
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?"
    |> query_rows([table])
    |> List.flatten()
  end

  defp column_names(table) do
    "SELECT name FROM pragma_table_info(?)"
    |> query_rows([table])
    |> List.flatten()
  end

  # Sorted, because sqlite_sequence is an ordinary table: rewriting a row
  # moves it to the end.
  defp sequence_rows do
    "SELECT name, seq FROM sqlite_sequence"
    |> query_rows([])
    |> Enum.sort()
  end

  defp query_rows(sql, params) do
    %{rows: rows} = EscapeRepo.query!(sql, params)
    rows
  end

  # --- generators ------------------------------------------------------------

  # Chunks picked to break careless escaping: both SQL quote characters and
  # their doubled forms, a backslash (an ordinary character to SQLite, so
  # doubling it corrupts the value), comment and statement punctuation,
  # parameter markers, the characters SQLite's JSON path grammar treats as
  # structural, whitespace and control characters, non-Latin scripts, and
  # words SQLite reserves.
  #
  # A NUL byte is deliberately absent. Every surface tested here splices
  # text into SQL, and xqlite refuses SQL text carrying a NUL before it
  # reaches SQLite — `reject_interior_nul/1` in xqlite's
  # `native/xqlitenif/src/query.rs` returns `:null_byte_in_string`, because
  # SQLite's tokenizer stops at the first NUL and would otherwise run a
  # silently truncated statement. A NUL inside a *bound parameter* is fine
  # and already covered by `unicode_binary_test.exs`.
  @chunks [
    "'",
    "''",
    "\"",
    "\"\"",
    "\\",
    "\\\\",
    "\\'",
    "\\\"",
    ",",
    ".",
    ";",
    ":",
    "--",
    "/*",
    "*/",
    "$",
    "?",
    "?1",
    "%",
    "_",
    "[",
    "]",
    "(",
    ")",
    "`",
    "|",
    "=",
    "*",
    "#",
    "@",
    "&",
    " ",
    "  ",
    "\t",
    "\n",
    "\r",
    "ünï",
    "日本語",
    "Ελληνικά",
    "😀",
    "ß",
    "İ",
    "select",
    "FROM",
    "where",
    "table",
    "index",
    "order",
    "group",
    "null",
    "rowid",
    "primary key",
    "DROP TABLE",
    "1=1",
    "0",
    "123",
    "x'41'"
  ]

  # `string(:printable, ...)` never emits a NUL: StreamData's printable set
  # is the escape characters plus the printable ranges from 0x20 up.
  defp text_chunk do
    frequency([
      {6, member_of(@chunks)},
      {2, string(:printable, max_length: 3)},
      {1, string(:alphanumeric, min_length: 1, max_length: 4)}
    ])
  end

  defp exotic_text do
    gen all(parts <- list_of(text_chunk(), max_length: 4)) do
      Enum.join(parts)
    end
  end

  defp exotic_identifier do
    filter(exotic_text(), fn text -> text != "" end)
  end

  # SQLite reports a UNIQUE violation as plain text — `table.column`, with
  # `, ` between the entries when the index covers several columns — and
  # xqlite splits that text back apart (`parse_table_columns` in xqlite's
  # `native/xqlitenif/src/constraint_parse.rs`, which splits on `, ` and
  # then on the first `.`). A table name carrying either separator makes the
  # split land in the wrong place, and the error then names a table and
  # columns that are not in the schema. That is message parsing, not name
  # quoting: the table is created correctly, the index fires, and the index
  # name is still recovered. So this generator keeps both separators out
  # and leaves the message question to the parser's own tests.
  defp separator_free_identifier do
    filter(exotic_identifier(), fn text ->
      not String.contains?(text, ".") and not String.contains?(text, ", ")
    end)
  end
end
