defmodule XqliteEcto3.FkConstraintDefaultConfigTest do
  @moduledoc """
  With the shipped default `rich_fk_diagnostics: false`, SQLite's generic FK
  error names no constraint, so `to_constraints/2` must return `[]` and let
  ecto_sql re-raise the structured error. A nil constraint name instead
  crashed Ecto's suffix/prefix/regex matching and rendered `* nil` advice.
  The main suite's repos run with rich diagnostics ON, which is why this
  file boots its own repo.
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset

  defmodule PlainRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule Child do
    use Ecto.Schema

    schema "fk_plain_child" do
      field(:parent_id, :integer)
    end
  end

  setup do
    db =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_fk_plain_#{:erlang.unique_integer([:positive])}.db"
      )

    start_supervised!({PlainRepo, database: db, pool_size: 1, rich_fk_diagnostics: false})

    PlainRepo.query!("CREATE TABLE fk_plain_parent (id INTEGER PRIMARY KEY)")

    PlainRepo.query!(
      "CREATE TABLE fk_plain_child (id INTEGER PRIMARY KEY, " <>
        "parent_id INTEGER REFERENCES fk_plain_parent(id))"
    )

    on_exit(fn -> File.rm(db) end)
    :ok
  end

  test "an FK violation surfaces the structured error, not a nil-name constraint" do
    cs = change(%Child{}, parent_id: 999)

    err = assert_raise XqliteEcto3.Error, fn -> PlainRepo.insert(cs) end

    assert %XqliteEcto3.Error{
             type: :constraint_violation,
             details: %XqliteEcto3.Error.Constraint{subtype: :constraint_foreign_key}
           } = err
  end

  test "a declared foreign_key_constraint with match: :suffix does not crash" do
    cs =
      %Child{}
      |> change(parent_id: 999)
      |> foreign_key_constraint(:parent_id, name: "_fkey", match: :suffix)

    assert_raise XqliteEcto3.Error, fn -> PlainRepo.insert(cs) end
  end
end
