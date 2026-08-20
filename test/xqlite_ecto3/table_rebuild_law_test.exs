defmodule XqliteEcto3.TableRebuildLawTest do
  @moduledoc """
  The rule the opt-in table rebuild has to obey: a rebuilt table carries over
  every structural fact of the original one, changed only where the
  migration's own changes say so.

  Random tables (columns, types, NOT NULL, literal defaults, single or
  composite primary keys, AUTOINCREMENT, unique constraints, a
  self-referencing foreign key, a trigger, awkward identifiers) meet random
  change sets (modify with and without options, add, remove). Each pair runs
  a real rebuild against a real database file, and the structure read
  afterwards has to equal what `XqliteEcto3.RebuildVerification` predicts
  from the structure read before. Rows are seeded first, so the run also
  checks that the copy kept every row and every value it was not asked to
  touch.

  The second property covers the other side: a table declaring something a
  rebuild cannot reconstruct, or a change set that would take the primary key
  away entirely, has to raise before anything is dropped and leave the table
  exactly as it was.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Migration.Table
  alias XqliteEcto3.RebuildVerification

  defmodule LawRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  # Every run creates a table, seeds it, rebuilds it and reads its structure
  # twice. The house floor for property runs is 2000.
  @law_runs 2000
  @refusal_runs 2000

  @types ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC"]
  @modify_types [:integer, :string, :float, :binary, :decimal]

  # Identifier shapes SQLite accepts but code that forgets to quote does not:
  # mixed case, a reserved word, non-ASCII letters, an embedded double quote,
  # an embedded single quote, a space.
  @name_flavors ["plain", "Mixed", "select", "ünïcodé", ~s(quo"te), "it's", "spa ce"]
  @table_flavors ["", "_Mixed", "_ünï", ~s(_it's)]

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_rebuild_law_#{System.os_time(:nanosecond)}.db"
      )

    remove_database(database)

    config = [
      adapter: XqliteEcto3,
      database: database,
      pool_size: 1,
      support_alter_via_table_rebuild: true
    ]

    Application.put_env(:xqlite_ecto3, LawRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({LawRepo, config})

    on_exit(fn -> remove_database(database) end)

    :ok
  end

  defp remove_database(database) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
  end

  # --- the law ---------------------------------------------------------------

  # This property's first run caught a real drop: the rebuild used to decide
  # whether to write AUTOINCREMENT again by looking the table up in
  # sqlite_sequence, and SQLite only puts a row there on the first insert —
  # so rebuilding a never-written table silently lost the keyword and ids
  # became reusable (shrunk to one empty AUTOINCREMENT column at ExUnit
  # seed 1). The flag now comes from the stored CREATE text; empty tables
  # stay in the generator so the case can never quietly return.
  property "a rebuilt table carries over everything the changes did not touch" do
    check all(
            plan <- table_plan(),
            changes <- changes_for(plan),
            max_runs: @law_runs
          ) do
      create_table!(plan)
      seed_rows!(plan)

      kept = untouched_columns(plan, changes)
      before = read_structure(plan.table)
      rows_before = row_count(plan.table)
      values_before = column_values(plan.table, kept)

      assert {:ok, []} = alter(plan.table, changes)

      assert :ok = RebuildVerification.verify(before, changes, read_structure(plan.table))
      assert row_count(plan.table) == rows_before
      assert column_values(plan.table, kept) == values_before

      drop_table!(plan.table)
    end
  end

  # --- the refusals ----------------------------------------------------------

  property "a refused rebuild leaves the table exactly as it was" do
    check all(refusal <- refusal_case(), max_runs: @refusal_runs) do
      clean_up!(refusal)
      Enum.each(refusal.setup, fn sql -> LawRepo.query!(sql) end)

      before = read_structure(refusal.table)
      rows_before = row_count(refusal.table)

      assert_raise ArgumentError, fn -> alter(refusal.table, refusal.changes) end

      assert read_structure(refusal.table) == before
      assert row_count(refusal.table) == rows_before

      clean_up!(refusal)
    end
  end

  # --- driving the adapter ---------------------------------------------------

  defp alter(table, changes) do
    XqliteEcto3.execute_ddl(
      Ecto.Adapter.lookup_meta(LawRepo),
      {:alter, %Table{name: table}, changes},
      []
    )
  end

  defp read_structure(table) do
    RebuildVerification.read(table, fn sql, params ->
      %{rows: rows} = LawRepo.query!(sql, params)
      rows
    end)
  end

  defp row_count(table) do
    %{rows: [[count]]} = LawRepo.query!("SELECT count(*) FROM #{quoted(table)}")
    count
  end

  defp column_values(_table, []), do: []

  # Sorted, because a rebuild preserves rows and not their physical order: a
  # table whose row id came from a column the migration re-types gets fresh
  # row ids from the copy.
  defp column_values(table, columns) do
    list = Enum.map_join(columns, ", ", &quoted/1)
    %{rows: rows} = LawRepo.query!("SELECT #{list} FROM #{quoted(table)}")
    Enum.sort(rows)
  end

  defp create_table!(plan) do
    drop_table!(plan.table)
    LawRepo.query!(create_table_sql(plan))
    Enum.each(plan.uniques, fn unique -> create_unique_index!(plan, unique) end)
    create_trigger!(plan)
  end

  defp create_unique_index!(_plan, %{form: :table_level}), do: :ok

  defp create_unique_index!(plan, %{form: :index, name: name, columns: columns}) do
    LawRepo.query!(
      "CREATE UNIQUE INDEX #{quoted(name)} ON #{quoted(plan.table)} " <>
        "(#{index_column_list(columns)})"
    )
  end

  defp create_trigger!(%{trigger: nil}), do: :ok

  defp create_trigger!(plan) do
    LawRepo.query!(
      "CREATE TRIGGER #{quoted(plan.trigger)} AFTER INSERT ON #{quoted(plan.table)} " <>
        "BEGIN SELECT 1; END"
    )
  end

  defp drop_table!(table), do: LawRepo.query!("DROP TABLE IF EXISTS #{quoted(table)}")

  defp clean_up!(refusal), do: Enum.each(refusal.cleanup, fn sql -> LawRepo.query!(sql) end)

  # The row count is generated, empty tables included: a table that has never
  # been written to is a normal thing to alter in the first migration that
  # touches it.
  defp seed_rows!(%{seeded_rows: 0}), do: :ok

  defp seed_rows!(plan) do
    names = Enum.map_join(plan.columns, ", ", fn col -> quoted(col.name) end)
    holes = Enum.map_join(1..length(plan.columns), ", ", fn i -> "?#{i}" end)
    sql = "INSERT INTO #{quoted(plan.table)} (#{names}) VALUES (#{holes})"

    Enum.each(1..plan.seeded_rows, fn row ->
      LawRepo.query!(sql, Enum.map(plan.columns, fn col -> seed_value(plan, col, row) end))
    end)
  end

  # Every column gets a distinct value that any of the generated type changes
  # can carry: a change set may narrow a composite key down to one column,
  # which makes that column the table's row id, and only whole numbers fit
  # there. The self-referencing foreign key points every row at itself, so no
  # column is ever null and a NOT NULL change is always satisfiable.
  defp seed_value(%{fk: %{column: name}}, %{name: name}, row), do: row
  defp seed_value(_plan, %{type: "TEXT"}, row), do: "#{row}"
  defp seed_value(_plan, %{type: "BLOB"}, row), do: "#{row}"
  defp seed_value(_plan, %{type: "REAL"}, row), do: row * 1.0
  defp seed_value(_plan, _col, row), do: row

  # --- SQL for the generated table -------------------------------------------

  defp create_table_sql(plan) do
    definitions =
      Enum.map(plan.columns, fn col -> column_sql(plan, col) end) ++
        composite_key_sql(plan) ++ table_unique_sql(plan) ++ foreign_key_sql(plan)

    "CREATE TABLE #{quoted(plan.table)} (#{Enum.join(definitions, ", ")})"
  end

  defp column_sql(plan, col) do
    [
      quoted(col.name),
      " ",
      col.type,
      if(col.notnull, do: " NOT NULL", else: ""),
      default_sql(col.default),
      inline_key_sql(plan, col)
    ]
    |> Enum.join()
  end

  defp default_sql(nil), do: ""
  defp default_sql({:integer, value}), do: " DEFAULT #{value}"
  defp default_sql({:text, value}), do: " DEFAULT #{quoted_literal(value)}"

  defp inline_key_sql(%{key_members: [name], autoincrement: true}, %{name: name}),
    do: " PRIMARY KEY AUTOINCREMENT"

  defp inline_key_sql(%{key_members: [name]}, %{name: name}), do: " PRIMARY KEY"
  defp inline_key_sql(_plan, _col), do: ""

  defp composite_key_sql(%{key_members: [_first, _second | _rest] = members}) do
    ["PRIMARY KEY (#{Enum.map_join(members, ", ", &quoted/1)})"]
  end

  defp composite_key_sql(_plan), do: []

  defp table_unique_sql(plan) do
    for %{form: :table_level, columns: columns} <- plan.uniques,
        do: "UNIQUE (#{index_column_list(columns)})"
  end

  defp foreign_key_sql(%{fk: nil}), do: []

  defp foreign_key_sql(plan) do
    %{column: column, target: target, on_delete: on_delete} = plan.fk

    [
      "FOREIGN KEY (#{quoted(column)}) REFERENCES #{quoted(plan.table)} " <>
        "(#{quoted(target)}) ON DELETE #{on_delete}"
    ]
  end

  defp index_column_list(columns) do
    Enum.map_join(columns, ", ", fn
      %{name: name, desc: true} -> "#{quoted(name)} DESC"
      %{name: name} -> quoted(name)
    end)
  end

  defp quoted(name), do: ~s|"| <> String.replace(to_string(name), ~s|"|, ~s|""|) <> ~s|"|

  defp quoted_literal(value),
    do: ~s|'| <> String.replace(to_string(value), ~s|'|, ~s|''|) <> ~s|'|

  # --- generators ------------------------------------------------------------

  defp table_plan do
    gen all(
          suffix <- string(:alphanumeric, min_length: 4, max_length: 8),
          table_flavor <- member_of(@table_flavors),
          count <- integer(1..6),
          flavors <- list_of(member_of(@name_flavors), length: 6),
          types <- list_of(member_of(@types), length: 6),
          notnulls <- list_of(boolean(), length: 6),
          defaults <- list_of(default_literal(), length: 6),
          composite_key? <- boolean(),
          autoincrement? <- boolean(),
          unique_specs <- list_of(unique_spec(), max_length: 2),
          self_fk? <- boolean(),
          on_delete <- member_of(["CASCADE", "SET NULL", "NO ACTION", "RESTRICT"]),
          trigger? <- boolean(),
          seeded_rows <- integer(0..3)
        ) do
      build_plan(%{
        table: "law_#{suffix}#{table_flavor}",
        count: count,
        flavors: flavors,
        types: types,
        notnulls: notnulls,
        defaults: defaults,
        composite_key?: composite_key?,
        autoincrement?: autoincrement?,
        unique_specs: unique_specs,
        self_fk?: self_fk?,
        on_delete: on_delete,
        trigger?: trigger?,
        seeded_rows: seeded_rows
      })
    end
  end

  defp default_literal do
    one_of([
      constant(nil),
      map(integer(-1000..1000), fn value -> {:integer, value} end),
      map(member_of(["plain", "it's", "ünïcodé", ""]), fn value -> {:text, value} end)
    ])
  end

  defp unique_spec do
    gen all(
          form <- member_of([:table_level, :index]),
          offset <- integer(0..5),
          size <- integer(1..2),
          desc? <- boolean()
        ) do
      %{form: form, offset: offset, size: size, desc?: desc?}
    end
  end

  # Columns come first, then the shape of the key over them, then the
  # constructs that need columns to point at. Everything a construct depends
  # on is protected from removal, so a generated change set can never produce
  # SQL the engine has no way to write.
  defp build_plan(raw) do
    base = base_columns(raw)
    {key_members, autoincrement?} = key_shape(raw, base)
    fk = foreign_key(raw, base, key_members)
    columns = base ++ fk_column(fk)
    uniques = unique_constraints(raw, columns, key_members, fk)

    %{
      table: raw.table,
      columns: columns,
      key_members: key_members,
      autoincrement: autoincrement?,
      uniques: uniques,
      fk: fk,
      trigger: if(raw.trigger?, do: "#{raw.table}_trg"),
      protected: protected_columns(key_members, uniques, fk),
      seeded_rows: raw.seeded_rows
    }
  end

  defp base_columns(raw) do
    raw.flavors
    |> Enum.take(raw.count)
    |> Enum.with_index(1)
    |> Enum.map(fn {flavor, index} ->
      %{
        name: "#{flavor}_#{index}",
        type: Enum.at(raw.types, index - 1),
        notnull: Enum.at(raw.notnulls, index - 1),
        default: Enum.at(raw.defaults, index - 1)
      }
    end)
    |> key_columns_plain()
  end

  # The key columns are declared as a plain INTEGER / TEXT column with no
  # NOT NULL and no default, so the key clause is the only thing that varies.
  defp key_columns_plain([first | rest]) do
    [%{first | type: "INTEGER", notnull: false, default: nil} | plain_second(rest)]
  end

  defp plain_second([]), do: []
  defp plain_second([second | rest]), do: [%{second | notnull: false, default: nil} | rest]

  defp key_shape(%{composite_key?: true}, [first, second | _rest]) do
    {[first.name, second.name], false}
  end

  defp key_shape(raw, [first | _rest]), do: {[first.name], raw.autoincrement?}

  # A self-reference needs a single-column key to point at.
  defp foreign_key(%{self_fk?: true, on_delete: on_delete}, _base, [target]) do
    %{column: "parent_ref", target: target, on_delete: on_delete}
  end

  defp foreign_key(_raw, _base, _key_members), do: nil

  defp fk_column(nil), do: []

  defp fk_column(%{column: name}),
    do: [%{name: name, type: "INTEGER", notnull: false, default: nil}]

  # A unique constraint over a column the change set later removes would be
  # unwritable, so the columns it covers join the protected set below.
  defp unique_constraints(raw, columns, key_members, fk) do
    eligible = Enum.reject(columns, fn col -> col.name in key_members or fk_column?(fk, col) end)

    raw.unique_specs
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, index} -> unique_constraint(raw, spec, eligible, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp unique_constraint(_raw, _spec, [], _index), do: nil

  defp unique_constraint(raw, spec, eligible, index) do
    start = rem(spec.offset, length(eligible))

    columns =
      eligible
      |> Enum.slice(start, spec.size)
      |> Enum.with_index()
      |> Enum.map(fn {col, position} ->
        %{name: col.name, desc: spec.desc? and position == 0}
      end)

    %{form: spec.form, name: "#{raw.table}_u#{index}", columns: columns}
  end

  defp fk_column?(nil, _col), do: false
  defp fk_column?(%{column: name}, %{name: name}), do: true
  defp fk_column?(_fk, _col), do: false

  defp protected_columns(key_members, uniques, fk) do
    unique_columns = for unique <- uniques, col <- unique.columns, do: col.name
    fk_columns = if fk, do: [fk.column, fk.target], else: []

    MapSet.new(unique_columns ++ fk_columns ++ single_key_member(key_members))
  end

  # A composite key may lose members as long as one survives; a single-column
  # key has nothing to spare.
  defp single_key_member([only]), do: [only]
  defp single_key_member(_members), do: []

  # Only a `modify` sends an alter block through the rebuild — a block of
  # plain adds and removes is an ordinary ALTER TABLE — so every change set
  # starts with one.
  defp changes_for(plan) do
    removable = Enum.reject(plan.columns, fn col -> MapSet.member?(plan.protected, col.name) end)

    gen all(
          first <- modify_change(plan),
          rest <- list_of(change(plan, removable), max_length: 2)
        ) do
      normalize_changes(plan, [first | rest])
    end
  end

  defp change(plan, removable) do
    frequency(
      [{3, add_change()}, {4, modify_change(plan)}] ++ weighted(removable, 2, &remove_change/1)
    )
  end

  defp weighted([], _weight, _builder), do: []
  defp weighted(pool, weight, builder), do: [{weight, builder.(pool)}]

  defp modify_change(plan) do
    gen all(
          col <- member_of(plan.columns),
          type <- modify_type(plan, col),
          null_opt <- one_of([constant([]), map(boolean(), &[null: &1])]),
          default_opt <- one_of([constant([]), map(change_default(), &[default: &1])])
        ) do
      {:modify, col.name, type, null_opt ++ default_opt}
    end
  end

  defp modify_type(plan, col) do
    if pinned_type?(plan, col) do
      constant(:integer)
    else
      member_of(@modify_types)
    end
  end

  # Two columns keep their declared type because the table's own constraints
  # depend on it: AUTOINCREMENT is legal only on an INTEGER primary key, and
  # both ends of the self-reference have to keep comparing equal once the copy
  # has re-typed the values. Their other aspects still change freely.
  defp pinned_type?(plan, col) do
    (plan.autoincrement and col.name in plan.key_members) or fk_endpoint?(plan.fk, col)
  end

  defp fk_endpoint?(nil, _col), do: false
  defp fk_endpoint?(%{column: name}, %{name: name}), do: true
  defp fk_endpoint?(%{target: name}, %{name: name}), do: true
  defp fk_endpoint?(_fk, _col), do: false

  defp change_default do
    one_of([
      constant(nil),
      integer(-500..500),
      member_of(["plain", "ünïcodé", "it's", ""])
    ])
  end

  defp add_change do
    gen all(
          flavor <- member_of(@name_flavors),
          type <- member_of(@modify_types)
        ) do
      {:add, "#{flavor}_added", type, []}
    end
  end

  defp remove_change(removable) do
    gen all(
          col <- member_of(removable),
          long_form? <- boolean()
        ) do
      if long_form? do
        {:remove, col.name, :integer, []}
      else
        {:remove, col.name}
      end
    end
  end

  # Two adds can draw the same name, and a run of removals can empty the
  # table or its key. Rewriting the list here keeps every generated change set
  # something a migration could really ask for.
  defp normalize_changes(plan, changes) do
    state = %{names: Enum.map(plan.columns, & &1.name), key_members: plan.key_members}
    {normalized, _state} = Enum.flat_map_reduce(changes, state, &normalize_change/2)

    case normalized do
      [] -> [{:add, "law_fallback", :string, []}]
      list -> list
    end
  end

  defp normalize_change({:add, name, type, opts}, state) do
    unique = unique_name(name, state.names)
    {[{:add, unique, type, opts}], %{state | names: state.names ++ [unique]}}
  end

  defp normalize_change({:remove, name, type, opts}, state) do
    normalize_removal({:remove, name, type, opts}, name, state)
  end

  defp normalize_change({:remove, name}, state) do
    normalize_removal({:remove, name}, name, state)
  end

  defp normalize_change(change, state), do: {[change], state}

  defp normalize_removal(change, name, state) do
    remaining = state.names -- [name]
    surviving_key = state.key_members -- [name]

    cond do
      name not in state.names -> {[change], state}
      remaining == [] -> {[], state}
      state.key_members != [] and surviving_key == [] -> {[], state}
      true -> {[change], %{state | names: remaining, key_members: surviving_key}}
    end
  end

  defp unique_name(name, taken) do
    if name in taken do
      unique_name(name <> "_x", taken)
    else
      name
    end
  end

  defp untouched_columns(plan, changes) do
    touched =
      changes
      |> Enum.map(&touched_column/1)
      |> Enum.reject(&is_nil/1)

    plan.columns
    |> Enum.map(& &1.name)
    |> Enum.reject(fn name -> name in touched end)
  end

  defp touched_column({:modify, name, _type, _opts}), do: name
  defp touched_column({:remove, name, _type, _opts}), do: name
  defp touched_column({:remove, name}), do: name
  defp touched_column(_change), do: nil

  # --- refusals --------------------------------------------------------------

  @refusal_flavors [
    :check,
    :collate,
    :generated,
    :deferrable,
    :on_conflict,
    :without_rowid,
    :strict,
    :dependent_view,
    :key_removed_single,
    :key_removed_composite
  ]

  defp refusal_case do
    gen all(
          flavor <- member_of(@refusal_flavors),
          suffix <- string(:alphanumeric, min_length: 4, max_length: 8),
          name_flavor <- member_of(@name_flavors)
        ) do
      build_refusal(flavor, "refuse_#{suffix}", "#{name_flavor}_v")
    end
  end

  defp build_refusal(flavor, table, column) do
    refusal = refusal_shape(flavor, table, column)

    %{
      table: table,
      setup: refusal.setup ++ [refusal_insert(flavor, table, column)],
      cleanup: refusal.cleanup ++ ["DROP TABLE IF EXISTS #{quoted(table)}"],
      changes: refusal.changes
    }
  end

  defp refusal_shape(:check, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, " <>
          "CHECK (#{quoted(column)} <> 'bad'))"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:collate, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, " <>
          "#{quoted(column)} TEXT COLLATE NOCASE)"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:generated, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, " <>
          "doubled INTEGER GENERATED ALWAYS AS (id * 2) VIRTUAL)"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:deferrable, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, " <>
          "parent INTEGER REFERENCES #{quoted(table)} (id) DEFERRABLE INITIALLY DEFERRED)"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:on_conflict, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, " <>
          "sku TEXT, UNIQUE (sku) ON CONFLICT REPLACE)"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:without_rowid, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (k TEXT PRIMARY KEY, #{quoted(column)} TEXT) WITHOUT ROWID"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:strict, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT) STRICT"
      ],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:dependent_view, table, column) do
    view = "#{table}_view"

    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT)",
        "CREATE VIEW #{quoted(view)} AS SELECT id FROM #{quoted(table)}"
      ],
      cleanup: ["DROP VIEW IF EXISTS #{quoted(view)}"],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:key_removed_single, table, column) do
    %{
      setup: ["CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT)"],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}, {:remove, "id", :integer, []}]
    }
  end

  defp refusal_shape(:key_removed_composite, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (a INTEGER, b TEXT, #{quoted(column)} TEXT, " <>
          "PRIMARY KEY (a, b))"
      ],
      cleanup: [],
      changes: [
        {:modify, column, :string, [null: true]},
        {:remove, "a", :integer, []},
        {:remove, "b", :string, []}
      ]
    }
  end

  defp refusal_insert(:without_rowid, table, column) do
    "INSERT INTO #{quoted(table)} (k, #{quoted(column)}) VALUES ('k1', 'v1')"
  end

  defp refusal_insert(:key_removed_composite, table, column) do
    "INSERT INTO #{quoted(table)} (a, b, #{quoted(column)}) VALUES (1, 'b1', 'v1')"
  end

  defp refusal_insert(_flavor, table, column) do
    "INSERT INTO #{quoted(table)} (id, #{quoted(column)}) VALUES (1, 'v1')"
  end
end
