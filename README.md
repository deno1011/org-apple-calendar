# org-apple-calendar

The **calendar half** of a personal GTD system that lives in Emacs/org-mode and
mirrors to Apple on macOS. It is the sibling of
[`org-apple-reminders`](https://github.com/deno1011/org-apple-reminders):

| Package | Owns | Apple target |
|---|---|---|
| `org-apple-reminders` | **dated tasks** (org `SCHEDULED`) | Apple **Reminders** |
| `org-apple-calendar` (this) | **appointments** + **calendar reading** | Apple **Calendar** (iCloud) |

> Status: **design phase.** This repo holds the architecture and rules;
> implementation follows the layered model in [`ARCHITECTURE.md`](ARCHITECTURE.md).
>
> **Decision (2026-06-17): pluggable write backend — EventKit default, CalDAV
> optional.** `org-apple-calendar-write-backend` selects `'eventkit` (default:
> local, credential-free, robust) or `'caldav` (optional: server-side sync via
> `org-caldav`, with its iCloud `url.el` fragility left to that user to tune —
> see *Known risks*). Reading is always EventKit and backend-agnostic. Build
> order: read layers (L1/L2) → ingest → EventKit write backend (caldav stays
> available behind the same interface). The interim `org-caldav` config in
> `emacs-mac-setup` (`modules/55_calendar.org` + `local.org`) becomes the
> optional `'caldav` backend's wiring.

## Why

org-mode is the single source of truth for the whole GTD system. Apple is a
**thin edge** so things show up on the iPhone and in the macOS Calendar app:
- appointments you enter in Emacs appear in Apple Calendar,
- events created on the phone flow back into org,
- *all* calendars can be read for availability ("when am I free?"),
- deadlines that live in calendars you don't own (university, clubs) become
  proper GTD tasks.

You never have to *manage* the system inside Apple — org-agenda is the one pane
of glass.

## The two entry types (the core distinction)

| Type | "feels like" | org form | lands in |
|---|---|---|---|
| **Appointment** | *um dann* — fixed date/time | active timestamp `<2026-06-25 Wed 09:30-10:15>` in `calendar.org` (no TODO) | Apple **Calendar** ("Org") |
| **Dated task / deadline** | *bis dann* — do something by a date | `SCHEDULED:` on a GTD heading | Apple **Reminders** ("Anstehend"), via `org-apple-reminders` |

The calendar is the *hard landscape*: only true appointments go there, never
task deadlines. This keeps it uncluttered and trustworthy.

## The rules (how calendars and entries are handled)

1. **Single writer.** Emacs writes to **exactly one** calendar — the dedicated
   iCloud **"Org"** calendar. Every other calendar is **read-only** to us.
2. **Never write to managed/subscribed calendars** (university feeds, club
   calendars, family calendars). They are authoritative read-only sources;
   writing would corrupt them and break on their next update.
3. **Classification happens on the org side, at import** — because you cannot
   edit a managed calendar to tag its entries. An external event is either:
   - an **appointment** → shown read-only in org-agenda, or
   - a **deadline/task** → *proposed* as a GTD `SCHEDULED` task (you confirm).
4. **Adoption is explicit.** If an external event should become part of your
   personal hard landscape, run `org-apple-calendar-adopt-event-at-point` from
   the upcoming/mirror view. It copies that occurrence to `calendar.org`,
   creates a linked event in the writable **"Org"** calendar, and marks the
   source event `ignore` so the mirror does not show both copies.
5. **"See only org."** You do **not** physically merge/delete managed calendars
   (impossible — the source re-syncs them). Instead: read them into org-agenda,
   adopt the few events you want in the visible "Org" calendar, and hide noisy
   calendars in Calendar.app's sidebar. Same effect, robust, reversible.
6. **Availability** ("when am I free") is computed by reading **all** calendars
   (busy intervals), not just "Org".
7. **Events have a role, not just a time:** `busy` (blocks my time), `info`
   (time-bound context — a colleague's slot, a custody week, school — shown but
   never blocking), or `ignore`. Role = per-event **override** (set in the GTD
   view, persisted) > per-calendar policy > Apple "Show As" availability >
   default busy. Only `busy` events reduce free slots. See `ARCHITECTURE.md`
   → *Event classification & roles*. The override exists because read-only
   third-party calendars can't be fixed at the source.
8. **Date convention** (shipped in `org-apple-reminders` v1.16): org `SCHEDULED`
   ⇄ Apple due date. Apple shows an item on its due day (like `SCHEDULED`), not
   ahead of time (like `DEADLINE`). `DEADLINE` is not synced.

## Components

**Read** is always **EventKit/JXA** (local, credential-free, same pattern as
`org-apple-reminders`). **Write** is a **pluggable backend**:

1. **Read + ingest — all calendars** (EventKit, backend-agnostic). Read every
   calendar for availability and read-only agenda display; ingest deadline-like
   external events into GTD tasks.
2. **Write — appointments** to the dedicated "Org" calendar from `calendar.org`,
   via the selected backend:
   - `'eventkit` (default) — local, no credentials.
   - `'caldav` (optional) — `org-caldav`, for server-side multi-device sync;
     the user tunes its iCloud `url.el` quirks themselves.
3. **Adopt — external appointment → Org-owned appointment.** The mirror remains
   the read-only intake layer, but `org-apple-calendar-adopt-event-at-point`
   promotes a chosen external occurrence into `calendar.org` and the writable
   "Org" calendar, then hides the source event from the mirror via override.

Recurrence, all-day vs timed, and timezones are the real work of the EventKit
write backend and are called out in `ARCHITECTURE.md`.

## Relationship to the GTD setup

- GTD home: the split org files under `~/emacs/data/org/` (`inbox.org`,
  `gtd/*.org`, Horizons in `gtd.org`), plus `calendar.org` for appointments.
- `org-agenda` already unifies the view: appointments (active timestamps) +
  dated tasks (`SCHEDULED`) + deadlines, across `calendar.org` and the GTD files.
- See the personal setup manual: `~/emacs/data/org/gtd/apple-reminders-setup.org`.

## Known risks / findings (2026-06-17)

- **org-caldav + iCloud + url.el is fragile.** Two problems hit during setup:
  1. url.el's *401-then-retry* auth **stalls** against iCloud — it must send
     **preemptive Basic auth** (verified: preemptive → `207`, retry path hangs).
     Worked around by advising `url-http-create-request`.
  2. `org-caldav-check-connection` then fails with
     `wrong-type-argument number-or-marker-p ""` — `url-dav` parses iCloud's
     PROPFIND response and yields an empty `DAV:status` instead of a number.
     **Open.**
- **Auth-source/Keychain matching:** url.el queries HTTPS creds with port `443`;
  a port-less Keychain Internet-password entry is **not** matched and url.el
  falls back to an interactive prompt (which wedges the daemon). Entries must be
  stored **with port 443** (`security … -P 443`). Handled in the
  `my/keychain-set-internet` primitive + `my/caldav-set-password`.
- **org-id scan cost:** `org-caldav` triggers `org-id` location updates across
  all agenda + `org-id-extra-files` (here ~69 files incl. the wiki) on each sync.

These findings are the main argument for evaluating the **EventKit write path**
(option 2) instead of `org-caldav` — tracked in [`ARCHITECTURE.md`](ARCHITECTURE.md).
