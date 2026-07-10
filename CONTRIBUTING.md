# Contributing to MongrelDB Odin

Thanks for taking the time to help the MongrelDB Odin client. This document
describes how to propose a change, what we expect from a pull request, and the
coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical details,
not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Odin client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Odin`](https://github.com/visorcraft/MongrelDB-Odin)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Odin.git
   cd MongrelDB-Odin
   git remote add upstream https://github.com/visorcraft/MongrelDB-Odin.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-alias`, `feature/vector-search`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the preflight
   (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Odin`. Fill
   in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

Run the full CI preflight locally (requires Odin and libcurl-dev):

```sh
# Build the library warning-clean.
odin build mongreldb -build-mode:lib -vet -strict-style

# Build the examples (each is a single-file package; use -file).
for ex in examples/*.odin; do
  name=$(basename "$ex" .odin)
  odin build "$ex" -file -collection:mdb=. -out:build/"$name" -vet -strict-style
done

# Run the suite. The live tests self-skip without a daemon; the wire-shape
# test always runs.
odin test tests -collection:mdb=. -vet -strict-style
```

All steps must pass warning-clean under `-vet -strict-style`. If a check fails,
fix the root cause - don't silence the compiler or skip the test.

To run the live integration suite against a running `mongreldb-server`:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 odin test tests -collection:mdb=.
```

Live tests self-skip when no server is reachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test in
  `tests/`. Query wire-format changes: cover the exact outgoing JSON keys (the
  `column_to_json_string` helper is exposed for exactly this). Daemon-dependent
  coverage: a live test that skips cleanly when no server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Don't
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Odin

- **Version.** Track a recent Odin dev build. The client uses `core:fmt`,
  `core:mem`, `core:strings`, `core:os`, and the C FFI (`foreign import`).
- **Dependencies.** libcurl is the only runtime dependency beyond the Odin core
  library. The JSON layer is bundled and dependency-free - do not pull in an
  external JSON library. New third-party dependencies must be MIT or
  Apache-2.0 licensed and justified.
- **Memory model.** Document ownership in the doc comments. Builders
  (`QueryBuilder`) and batches (`Transaction`) own dynamic storage and must be
  freed with `free_query_builder` / `free_transaction`. Result slices returned
  by `execute` / `commit` / `sql` are owned by the caller until their owning
  JSON value is destroyed. All allocations come from `context.allocator`.
- **Errors.** Return `Mongrel_Error` from every public procedure. Never leak
  memory on an error path.
- **Naming.** `snake_case` for procedures and types, with a trailing underscore
  where a name would otherwise clash with a keyword (`where_`, `limit_`).
  `MONGREL_*` is not used - the package is imported as `mongreldb`.
- **Style.** Tabs for indentation, opening brace on the same line. Run the Odin
  formatter (`odin fmt`) if you have it, but matching the surrounding style is
  what matters. `-vet -strict-style` must be clean.

### Commit messages

- Subject line: imperative mood, <= 72 characters, no trailing period.
  Example: `Add FM-index full-text condition to query builder`.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff shows the
  what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line when
  applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no `Generated
  with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Odin client version (from git tag).
- Your Odin version (`odin version`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you're trying to
solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue. Report it
privately through GitHub's private vulnerability reporting - the repository's
**Security** tab -> **Report a vulnerability**. The full policy is in
[`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Odin client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the same
license.

- Do **not** paste code from other database clients unless you have done a
  license review first.
- New third-party dependencies must be MIT or Apache-2.0 licensed.

Thanks again - looking forward to your PR.
