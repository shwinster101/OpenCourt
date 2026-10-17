# Staged copies of the legacy repositories' agent docs

These files belong in `PickUpBois/PickUp` and `PickUpBois/PickUpHasura` (as each repo's `CLAUDE.md`,
`AGENTS.md` and, for PickUpHasura, `README.md`). They were written on 2026-10-17 and committed on
each repo's `claude/pickup-opencourt-migration-rbgxlp` branch inside the review session, but **the
push was refused**: the Claude GitHub App is not installed on the `PickUpBois` organisation (git and
the GitHub API both answered 403), so the commits exist only in that session's container.

They are staged here so the work is not lost. Once an owner of `PickUpBois` installs the app (or the
files are copied by hand), delete this folder: the legacy repositories are the canonical home, and
the files are not meant to be maintained in two places. Both legacy repositories are frozen, so the
copies will not drift in the meantime.
