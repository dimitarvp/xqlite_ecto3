defmodule XqliteEcto3.RebuildAffinityGuardTest do
  @moduledoc """
  The table rebuild's value-safety pre-flights.

  A `modify` that moves a populated column's affinity refuses before any
  destructive step when the copy would rewrite stored values — byte loss
  toward a numeric affinity ("007" becomes 7), stringified storage
  classes toward TEXT — and leaves the table byte-identical. Values the
  conversion carries exactly migrate freely.

  Beside it, the carried-type and construct-scan fixes: a column whose
  NAME spells a scanned keyword does not block a rebuild, a stored type
  text SQLite cannot re-read bare is quoted, a parenthesis inside a
  string literal in a fragment default does not abort the post-check,
  and a `SELECT *` trigger passes the pre-flight exactly as SQLite's own
  `DROP COLUMN` allows it (the documented parity hole).
  """
  use ExUnit.Case, async: true

  alias Ecto.Migration.Table

  defmodule GuardRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule PooledGuardRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_affinity_guard_#{System.os_time(:nanosecond)}.db"
      )

    remove_database(database)

    config = [
      adapter: XqliteEcto3,
      database: database,
      pool_size: 1,
      support_alter_via_table_rebuild: true
    ]

    Application.put_env(:xqlite_ecto3, GuardRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({GuardRepo, config})

    on_exit(fn -> remove_database(database) end)

    :ok
  end

  defp remove_database(database) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
  end

  defp alter!(table, changes), do: alter!(GuardRepo, table, changes)

  defp alter!(repo, table, changes) do
    {:ok, []} =
      XqliteEcto3.execute_ddl(
        Ecto.Adapter.lookup_meta(repo),
        {:alter, %Table{name: table}, changes},
        []
      )

    :ok
  end

  defp dump(table, cols, order \\ "rowid") do
    select = Enum.map_join(cols, ", ", fn c -> ~s|typeof("#{c}"), "#{c}"| end)
    %{rows: rows} = GuardRepo.query!("SELECT #{select} FROM \"#{table}\" ORDER BY #{order}")
    rows
  end

  defp declared_type(table, col) do
    %{rows: rows} = GuardRepo.query!("SELECT name, type FROM pragma_table_info(?1)", [table])
    [type] = for [n, t] <- rows, n == col, do: t
    type
  end

  describe "the affinity guard" do
    test "refuses a text-to-numeric modify that would lose bytes, table intact" do
      GuardRepo.query!("CREATE TABLE ag_lossy (id INTEGER PRIMARY KEY, code TEXT)")
      GuardRepo.query!("INSERT INTO ag_lossy (code) VALUES ('007'), ('12345678901234567890')")

      rows_before = dump("ag_lossy", ["code"])

      assert_raise ArgumentError, fn ->
        alter!("ag_lossy", [{:modify, :code, :decimal, []}])
      end

      assert declared_type("ag_lossy", "code") == "TEXT"
      assert dump("ag_lossy", ["code"]) == rows_before
    end

    test "lets a text-to-numeric modify through when every value converts exactly" do
      GuardRepo.query!("CREATE TABLE ag_exact (id INTEGER PRIMARY KEY, amount TEXT)")
      GuardRepo.query!("INSERT INTO ag_exact (amount) VALUES ('42'), ('1.5')")

      assert :ok = alter!("ag_exact", [{:modify, :amount, :decimal, []}])

      assert declared_type("ag_exact", "amount") == "DECIMAL"
      assert dump("ag_exact", ["amount"]) == [["integer", 42], ["real", 1.5]]
    end

    test "refuses a numeric-to-text modify that would stringify storage classes" do
      GuardRepo.query!("CREATE TABLE ag_jsonb (id INTEGER PRIMARY KEY, payload JSONB)")
      GuardRepo.query!("INSERT INTO ag_jsonb (payload) VALUES (7), ('{\"a\":1}'), (10)")

      rows_before = dump("ag_jsonb", ["payload"])

      assert_raise ArgumentError, fn ->
        alter!("ag_jsonb", [{:modify, :payload, :jsonb, [null: false]}])
      end

      assert declared_type("ag_jsonb", "payload") == "JSONB"
      assert dump("ag_jsonb", ["payload"]) == rows_before
    end

    test "plain text and exact-converting values pass; the copy is the oracle" do
      GuardRepo.query!("CREATE TABLE ag_oracle (id INTEGER PRIMARY KEY, v TEXT)")
      GuardRepo.query!("INSERT INTO ag_oracle (v) VALUES ('abc'), (''), ('42'), ('1.5')")

      assert :ok = alter!("ag_oracle", [{:modify, :v, :decimal, []}])

      assert dump("ag_oracle", ["v"]) ==
               [["text", "abc"], ["text", ""], ["integer", 42], ["real", 1.5]]
    end

    test "an affinity-preserving modify stays a no-op for stored values" do
      GuardRepo.query!("CREATE TABLE ag_money (id INTEGER PRIMARY KEY, fee MONEY)")
      GuardRepo.query!("INSERT INTO ag_money (fee) VALUES (7), (3.5)")

      assert :ok = alter!("ag_money", [{:modify, :fee, :money, [null: false]}])

      assert declared_type("ag_money", "fee") == "MONEY"
      assert dump("ag_money", ["fee"]) == [["integer", 7], ["real", 3.5]]
    end

    test "a column named rowid does not blind the guard" do
      GuardRepo.query!(~s|CREATE TABLE ag_shadow ("rowid" TEXT, amt TEXT)|)
      GuardRepo.query!("INSERT INTO ag_shadow (amt) VALUES ('007'), ('0012')")

      assert_raise ArgumentError, fn ->
        alter!("ag_shadow", [{:modify, :amt, :integer, []}])
      end

      assert declared_type("ag_shadow", "amt") == "TEXT"
      assert dump("ag_shadow", ["amt"], "_rowid_") == [["text", "007"], ["text", "0012"]]

      GuardRepo.query!(~s|CREATE TABLE ag_shadow_up ("ROWID" TEXT, amt TEXT)|)
      GuardRepo.query!("INSERT INTO ag_shadow_up (amt) VALUES ('007'), ('0012')")

      assert_raise ArgumentError, fn ->
        alter!("ag_shadow_up", [{:modify, :amt, :integer, []}])
      end

      assert declared_type("ag_shadow_up", "amt") == "TEXT"
      assert dump("ag_shadow_up", ["amt"], "_rowid_") == [["text", "007"], ["text", "0012"]]
    end

    test "the same table shape with an ordinary column name refuses too" do
      GuardRepo.query!("CREATE TABLE ag_plain (rid TEXT, amt TEXT)")
      GuardRepo.query!("INSERT INTO ag_plain (amt) VALUES ('007'), ('0012')")

      assert_raise ArgumentError, fn ->
        alter!("ag_plain", [{:modify, :amt, :integer, []}])
      end

      assert declared_type("ag_plain", "amt") == "TEXT"
      assert dump("ag_plain", ["amt"]) == [["text", "007"], ["text", "0012"]]
    end

    test "a WITHOUT ROWID table is refused before the guard reaches the values" do
      GuardRepo.query!("CREATE TABLE ag_wr (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID")
      GuardRepo.query!("INSERT INTO ag_wr (k, v) VALUES ('a', '007')")

      assert_raise ArgumentError, fn ->
        alter!("ag_wr", [{:modify, :v, :integer, []}])
      end

      assert declared_type("ag_wr", "v") == "TEXT"
      assert dump("ag_wr", ["v"], "k") == [["text", "007"]]
    end

    test "empty, all-NULL, and quoted-name columns take the guard's boundaries" do
      GuardRepo.query!("CREATE TABLE ag_none (id INTEGER PRIMARY KEY, v TEXT)")

      assert :ok = alter!("ag_none", [{:modify, :v, :integer, []}])
      assert declared_type("ag_none", "v") == "INTEGER"

      GuardRepo.query!("CREATE TABLE ag_nulls (id INTEGER PRIMARY KEY, v TEXT)")
      GuardRepo.query!("INSERT INTO ag_nulls (v) VALUES (NULL), (NULL)")

      assert :ok = alter!("ag_nulls", [{:modify, :v, :integer, []}])
      assert dump("ag_nulls", ["v"]) == [["null", nil], ["null", nil]]

      GuardRepo.query!(~s|CREATE TABLE ag_quoted (id INTEGER PRIMARY KEY, "my col" TEXT)|)
      GuardRepo.query!(~s|INSERT INTO ag_quoted ("my col") VALUES ('007')|)

      assert_raise ArgumentError, fn ->
        alter!("ag_quoted", [{:modify, :"my col", :integer, []}])
      end

      GuardRepo.query!(~s|UPDATE ag_quoted SET "my col" = '7'|)

      assert :ok = alter!("ag_quoted", [{:modify, :"my col", :integer, []}])
      assert dump("ag_quoted", ["my col"]) == [["integer", 7]]
    end
  end

  describe "the affinity guard under a pool of several connections" do
    test "refuses on one connection and strands no scratch table" do
      database =
        Path.join(
          System.tmp_dir!(),
          "xqlite_ecto3_affinity_pool_#{System.os_time(:millisecond)}.db"
        )

      remove_database(database)

      config = [
        adapter: XqliteEcto3,
        database: database,
        pool_size: 3,
        journal_mode: :wal,
        busy_timeout: 1_000,
        support_alter_via_table_rebuild: true
      ]

      Application.put_env(:xqlite_ecto3, PooledGuardRepo, config)
      :ok = XqliteEcto3.storage_up(config)
      start_supervised!({PooledGuardRepo, config})
      on_exit(fn -> remove_database(database) end)

      probes = fn ->
        %{rows: [[n]]} =
          PooledGuardRepo.query!(
            "SELECT count(*) FROM sqlite_temp_schema WHERE name LIKE 'xqlite_affinity_probe%'"
          )

        n
      end

      me = self()

      # Deferred: this process only has to occupy a pool connection. The
      # repo's default BEGIN IMMEDIATE would hold the write lock too, and
      # every other statement in this test would time out on it.
      parked =
        spawn_link(fn ->
          PooledGuardRepo.transaction(
            fn ->
              send(me, :parked)

              receive do
                :release -> send(me, {:parked_probes, probes.()})
              end
            end,
            mode: :deferred
          )
        end)

      assert_receive :parked, 5_000

      PooledGuardRepo.query!("CREATE TABLE ap_lossy (id INTEGER PRIMARY KEY, v TEXT)")
      PooledGuardRepo.query!("INSERT INTO ap_lossy (v) VALUES ('007'), ('0012')")

      assert_raise ArgumentError, fn ->
        alter!(PooledGuardRepo, "ap_lossy", [{:modify, :v, :integer, []}])
      end

      assert probes.() == 0

      holders =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            PooledGuardRepo.checkout(fn ->
              send(me, {:held, self()})

              receive do
                :count -> probes.()
              end
            end)
          end)
        end)

      Enum.each(holders, fn _ -> assert_receive {:held, _}, 5_000 end)
      Enum.each(holders, fn task -> send(task.pid, :count) end)
      assert Enum.map(holders, &Task.await(&1, 5_000)) == [0, 0]

      PooledGuardRepo.query!("CREATE TABLE ap_exact (id INTEGER PRIMARY KEY, v TEXT)")
      PooledGuardRepo.query!("INSERT INTO ap_exact (v) VALUES ('7'), ('12')")

      assert :ok = alter!(PooledGuardRepo, "ap_exact", [{:modify, :v, :integer, []}])

      send(parked, :release)
      assert_receive {:parked_probes, 0}, 5_000
    end
  end

  describe "construct scans over quoted identifiers" do
    test "a column named check does not block the rebuild" do
      GuardRepo.query!(~s|CREATE TABLE kw_t (id INTEGER PRIMARY KEY, "check" INTEGER, v TEXT)|)
      GuardRepo.query!(~s|INSERT INTO kw_t ("check", v) VALUES (1, 'a')|)

      assert :ok = alter!("kw_t", [{:modify, :v, :string, [null: false]}])

      assert dump("kw_t", ["check", "v"]) == [["integer", 1, "text", "a"]]
    end

    test "a real CHECK constraint still refuses" do
      GuardRepo.query!("CREATE TABLE ck_t (id INTEGER PRIMARY KEY, v INTEGER CHECK (v > 0))")

      assert_raise ArgumentError, fn ->
        alter!("ck_t", [{:modify, :v, :integer, [null: false]}])
      end
    end
  end

  describe "carried stored type texts" do
    test "a type SQLite cannot re-read bare is quoted; bare and quoted forms carry" do
      GuardRepo.query!(
        ~s|CREATE TABLE ct_t (id INTEGER PRIMARY KEY, a "foo-bar", b "select", | <>
          ~s|c VARCHAR (255), d NUMERIC(10, 2), e [my type], f 'legacy', v TEXT)|
      )

      GuardRepo.query!("INSERT INTO ct_t (a, b, c, d, e, f, v) VALUES (1, 2, 'x', 3, 4, 5, 'y')")

      assert :ok = alter!("ct_t", [{:modify, :v, :string, [null: false]}])

      assert declared_type("ct_t", "a") == "foo-bar"
      assert declared_type("ct_t", "b") == "select"
      assert declared_type("ct_t", "c") == "VARCHAR (255)"
      assert declared_type("ct_t", "d") == "NUMERIC(10, 2)"

      assert dump("ct_t", ["a", "b", "c", "d", "e", "f", "v"]) ==
               [
                 [
                   "integer",
                   1,
                   "integer",
                   2,
                   "text",
                   "x",
                   "integer",
                   3,
                   "integer",
                   4,
                   "integer",
                   5,
                   "text",
                   "y"
                 ]
               ]
    end
  end

  describe "fragment defaults with parens inside literals" do
    test "survive the rebuild and store the exact default" do
      GuardRepo.query!("CREATE TABLE fd_t (id INTEGER PRIMARY KEY, v TEXT)")
      GuardRepo.query!("INSERT INTO fd_t (v) VALUES ('seed')")

      assert :ok =
               alter!("fd_t", [
                 {:add, :tag, :string, [default: {:fragment, "('a)b')"}]},
                 {:modify, :v, :string, [null: false]}
               ])

      GuardRepo.query!("INSERT INTO fd_t (v) VALUES ('fresh')")

      %{rows: rows} = GuardRepo.query!("SELECT tag FROM fd_t ORDER BY rowid")
      assert rows == [["a)b"], ["a)b"]]
    end
  end

  describe "the SELECT * trigger parity hole" do
    test "passes the pre-flight and bricks later writes exactly as SQLite's own DROP COLUMN" do
      GuardRepo.query!("CREATE TABLE tp_t (id INTEGER PRIMARY KEY, gone INTEGER, keep TEXT)")
      GuardRepo.query!("CREATE TABLE tp_log (id INTEGER, gone INTEGER, keep TEXT)")

      GuardRepo.query!(
        "CREATE TRIGGER tp_tr AFTER INSERT ON tp_t BEGIN " <>
          "INSERT INTO tp_log SELECT * FROM tp_t WHERE id = NEW.id; END"
      )

      assert :ok = alter!("tp_t", [{:remove, :gone}])

      assert_raise XqliteEcto3.Error, fn ->
        GuardRepo.query!("INSERT INTO tp_t (keep) VALUES ('x')")
      end
    end
  end
end
