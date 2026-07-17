defmodule XqliteEcto3.JsonExtractPathTest do
  @moduledoc """
  Adapter-owned coverage for `json_extract_path` beyond the shared
  Ecto suite: dynamic (runtime) path segments and the explicit-typing
  escape hatch for boolean extraction.

  SQLite stores JSON booleans as INTEGER 1/0 and Ecto gives untyped
  select expressions no load hook, so a bare
  `select: o.meta["enabled"]` faithfully returns `1`. The sanctioned
  fix is `type(..., :boolean)`, which routes the value through the
  adapter's `:boolean` loader.
  """

  use XqliteEcto3.AdapterCase, async: true

  defmodule Doc do
    use Ecto.Schema

    schema "jep_docs" do
      field(:label, :string)
      field(:idx, :integer)
      field(:meta, :map)
    end
  end

  setup_all do
    create_table!(
      "jep_docs",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT, idx INTEGER, meta TEXT"
    )
  end

  setup do
    clear_table!("jep_docs")

    {:ok, doc} =
      Repo.insert(%Doc{
        label: "tags",
        idx: 1,
        meta: %{
          "enabled" => true,
          "disabled" => false,
          "tags" => [%{"name" => "red"}, %{"name" => "green"}],
          "dotted.key" => "found"
        }
      })

    {:ok, doc: doc}
  end

  # ---------------------------------------------------------------------------
  # Dynamic path segments
  # ---------------------------------------------------------------------------

  test "dynamic string key from a column" do
    assert Repo.one(from(d in Doc, select: d.meta[d.label][0]["name"])) == "red"
  end

  test "dynamic integer index from a column" do
    assert Repo.one(from(d in Doc, select: d.meta["tags"][d.idx]["name"])) == "green"
  end

  test "dynamic key and dynamic index combined" do
    assert Repo.one(from(d in Doc, select: d.meta[d.label][d.idx]["name"])) == "green"
  end

  test "dynamic key containing a dot resolves via quoted-key form" do
    Repo.update_all(Doc, set: [label: "dotted.key"])
    assert Repo.one(from(d in Doc, select: d.meta[d.label])) == "found"
  end

  test "dynamic key that matches nothing yields nil" do
    Repo.update_all(Doc, set: [label: "absent"])
    assert Repo.one(from(d in Doc, select: d.meta[d.label])) == nil
  end

  test "NULL dynamic segment yields nil, not an error" do
    Repo.update_all(Doc, set: [label: nil])
    assert Repo.one(from(d in Doc, select: d.meta[d.label])) == nil
  end

  test "dynamic segment in WHERE position" do
    assert Repo.exists?(from(d in Doc, where: d.meta[d.label][0]["name"] == "red", select: d.id))
  end

  # ---------------------------------------------------------------------------
  # Boolean extraction: storage-faithful by default, typed on request
  # ---------------------------------------------------------------------------

  test "untyped boolean extraction is storage-faithful (1/0)" do
    assert Repo.one(from(d in Doc, select: d.meta["enabled"])) == 1
    assert Repo.one(from(d in Doc, select: d.meta["disabled"])) == 0
  end

  test "type/2 routes boolean extraction through the :boolean loader" do
    assert Repo.one(from(d in Doc, select: type(d.meta["enabled"], :boolean))) == true
    assert Repo.one(from(d in Doc, select: type(d.meta["disabled"], :boolean))) == false
  end

  test "boolean comparisons in WHERE work without typing" do
    assert Repo.exists?(from(d in Doc, where: d.meta["enabled"] == true, select: d.id))
    refute Repo.exists?(from(d in Doc, where: d.meta["disabled"] == true, select: d.id))
  end
end
