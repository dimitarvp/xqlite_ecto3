defmodule XqliteEcto3.PassthroughAffinityTest do
  use XqliteEcto3.AdapterCase, async: true

  alias Ecto.Migration.Table
  alias XqliteEcto3.Connection

  test "an aliased spelling stores numeric-looking text intact; the affinity rule does not" do
    table = %Table{name: "affinity_boundary"}

    columns = [
      {:add, :id, :integer, [primary_key: true]},
      {:add, :doc, :jsonb, []},
      {:add, :fee, :money, []}
    ]

    for statement <- Connection.execute_ddl({:create, table, columns}) do
      Repo.query!(IO.iodata_to_binary(statement))
    end

    Repo.query!("INSERT INTO affinity_boundary (id, doc, fee) VALUES (1, ?1, ?2)", [
      "007",
      "007"
    ])

    %{rows: [[doc_type, doc, fee_type, fee]]} =
      Repo.query!("SELECT typeof(doc), doc, typeof(fee), fee FROM affinity_boundary")

    assert {doc_type, doc} == {"text", "007"}
    assert {fee_type, fee} == {"integer", 7}
  end
end
