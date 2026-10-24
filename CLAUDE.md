<structure-and-conventions>
## Structure & Conventions — Documentation Map

<!-- Maintained automatically. The master copy is block/structure-and-conventions.md in
     the structure-and-conventions Claude Code plugin (repository
     BikS2013-coding-agents/structure-and-conventions-repo), which checks this copy at
     every session start and brings it up to date — edit the master, never this block. The block is committed with the repository on
     purpose: it tells anyone (human or agent) working with this repo where the
     project's documentation lives and how to read and maintain it. -->

### Where the documentation lives

- `docs/plans/` — every plan, one file per plan, named `plan-NNN-<indicative-description>.md`.
- `docs/design/` — all other planning and design documents:
  - `project-design.md` — the complete, always-current project design; update it with every new design or design change.
  - `project-functions.md` — the registry of all functional requirements and feature descriptions.
  - `configuration-guide.md` — the project's configuration guide, when one exists (structure below).
- `docs/reference/` — all reference material collected for the project.
- `docs/refined_requests/` — every refined request specification (create the folder if missing), one file per request named `refined-request-NNN-<slug>.md`. `NNN` is a zero-padded three-digit sequential number: the next number is the highest `NNN` already present in the folder plus one, starting at `001` — and when the category has an archive history branch, the archive's numbering counts too (see "Archiving historical documents" below). `<slug>` is the request slug reused by all downstream artifacts of the same request.
- `docs/prompts/` — every prompt created while working on the project (create the folder if missing), one file per prompt named `NNN-<indicative-description>.md`. `NNN` is a zero-padded three-digit sequential number: the next number is the highest `NNN` already present in the folder plus one, starting at `001` — and when the category has an archive history branch, the archive's numbering counts too (see "Archiving historical documents" below). The description states the prompt's use and purpose.
- `docs/tools/<tool-name>.md` — one dedicated documentation file per project tool.
- `test_scripts/` — every test script goes here; create the folder if it doesn't exist.
- `Issues - Pending Items.md` (project root) — the register of every issue, pending item, inconsistency, or discrepancy detected while working on the project. Pending items come first (most critical and important on top), completed items after. Whenever a defect or issue is fixed, check this file for an item to remove.

### How to use the documentation

- Every time an issue is solved, it must be resolved AND both the issue and the solution must be thoroughly documented.
- This file's "Tools" section (when present) lists each project tool with a one-or-two-sentence description of what it is capable of and the relative path to its dedicated documentation file under `docs/tools/` — retrieve the full documentation from there whenever it is needed. Full tool documentation must never be inlined into this file.
- Before writing any code script, consult the "Tools" section and the documentation under `docs/tools/` to check whether the planned code fits the scope of an existing tool. If so, implement it as an extension of that tool; otherwise build a generic, abstract version of the code as a new tool in the project's toolset, document it under `docs/tools/`, and reference it in the "Tools" section. The goal is to progressively grow the tools needed to test, evaluate, generate data, collect information, etc., and reuse them consistently.

### Archiving historical documents (history branches)

