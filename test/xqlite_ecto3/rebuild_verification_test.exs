defmodule XqliteEcto3.RebuildVerificationTest do
  @moduledoc """
  The table rebuild's structural check, exercised without a database.

  Every test hands the checker a reading taken before the rebuild, the
  migration's changes, and a doctored reading of the rebuilt table — one
  structural fact deliberately missing or altered, the way a rebuild that
  forgot to re-emit a construct would leave it. The checker must name the
  construct that went missing; nothing here reads an error message.
  """
  use ExUnit.Case, async: true

  alias XqliteEcto3.RebuildVerification
  alias XqliteEcto3.RebuildVerificationError

  defp column(name, type, opts \\ []) do
    %{
      name: name,
      type: type,
      notnull: Keyword.get(opts, :notnull, false),
      default: Keyword.get(opts, :default),
      pk: Keyword.get(opts, :pk, 0)
    }
  end

  defp snapshot(overrides \\ []) do
    base = %{
      table: "widgets",
      columns: [
        column("id", "INTEGER", pk: 1),
        column("name", "TEXT", notnull: true),
        column("price", "REAL", default: "0.0")
      ],
      foreign_keys: [],
      unique_constraints: [],
      indexes: %{schema: [], index_list: []},
      triggers: [],
      table_options: %{without_rowid: false, strict: false},
      autoincrement: false,
      sequence: nil
    }

    Map.merge(base, Map.new(overrides))
  end

  defp put_column(snap, name, changes) do
    columns =
      Enum.map(snap.columns, fn col ->
        if col.name == name, do: Map.merge(col, Map.new(changes)), else: col
      end)

    %{snap | columns: columns}
  end

  defp verify(before, changes, actual), do: RebuildVerification.verify(before, changes, actual)

  describe "a rebuild that carried everything over" do
    test "no changes at all" do
      before = snapshot()

      assert :ok = verify(before, [], before)
    end

    test "modify, add and remove together" do
      before = snapshot()

      changes = [
        {:modify, :name, :integer, [null: true]},
        {:remove, :price, :float, []},
        {:add, :note, :string, []}
      ]

      actual = %{
        before
        | columns: [
            column("id", "INTEGER", pk: 1),
            column("name", "INTEGER"),
            column("note", "TEXT")
          ]
      }

      assert :ok = verify(before, changes, actual)
    end

    test "a modified column keeps the aspects the migration did not mention" do
      before = snapshot()
      changes = [{:modify, :name, :string, []}]

      assert :ok = verify(before, changes, before)
    end
  end

  describe "a construct that went missing" do
    test "a dropped NOT NULL is named with its column" do
      before = snapshot()
      actual = put_column(before, "name", notnull: false)

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :column_null
      assert error.column == "name"
      assert error.table == "widgets"
      assert error.expected == true
      assert error.actual == false
    end

    test "a dropped DEFAULT is named with its column" do
      before = snapshot()
      actual = put_column(before, "price", default: nil)

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :column_default
      assert error.column == "price"
      assert error.expected == "0.0"
      assert error.actual == nil
    end

    test "a column whose type changed on its own" do
      before = snapshot()
      actual = put_column(before, "price", type: "TEXT")

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :column_type
      assert error.column == "price"
      assert error.expected == "REAL"
      assert error.actual == "TEXT"
    end

    test "a column that vanished" do
      before = snapshot()
      actual = %{before | columns: Enum.reject(before.columns, &(&1.name == "price"))}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :columns
      assert error.expected == ["id", "name", "price"]
      assert error.actual == ["id", "name"]
    end

    test "a lost primary key" do
      before = snapshot()
      actual = put_column(before, "id", pk: 0)

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :primary_key
      assert error.column == "id"
      assert error.expected == 1
      assert error.actual == 0
    end

    test "a composite key narrowed to its first member" do
      before =
        snapshot(
          columns: [
            column("tenant", "INTEGER", pk: 1),
            column("code", "TEXT", pk: 2),
            column("label", "TEXT")
          ]
        )

      actual = put_column(before, "code", pk: 0)

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :primary_key
      assert error.column == "code"
      assert error.expected == 2
      assert error.actual == 0
    end

    test "a foreign key that did not come back" do
      keys = [
        %{
          columns: ["owner_id"],
          target: "owners",
          target_columns: ["id"],
          on_delete: "CASCADE",
          on_update: "NO ACTION"
        }
      ]

      before = snapshot(foreign_keys: keys)
      actual = %{before | foreign_keys: []}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :foreign_keys
      assert error.expected == keys
      assert error.actual == []
    end

    test "a unique constraint whose DESC was flattened" do
      before = snapshot(unique_constraints: [[%{column: "name", desc: true}]])
      actual = %{before | unique_constraints: [[%{column: "name", desc: false}]]}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :unique_constraints
      assert error.expected == [[%{column: "name", desc: true}]]
      assert error.actual == [[%{column: "name", desc: false}]]
    end

    test "an index that was not re-created" do
      indexes = %{schema: ["widgets_name_idx"], index_list: ["widgets_name_idx"]}
      before = snapshot(indexes: indexes)
      actual = %{before | indexes: %{schema: [], index_list: []}}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :indexes
      assert error.expected == indexes
      assert error.actual == %{schema: [], index_list: []}
    end

    test "a trigger that was not re-created" do
      before = snapshot(triggers: ["widgets_touch"])
      actual = %{before | triggers: []}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :triggers
      assert error.expected == ["widgets_touch"]
      assert error.actual == []
    end

    test "a lost STRICT table option" do
      before = snapshot(table_options: %{without_rowid: false, strict: true})
      actual = %{before | table_options: %{without_rowid: false, strict: false}}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :table_options
    end

    test "a lost AUTOINCREMENT" do
      before = snapshot(autoincrement: true, sequence: 41)
      actual = %{before | autoincrement: false}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :autoincrement
      assert error.expected == true
      assert error.actual == false
    end

    test "a reset AUTOINCREMENT sequence" do
      before = snapshot(autoincrement: true, sequence: 41)
      actual = %{before | sequence: 0}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, [], actual)
      assert error.construct == :sequence
      assert error.expected == 41
      assert error.actual == 0
    end
  end

  describe "what the prediction expects of the change set" do
    test "an option the modify does not give leaves that aspect alone" do
      before = snapshot()
      actual = put_column(before, "name", type: "INTEGER", notnull: false)

      assert {:error, %RebuildVerificationError{} = error} =
               verify(before, [{:modify, :name, :integer, []}], actual)

      assert error.construct == :column_null
      assert error.column == "name"
      assert error.expected == true
    end

    test "a given default replaces the stored one" do
      before = snapshot()
      changes = [{:modify, :price, :float, [default: 3]}]
      actual = put_column(before, "price", type: "NUMERIC", default: "3")

      assert :ok = verify(before, changes, actual)
    end

    test "a string default is written as a quoted literal" do
      before = snapshot()
      changes = [{:modify, :name, :string, [default: "n/a"]}]
      actual = put_column(before, "name", default: "'n/a'")

      assert :ok = verify(before, changes, actual)
    end

    test "AUTOINCREMENT rides along with the key it belongs to" do
      before = snapshot(autoincrement: true, sequence: 7)
      changes = [{:modify, :name, :string, [null: false]}]

      assert :ok = verify(before, changes, before)
    end

    test "a second modify of one column merges against the stored declaration" do
      before = snapshot()

      changes = [
        {:modify, :price, :float, [default: 9]},
        {:modify, :price, :float, []}
      ]

      actual = put_column(before, "price", type: "NUMERIC")

      assert :ok = verify(before, changes, actual)
    end

    test "a column added in the same block is modified from its options alone" do
      before = snapshot()

      changes = [
        {:add, :note, :string, [null: false, default: "x"]},
        {:modify, :note, :integer, []}
      ]

      actual = %{before | columns: before.columns ++ [column("note", "INTEGER")]}

      assert :ok = verify(before, changes, actual)
    end

    test "a composite key narrows to the members that survive" do
      before =
        snapshot(
          columns: [
            column("tenant", "INTEGER", pk: 1),
            column("code", "TEXT", pk: 2),
            column("label", "TEXT")
          ]
        )

      changes = [{:remove, :tenant, :integer, []}]

      actual = %{
        before
        | columns: [column("code", "TEXT", pk: 1), column("label", "TEXT")]
      }

      assert :ok = verify(before, changes, actual)
    end

    test "removing every key member is refused, not predicted" do
      before =
        snapshot(
          columns: [
            column("tenant", "INTEGER", pk: 1),
            column("code", "TEXT", pk: 2),
            column("label", "TEXT")
          ]
        )

      changes = [{:remove, :tenant, :integer, []}, {:remove, :code, :string, []}]
      actual = %{before | columns: [column("label", "TEXT")]}

      assert {:error, %RebuildVerificationError{} = error} = verify(before, changes, actual)
      assert error.construct == :primary_key
      assert error.expected == {:refused, :primary_key_fully_removed}
      assert error.actual == :rebuilt
    end

    test "a column declared without a type is rebuilt as BLOB" do
      before = snapshot(columns: [column("id", "INTEGER", pk: 1), column("loose", "")])
      actual = %{before | columns: [column("id", "INTEGER", pk: 1), column("loose", "BLOB")]}

      assert :ok = verify(before, [], actual)
    end
  end

  describe "primary-key survival" do
    test "reports the key members in declared key order" do
      columns = [
        column("code", "TEXT", pk: 2),
        column("tenant", "INTEGER", pk: 1),
        column("label", "TEXT")
      ]

      assert RebuildVerification.primary_key_members(columns) == ["tenant", "code"]
    end

    test "a table with no key has no members" do
      assert RebuildVerification.primary_key_members([column("a", "TEXT")]) == []
    end

    test "removals narrow the surviving members" do
      columns = [
        column("tenant", "INTEGER", pk: 1),
        column("code", "TEXT", pk: 2),
        column("label", "TEXT")
      ]

      changes = [{:remove, :tenant, :integer, []}]

      assert RebuildVerification.surviving_primary_key_members(columns, changes) == ["code"]
    end

    test "removing every member leaves none" do
      columns = [column("tenant", "INTEGER", pk: 1), column("code", "TEXT", pk: 2)]
      changes = [{:remove, :tenant, :integer, []}, {:remove_if_exists, :code, :string}]

      assert RebuildVerification.surviving_primary_key_members(columns, changes) == []
    end

    test "removing the only member of a single-column key leaves none" do
      columns = [column("id", "INTEGER", pk: 1), column("name", "TEXT")]

      assert RebuildVerification.surviving_primary_key_members(columns, [{:remove, :id}]) == []
    end
  end
end
