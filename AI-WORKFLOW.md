# AI-assisted workflow — why this whole system is maintainable at all

This package is one piece of a larger, deeply personalized system: a complete
**GTD setup in Emacs/org-mode that mirrors to Apple on macOS**, built and run by
one person — **but only because an AI assistant carries the load.** Without it,
nobody would have the capacity to create, operate, and keep a system this
tailored alive. This file documents *how* the AI is used across **all** of it,
so the approach is reproducible. (It lives in the calendar repo but describes
the system spanning several repos.)

## The premise

A GTD system is only useful if it is *trusted* and *current*. Keeping a setup
this tailored current — clarifying captures, deciding which calendar entries
block time, ingesting external deadlines, extending the Elisp when life adds a
new case, debugging macOS/EventKit/CalDAV quirks, keeping several repos in sync
and reinstall-safe — is more ongoing work than a busy single parent can sustain
by hand. The AI turns "more than I can maintain" into "a conversation". That is
the whole point.

## The system (what was built)

1. **GTD core (org-mode).** `inbox.org`, `gtd/{next,projects,waiting,someday,
   tickler,reference}.org`, `calendar.org`, Horizons in `gtd.org`, plus
   assistant *coach* skill files (initial-setup, daily, weekly-review,
   inbox-clarifier, scheduling-policy, horizon). One data repo, git-crypt,
   folder-level auto-sync.
2. **org-apple-reminders.** Dated tasks ↔ Apple Reminders. Layered rewrite;
   the `SCHEDULED` ⇄ Apple-due-date convention (v1.16); push/promote to the
   "Anstehend" list; conflict resolution via dual timestamps.
3. **org-apple-calendar (this repo).** Read all calendars, classify
   owned/managed, free/busy + free-slots, a read-only agenda mirror, deadline
   ingest, EventKit write of appointments, and event **roles** (busy/info/
   ignore) with per-event overrides. Optional CalDAV backend (`org-caldav`).
4. **Config + infrastructure (`emacs-mac-setup`).** Literate modules, a layered
   bootstrap (L1 primitives → L2 ops → L3 orchestrator), macOS Keychain
   primitives, a `doctor` of health checks, elpaca package management, and the
   per-Mac `local.org`.
5. **Repo & reinstall discipline.** Four repos kept in sync (config, the two
   packages, the git-crypt data repo); no hard-coded per-Mac IDs; secrets in
   Keychain; everything pushed so a fresh install loses nothing.

## How the AI was used, per aspect

- **Operating the GTD.** Ran the initial-setup coach end-to-end: a mind-sweep
  of ~50 open loops → clarified each → organized into buckets with one concrete
  NEXT per project, parked life-direction items in Horizons; ran the weekly
  review to prune stale data; classified inbox items; decided what becomes a
  task vs. reference vs. someday.
- **Reminders.** Rewrote the package into clean layers; designed and shipped the
  `SCHEDULED` ⇄ due-date convention (because Apple shows items on the due day,
  like `SCHEDULED`, not ahead like `DEADLINE`) with tests + checkdoc + a version
  bump and `stable` tag; promoted dated tasks to "Anstehend"; decommissioned the
  old Apple-as-GTD lists, migrating worthwhile notes into the org files first.
- **Calendar.** Built L1–L6 (EventKit transport → list/classify → events/
  free-busy → free-slots → mirror → ingest → write); established the event-role
  model so a colleague's training and a custody week stop blocking free-slots;
  added per-event overrides as the safety net for read-only third-party
  calendars; added an explicit adopt command so the AI/human can promote a
  mirrored appointment into `calendar.org` + the writable "Org" calendar without
  hand-recreating all the implementation steps; exposed
  `org-apple-calendar-adopt-event-by-uid` so AI runtimes can delegate adoption
  to this package instead of duplicating calendar writes.
- **Hard debugging.** The org-caldav/`url.el` saga (iCloud needs preemptive
  Basic auth; `org-caldav-check-connection` yields `DAV:status ""`), EventKit
  permission prompts, Keychain port-443 matching, elpaca's async `:config`,
  the `:depth treeless` empty-clone bug — each diagnosed with backtraces and
  **bounded tests** (every Emacs call has a hard timeout so the daemon never
  wedges) and turned into a documented fix or decision.
- **Infrastructure.** Added Keychain Internet-password primitives + an interactive
  credential command, doctor checks (incl. an iCloud-CalDAV password check and a
  stale-`.elc` check), folder-level data auto-sync, and verified
  reinstall-survival across all repos.

## The working pattern

- **Drive from intent, not implementation.** "When am I free?", "ingest the
  school deadlines", "this colleague's training shouldn't block me", "Übereiter
  is the kids' school", "make the date convention match how Apple shows things"
  → the AI translates each into the right config, code, data, or repo change.
- **AI proposes, the human decides.** Ingest is confirm-each; role overrides,
  bucket placement, architecture choices (EventKit vs CalDAV), what becomes a
  task — all the human's call. The AI lays out trade-offs and recommends.
- **Continuity across sessions.** Literate docs + a persistent memory let a
  fresh session re-acquire the architecture, the rules, and the open threads
  without re-explaining.

## Guardrails (keeping the human in control)

- Confirm before destructive or outward-facing actions; commit/push only when
  asked; branch before committing on a default branch.
- Per-Mac secrets (the iCloud app-password) never leave the Keychain; account
  specifics live in `local.org`, never in a shared repo.
- Two emacs-config repos and the package repos are kept in sync after every
  change; the data repo auto-commits and pushes.
- Every non-obvious decision is written down (here, in `ARCHITECTURE.md`, in the
  GTD setup manuals, and in the AI's cross-session memory) so the system stays
  legible to its owner.

## The takeaway

The sophistication is not the point — *sustainability* is. The AI lowers the
marginal cost of building and maintaining a bespoke system far enough that a
single person can have a GTD setup shaped exactly to their life (single parent,
work rhythm, kids' school calendar, hobbies, studies, an overdue tax backlog)
and keep it trustworthy over time. "Use an AI to make this possible" means: the
AI is the maintenance capacity that would otherwise not exist.
