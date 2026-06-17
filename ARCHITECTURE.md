# org-apple-calendar — Architecture & Layer Model

Same discipline as `org-apple-reminders`: a strict layered model, each layer
calls **only** the layer below, internal helpers are `--`-prefixed, public API
is documented per file. The literate source will be one `.org` that tangles to
one `.el` (TBD), with an `ert` suite that stubs the L1 transport boundary.

## Scope of this package

This package implements the **read + ingest** mechanism (option 2 in the
README). The **write path** for appointments (`calendar.org` ↔ iCloud "Org")
is a separate concern — currently `org-caldav`, configured in `emacs-mac-setup`.
The "Write-path decision" section below weighs folding the write path in here
via EventKit.

## Layered model

```
L6  Surface        commands, keymap, org-agenda integration, timers, doctor checks
L5  Business logic refresh cycle; deadline-ingest workflow; availability queries;
                   the "write only to Org" boundary
L4  Org I/O        read-only event mirror file / agenda feed; create+link GTD
                   SCHEDULED tasks from deadlines (idempotent)
L3  Model&mapping  event struct; classification (appointment vs deadline);
                   free/busy intervals; org timestamp formatting
L2  Calendar API   list calendars (+ owned vs subscribed); fetch events in a
                   window; raw free/busy
L1  Primitives     JXA/EventKit transport (run script -> JSON); defcustoms
```

### L1 — System primitives
- `--jxa-run SCRIPT` → run JXA via `osascript`, return raw stdout (sync).
- `--jxa-run-json SCRIPT` → parse JSON result.
- Config defcustoms: which calendars to read, the deadline-detection patterns,
  the read window (past/future days), the read-only mirror file path.
- No business logic. The `ert` suite stubs this boundary.

### L2 — Apple Calendar API
- `--list-calendars` → `[(title id writable subscribed color) …]`. Classifies
  **owned/writable** vs **subscribed/managed/read-only** (EventKit
  `allowsContentModifications`, `type`).
- `--fetch-events CAL-IDS START END` → raw event dicts (uid, title, start, end,
  all-day, notes, url, calendar, recurrence flag).
- `--free-busy START END` → busy intervals across the chosen calendars.

### L3 — Model & mapping
- `--event` struct: uid, title, start, end, all-day-p, calendar, notes, kind.
- `--classify EVENT` → `:appointment` | `:deadline` | `:ignore`. Heuristics:
  deadline-ish titles (`Abgabe`, `Einsendeaufgabe`, `Frist`, `Deadline`, `due`),
  all-day single-day events on managed academic calendars, etc. Tunable +
  always overridable by the user at confirm time.
- `--event->org-timestamp` / `--event->scheduled` formatting.
- free/busy interval merge.

### L4 — Org I/O
- `--write-readonly-mirror EVENTS` → maintain a read-only `calendar-external.org`
  (or feed `org-agenda` directly) so external appointments are visible. Marked
  read-only; **never** pushed anywhere.
- `--ensure-gtd-task EVENT` → create (or update) a linked GTD heading with
  `SCHEDULED:` = the deadline, in the right bucket; idempotent via a stable
  property keyed on the source event uid. Drives `org-apple-reminders` → Apple
  Reminders "Anstehend" through the normal `SCHEDULED` path.

### L5 — Business logic
- **Refresh cycle:** read window → classify → update mirror + free/busy cache.
- **Deadline-ingest workflow:** new deadline events → *propose* GTD tasks →
  user confirms (first; auto for high-confidence patterns later) → `--ensure-gtd-task`.
- **Availability:** `(free-slots START END MIN-DURATION)` from free/busy, for
  planning study/work blocks (e.g. around Einsendeaufgaben deadlines).
- **Write boundary:** this package never writes to Apple calendars; appointment
  writes go through the configured write path (org-caldav today).

### L6 — Surface
- Commands: refresh, ingest-deadlines, show-free-slots, jump-to-source-event.
- `org-agenda` integration for the read-only mirror.
- Optional idle timer for periodic read refresh (read-only ⇒ safe).
- Doctor checks (extend the existing `90_doctor` set).

## Write-path decision: org-caldav vs EventKit

| | **org-caldav** (current) | **EventKit/JXA write** (candidate) |
|---|---|---|
| Mechanism | CalDAV over `url.el` | local Calendar.app via JXA, like reminders |
| Credentials | iCloud app-password in Keychain | none (local app access) |
| Multi-device | server-side, propagates everywhere | relies on Calendar.app sync (also everywhere) |
| Maturity | community tool, but **fragile on iCloud** (see Known risks) | must be built; recurrence/timezones are real work |
| Consistency w/ reminders | different stack | **same stack** as `org-apple-reminders` |

**Recommendation (to decide):** keep `org-caldav` only if the two iCloud bugs
(preemptive auth — fixed; `DAV:status ""` parse — open) are cleanly resolved.
Otherwise build the EventKit write path and retire `org-caldav`, giving one
credential-free, consistent mechanism for both reminders and calendar. The
read+ingest layers above are unaffected by this choice.

## Cross-cutting rules (authoritative)

1. Single writer = the "Org" iCloud calendar.
2. Managed/subscribed calendars: read-only; never written.
3. Classification on the org side, at import; user-confirmable.
4. "See only org": read-into-org + hide-in-Apple, no physical merge/delete.
5. Availability from reading all calendars.
6. `SCHEDULED` ⇄ Apple due date; appointments = active timestamps; `DEADLINE`
   not synced.

## Known risks (snapshot, see README for detail)
- org-caldav + iCloud + url.el: needs preemptive Basic auth; `org-caldav-check-connection`
  yields `DAV:status ""` (open).
- Keychain Internet-password entries must carry port 443 or url.el prompts.
- `org-id` location scan cost on each org-caldav sync.

## Test strategy
- Stub L1 (`--jxa-run`) with canned JSON; drive L2–L5 deterministically.
- `ert` suite mirrors `org-apple-reminders`'s approach (boundary stubbing,
  idempotency tests, classification tables).
