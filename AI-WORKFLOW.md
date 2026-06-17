# AI-assisted workflow — why this system is maintainable at all

This calendar package is one piece of a larger, deeply personalized system:
GTD in Emacs/org-mode, `org-apple-reminders` (dated tasks ↔ Apple Reminders),
`org-apple-calendar` (appointments + read/ingest ↔ Apple Calendar via EventKit),
a git-crypt data repo, a literate Emacs config across modules, and event
classification/ingest rules. **Built and maintained by one person — but only
because an AI assistant carries the load.** Without it, nobody would have the
capacity to create, operate, and keep such a tailored system alive. This file
documents *how* the AI is used, so the approach is reproducible.

## The premise

A GTD system is only useful if it is *trusted* and *current*. Keeping a system
this tailored current — classifying inbox items, deciding which calendar events
block time, ingesting external deadlines, extending the Elisp when life
introduces a new case, debugging macOS/EventKit/CalDAV quirks, and keeping four
repositories in sync and reinstall-safe — is more ongoing work than a busy
single parent can sustain by hand. The AI turns "more than I can maintain" into
"a conversation". That is the whole point.

## What the AI does

1. **Builds and extends the packages.** Implements the layered model (L1–L6),
   writes the JXA/EventKit bridges, keeps the "layer N calls only N−1"
   discipline, tangles the literate `.org` → `.el`, runs the `ert`/checkdoc
   suites, bumps versions, commits, merges to `stable`, tags, pushes.
2. **Operates the GTD.** Runs the coaches (mind-sweep, clarify, weekly review),
   files inbox items into buckets, ingests calendar deadlines into tasks,
   proposes `busy`/`info`/`ignore` roles, and surfaces what needs attention.
3. **Debugs the hard parts.** The org-caldav/`url.el` saga (preemptive auth,
   `DAV:status ""`), EventKit permission prompts, the Keychain port-443
   matching, elpaca's async `:config` — diagnosed with backtraces and **bounded
   tests** (every Emacs call has a hard timeout so the daemon never wedges).
4. **Keeps it coherent and safe.** Syncs the repos, verifies reinstall-survival
   (no hard-coded per-Mac IDs; secrets in Keychain; data in the git-crypt repo),
   and writes the decisions down — in these docs and in its own cross-session
   memory — so context is never lost.

## The working pattern

- **Drive from intent, not implementation.** "When am I free?", "ingest the
  school deadlines", "this colleague's training shouldn't block me", "make the
  date convention match how Apple shows things" → the AI translates each into
  the right config, code, data, or repo change.
- **AI proposes, the human decides.** Ingest is confirm-each; role overrides,
  architecture choices (EventKit vs CalDAV), and what becomes a task are the
  human's call. The AI lays out trade-offs and recommends.
- **Continuity across sessions.** Literate docs + a persistent memory mean a
  fresh session re-acquires the architecture, the rules, and the open threads
  without re-explaining.

## Guardrails (keeping the human in control)

- Confirm before destructive or outward-facing actions; commit/push only when
  asked.
- Per-Mac secrets (the iCloud app-password) never leave the Keychain; account
  specifics live in `local.org`, never in a shared repo.
- Every non-obvious decision is documented (here, in `ARCHITECTURE.md`, and in
  the GTD setup manuals) so the system stays legible to its owner.

## The takeaway

The sophistication here is not the point — *sustainability* is. The AI lowers
the marginal cost of building and maintaining a bespoke system far enough that
a single person can have a GTD setup shaped exactly to their life (single
parent, shift/work rhythm, kids' school calendar, hobbies, studies) and keep it
trustworthy over time. That is what "use an AI to make this possible" means in
practice.