- A project MAY move accumulated historical, write-once process artifacts — deployment reports, codebase scans, refined requests, plans, session handoffs, and similar — off the default branch to keep its documentation lean. Living, authoritative documents (`project-design.md`, `project-functions.md`, the guides, tool docs, the issue register) are never archived.
- Each archived category gets a dedicated **orphan, docs-only branch** named `<category>-history`, whose tree contains ONLY that category's files at their original repository paths — so retrieval paths never change: `git show <category>-history:<original-path>`, no branch switching required. A pointer note/README stays in the category's folder on the default branch stating the branch name, the retrieval command, and (for numbered categories) the next number. Archive branches are append-only: never rebase, rewrite, delete, or merge them.
- **Numbering across the archive**: for every `NNN`-numbered folder, the next number is `max(highest NNN in the folder, highest NNN on the category's archive branch) + 1`. Before creating the FIRST document of a numbered category, check whether an archive branch exists for it (the folder's README/pointer note, or `git branch --list --all '*-history'`) and continue from the archive's highest number — never restart at `001`, never reuse an archived number. The archive branch is authoritative over the pointer note's recorded "next number" if they disagree.
- **Migration** runs in a temporary linked worktree so the main checkout — and any uncommitted changes in it — is never disturbed: `git worktree add <tmp> <category>-history` (first-time archiving: `git worktree add --detach <tmp> <default-branch>`, then inside it `git switch --orphan <category>-history` and `git checkout <default-branch> -- <category-paths>`); bring the new artifacts over at their original paths and commit ONLY the category's files; then on the default branch `git rm` the migrated files, update the pointer note, and commit referencing the archive commit. Verify with `git ls-tree -r <category>-history --name-only` and a `git show` spot-check.
- The project's concrete category → branch registry (which categories are archived, under which branch names) is project-specific and lives OUTSIDE this synced block — typically a "Document Archiving Strategy" section in the project's CLAUDE.md.

<configuration-guide>
- A configuration guide, when requested, is created at `docs/design/configuration-guide.md` and explains:
  - When multiple configuration options exist (config file, env variables, CLI params, etc.), what the options are and the priority of each one.
  - The purpose and use of each configuration variable.
  - How the user can obtain such a configuration variable.
  - The recommended approach for storing or managing the variable.
  - Which options exist for the variable and what each option means for the project.
  - Any default value the parameter has.
  - For configuration parameters that expire (e.g., PAT keys, tokens), propose adding a parameter that captures the expiration date, so the app or service can proactively warn users to renew.
</configuration-guide>

</structure-and-conventions>

# Tiler

Menu bar tiling window manager for macOS (Swift, SwiftPM, no dependencies). Tiles only the
desktops (display + Space) the user turns on. Design: `docs/design/project-design.md`.

## Hard rules

- Never touch windows outside a tiled desktop's display **and** Space. Exceptions, all explicit
  user requests on one window: the move/resize mode (`MoveResizeMode`) and moving a window to
  the previous/next desktop or to the screen under the pointer (`DesktopMover`), all on the
  focused window, unminimizing the
  frontmost app's windows (`unminimizeAll`), and modifier + drag (`WindowDrag`) on the window
  under the pointer.
- Never call Space-mutation APIs. Moving a window to another desktop drives the user's own
  Mission Control shortcut with a synthetic title-bar drag (see `DesktopMover`).
- No polling. React to AX/NSWorkspace events; hotkeys via Carbon. Only two event taps exist:
  focus-follows-mouse's listen-only mouse-moved tap (present only while that setting is on and a
  desktop is tiled, switched off while the pointer is tracked by a bounded 40 ms check), and
  `WindowDrag`'s active tap for left-button down/dragged/up only (present only while
  `dragToMove` is set), on its own thread, whose callback does no AX or other blocking work.
  Never add a keyboard tap.
- Floating windows are saved with their owner pid; never trust a saved window id without it.
- All AX calls for an app run on that app's `AppHandle` thread (or, for the move/resize mode,
  the `WindowMover` thread), never on the main thread.
- Act on window moved/resized notifications only while the mouse button is down (or a
  `WindowDrag` is active: its swallowed press never shows as a pressed button).
- Config keys are all required; never add silent defaults (see `Config.parse`). Settings writes
  the file through `Controller.save` (validate, write atomically, reload); it is never a second
  source of truth.
- UI that pops up from a hotkey must not take focus from the app underneath (see
  `ShortcutsOverlay`); keys it needs are borrowed as Carbon hotkeys while it is visible.
- Written in Swift rather than TypeScript (the usual rule for project tools) because it is a
  native macOS app built on Accessibility and SkyLight APIs.

## Commands

- `swift build`, `swift test`
- `TILER_SIGN_IDENTITY=… scripts/build-app.sh [--install]`
- Release: `TILER_SIGN_IDENTITY=2C7D6068C232BA74073D56085DDBB04E5F14DF30 NOTARY_PROFILE=tiler-notary scripts/package.sh`,
  then `docs/design/release-runbook.md` (GitHub `biks2013-tools/tiler`, tap `biks2013-tools/homebrew-tiler`)
- Decks: `Project Deck/` (nbg-design skill, BikS2013 theme), published with GitHub Pages
- `scripts/tiler-ctl.sh toggle active | retile | reload | settings | shortcuts | moveresize | unminimize | nextdesktop | previousdesktop | here | dump`
