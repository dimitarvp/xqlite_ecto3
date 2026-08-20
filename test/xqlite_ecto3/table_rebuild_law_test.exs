defmodule XqliteEcto3.TableRebuildLawTest do
  @moduledoc """
  The rule the opt-in table rebuild has to obey: a rebuilt table carries over
  every structural fact of the original one, changed only where the
  migration's own changes say so.

  Random tables (columns, types, NOT NULL, literal and expression defaults,
  single or composite primary keys with their sort order, AUTOINCREMENT in
  each of its spellings, unique constraints, a self-referencing foreign key,
  a trigger, awkward identifiers) meet random change sets: modify with and
  without options, add, remove, the conditional add and remove, defaults of
  every shape a migration can give, names spelled in any ASCII case, and the
  grant that moves the primary key to another column. Each pair runs a real
  rebuild against a real database file, and the structure read afterwards
  has to equal what `XqliteEcto3.RebuildVerification` predicts from the
  structure read before. Rows are seeded first, so the run also checks that
  the copy kept every row and every value it was not asked to touch.

  The second property covers the other side: a table declaring something a
  rebuild cannot reconstruct, a change set that would take the primary key
  away entirely or ask one table for two keys, and a removal that would
  strand a constraint, an index or a trigger — each has to raise before
  anything is dropped and leave the table exactly as it was.
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

  # SQLite resolves a column name by folding ASCII case and nothing else, so
  # a change may spell a stored name any of these ways and still reach it.
  @spellings [:stored, :upper, :lower, :swapped]

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
  defp default_sql({:expression, expression}), do: " DEFAULT (#{expression})"

  # A single-column key carries its sort order inline, and the AUTOINCREMENT
  # spellings the grammar allows put a sort order between the two keywords.
  defp inline_key_sql(%{key_members: [name]} = plan, %{name: name}), do: single_key_sql(plan)
  defp inline_key_sql(_plan, _col), do: ""

  defp single_key_sql(%{autoincrement: true, key_direction: :asc}),
    do: " PRIMARY KEY ASC AUTOINCREMENT"

  defp single_key_sql(%{autoincrement: true}), do: " PRIMARY KEY AUTOINCREMENT"
  defp single_key_sql(%{key_direction: :asc}), do: " PRIMARY KEY ASC"
  defp single_key_sql(%{key_direction: :desc}), do: " PRIMARY KEY DESC"
  defp single_key_sql(_plan), do: " PRIMARY KEY"

  defp composite_key_sql(%{key_members: [_first, _second | _rest] = members} = plan) do
    ["PRIMARY KEY (#{key_member_list(members, plan.key_direction)})"]
  end

  defp composite_key_sql(_plan), do: []

  # The sort order rides on the first member, the way the generated unique
  # constraints put theirs on their first column.
  defp key_member_list(members, direction) do
    members
    |> Enum.with_index()
    |> Enum.map_join(", ", fn {name, position} -> key_member_sql(name, position, direction) end)
  end

  defp key_member_sql(name, 0, :asc), do: "#{quoted(name)} ASC"
  defp key_member_sql(name, 0, :desc), do: "#{quoted(name)} DESC"
  defp key_member_sql(name, _position, _direction), do: quoted(name)

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
          key_direction <- member_of([:none, :asc, :desc]),
          key_type <- member_of(["INTEGER", "TEXT"]),
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
        key_direction: key_direction,
        key_type: key_type,
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
      map(member_of(["plain", "it's", "ünïcodé", ""]), fn value -> {:text, value} end),
      map(member_of(["datetime('now')", "1 + 1"]), fn expr -> {:expression, expr} end)
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
    columns = retype_single_key(base, raw, key_members, autoincrement?, fk) ++ fk_column(fk)
    uniques = unique_constraints(raw, columns, key_members, fk)

    %{
      table: raw.table,
      columns: columns,
      key_members: key_members,
      autoincrement: autoincrement?,
      key_direction: key_direction(raw, autoincrement?),
      uniques: uniques,
      fk: fk,
      trigger: if(raw.trigger?, do: "#{raw.table}_trg"),
      protected: protected_columns(key_members, uniques, fk),
      seeded_rows: raw.seeded_rows
    }
  end

  # `INTEGER PRIMARY KEY DESC AUTOINCREMENT` is not a shape SQLite accepts:
  # AUTOINCREMENT needs the column to be the table's row id, and DESC is
  # exactly the spelling that stops it from being one.
  defp key_direction(%{key_direction: :desc}, true), do: :asc
  defp key_direction(raw, _autoincrement?), do: raw.key_direction

  # A single-column key declared TEXT is not the table's row id, so the table
  # keeps row ids of its own and SQLite builds the key an index. AUTOINCREMENT
  # and the self-reference both need the INTEGER form, so they keep it.
  defp retype_single_key([first | rest] = base, raw, key_members, autoincrement?, fk) do
    if plain_single_key?(raw, key_members, autoincrement?, fk) do
      [%{first | type: raw.key_type} | rest]
    else
      base
    end
  end

  defp plain_single_key?(raw, [_only], false, nil), do: raw.key_type != "INTEGER"
  defp plain_single_key?(_raw, _members, _autoincrement?, _fk), do: false

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

    frequency(
      [{8, ordinary_changes(plan, removable)}] ++
        key_move_arm(plan, removable) ++ key_narrow_arm(plan)
    )
  end

  defp ordinary_changes(plan, removable) do
    gen all(
          first <- modify_change(plan),
          rest <- list_of(change(plan, removable), max_length: 2)
        ) do
      normalize_changes(plan, [first | rest])
    end
  end

  # Moving a single-column key needs no AUTOINCREMENT sequence to carry and no
  # foreign key pointing at it: both of those belong to the column the key sits
  # on, and neither survives the move. A key with several members moves the
  # same way as long as every one of them is de-keyed in the same block — one
  # left keyed is a second key SQLite has no way to write, which the refusal
  # property below covers.
  defp key_move_arm(plan, removable) do
    case key_move_target(plan, removable) do
      nil -> []
      target -> [{2, key_move_changes(plan, target)}]
    end
  end

  defp key_move_target(%{key_members: [_only], autoincrement: false, fk: nil}, [target | _rest]),
    do: target

  defp key_move_target(%{key_members: [_first, _second | _rest]} = plan, removable) do
    removable
    |> Enum.reject(fn col -> col.name in plan.key_members end)
    |> List.first()
  end

  defp key_move_target(_plan, _removable), do: nil

  defp key_move_changes(%{key_members: [only]}, target) do
    gen all(grant_only? <- boolean()) do
      if grant_only? do
        [{:modify, only, :integer, [primary_key: true]}]
      else
        [
          {:modify, only, :integer, [primary_key: false]},
          {:modify, target.name, :integer, [primary_key: true]}
        ]
      end
    end
  end

  defp key_move_changes(%{key_members: members}, target) do
    gen all(spellings <- list_of(member_of(@spellings), length: length(members))) do
      de_keys =
        members
        |> Enum.zip(spellings)
        |> Enum.map(fn {name, spelling} ->
          {:modify, respell(name, spelling), :integer, [primary_key: false]}
        end)

      de_keys ++ [{:modify, target.name, :integer, [primary_key: true]}]
    end
  end

  # De-keying a member is the other way to narrow a key with several members:
  # the column stays in the table and leaves the key, which is exactly what
  # removing it would do to the key.
  defp key_narrow_arm(%{key_members: [_first, _second | _rest] = members}),
    do: [{2, key_narrow_changes(members)}]

  defp key_narrow_arm(_plan), do: []

  defp key_narrow_changes(members) do
    gen all(
          dropped <- member_of(members),
          spelling <- member_of(@spellings)
        ) do
      [{:modify, respell(dropped, spelling), :integer, [primary_key: false]}]
    end
  end

  defp change(plan, removable) do
    frequency(
      [
        {3, add_change()},
        {4, modify_change(plan)},
        {2, conditional_add_change(plan)},
        {2, conditional_remove_change(removable)}
      ] ++ weighted(removable, 2, &remove_change/1)
    )
  end

  defp weighted([], _weight, _builder), do: []
  defp weighted(pool, weight, builder), do: [{weight, builder.(pool)}]

  defp modify_change(plan) do
    gen all(
          col <- member_of(plan.columns),
          spelling <- member_of(@spellings),
          type <- modify_type(plan, col),
          null_opt <- one_of([constant([]), map(boolean(), &[null: &1])]),
          default_opt <- one_of([constant([]), map(change_default(), &[default: &1])])
        ) do
      {:modify, respell(col.name, spelling), type, null_opt ++ default_opt}
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
      member_of(["plain", "ünïcodé", "it's", ""]),
      boolean(),
      constant({:fragment, "(datetime('now'))"}),
      constant(%{"a" => 1}),
      constant([])
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

  # A conditional add either draws a name the table already has — in whatever
  # spelling — and must come out a no-op, or brings a new column.
  defp conditional_add_change(plan) do
    gen all(
          col <- member_of(plan.columns),
          spelling <- member_of(@spellings),
          fresh? <- boolean(),
          flavor <- member_of(@name_flavors),
          type <- member_of(@modify_types)
        ) do
      name = if fresh?, do: "#{flavor}_cond", else: respell(col.name, spelling)

      {:add_if_not_exists, name, type, []}
    end
  end

  # A conditional removal draws either a removable column or a name the table
  # does not have, where it must come out a no-op.
  defp conditional_remove_change(removable) do
    gen all(
          name <- conditional_target(removable),
          spelling <- member_of(@spellings),
          long_form? <- boolean()
        ) do
      spelled = respell(name, spelling)

      if long_form? do
        {:remove_if_exists, spelled, :string}
      else
        {:remove_if_exists, spelled}
      end
    end
  end

  defp conditional_target([]), do: constant("law_absent")

  defp conditional_target(removable) do
    one_of([constant("law_absent"), map(member_of(removable), & &1.name)])
  end

  defp remove_change(removable) do
    gen all(
          col <- member_of(removable),
          spelling <- member_of(@spellings),
          long_form? <- boolean()
        ) do
      name = respell(col.name, spelling)

      if long_form? do
        {:remove, name, :integer, []}
      else
        {:remove, name}
      end
    end
  end

  defp respell(name, :stored), do: name
  defp respell(name, :upper), do: String.upcase(name, :ascii)
  defp respell(name, :lower), do: String.downcase(name, :ascii)

  defp respell(name, :swapped) do
    name
    |> String.to_charlist()
    |> Enum.map(&swapped_case/1)
    |> List.to_string()
  end

  defp swapped_case(char) when char in ?a..?z, do: char - 32
  defp swapped_case(char) when char in ?A..?Z, do: char + 32
  defp swapped_case(char), do: char

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

  # A conditional add of a name the table already has is a no-op the engine
  # has to make, so it stays in the change set either way.
  defp normalize_change({:add_if_not_exists, name, type, opts} = change, state) do
    if named?(state.names, name) do
      {[change], state}
    else
      {[{:add_if_not_exists, name, type, opts}], %{state | names: state.names ++ [name]}}
    end
  end

  defp normalize_change({:remove, name, type, opts}, state) do
    normalize_removal({:remove, name, type, opts}, name, state)
  end

  defp normalize_change({:remove, name}, state) do
    normalize_removal({:remove, name}, name, state)
  end

  # A conditional removal of a column that is not there is a no-op a migration
  # could really ask for, so it stays; one that would empty the table or its
  # key is dropped, exactly like a plain removal.
  defp normalize_change({:remove_if_exists, name, _type} = change, state) do
    normalize_conditional_removal(change, name, state)
  end

  defp normalize_change({:remove_if_exists, name} = change, state) do
    normalize_conditional_removal(change, name, state)
  end

  # The engine refuses a change naming a column the table no longer has,
  # so a modify of a column an earlier change removed is not something a
  # migration could really ask for.
  defp normalize_change({:modify, name, type, opts}, state) do
    if named?(state.names, name) do
      {[{:modify, name, type, opts}], state}
    else
      {[], state}
    end
  end

  defp normalize_change(change, state), do: {[change], state}

  defp normalize_conditional_removal(change, name, state) do
    if named?(state.names, name) do
      normalize_removal(change, name, state)
    else
      {[change], state}
    end
  end

  defp normalize_removal(change, name, state) do
    remaining = without_name(state.names, name)
    surviving_key = without_name(state.key_members, name)

    cond do
      # Already removed by an earlier change: the engine refuses a removal
      # naming a column the table no longer has, so drop it.
      not named?(state.names, name) -> {[], state}
      remaining == [] -> {[], state}
      state.key_members != [] and surviving_key == [] -> {[], state}
      true -> {[change], %{state | names: remaining, key_members: surviving_key}}
    end
  end

  defp unique_name(name, taken) do
    if named?(taken, name) do
      unique_name(name <> "_x", taken)
    else
      name
    end
  end

  # Every name comparison in the bookkeeping above folds ASCII case, because
  # that is how SQLite itself resolves the names the change sets carry.
  defp named?(names, name), do: Enum.any?(names, &same_name?(&1, name))

  defp without_name(names, name), do: Enum.reject(names, &same_name?(&1, name))

  defp same_name?(one, other), do: String.downcase(one, :ascii) == String.downcase(other, :ascii)

  defp untouched_columns(plan, changes) do
    touched =
      changes
      |> Enum.map(&touched_column/1)
      |> Enum.reject(&is_nil/1)

    plan.columns
    |> Enum.map(& &1.name)
    |> Enum.reject(fn name -> named?(touched, name) end)
  end

  defp touched_column({:modify, name, _type, _opts}), do: name
  defp touched_column({:remove, name, _type, _opts}), do: name
  defp touched_column({:remove, name}), do: name
  defp touched_column({:remove_if_exists, name, _type}), do: name
  defp touched_column({:remove_if_exists, name}), do: name
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
    :key_removed_composite,
    :key_dekeyed_single,
    :key_dekeyed_composite,
    :virtual_table,
    :trigger_reads_removed_column,
    :stranded_unique,
    :stranded_foreign_key,
    :stranded_index,
    :single_key_grant,
    :composite_key_grant,
    :partly_dekeyed_key_grant
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

  # The table goes first in the cleanup: dropping it takes its triggers and
  # indexes with it, and a table another one points at can only go after.
  defp build_refusal(flavor, table, column) do
    refusal = refusal_shape(flavor, table, column)

    %{
      table: table,
      setup: refusal.setup ++ [refusal_insert(flavor, table, column)],
      cleanup: ["DROP TABLE IF EXISTS #{quoted(table)}"] ++ refusal.cleanup,
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

  defp refusal_shape(:key_dekeyed_single, table, column) do
    %{
      setup: ["CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT)"],
      cleanup: [],
      changes: [
        {:modify, "id", :integer, [primary_key: false]},
        {:modify, column, :string, [null: true]}
      ]
    }
  end

  defp refusal_shape(:key_dekeyed_composite, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (a INTEGER, b TEXT, #{quoted(column)} TEXT, " <>
          "PRIMARY KEY (a, b))"
      ],
      cleanup: [],
      changes: [
        {:modify, "a", :integer, [primary_key: false]},
        {:modify, "b", :string, [primary_key: false]}
      ]
    }
  end

  defp refusal_shape(:virtual_table, table, column) do
    %{
      setup: ["CREATE VIRTUAL TABLE #{quoted(table)} USING fts5(#{quoted(column)})"],
      cleanup: [],
      changes: [{:modify, column, :string, [null: true]}]
    }
  end

  defp refusal_shape(:trigger_reads_removed_column, table, column) do
    log = "#{table}_log"

    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, v REAL)",
        "CREATE TABLE #{quoted(log)} (note TEXT)",
        "CREATE TRIGGER #{quoted("#{table}_trg")} AFTER INSERT ON #{quoted(table)} " <>
          "BEGIN INSERT INTO #{quoted(log)} (note) VALUES (NEW.#{quoted(column)}); END"
      ],
      cleanup: ["DROP TABLE IF EXISTS #{quoted(log)}"],
      changes: [{:remove, column, :string, []}, {:modify, "v", :float, [null: false]}]
    }
  end

  defp refusal_shape(:stranded_unique, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, " <>
          "b TEXT, v REAL, UNIQUE (#{quoted(column)}, b))"
      ],
      cleanup: [],
      changes: [{:remove, column, :string, []}, {:modify, "v", :float, [null: false]}]
    }
  end

  defp refusal_shape(:stranded_foreign_key, table, column) do
    parent = "#{table}_p"

    %{
      setup: [
        "CREATE TABLE #{quoted(parent)} (id INTEGER PRIMARY KEY)",
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, " <>
          "#{quoted(column)} INTEGER REFERENCES #{quoted(parent)} (id), v REAL)"
      ],
      cleanup: ["DROP TABLE IF EXISTS #{quoted(parent)}"],
      changes: [{:remove, column, :integer, []}, {:modify, "v", :float, [null: false]}]
    }
  end

  defp refusal_shape(:stranded_index, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT, v REAL)",
        "CREATE INDEX #{quoted("#{table}_ix")} ON #{quoted(table)} (#{quoted(column)})"
      ],
      cleanup: [],
      changes: [{:remove, column, :string, []}, {:modify, "v", :float, [null: false]}]
    }
  end

  defp refusal_shape(:single_key_grant, table, column) do
    %{
      setup: ["CREATE TABLE #{quoted(table)} (id INTEGER PRIMARY KEY, #{quoted(column)} TEXT)"],
      cleanup: [],
      changes: [{:modify, column, :string, [primary_key: true]}]
    }
  end

  defp refusal_shape(:composite_key_grant, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (a INTEGER, b TEXT, #{quoted(column)} REAL, " <>
          "PRIMARY KEY (a, b))"
      ],
      cleanup: [],
      changes: [{:modify, column, :float, [primary_key: true]}]
    }
  end

  # De-keying only part of the key leaves the rest of it standing, so the
  # grant still asks for a second key.
  defp refusal_shape(:partly_dekeyed_key_grant, table, column) do
    %{
      setup: [
        "CREATE TABLE #{quoted(table)} (a INTEGER, b TEXT, #{quoted(column)} REAL, " <>
          "PRIMARY KEY (a, b))"
      ],
      cleanup: [],
      changes: [
        {:modify, "a", :integer, [primary_key: false]},
        {:modify, column, :float, [primary_key: true]}
      ]
    }
  end

  defp refusal_insert(:without_rowid, table, column) do
    "INSERT INTO #{quoted(table)} (k, #{quoted(column)}) VALUES ('k1', 'v1')"
  end

  defp refusal_insert(flavor, table, column)
       when flavor in [:key_removed_composite, :key_dekeyed_composite] do
    "INSERT INTO #{quoted(table)} (a, b, #{quoted(column)}) VALUES (1, 'b1', 'v1')"
  end

  defp refusal_insert(flavor, table, column)
       when flavor in [:composite_key_grant, :partly_dekeyed_key_grant] do
    "INSERT INTO #{quoted(table)} (a, b, #{quoted(column)}) VALUES (1, 'b1', 1.0)"
  end

  defp refusal_insert(:virtual_table, table, column) do
    "INSERT INTO #{quoted(table)} (#{quoted(column)}) VALUES ('v1')"
  end

  defp refusal_insert(:stranded_unique, table, column) do
    "INSERT INTO #{quoted(table)} (id, #{quoted(column)}, b, v) VALUES (1, 'v1', 'b1', 1.0)"
  end

  defp refusal_insert(:stranded_foreign_key, table, column) do
    "INSERT INTO #{quoted(table)} (id, #{quoted(column)}, v) VALUES (1, NULL, 1.0)"
  end

  defp refusal_insert(flavor, table, column)
       when flavor in [:trigger_reads_removed_column, :stranded_index] do
    "INSERT INTO #{quoted(table)} (id, #{quoted(column)}, v) VALUES (1, 'v1', 1.0)"
  end

  defp refusal_insert(_flavor, table, column) do
    "INSERT INTO #{quoted(table)} (id, #{quoted(column)}) VALUES (1, 'v1')"
  end
end
