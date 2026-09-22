# Review runner protocol v1

Symphony can gate worker-controlled Linear handoff on execution evidence from an installed review
runner. This boundary verifies that the prescribed review ran; it does not make a merge decision.

## Configuration and trust boundary

```yaml
review:
  enabled: true
  executable: /opt/driver-symphony/review-run.py
  state_root: /var/lib/driver-symphony/review-runs
```

Both paths are absolute and fixed for an app-server session. The executable must be an installed
executable file. The private state root must be outside the workspace, `/tmp`, `TMPDIR`, and every
additional Codex-writable root. Review-enabled operation supports only local workers with the Linear
tracker. Invalid enabled configuration prevents startup; it never falls back to raw GraphQL.

The runtime invokes the executable directly, without a shell:

```text
/opt/driver-symphony/review-run.py --request /var/lib/driver-symphony/review-runs/requests/<request-id>.json
```

The request file is runtime-owned and contains no tracker credentials.

## Request

Every request is a JSON object:

```json
{
  "protocol_version": 1,
  "request_id": "42d5d910-7563-46f8-a207-0d40696be0c5",
  "operation": "verify",
  "run_id": "run-018",
  "issue": {
    "id": "linear-id",
    "identifier": "SYM-100",
    "description": "authoritative current issue description",
    "project": {"id": "project-id", "name": "Symphony Runtime"},
    "attachments": {"nodes": [{"url": "https://github.com/acme/runtime/pull/18"}]}
  },
  "execution": {
    "workspace": "/srv/symphony/workspaces/SYM-100",
    "repository": "https://github.com/acme/runtime",
    "thread_id": "thread-1",
    "session_id": "thread-1"
  },
  "state_root": "/var/lib/driver-symphony/review-runs"
}
```

`operation` is one of `start`, `status`, `resume`, `cancel`, or `verify`. A new `start` has a null
`run_id`; other operations refer to a run already bound to the issue. Start, resume, and verify use
a freshly fetched issue. The runner resolves the authoritative PR, comparison base, and published
head from the bound repository and attachment; worker-supplied SHAs and snapshots are not inputs.

## Events and completion evidence

The runner writes newline-delimited JSON events to stdout. Each event contains
`protocol_version`, `request_id`, `issue_id`, `run_id`, and `event`. Event order is `accepted`, zero
or more `progress` events, then `result`:

```json
{"protocol_version":1,"request_id":"...","issue_id":"linear-id","run_id":"run-018","event":"accepted"}
{"protocol_version":1,"request_id":"...","issue_id":"linear-id","run_id":"run-018","event":"result","status":"complete","evidence":{"plan_revision":"3","plan_hash":"sha256:...","repository":"github.com/acme/runtime","base":"abc","head":"def","context_fingerprint":"sha256:...","method_fingerprint":"sha256:...","config_fingerprint":"sha256:...","receipts":[]}}
```

Result status is `running`, `complete`, `incomplete`, `canceled`, or `unknown`. Non-complete results
include a bounded human-readable `reason`. Receipt references contain hashes, not credentials.
Unsupported versions, mismatched envelope identities, malformed output, nonzero exit, missing
result, unknown status, or incomplete evidence fail closed.

For `start` and `resume`, Symphony returns the accepted run ID while an OTP-owned process continues
consuming the runner. Duplicate starts for the same bound issue reuse that run. Runner records own
durability and accounting; runtime restart/reconciliation asks the runner rather than blindly
replaying work. Cancellation retains records, and failed control calls never imply that a paid run
ended.

Immediately before `In Review`, `Merging`, or `Done`, Symphony refetches the issue and calls
`verify`. It performs the Linear mutation only after a matching `complete` result with all evidence
fields and a successful runner exit. Comments, workspace files, prior accepted events, cached
completion, and exit status alone cannot authorize handoff.

## Review-enabled Linear tools

The session advertises only `symphony_review`, `linear_read`, `linear_comment`, `linear_attach_pr`,
and `linear_transition`. Inputs reject extra fields and bind mutations to the active issue, team,
workspace repository, and session. The legacy `linear_graphql` name is rejected at execution too.
Review-disabled deployments retain their existing provider tools unchanged.
