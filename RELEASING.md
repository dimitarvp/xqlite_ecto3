# Releasing xqlite_ecto3

Pure Elixir, no native code: a release is one Hex package, and the
repository has no release workflow — `.github/workflows/` holds `ci.yml`
only, so pushing a tag builds nothing. The one complication is the
dependency on xqlite, which is pre-1.0.

## The xqlite pin

`xqlite_dep/0` in `mix.exs` resolves the dependency two ways:

- `XQLITE_PATH` unset → the Hex release, pinned patch-level
  (`{:xqlite, "~> 0.X.0"}`; the file holds the series in force).
- `XQLITE_PATH` set → `{:xqlite, path: …, override: true}`, a local
  working copy, for developing against unreleased xqlite API.

xqlite is pre-1.0, so its minor version is where breaking changes land.
Each adapter release therefore pins exactly one xqlite minor series at
patch level: `~> 0.X.0` accepts `0.X.1` and refuses `0.(X+1).0`. Never
publish a release whose pin allows an xqlite the suite has not run
against.

To bump the pin:

1. Edit the bound in `xqlite_dep/0` in `mix.exs`.
2. `env -u XQLITE_PATH mix deps.update xqlite`, so `mix.lock` records
   the Hex release and not a path override.
3. Work through section B of `UPGRADE_PLAYBOOK.md` in the xqlite repo.
   It is the checklist for what a new xqlite can move underneath this
   adapter: the constraint-parse shapes, the vendored integration
   census against its recorded anchor, the test rationales that depend
   on SQLite compile options, and the SQLite version claims in
   `README.md` and `ECTO_INTEGRATION_TAGS.md`.
4. Update the Compatibility paragraph in `README.md`, which names the
   pinned xqlite series, and add a `CHANGELOG.md` line.

## Before you start

- Run the full suite with `XQLITE_PATH` unset. A path override compiles
  against your local xqlite checkout and hides the fact that the code
  needs API no Hex release has:

  ```bash
  env -u XQLITE_PATH mix deps.get
  env -u XQLITE_PATH mix xqlite_ecto3.test.seq
  ```

- `mix verify` passes. It is the alias in `mix.exs`: format check,
  warnings-as-errors compile, dependency audit, sobelow, dialyzer, the
  full suite through `mix xqlite_ecto3.test.seq`, and a stamp
  recording the tree it ran on.
- CI green on the commit you are about to tag, including the two lanes
  that only CI runs: the fresh-resolve lane (`mix deps.unlock --all`
  then `mix deps.get`, which is what a new user's dependency resolution
  does) and the telemetry-off lane (`XQLITE_ECTO3_TELEMETRY=off`,
  where the instrumentation compiles to no-ops).
- Read `README.md` top to bottom. On the first publish its Installation
  section has to stop saying the package is not on Hex and offering a
  git dependency, and start showing the Hex snippet; the Compatibility
  paragraph must name the xqlite series `mix.exs` actually pins.
- `CHANGELOG.md`. The file already carries a `## [0.1.0] - YYYY-MM-DD`
  section plus `[Unreleased]` and `[0.1.0]` link lines at the bottom.
  For the first release, fold everything currently under
  `## [Unreleased]` into the `## [0.1.0]` section and put the real date
  in that heading. For later releases, rename `## [Unreleased]` to
  `## [X.Y.Z] - YYYY-MM-DD` and add a link line beside the existing
  ones:
  `[X.Y.Z]: https://github.com/dimitarvp/xqlite_ecto3/releases/tag/vX.Y.Z`

## Version bump

One place: `@version` in `mix.exs`. `project/0` uses it for `version:`,
and `docs/0` derives `source_ref:` from it as `"v"` plus the version
with a `-dev` suffix stripped, so the docs' source links follow on
their own.

Drop the `-dev` suffix to release. Hex reads `0.1.0-dev` as a
pre-release version, and a user writing `{:xqlite_ecto3, "~> 0.1"}`
would not resolve to it. Because `source_ref` already strips the
suffix, dropping it does not move the docs link.

Commit the bump on its own.

## Tag and release notes

```bash
git add mix.exs CHANGELOG.md README.md
git commit -m "bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

Nothing runs on the tag, so create the GitHub release and write its
body yourself. The version's CHANGELOG section is the source, and the
CHANGELOG's own link lines already point at
`releases/tag/vX.Y.Z`, so the release has to exist for them to resolve:

```bash
gh release create vX.Y.Z --title vX.Y.Z --notes-file notes.md
```

## Publish to Hex

Before the first publish, look at what will ship:

```bash
mix hex.build     # writes xqlite_ecto3-X.Y.Z.tar and lists its contents
mix docs          # builds the hexdocs locally; read the warnings
```

`mix hex.build`'s file list must match `package/0` in `mix.exs` —
`lib`, `guides`, `.formatter.exs`, `mix.exs`, `README.md`,
`LICENSE.md`, `CHANGELOG.md` — with `lib/mix/tasks/` excluded, so this
repository's `mix xqlite_ecto3.test.seq` task does not turn up in
dependent projects' task lists. Check the rest of `package/0` while you
are there: `licenses`, the `links` map, and `description`, which is the
line Hex search shows. `mix docs` is the only place a broken guide link
shows up before the docs are public; `docs/0` lists its `extras:`
explicitly, so a new file under `guides/` that nobody added there ships
inside the package but never appears in the docs. The tarball is
gitignored — delete it or leave it.

Then:

```bash
mix hex.publish
```

It prints the package contents and the docs it is about to build, asks
for confirmation, and uploads both.

Account setup, the same as for xqlite, and it bites once per machine:

- Hex 2.5 and newer authenticate through `mix hex.user auth`, an OAuth
  device flow. Without TOTP two-factor enabled on the hex.pm account
  the token comes back silently read-only and the publish fails with a
  permissions error. Turn 2FA on before the first publish.
- A toolchain bump reinstalls hex and orphans the stored credential: a
  machine that could publish yesterday reports having no credentials.
  Re-run `mix hex.user auth`.
- There is no CLI key management any more. The fallback is a key
  generated in the hex.pm web dashboard and exported as `HEX_API_KEY`
  for the publish command.

## After the release

- Check that `https://hexdocs.pm/xqlite_ecto3` renders and that the
  guides are in the sidebar.
- Add a fresh `## [Unreleased]` heading to `CHANGELOG.md`, and an
  `[Unreleased]` link line comparing the new tag to `HEAD` if you keep
  that convention.
- The Hex version and download badges at the top of `README.md` start
  resolving once the package exists.
- If you resume development on a `-dev` version, remember that
  `source_ref` strips the suffix: the docs of an unreleased `-dev`
  build link into the last released tag.
