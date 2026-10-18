# CLAUDE.md — PickUp (iOS, 2021) — FROZEN LEGACY SOURCE

**Status (owner ruling 2026-10-17):** "OpenCourt is the modern successor — though keeping the PickUp
namesake and logo will be the path forward: migration of PickUp backend flow to the OpenCourt
structure and working APIs." This repository is therefore a **read-only reference**. The product
PickUp continues in [`shwinster101/OpenCourt`](https://github.com/shwinster101/OpenCourt), whose
`CLAUDE.md`, `docs/FOUNDATION.md`, `docs/LEGACY_PICKUP_BACKEND.md` and `docs/MIGRATION.md` are
canonical. When anything here and anything there disagree, OpenCourt wins.

## What this repository is

- The 2021 PickUp iOS app: SwiftUI, iOS 14, Swift 5, CocoaPods (Firebase 8 Auth/Storage/Messaging,
  Apollo iOS 0.43 codegen, SDWebImageSwiftUI, SwiftUIRefresh). Bundle `PickUpBois.PickUpSportsApp`,
  marketing version 0.1.0.
- Authors: Arian Rahbar (services, view models, the Hasura wiring; 47 commits), David Reynolds (UI;
  30 commits), Ashwin (app icon, the courts-near-me screen; 3 commits). History begins at `8c34855f`
  (2021-06-15), a squash of April–June work that survives only as the titles of 20 closed pull
  requests (backend-auth → UI → profile → events + Apollo → notifications → busyness → profile
  pictures → backend-up). Last commit `496b914e`, 2021-11-06.
- Backend it talked to: Hasura at `https://pickuphasura.herokuapp.com` (`PROD_HOST` in
  `project.pbxproj`), **dead since the Heroku free tier ended; answers 404**. Local dev used the
  Hasura/Firebase emulator stack in `PickUpBois/PickUpHasura`.

## Where things are (for reading, not building)

| Need | Look at |
|---|---|
| What the app let a player do | `PickUp/views/` (111 views: root, auth, home, event, notifications, profile, search, friends, nearme, map, message); the screen-by-screen inventory with live/partial/placeholder status is in OpenCourt `working/2026-10-17-pickup-opencourt-review.md` §3 |
| Every backend call | `PickUp/resources/graphql/*.graphql` (operations) and `fragments/`; generated client `PickUp/API.swift` (27 operations) |
| Identity and transport | `PickUp/services/Services.swift`, `services/interceptors/AuthenticationInterceptor.swift`, `services/GraphQLClient.swift`, `views/root/AppState.swift` — the Firebase UID is sent as `X-Hasura-User-Id` with nothing verifying it |
| Push registration | `PickUp/PickUpAppDelegate.swift`, `views/auth/LoginViewModel.swift`, `SignUpViewModel.swift` (`putDeviceToken`) |
| Domain vocabulary | `PickUp/models/EventModel.swift`, `UserModel.swift`; enums in `API.swift` (`event_type_enum`, `event_status_enum`, `event_attendee_status_enum`, `notification_type_enum`) |
| Brand | `PickUp/Assets.xcassets/logo.imageset/Logo.png` (581×197 wordmark; `Logo-1.png`/`Logo-2.png` are the same image), `AppIcon.appiconset/Picture3-1024.png`; copies live in OpenCourt `assets/img/` |
| Build config | `PickUp/Info.plist` reads `ENV`, `DEV_HOST`, `PROD_HOST` from build settings in `project.pbxproj`; the Apollo codegen build phase downloads the schema from the configured host |

## What the review found here (2026-10-17)

- Live against the backend: sign-up/login, profile and photo, friends (search, request, accept,
  reject, remove), create/delete/invite/join/leave pickups, in-app notifications, enter scores, vote
  MVP, past and upcoming pickups.
- Partial or placeholder: the sport picker (every pickup was created as `tennis`), location (typed
  but never sent), capacity (never enforced), preferences, update pickup, courts near me and
  busyness (hard-coded demo places), the map (Apple Maps search only), feed, posts, likes, chat,
  block/report, forgot password (calls login), GOAT meter.
- Defects worth knowing: sign-up ignores the action status; logout does not remove the device
  token; the date picker is pinned to 2021; several files are not in the Xcode target or would not
  compile (`ModalHalfView`, `PostViewModel`, `views/Busyness/` duplicate of `views/busyness/`);
  `Pods/` and `xcuserdata` are tracked; the unit test target references types that do not exist.
- `GoogleService-Info.plist` holds client-side Firebase configuration for the retired project
  `pickup-774f9` (not a server secret, but do not reuse the project).

## Rules for agents working here

- **Do not build features, upgrade dependencies, add CI or attempt to ship this app.** The web app
  in OpenCourt is the product.
- **Do read freely** to answer "what did 2021 do?"; quote file paths when you report.
- **Write findings in OpenCourt** (`working/<date>-<slug>.md`), not here. The only edits this
  repository should receive are corrections to this file and `AGENTS.md`.
- **Never resurrect the header-trust auth** or copy any credential from this repository anywhere.
