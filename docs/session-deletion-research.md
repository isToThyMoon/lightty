# Local session deletion research

Investigated 2026-09-08. No user session was deleted or modified. Only documentation, source, installed type declarations, and CLI help were inspected.

## Recommendation and decision needed

Use provider-owned deletion interfaces, not handwritten SQLite updates or removal of a guessed JSONL path. However, these interfaces perform **permanent deletion**, not a recoverable move to Trash. Codex also deletes spawned descendant threads. This differs materially from the earlier proposed recoverable deletion; obtain a user decision before implementing that behavior.

If permanent deletion is accepted, confirmation must state the provider-specific scope. If recoverability is required, design and test a separate complete backup/restore mechanism first; copying one transcript does not establish a supported Codex restore operation.

## Codex

- Installed `codex delete --help` supports `delete --force <SESSION>` and describes permanent deletion. `--force` requires a UUID. Version-matched source shows it only skips interactive confirmation, rather than bypassing writer locks. [Codex v0.153.4 CLI source](https://github.com/openai/codex/blob/rust-v0.153.4/codex-rs/cli/src/main.rs)
- The official app-server API documents `thread/delete` as deleting the target and spawned descendant threads, with deletion notifications. It is distinct from `thread/archive`. [Official app-server protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- The current official local store implementation coordinates writer locks, checks fork-history references, removes active/archived rollout files (including compressed siblings), local history projections, and name-index entries. Its comments assign main state-database cleanup to the app server. Tests cover rejecting owned descendants before deleting files. These are reasons to delegate to the provider, not a schema to reimplement in Lightty. Source on `main` can differ from installed versions; provider errors must remain authoritative. [Official local deletion implementation](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/delete_thread.rs)

Implementation candidate: invoke the resolved CLI with UUID argument and the record's configuration root, after Lightty confirmation. Do not pass remote endpoints, user launch-command arguments, or arbitrary display titles. Older unsupported CLIs should report unsupported deletion, never fall back to manual database surgery.

## Claude Code

- The repository pins `@anthropic-ai/claude-agent-sdk` 0.3.263. Its installed `sdk.d.ts` declares `deleteSession(sessionId, options)` at line 568. The declaration documents local deletion of `{sessionId}.jsonl` and its `{sessionId}/` subagent-transcript directory, and an error if absent. `SessionMutationOptions` provides a project directory scope. This is a first-party package contract, not a guarantee that every ancillary record is erased. [First-party SDK package](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk/v/0.3.263)
- Official documentation locates transcripts under `projects/<project>/<session-id>.jsonl`, supports `CLAUDE_CONFIG_DIR`, and explains that resuming in multiple terminals can interleave transcript writes. [Official session documentation](https://code.claude.com/docs/en/sessions)
- Other data lives in separate directories and global prompt history. The official project-wide purge command deletes more than one session, so it is inappropriate for this feature. Authentication, preferences, plugins, project files, and Handoff task files must remain untouched. [Official Claude directory and purge documentation](https://code.claude.com/docs/en/claude-directory)

The SDK declaration does not promise a cross-process deletion lock or cleanup of global prompt history, debug logs, or checkpoint files. Do not label this as complete privacy erasure. A running-process preflight is useful but cannot eliminate a check/use race with an external program; avoid claiming universal atomic exclusion.

## Lightty safety and ownership boundary

Proposed behavior, pending the decision above:

1. Resolve the exact composite identity (agent, source root, native UUID), not title or working directory alone.
2. Reconcile internal runtime associations and reject deletion of an open or starting session. Check external occupancy without terminating processes. Unknown occupancy must not silently become "safe".
3. Present provider-specific irreversible scope, including Codex descendants and Claude subagent transcripts.
4. Execute only the provider mutation. Preserve errors and refresh after partial failures; do not report a successful delete merely because the UI hid the item.
5. Clean Lightty's own grouping metadata after successful provider deletion and refresh its catalog, including any disappeared Codex descendants. Preserve Handoff task files and unrelated terminal bindings.
6. Verify with isolated fixture roots only: success, occupied target, unsupported version, custom root, missing session, failure, and collateral-data preservation.

## Implementation (approved 2026-09-08)

The user accepted permanent native deletion. `SessionDeletion` now provides a destructive menu action with a cancel-default confirmation. Codex uses `delete --force UUID`; Claude uses the pinned SDK through a separately packaged `delete-session.mjs`. No hand-written provider database or transcript mutation is used.

Only internal terminals and pending resumes for the exact target composite key block deletion; an idle shell does not. Lightty resume/picker launches are excluded while confirmation/deletion is active. Claude process inspection uses the existing hook association (PID plus kernel start time and composite session key): known unrelated sessions are allowed, the target is rejected with its PID, and unidentified external/unassociated Claude processes produce a distinct unknown-occupancy message with PID. Command-line resume IDs are not treated as current-session evidence because an Agent can switch conversations after launch. Negative `lsof` evidence alone remains insufficient. This check is not an atomic lock and cannot identify every custom wrapper; the confirmation asks users not to start the Agent elsewhere during deletion. Native Codex writer-lock rejection, including occupied descendants, remains authoritative.

Unknown Claude occupancy now opens a cancel-default risk confirmation with the target title and available PID. The user may explicitly choose “Permanently delete anyway” for this request only. Execution rechecks internal associations and process occupancy; this consent suppresses only unknown-occupancy failures, never positive occupancy or native writer-lock rejection. No external process is stopped and no persistent bypass setting is saved.

On success, Lightty removes the selected key and fully pages the refreshed provider catalog before pruning disappeared descendant grouping metadata. On native failure it refreshes without claiming success; native deletion may have partially completed. Unknown-occupancy preflight does not mutate or refresh the catalog. Handoff files and user configuration are untouched. No backup, Trash recovery, or complete privacy-erasure guarantee is offered.

Verification: `swift test --filter SessionDeletionTests` runs the real pinned Claude SDK and installed Codex deletion CLI only against newly generated temporary fixture roots, checking native catalog disappearance, other-session preservation, subagent transcript deletion, Handoff-file preservation, invalid identities, and injected occupancy rejection.
