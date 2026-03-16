defmodule XqliteEcto3.UnicodeBinaryTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule UB do
    use Ecto.Schema
    import Ecto.Changeset

    schema "ub_records" do
      field(:text_field, :string)
      field(:blob_field, :binary)
      timestamps()
    end

    def changeset(record, attrs \\ %{}),
      do: record |> cast(attrs, [:text_field, :blob_field])
  end

  setup_all do
    create_table!(
      "ub_records",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, text_field TEXT, blob_field BLOB, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
    )
  end

  setup do
    clear_table!("ub_records")
  end

  # ---------------------------------------------------------------------------
  # Unicode
  # ---------------------------------------------------------------------------

  test "ASCII text round-trips" do
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: "hello world"}))
    assert Repo.get(UB, r.id).text_field == "hello world"
  end

  test "Unicode Latin characters round-trip" do
    text = "café résumé naïve"
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    assert Repo.get(UB, r.id).text_field == text
  end

  test "CJK characters round-trip" do
    text = "你好世界"
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    assert Repo.get(UB, r.id).text_field == text
  end

  test "emoji round-trip" do
    text = "Hello 🌍🚀💎"
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    assert Repo.get(UB, r.id).text_field == text
  end

  test "mixed scripts round-trip" do
    text = "English 日本語 العربية Ελληνικά हिन्दी"
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    assert Repo.get(UB, r.id).text_field == text
  end

  test "empty string stored as nil by SQLite" do
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: ""}))
    # SQLite stores empty strings as NULL for TEXT columns via Ecto
    assert Repo.get(UB, r.id).text_field == nil
  end

  test "unicode string queryable with where" do
    {:ok, _} = Repo.insert(UB.changeset(%UB{}, %{text_field: "café"}))
    {:ok, _} = Repo.insert(UB.changeset(%UB{}, %{text_field: "hello"}))

    results = Repo.all(from(u in UB, where: u.text_field == "café", select: u.text_field))
    assert results == ["café"]
  end

  test "unicode string queryable with like" do
    {:ok, _} = Repo.insert(UB.changeset(%UB{}, %{text_field: "東京タワー"}))
    {:ok, _} = Repo.insert(UB.changeset(%UB{}, %{text_field: "大阪城"}))

    results = Repo.all(from(u in UB, where: like(u.text_field, "東京%"), select: u.text_field))
    assert results == ["東京タワー"]
  end

  # ---------------------------------------------------------------------------
  # Long strings
  # ---------------------------------------------------------------------------

  test "long string (10KB) round-trips" do
    text = String.duplicate("a", 10_000)
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    fetched = Repo.get(UB, r.id)
    assert String.length(fetched.text_field) == 10_000
    assert fetched.text_field == text
  end

  test "long string (100KB) round-trips" do
    text = String.duplicate("x", 100_000)
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    fetched = Repo.get(UB, r.id)
    assert String.length(fetched.text_field) == 100_000
  end

  # ---------------------------------------------------------------------------
  # Binary / BLOB
  # ---------------------------------------------------------------------------

  test "binary data round-trips" do
    data = <<0, 1, 2, 255, 128, 64>>
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{blob_field: data}))
    assert Repo.get(UB, r.id).blob_field == data
  end

  test "empty binary stored as nil by SQLite" do
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{blob_field: <<>>}))
    # SQLite stores empty blobs as NULL via Ecto
    assert Repo.get(UB, r.id).blob_field == nil
  end

  test "large binary (50KB) round-trips" do
    data = :crypto.strong_rand_bytes(50_000)
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{blob_field: data}))
    fetched = Repo.get(UB, r.id)
    assert byte_size(fetched.blob_field) == 50_000
    assert fetched.blob_field == data
  end

  test "binary with null bytes round-trips" do
    data = <<0, 0, 0, 1, 0, 0, 0, 2>>
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{blob_field: data}))
    assert Repo.get(UB, r.id).blob_field == data
  end

  test "string with newlines and tabs round-trips" do
    text = "line1\nline2\ttabbed\r\nwindows"
    {:ok, r} = Repo.insert(UB.changeset(%UB{}, %{text_field: text}))
    assert Repo.get(UB, r.id).text_field == text
  end
end
