# Spark user guide

[Back to the README](../README.md)

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / window | ⌘T / ⌘N |
| Close active pane (or tab) / window | ⌘W / ⇧⌘W |
| Split focused pane right / below | ⌘D / ⇧⌘D |
| Next pane | ⌃Tab |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| Open folder | ⌘O |
| Find | ⌘F |
| Command palette | ⌘K |
| Activity / recent conversations | ⇧⌘A |
| New worktree | ⇧⌘N |
| Review changes | ⇧⌘G |
| Focus mode | ⇧⌘F |
| Larger / smaller / default text | ⌘= / ⌘− / ⌘0 |
| Settings | ⌘, |

## Workspaces and split panes

Use the workspace switcher in the footer to create, rename or reopen a workspace. Switching changes the current window; other open workspaces stay alive in the background, including their shells and pane layouts. Changes are saved automatically, including tabs, pane titles, folders, split direction/proportions, selection, focus mode and window geometry. The next launch restores the workspaces that were open when you quit.

Split the focused pane with **⌘D** and choose a preset from the toolbar menu: columns, rows, a three-pane layout, or a four-pane grid. The focused pane stays in the template and new panes open to its right or below. Drag the gaps to resize; **⌃Tab** and clicking a terminal move focus. A tab supports up to eight panes. Closing a pane expands its sibling without restarting the surviving shells. Spark asks before closing a terminal only while a command is in its foreground. When a shell exits, Spark closes its pane and collapses the layout; the last pane closes its tab, and exiting the only tab quits Spark.

Layouts are stored atomically in `~/Library/Application Support/com.lucasarch.Spark/workspaces.json`, with private file permissions. Restoration starts **fresh shells**, not previous commands or agents; scrollback, prompts, credentials and conversation content are not stored. Missing directories fall back to your home folder. Unreadable or newer-format files are preserved and a visible error explains why saving is unavailable.

## Developer workflows

The command palette (**⌘K**) keeps search focused while **↑/↓** select actions, **Page Up/Down** move through longer lists, **Enter** runs the selection and **Esc** returns to the terminal. The list scrolls with the selection. Opening/closing transitions respect macOS Reduce Motion.

Open **Activity** with ⇧⌘A or the sidebar button. It shows live agents across open workspaces, their reported state and messages. Account allowance stays in the terminal usage badge/popover, rather than being repeated across Activity cards. Working agents use the animated working orb from ThinkingOrbsKit (only that preset is bundled), with Reduce Motion support. Click a running agent to focus its workspace and pane. **Recent conversations** retains up to 100 references per workspace, including conversations whose panes were closed. Resume opens a new tab using the exact CLI session ID; it focuses an already running conversation instead of launching it twice. Restoring a workspace does not automatically launch agents. Agent launch is scheduled after the first prompt initialization so themes such as Powerlevel10k can restore terminal I/O before Codex or Claude starts. The CLI remains responsible for retaining its conversation history and reporting resume errors.

**Worktrees** belongs to each terminal: the branch button sits just left of the agent usage badge, with **Review** to its left. Both appear only in Git directories. Spark reads the shell process's working directory as well as OSC directory reports. ⇧⌘N and ⇧⌘G use the focused terminal. A creation dialog pins the originating terminal, repository and branch; changing focus cannot redirect the operation.

New worktrees receive a generated two-word name such as `silver-otter`, used for both branch and folder. You can regenerate or edit it, choose Terminal/Codex/Claude Code, and open a new tab or split the originating terminal. Creation starts at the current commit and leaves local edits in their original folder.

The popover shows the current branch and worktree path. **Merge into <branch>** targets the original branch recorded at creation; older/imported worktrees use the explicitly identified main working tree. Both trees must be clean and free of unfinished Git operations. Spark previews conflicts with `git merge-tree` before running a normal merge; it rechecks branch identities and commits after confirmation. Conflicts found during preview leave working files untouched. A later Git/signing failure is reported with the destination path; Git's state is preserved for resolution in the terminal. No worktree or branch is deleted automatically. Git hooks are disabled for Spark's Git operations.

