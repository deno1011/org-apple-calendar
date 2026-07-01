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
- **Write dispatch:** appointment writes go through
  `org-apple-calendar-write-backend` — `'eventkit` (this package's EventKit
  writer) or `'caldav` (delegates to `org-caldav`). Reading never writes; only
  the dedicated "Org" calendar is ever written.

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

**DECIDED (2026-06-17): pluggable write backend — EventKit default, CalDAV
optional.** The write path is an abstraction (L5) with selectable backends:

```
org-apple-calendar-write-backend  =  'eventkit  (default)  |  'caldav  (optional)
```

- **Default `eventkit`:** local, credential-free, robust; unifies the stack
  with `org-apple-reminders`. Cost: we implement event write ourselves
  (recurrence, all-day vs timed, timezones, alarms).
- **Optional `caldav`:** keeps `org-caldav` available for server-side
  multi-device sync without Calendar.app. Its iCloud fragility (preemptive
  auth — see Known risks; `DAV:status ""` parse bug) is the *caldav user's*
  concern to tune (url.el tweaks); the default path does not depend on it. Not
  a version regression — the friction lives in `url.el`/`url-dav`, so chasing an
  older `org-caldav` tag is not expected to help.

The **read + ingest layers are backend-agnostic** (reading is always EventKit)
and are built first. Only L5's write dispatch and an `eventkit`/`caldav`
implementation differ between backends.

**Recurrence (EventKit write, done 2026-06-17):** simple org repeaters
(`+Nd/+Nw/+Nm/+Ny`) map to an `EKRecurrenceRule` (frequency + interval, no end)
via `--timestamp-recurrence`; `push-appointments` carries it through. The JXA
must use `ev.addRecurrenceRule(rule)` (assigning `recurrenceRules = [rule]`
raises an unrecognized-selector error in JXA). Hour repeaters and weekday/sexp
patterns are unsupported → keep those native in Apple. Covered by the `ert`
suite (parsing + script generation; live smoke-tested).

**Two-way sync (done 2026-06-17):** `org-apple-calendar-sync-appointments`
reconciles the "Org" calendar with `calendar.org` for non-recurring events:
unlinked timestamped headings are created in Apple; new Apple events are pulled
in as headings; linked events that differ are reconciled by `modDate` (Apple
newer ⇒ pull into org, else push to Apple) tracked in `:APPLE_MOD:`; events gone
from Apple are tagged `:apple-deleted:`/`:APPLE_GONE:` (heading kept); a heading
with `:APPLE_DELETE: t` is deleted in Apple and removed. Linking relies on a
stable `eventIdentifier` stored as `:APPLE_EVENT_ID:` in the heading's property
**drawer (which must precede the timestamp** — otherwise it is not the entry's
property drawer and the link is unreadable). Recurring events are matched (so
not duplicated) but otherwise left untouched. Apple-side edits of *recurring*
series and `DEADLINE`/sexp patterns remain out of scope.

## Cross-cutting rules (authoritative)

1. Single writer = the "Org" iCloud calendar.
2. Managed/subscribed calendars: read-only; never written.
3. Classification on the org side, at import; user-confirmable.
4. "See only org": read-into-org + hide-in-Apple, no physical merge/delete.
5. Availability from reading all calendars.
6. `SCHEDULED` ⇄ Apple due date; appointments = active timestamps; `DEADLINE`
   not synced.

## Event classification & roles (how calendar entries are handled)

The key insight: **a calendar entry is not automatically "I am busy".** Many
entries are time-bound *context* that informs planning without consuming the
user's time — a colleague's training slot ("Training Vladimir"), a custody week
("Kinder bei mir"), the kids' school calendar, week numbers. Treating all events
as busy makes free-slots wrong (it once blocked 20:00 for a colleague's class).

So every event has a **role**:

| Role | Meaning | Effect |
|---|---|---|
| `busy` | consumes my time | removed from free slots |
| `info` | time-bound context (colleague, custody, school) | shown in agenda/mirror, does **not** block |
| `ignore` | noise (e.g. week numbers) | not shown at all |

**Role is decided by priority** (`org-apple-calendar--event-role`):
1. **per-event override** — highest. Kept on the Emacs side (an `(uid . role)`
   alist persisted to `org-apple-calendar-overrides-file`), because the source
   calendars are read-only and Apple's data is often misclassified. Set via
   `org-apple-calendar-override-role` (`C-c k o`) on the event at point in the
   upcoming/mirror views. **This is the safety net.**
2. **per-calendar policy** — `org-apple-calendar-ignore-calendars` /
   `-info-calendars` (classify a whole calendar once: colleagues' schedule,
   family/custody, school → info; week numbers → ignore).
3. **Apple availability** — `EKEvent.availability`; "Show As: Free" ⇒ info.
4. **default** — `busy`.

Only `busy` (and non-all-day) events feed `free-busy`/`free-slots`. All-day
entries are context by nature and never block. `info` events still appear in
the agenda mirror (tagged `:info:`); `ignore` events are dropped.

Rationale for the override being authoritative: with read-only third-party
calendars you cannot fix classification at the source, and maintaining correct
"Show As" on every event by hand is unrealistic — so the GTD side must be able
to overrule, cheaply, per event, and have it persist across re-fetches.

Provider APIs for agents and other non-interactive callers:

- `org-apple-calendar-calendar-classifications` lists the persisted
  per-calendar `busy`/`info`/`ignore` policy and can sync newly discovered
  calendars into the private classification file as default `busy`.
- `org-apple-calendar-set-calendar-role` updates one whole calendar policy.
- `org-apple-calendar-event-role` exposes the effective role decision for one
  event.
- `org-apple-calendar-set-event-role` updates the authoritative per-event
  override.

AI callers should inspect classifications and upcoming events before planning
free time, then write only clear corrections: use `busy` for time the user
actually cannot use, `info` for context that should not block, and `ignore` for
noise.

## Event adoption (external event → Org hard landscape)

The mirror is the AI/GTD intake layer; `calendar.org` is the writable personal
hard landscape. When a mirrored external event should also be visible in Apple
Calendar with only the "Org" calendar enabled, adoption makes that explicit:

1. Read the event at point from the upcoming buffer (`apple-event` text
   property) or the mirror heading (`APPLE_EVENT_UID`, `CALENDAR`, timestamp).
2. Create a new EventKit event in `org-apple-calendar-target-calendar`.
3. Append a linked appointment to `org-apple-calendar-source-file` with
   `ADOPTED_FROM_CALENDAR`, `ADOPTED_FROM_UID`, `ADOPTED_FROM_KEY`,
   `APPLE_EVENT_ID`, and `APPLE_CALENDAR`.
4. Persist an `ignore` override for the source UID so the regenerated mirror
   shows the Org-owned copy rather than duplicating the external source.
5. Refresh the mirror.

`ADOPTED_FROM_KEY` includes the source UID and occurrence start time, so one
source event occurrence is not adopted twice. If a source event is recurring and
Apple exposes the recurrence with one UID, the `ignore` override applies to all
mirror occurrences represented by that UID; adopt recurring commitments
deliberately.

## Known risks (snapshot, see README for detail)
- org-caldav + iCloud + url.el: needs preemptive Basic auth; `org-caldav-check-connection`
  yields `DAV:status ""` (open).
- Keychain Internet-password entries must carry port 443 or url.el prompts.
- `org-id` location scan cost on each org-caldav sync.

## Test strategy
- Stub L1 (`--jxa-run`) with canned JSON; drive L2–L5 deterministically.
- `ert` suite mirrors `org-apple-reminders`'s approach (boundary stubbing,
  idempotency tests, classification tables).
