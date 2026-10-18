# AGENTS.md — PickUp (iOS, 2021) — frozen legacy source

> **Read [`CLAUDE.md`](./CLAUDE.md) first.** It states the owner's 2026-10-17 ruling: this
> repository is a read-only reference for the migration of PickUp into
> [shwinster101/PickUp](https://github.com/shwinster101/PickUp). When this file and
> CLAUDE.md disagree, CLAUDE.md wins.

- **Do not build features here.** No dependency upgrades, no CI, no new screens. The 2021 backend
  host is dead and the Firebase project is retired.
- **Do read here** when you need to know what the 2021 app did: the screens under `PickUp/views/`,
  the operations under `PickUp/resources/graphql/`, the services under `PickUp/services/`.
- **Write findings in OpenCourt**, in a dated `working/` note there, not in this repository.
- **The brand lives on:** `PickUp/Assets.xcassets/logo.imageset/Logo.png` and
  `AppIcon.appiconset/Picture3-1024.png` are the PickUp logo and icon; OpenCourt carries copies.
