# Ecto Integration Test Tags

Status of every exclusion tag from the shared ecto/ecto_sql integration test suite.
Bundled SQLite version: **3.53.2**. Shared files loaded: **16/18**.

| Tag | Status | Notes |
|-----|--------|-------|
| `:add_column_if_not_exists` | supported | adapter checks `PRAGMA table_info()` per alter block; filters no-ops |
| `:alter_foreign_key` | excluded | SQLite has no ALTER TABLE MODIFY COLUMN for FK constraints |
| `:alter_primary_key` | excluded | SQLite cannot add a PRIMARY KEY column via ALTER TABLE |
| `:array_type` | excluded | SQLite has no native array column type |
| `:assigns_id_type` | needs adapter work | user-assigned PKs work in SQLite; may need PK handling adjustments |
| `:bitstring_type` | excluded | SQLite has no native bitstring type |
| `:concat` | supported | SQLite 3.44+ has `concat()` and `concat_ws()` |
| `:concurrent_poolrepo_transactions` | excluded | SQLite single-writer: concurrent transactions from separate processes deadlock with pool_size 1 |
| `:delete_with_join` | supported | conservative rewrite to `DELETE FROM t WHERE pk IN (SELECT …)`; raises `Ecto.QueryError` on shapes we can't safely transform |
| `:duration_type` | excluded | SQLite has no native duration/interval type |
| `:foreign_key_constraint` | excluded | SQLite FK violations report no constraint name |
| `:insert_cell_wise_defaults` | excluded | SQLite multi-row VALUES requires all rows to have the same columns |
| `:insert_select` | supported | `insert_all` emits NULL for Ecto-padded uneven rows; trivial WHERE injected to disambiguate `ON CONFLICT` |
| `:json_extract_path` | needs adapter work | `json_extract` returns 1/0 for booleans; adapter needs coercion layer |
| `:like_match_blob` | excluded | SQLite compiled with `SQLITE_LIKE_DOESNT_MATCH_BLOBS` rejects LIKE on BLOBs |
| `:lock_for_migrations` | excluded | SQLite is single-writer; no advisory lock mechanism |
| `:map_type_schemaless` | excluded | JSON stored as TEXT; without schema Ecto cannot invoke the JSON decoder |
| `:microsecond_precision` | excluded (permanent) | SQLite's `strftime %f` is millisecond-precision; microsecond-exact datetime arithmetic rounds. Non-arithmetic µs round-trips via TEXT storage work fine (see types_test.exs). Not an adapter gap. |
| `:modify_column` | supported (opt-in) | full SQLite table-rebuild dance behind `support_alter_via_table_rebuild: true` repo config; batches all changes in one alter block into a single rebuild |
| `:multicolumn_distinct` | supported | SQLite DISTINCT applies to full rows |
| `:on_delete_default_all` | supported | SQLite supports `ON DELETE SET DEFAULT` |
| `:on_delete_default_column_list` | excluded | SQLite `ON DELETE SET DEFAULT` applies to all FK columns; no column-list syntax |
| `:on_delete_nilify_column_list` | excluded | SQLite `ON DELETE SET NULL` applies to all FK columns; no column-list syntax |
| `:placeholders` | supported | incidentally covered by the `INSERT SELECT ... WHERE 1` disambiguator; the `repo.exs:1092` (`:placeholders + :with_conflict_target`) location was re-enabled after verification |
| `:prefix` | excluded | SQLite has no schema/namespace concept |
| `:remove_column_if_exists` | supported | adapter checks `PRAGMA table_info()` per alter block; filters no-ops |
| `:right_join` | supported | SQLite 3.39+ supports RIGHT JOIN and FULL OUTER JOIN |
| `:selected_as_with_group_by` | supported | SQLite allows column alias references in GROUP BY |
| `:selected_as_with_having` | supported | SQLite allows column alias references in HAVING |
| `:selected_as_with_order_by` | supported | SQLite allows column alias references in ORDER BY |
| `:selected_as_with_order_by_expression` | supported | SQLite allows expressions on aliases in ORDER BY |
| `:transaction_checkout_raises` | supported | not excluded and passes (`--only transaction_checkout_raises` ⇒ 1 passed): `checkout` raises `DBConnection.ConnectionError` on a raw `BEGIN` |
| `:transaction_isolation` | excluded | SQLite has no SQL-standard isolation levels |
| `:values_list` | supported | not excluded and all 5 subtests pass (`--only values_list` ⇒ 5 passed); `delete_all` works via the DELETE+JOIN rewrite |
