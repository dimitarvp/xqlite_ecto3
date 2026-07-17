defmodule XqliteEcto3.SchemalessMapTest do
  use XqliteEcto3.AdapterCase, async: true

  setup_all do
    create_table!("sm_items", "id INTEGER PRIMARY KEY, meta TEXT")
  end

  setup do
    clear_table!("sm_items")
  end

  test "type/2 :map decodes JSON on schemaless selects" do
    Repo.insert_all("sm_items", [[id: 1, meta: ~s({"color":"red","sizes":[1,2]})]])

    assert [%{"color" => "red", "sizes" => [1, 2]}] =
             Repo.all(from(t in "sm_items", select: type(t.meta, :map)))
  end

  test "type/2 :map on a JSON path extracts nested structures" do
    Repo.insert_all("sm_items", [[id: 1, meta: ~s({"nested":{"a":1}})]])

    assert [%{"a" => 1}] =
             Repo.all(from(t in "sm_items", select: type(t.meta["nested"], :map)))
  end

  test "type/2 :map inside a select map decodes alongside plain fields" do
    Repo.insert_all("sm_items", [[id: 7, meta: ~s({"x":1})]])

    assert [%{id: 7, meta: %{"x" => 1}}] =
             Repo.all(from(t in "sm_items", select: %{id: t.id, meta: type(t.meta, :map)}))
  end

  test "untyped schemaless select returns the raw stored TEXT" do
    Repo.insert_all("sm_items", [[id: 1, meta: ~s({"x":1})]])

    assert [~s({"x":1})] = Repo.all(from(t in "sm_items", select: t.meta))
  end
end
