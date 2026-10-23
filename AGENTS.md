# AGENTS.md

## Environment

- `/tmp` is not writable on Termux. Put temporary files in `$TMPDIR`.

## Patches

- Anchors must be exact and unique. A patch that refuses to apply is the safe outcome — never force it through with `sed` or any other rewrite.

## Documentation

- `README.md` and `README.zh.md` must be updated together, or the two versions drift apart.

## Commits

- Commit messages use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) and are written in English.
- Keep the body short; small changes do not need one.

## Versioning

- The `v<version>` form is only for release-note titles and references in documentation. Everywhere else — git tags in particular — use plain SemVer, e.g. `1.11.0`.
- No release without a substantive code change. Documentation-only commits stay unreleased.
