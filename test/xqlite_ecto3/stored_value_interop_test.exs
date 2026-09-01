defmodule XqliteEcto3.StoredValueInteropTest do
  @moduledoc """
  Values the adapter stores must interoperate with values SQLite itself
  writes into the same columns.

  Datetimes: the adapter stores SQLite's own form (space separator, no
  trailing designator), so a `CURRENT_TIMESTAMP` default, `datetime()`,
  `date()` and `time()` results all load under their matching Ecto
  types, and a column written by both parties orders and range-filters
  by instant. The trailing-Z byte-order trap (a sub-second value
  sorting before its own whole second) is pinned through mixed
  precisions in one column.

  Decimals: text spellings `Decimal.parse/1` clean-parses into
  non-finite values (NaN, Infinity) fail the load with Ecto's typed
  error naming field and value — Ecto's `:decimal` cannot hold them
  and its own exception names nothing.
  """
  use XqliteEcto3.AdapterCase, async: true

  import Ecto.Query

  defmodule Audit do
    use Ecto.Schema

    schema "svi_audit" do
      field(:note, :string)
      field(:at, :utc_datetime)
      field(:atu, :utc_datetime_usec)
      field(:d, :date)
      field(:t, :time)
    end
  end

  defmodule Price do
    use Ecto.Schema

    schema "svi_prices" do
      field(:amount, :decimal)
    end
  end

  defmodule WholeAudit do
    use Ecto.Schema

    schema "svi_audit" do
      field(:note, :string)
      field(:atu, :utc_datetime)
    end
  end

  defmodule PriceText do
    use Ecto.Schema

    schema "svi_prices" do
      field(:amount, :string)
    end
  end

  setup_all do
    create_table!(
      "svi_audit",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, note TEXT, " <>
        "at TEXT DEFAULT CURRENT_TIMESTAMP, atu TEXT, d TEXT, t TEXT"
    )

    create_table!("svi_prices", "id INTEGER PRIMARY KEY AUTOINCREMENT, amount DECIMAL")
  end

  setup do
    clear_table!("svi_audit")
    clear_table!("svi_prices")
  end

  describe "datetime storage form" do
    test "adapter writes store SQLite's own form" do
      base = ~U[2026-09-01 10:20:30Z]

      {:ok, _} =
        Repo.insert(struct(Audit, note: "a", at: base, atu: ~U[2026-09-01 10:20:30.500000Z]))

      %{rows: [[at, atu]]} = Repo.query!("SELECT at, atu FROM svi_audit")

      assert at == "2026-09-01 10:20:30"
      assert atu == "2026-09-01 10:20:30.500000"
    end

    test "SQLite-written values load under their matching types" do
      Repo.query!(
        "INSERT INTO svi_audit (note, atu, d, t) " <>
          "VALUES ('db', datetime('2026-09-01 10:20:30'), date('2026-09-01'), time('10:20:30'))"
      )

      row = Repo.one!(from(a in Audit, where: a.note == "db"))

      assert %DateTime{time_zone: "Etc/UTC"} = row.at
      assert DateTime.compare(row.atu, ~U[2026-09-01 10:20:30Z]) == :eq
      assert row.d == ~D[2026-09-01]
      assert row.t == ~T[10:20:30]
    end

    test "a mixed-writer column orders and range-filters by instant" do
      # The SQLite-written row uses a fixed literal (datetime() is the
      # writer, the instant is pinned) so every comparison is
      # deterministic and every row shares one date — the adversarial
      # shape where the separator byte decides the order.
      base = ~U[2026-09-01 12:00:00Z]

      Repo.query!(
        "INSERT INTO svi_audit (note, at) VALUES ('db', datetime('2026-09-01 12:00:00'))"
      )

      {:ok, _} = Repo.insert(struct(Audit, note: "later", at: DateTime.add(base, 3600)))
      {:ok, _} = Repo.insert(struct(Audit, note: "earlier", at: DateTime.add(base, -3600)))

      ordered = Repo.all(from(a in Audit, order_by: a.at, select: a.note))
      assert ordered == ["earlier", "db", "later"]

      in_range =
        Repo.all(from(a in Audit, where: a.at < ^DateTime.add(base, -1800), select: a.note))

      assert in_range == ["earlier"]
    end

    test "whole-second and sub-second rows in one column order by instant" do
      # Two schemas at different precisions over one column — the shape
      # that mixes whole-second and six-digit stored texts.
      Repo.insert_all(WholeAudit, [%{note: "1", atu: ~U[2024-01-01 00:00:00Z]}])
      Repo.insert_all(Audit, [%{note: "2", atu: ~U[2024-01-01 00:00:00.500000Z]}])
      Repo.insert_all(WholeAudit, [%{note: "3", atu: ~U[2024-01-01 00:00:01Z]}])

      %{rows: stored} = Repo.query!("SELECT atu FROM svi_audit ORDER BY rowid")

      assert [["2024-01-01 00:00:00"], ["2024-01-01 00:00:00.500000"], ["2024-01-01 00:00:01"]] =
               stored

      assert Repo.all(from(a in Audit, order_by: a.atu, select: a.note)) == ["1", "2", "3"]
    end
  end

  describe "non-finite decimal text" do
    test "every spelling fails the load with Ecto's typed error" do
      spellings = ~w(NaN nan -NaN Inf inf Infinity -Infinity +Inf)

      for spelling <- spellings do
        Repo.insert_all(PriceText, [%{amount: spelling}])

        assert_raise ArgumentError, ~r/for field :amount/, fn ->
          Repo.all(Price)
        end

        clear_table!("svi_prices")
      end
    end

    test "a finite decimal still loads" do
      Repo.insert_all(PriceText, [%{amount: "1.5"}])

      assert [price] = Repo.all(Price)
      assert Decimal.equal?(price.amount, Decimal.new("1.5"))
    end
  end
end
