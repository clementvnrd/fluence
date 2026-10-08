# CLAUDE.md

Read `AGENTS.md` first: it describes the project, the cross-platform test vectors and the traps
(iCloud builds, code signing, Windows pins). This file only adds the working agreement with Clement
around Linear.

## Working with Linear (Clement, 2026-10-05)

Linear is the **live board** of the Fluence app, and Claude keeps it in sync **during** a task, not
only at the end. Team **Fluence App**, key **`FLU`**, MCP server `linear-server` (signed in as
Clement). The GitHub integration is connected: a pull request whose description names `FLU-n` is
linked to that issue. A **project** is a large stream of work (`list_projects`), a **milestone** is a
phase of a project, the **Reviews** tab lists the pull requests waiting for a review; cycles are not
used.

Labels on the team (the extra ones created after Clement's answer on FLU-9): type `Bug`, `Improvement`,
`Feature`; area `macOS`, `Windows`, `Shared`; and `Decision`, `Owner action`, `Process`. Any other
label: propose it (`save_issue_label`) and wait for Clement's answer, never create it silently.

### 1. Start of every reply: read Clement's answers first
Before anything else, list the issues in `Needs Input`, the open issues labelled `Decision` or
`Owner action` (once those labels exist), and the issues updated since the last check
(`list_issues` with `updatedAt`, then `list_comments`). Act on what Clement wrote, and say in the
reply which answers were taken into account. Clement answers in Linear (a comment, or a move to
`In Progress` / `Done`), not in chat.

### 2. One issue per piece of work, created before starting it
- Every request, idea or bug Clement voices becomes an issue **in the same reply**: `Backlog` unless
  he decides to do it now. No work starts without an issue. It joins its project and milestone when
  one fits.
- **Title**: plain and descriptive, in English (it matches the branch, commit and pull request).
- **Labels**: exactly one type (`Bug`, `Improvement`, `Feature`); plus an area, `Owner action` (a
  person must act, Claude cannot), `Decision` (a choice to make) or `Process` (how we work) once those
  labels exist.
- **Priority**: P0 → Urgent, P1 → High, P2 → Medium, P3 → Low.
- An issue about the macOS and the Windows apps says which one it concerns. Anything that changes
  correction behaviour starts from `shared/dictionary-test-vectors.json` (see `AGENTS.md`).

### 3. The status says who has the ball

| Status | Meaning |
|---|---|
| `Backlog` | Not decided |
| `On Hold` | Kept on purpose, not now: Clement's choice. Claude never touches it |
| `Todo` | Decided, ready to be taken |
| `Needs Input` | **Clement's turn**: a question, a decision or a confirmation waits for him |
| `In Progress` | **Claude's turn**: started, or Clement answered and Claude is on it. Code committed locally without a pull request stays here |
| `In Review` | **The reviewer's turn**: only while a pull request is open and waiting in the Reviews tab |
| `Done` | Set by the merge of the pull request (code), or once a decision is taken and recorded (no code) |
| `Canceled` / `Duplicate` | Dropped / folded into another issue |

### 4. Every comment comes with a status change
One event = **one comment + one status change**, then a re-read of the issue (`get_issue`) to confirm
the change took effect. A comment without a status change is a mistake.
- Claude answered and Clement must decide or check again → `Needs Input`.
- Clement decided and nothing remains → `Done`. This is how `Decision` and `Owner action` issues close.
- Clement decided and real work remains → the work becomes **its own issue** (`Todo`, or `In Progress`
  if started now) and the decision issue goes `Done`.
- Claude needs explicit confirmation before something risky or irreversible (resetting a TCC grant,
  changing signing, deleting files, pushing) → `Needs Input`, the comment naming the exact words that
  confirm.
- Claude opens a new question or decision for Clement → `Needs Input`.
- Code finished → open the pull request first, then `In Review`. Never `In Review` without one.
- When Clement has answered, he moves the issue from `Needs Input` to `In Progress`.

### 5. Comments: signed, single, readable
- The MCP server signs in as Clement, so **every comment Claude writes starts with `🤖 Claude:`**. A
  comment without the prefix is Clement's; a prefixed comment is never his decision.
- **One comment per event.** Before posting, re-read the issue's comments: if a `🤖 Claude:` comment
  already reports the same event (same question answered, same commit or pull request, same decision
  recorded), post nothing and change nothing. This matters more when several sessions share the board.
- **Language**: issue titles and descriptions in English; comments to Clement in French with English
  technical terms.
- **A question or decision for Clement is written much more simply than a technical note** (Clement,
  2026-10-05, after answering "je n'ai pas compris" to four questions that opened with paths and tool
  names): first say what the thing *is* in everyday words, as if to someone who has never seen it;
  then whether it is used and what for; then the options side by side (one small table at most) with
  what changes for him in each; then **my recommendation and why**; then the **exact words** that
  answer it. Paths, versions and tool names come last, only as evidence. An `Owner action` says why
  the person must do it themselves.

### 6. Delivery by pull request: the lifecycle of one issue
- **One pull request per lot of work**, carrying every issue of the lot, from a short branch cut from
  `main` into `main`. Never push to `main`.
- **Branch**: `<type>/<topic>-flu-<n>`, for example `feat/compare-mode-flu-12`,
  `fix/ptt-release-flu-7`. Not the `<user>/flu-n-…` name Linear suggests.
- **Pull request description opens with one `Closes FLU-n` line per issue it delivers**: this line is
  what makes the merge set `Done`; `Refs FLU-n` only links and leaves the issue open.
- **Commits**: short imperative summary, with `Refs FLU-n` in the body, never `Closes`. An issue
  closes by the merge of its pull request and by nothing else.
- **At most one open code pull request per repository**: the next branch is cut once the previous one
  is merged.
- **Before opening a pull request, review the board**: read every Linear issue of the projects the pull
  request touches, update the ones it delivers, changes or makes obsolete (description, status, links;
  an obsolete issue is closed as `Canceled` or `Duplicate` with a comment saying why), and list that
  review in the pull request description.
- A branch is pushed **only to open its pull request**; work not ready stays local and is reported as
  "committed locally, no pull request".
- **Review and merge**: any developer may review and approve in Linear's Reviews tab. Claude never
  merges and never approves in anyone's name.
- Lifecycle: `In Progress` → pull request opened → `In Review` → the merge sets `Done`. **Nobody sets
  `Done` by hand on an issue that carries code**: if a merge did not close it, fix the link (the
  `Closes` line), not the status.
- Work a short branch in its own `git worktree` when useful, so the main clone never switches branch
  under a running app. Build with `make`, never a bare `swift build` (see `AGENTS.md`).

### 7. Linear complements the repository files, it never replaces them
The record stays in the repository, which survives without Linear. A decision that changes how the
app works is written where the code and docs keep it (`AGENTS.md`, `docs/`, the test vectors) **and**
on its `Decision` issue, in the same step.

### 8. Interface issues carry images
An issue about a user interface embeds screenshots of the current state and mock-ups or inspiration
for the target: Clement decides and reviews design from images, not from code. Mock-ups follow the
design system in `AGENTS.md` (Clement's look: light canvas, rounded white cards, one aqua-blue
accent and the Aqua orb, the blue gradient only on the orb / "AI" badge / *Dicter* button, red
only for a recording or an error, French UI).

### 9. Close every substantial reply with the Linear changes
List the issues created, moved or closed, with their keys, at the end of the reply.

### 10. Hourly watch: not set up
Set up only if Clement asks. Its limits would be written in the scheduled task's prompt and mirrored here.