**Review Changes** (⇧⌘G) uses a folder/file tree with language icons and a native, selectable code viewer. While open, a recursive macOS FSEvents watcher observes the project and its Git/common directories (including linked worktrees). Changes are coalesced and diffs update automatically, preserving the selected file and scroll position. The watcher stops when Review closes; there is no periodic Git polling. Switching files starts at the top left. Old/new line numbers live in a separate gutter; copying code excludes them. Language syntax colors are independent of translucent addition/removal backgrounds. Raw patch headers, hunk markers and leading `+`/`-` symbols are omitted. Highlighting uses [HighlighterSwift 3.1.0](https://github.com/smittytone/HighlighterSwift/tree/3.1.0), runs off the UI thread and makes no network requests. Unknown languages and very large sources fall back to plain text; binary files have a descriptive state. Third-party licenses ship in `ThirdPartyNotices.txt`.

**Working Tree** compares with HEAD (or the empty tree before the first commit). **Entire Task**, available for recorded worktrees, compares with their creation commit and includes subsequent commits. Discard File/Discard All operate only on uncommitted changes and require confirmation. File copies and binary patches are backed up under the worktree's Git directory in `spark-discarded/<UUID>` before restoring tracked files and removing new files. The recovery folder is accessible from the review footer. New edits after confirmation cancel the discard; existing commits are preserved. Directories, submodules and unfinished Git operations must be handled in the terminal. Output above 4 MB shows a size-limit message; external diff/textconv programs are disabled.

Conversation IDs come from the existing per-PTY integrations: Claude's `session_id`, and Codex's `thread-id` title item. Codex currently shortens the latter, so Spark matches its long UUID prefix against rollout **filenames** under that invocation's `CODEX_HOME/sessions`; it never reads transcript contents or chooses by folder/recency. Ambiguous IDs and unsupported/overridden integrations are not resumable. Allowance fields come first in the title to preserve usage information when Codex truncates a long title. Layout files now also retain conversation references and worktree base commits; old workspace files remain readable.

## Agent notifications

Agent notifications are always enabled in Spark. Allow them in the macOS permission prompt; manage or disable delivery only in **System Settings → Notifications → Spark**. Spark uses Apple's [UserNotifications delegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate) to handle delivery and clicks. If access is denied, allow Spark in System Settings → Notifications.

An agent's transition to completion, error or a request for approval/attention can generate an alert. Initial idle/done states and repeated progress updates stay quiet, as does the session currently focused in the active window. Notifications contain only the provider, status and pane title; one outstanding alert per session avoids flooding Notification Center. Clicking an alert activates its workspace, tab and pane. Support depends on the CLI reporting its activity through OSC 7501; system notification settings and Focus modes still govern visible delivery.

## Codex and Claude Code

Run either CLI normally. On versions that emit **OSC 7501 (Program Status Protocol)**, Spark automatically shows the provider logo and status color in that terminal's tab, including background tabs:

| Color | State |
| --- | --- |
| Blue | Working |
| Amber | Needs approval, an answer, sign-in, or other attention |
| Green | Done |
| Rose | Error |
| Lavender | Ready |

Tabs keep a fixed height and a single title line. Codex uses the OpenAI logo; Claude Code uses the Anthropic logo. Status is conveyed by color, with the agent name and status also available in the tooltip and accessibility label. Click the agent badge above the terminal to see its reported status, message, and task progress when supplied. Child reports that need attention take priority. Clearing the report or ending the PTY removes the agent UI.

The OpenAI, Anthropic and code language logo assets are from [Simple Icons 13.21.0](https://github.com/simple-icons/simple-icons/tree/13.21.0), distributed under [CC0](https://github.com/simple-icons/simple-icons/blob/13.21.0/LICENSE.md). The marks belong to their respective owners.

The panel displays **live model, context usage, input/output tokens, and plan limits**, plus Claude's estimated session cost. The button above the terminal shows **`x% usage left`**, meaning the remaining account allowance (the lowest remaining percentage among reported 5-hour and weekly limits). Context usage is shown separately in the panel; the tooltip identifies the limiting allowance and activity state. Missing fields say “Not reported”; a missing metric is never presented as zero. Codex tabs start as **Codex** and adopt the conversation name once one is reported.

**Connecting metrics:** open a **new zsh tab** in Spark, then run `codex` or `claude` normally. Spark forwards your normal `.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin`, restores your `ZDOTDIR`, and adds session-local launchers to `PATH`. This also covers `command codex`, `caveman codex`, and aliases such as `cdx='caveman codex'`: child processes find the launcher just as the shell does. User aliases, startup files, and global CLI settings are never edited. The launchers preserve arguments, environment, and exit status; redirected/non-interactive input or output bypasses the integration. Before each interactive zsh prompt, Spark disables leftover mouse/focus reporting and clears the Kitty keyboard stack so an exited CLI cannot inject input codes into the shell. Existing tabs, other shells, absolute executable paths, and commands that replace `PATH` may show “Metrics not connected.”

**Data sources and meanings:**

- **Codex:** the wrapper configures the supported `tui.terminal_title` items for that invocation. Spark receives model/context/token/limit updates through OSC title events from that exact PTY. Fixed slots separated by the `app-name` item preserve absent values; truncated slots are discarded. Input/output are session totals rounded by Codex, and limit text retains the client's remaining/used semantics. Only the conversation name appears in the tab. Custom title settings supplied on the command line can override the integration. Validated with Codex 0.164.0.
- **Claude Code:** a per-invocation `--settings` value connects `statusLine` to Spark's helper. This replaces a custom status line **inside Spark only**, displaying a compact model/context/cost footer. Explicit settings passed afterwards can override it. The helper accepts bounded JSON, retains only display metadata and usage figures, and writes atomically into a private temporary folder. Each invocation has its own UUID, and each tab has its own folder. Input/output refer to the **current context from the latest response**, not lifetime session totals. Cost is the client's list-price estimate, not an invoice. Plan limits and context may be absent until a response is received. Validated with Claude Code 2.1.311. The panel polls these local snapshots once per second; the folder is removed when the terminal session is released.

OSC 7501 remains the activity source; metrics never approve tool calls or send prompts. Spark does not scan transcripts, read API keys, poll billing endpoints, or associate sessions by project directory. All displayed values are program-supplied hints, not authenticated process identities. Older clients may lack the required status/title fields. After an abrupt unwrapped client crash, a full terminal reset (`reset`) clears retained activity reports.

References: [Codex title fields](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/title_setup.rs), [Codex status rendering](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs), [Claude status-line JSON](https://code.claude.com/docs/en/statusline), [Codex activity emitter](https://github.com/openai/codex/blob/main/codex-rs/tui/src/terminal_program_status.rs).
