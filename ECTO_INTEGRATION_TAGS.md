# Ecto Integration Test Tags

Status of every exclusion from the shared ecto/ecto_sql integration test
suite — the tag table first, then the location-scoped single-test
exclusions. Bundled SQLite version: **3.53.2**. Shared files loaded:
**16/18**.

| Tag | Status | Notes |
|-----|--------|-------|
| `:add_column_if_not_exists` | supported | adapter checks `PRAGMA table_info()` per alter block; filters no-ops |
| `:alter_foreign_key` | excluded | the rebuild engine refuses `modify :col, references(...)` up front with guidance — it reconstructs foreign keys from the existing schema and cannot merge a new or repointed one in. An adapter gap (`F-B7-25-feature` in BACKLOG), not a SQLite limit |
| `:alter_primary_key` | excluded | two separate causes: migration.exs:640 hits the reference refusal above; migration.exs:705 ADDs a PRIMARY KEY column, which SQLite's ALTER TABLE cannot do (no rebuild involved — it only engages for `modify`) |
| `:array_type` | excluded | the adapter DOES ship arrays (`{:array, _}` maps to TEXT; `XqliteEcto3.Types.Array` stores JSON with round-trips) — what cannot work is the Postgres array operator surface these tests exercise (`x in t.ints`, `update_all` `push:`/`pull:`) and untyped/fragment decoding |
| `:assigns_id_type` | supported (3/4) | user-assigned PKs work; the tag's one failing test is `migration.exs:664`, location-excluded — the up-front reference refusal (`F-B7-25-feature`), nothing to do with PK handling |
| `:bitstring_type` | excluded | SQLite has no native bitstring type |
| `:concat` | supported | SQLite 3.44+ has `concat()` and `concat_ws()` |
| `:delete_with_join` | supported | conservative rewrite to `DELETE FROM t WHERE pk IN (SELECT …)`; raises `Ecto.QueryError` on shapes we can't safely transform |
| `:duration_type` | excluded | Ecto's `:duration` dumps a `%Duration{}` struct our param encoder has no clause for (it reaches the JSON fallback and raises) — our gap, not SQLite's; the upstream tests additionally assert Postgres `fields:`/`precision:` truncation |
| `:foreign_key_constraint` | supported | not excluded and all 6 pass (`--only foreign_key_constraint` ⇒ 6 passed); rich FK diagnostics (opt-in `rich_fk_diagnostics: true`) synthesize the `<table>_<col>_fkey` name that `foreign_key_constraint/3` matches on |
| `:insert_cell_wise_defaults` | supported (7/8) | only `repo.exs:864` actually inserts uneven rows (location-excluded): Ecto pads the missing cell with NULL, so the column DEFAULT never applies. The other seven tagged tests pass and run |
| `:insert_select` | supported | `insert_all` emits NULL for Ecto-padded uneven rows; trivial WHERE injected to disambiguate `ON CONFLICT` |
| `:json_extract_path` | supported (4/5, one permanent location exclusion) | untyped boolean SELECTs return 1/0 by design — no load hook exists for untyped selects, so no coercion layer is coming; `type.exs:362` is location-excluded and the sanctioned fix is explicit `type(..., :boolean)` (see json_extract_path_test.exs) |
| `:like_match_blob` | supported | bundled SQLite 3.53.2 is NOT built with `SQLITE_LIKE_DOESNT_MATCH_BLOBS`; `LIKE` matches BLOB operands, so both tagged `type.exs` tests pass un-excluded. (`:binary` columns are declared BLOB — no affinity — and the storage class follows the value: text for valid UTF-8, blob otherwise; LIKE matches both) |
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

## Location-scoped exclusions

Individual upstream tests excluded by `{:location, {file, line}}`; the
full rationales live next to each tuple in `test/test_helper.exs`.

| File:line | Why |
|-----------|-----|
| `ecto_sql .../sql/transaction.exs:161` | fails from two adapter-suite settings (test pool_size 1 + the driver's BEGIN IMMEDIATE default), not a SQLite limit — passes at pool ≥ 2 with `:deferred` mode |
| `ecto_sql .../sql/alter.exs:44` | a schemaless SELECT after `modify :numeric` returns the storage value (INTEGER 1), never `%Decimal{}` — types live at the Ecto schema layer by design |
| `ecto_sql .../sql/logging.exs:74` | UUIDs are stored as TEXT by default, so query-telemetry params carry the 36-char string, not Postgres's 16-byte binary |
| `ecto .../cases/type.exs:362` | untyped boolean SELECT returns 1/0 (no load hook on untyped selects); use `type(..., :boolean)` |
| `ecto_sql .../sql/migration.exs:664` | `modify` with a `references(...)` type — the up-front reference refusal (`F-B7-25-feature`), not a SQLite limit |
| `ecto .../cases/repo.exs:864` | uneven `insert_all` rows: the NULL Ecto pads in suppresses the column DEFAULT |

Line pointers in this table and in `test_helper.exs` name the `test`
line, never the `@tag` line: an ExUnit line filter snaps to the nearest
test at or before the given line, so a pointer at a `@tag` line silently
runs the preceding test and reports a false all-clear.
