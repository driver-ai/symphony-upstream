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

Both paths are literal absolute paths (`$VAR` expansion is not supported) and fixed for an app-server session. The executable must be an installed
executable file outside worker-writable roots. The state root must be an existing private directory
(no group/other permissions) outside the workspace, `/tmp`, `TMPDIR`, and every
additional Codex-writable root. Review-enabled operation supports only local workers with the Linear
tracker. Invalid enabled configuration prevents startup; it never falls back to raw GraphQL.

These protections rely on the Codex sandbox and trusted runtime-side hooks and launch commands.
They do not isolate same-user programs running outside that sandbox. Such hooks must not execute
untrusted workspace code with access to the runtime's trusted paths; stronger operating-system
separation belongs to deployment policy.

The runtime invokes the executable directly, without a shell:

```text
/opt/driver-symphony/review-run.py --request /var/lib/driver-symphony/review-runs/requests/<request-id>.json
```

The request file is runtime-owned, mode 0600, and contains no tracker credentials. Each invocation uses a
separate scratch file that is deleted when its process exits. The filename is not the request identity.

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
    "repository": "acme/runtime",
    "thread_id": "thread-1",
    "session_id": "thread-1"
  },
  "state_root": "/var/lib/driver-symphony/review-runs"
}
```

`operation` is one of `start`, `status`, `resume`, `cancel`, or `verify`. A new `start` has a null
`run_id`; other operations refer to a run already bound to the issue. If a start was interrupted before
acceptance, `resume` may carry null `run_id` with the persisted original `request_id`. The runner must
reconcile that request before starting any paid work. A missing or corrupt binding fails closed; a
worker cannot introduce an arbitrary run ID. Status/cancel/verify require an accepted bound run. Start, resume, and verify use
a freshly fetched issue. The runner resolves the authoritative PR, comparison base, and published
head from the bound repository and attachment; worker-supplied SHAs and snapshots are not inputs.

## Events and completion evidence

The runner writes newline-delimited JSON events to stdout. Each event contains
`protocol_version`, `request_id`, `issue_id`, `run_id`, and `event`. Event order is `accepted`, zero
or more `progress` events, then `result`:

```json
{"protocol_version":1,"request_id":"...","issue_id":"linear-id","run_id":"run-018","event":"accepted"}
{"protocol_version":1,"request_id":"...","issue_id":"linear-id","run_id":"run-018","event":"result","status":"complete","evidence":{"plan_revision":"3","plan_hash":"sha256:...","repository":"acme/runtime","base":"abc","head":"def","context_fingerprint":"sha256:...","method_fingerprint":"sha256:...","config_fingerprint":"sha256:...","receipts":[{"path":"runs/run-018/receipt.json","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}
```

Result status is `running`, `complete`, `incomplete`, `canceled`, or `unknown`. Non-complete results
include a nonempty human-readable `reason` of at most 2,000 bytes. Events are limited to 65,536 bytes
each; paid-run streaming duration is not limited. Status, cancel, and verify callers wait at most
five seconds, then receive `review_control_timeout`. The runtime continues consuming that control
process: a caller timeout neither cancels paid work nor clears its binding or accounting. A later
handoff must perform a new successful verification. Identical repeated acceptance is idempotent, but later
events must retain the accepted run ID. Output after a result is invalid. Completion must include
nonempty evidence fields and at least one receipt with a nonempty `path` and a 64-character lowercase
hexadecimal `sha256`. The evidence repository must equal the captured `owner/repository` identity.
Receipt references contain hashes, not credentials.
Unsupported versions, mismatched envelope identities, malformed output, nonzero exit, missing
result, unknown status, or incomplete evidence fail closed.

For `start` and `resume`, Symphony returns the accepted run ID while an OTP-owned process continues
consuming the runner. Concurrent starts, including calls before acceptance, share the owned process.
The runtime persists only request/run/repository identity and last observed execution status before
launch and after acceptance/result. Runner records own durability, subject/plan deduplication and
accounting. After restart or an uncertain/incomplete exit, start/resume invokes `resume` with the
original request ID; a saved ID alone never establishes live ownership. The runner must reconcile
existing work without replaying paid calls. A subsequent start after a successfully exited complete
or confirmed canceled run gets a new request ID; the runner still deduplicates the current subject
and plan against its durable records. A failed control never implies a paid process ended.

Cancellation releases the local handle only after a matching canceled result and successful process
exit. Accounting records remain runner-owned and are never deleted by the runtime. Review process
ownership is supervised separately from worker/orchestrator restarts. The owner singleton does not
load mutable workflow settings: every call carries the immutable runtime-created session binding.

The runner transport process must monitor stdin and exit on EOF, and must also exit on a broken
stdout pipe. This lets confirmed cancellation and graceful runtime shutdown release even an idle
transport when its OTP owner closes the port. Transport exit alone does not prove paid descendants
were canceled: the runner's cancel operation must reap its owned work before reporting `canceled`,
and recovery must retain unknown accounting until the runner reconciles it.

Immediately before a handoff transition, Symphony
refetches the issue and calls `verify`. The destination is resolved from the bound issue's team, so
renaming a review or completion state does not bypass the gate. Completed states, In Review and
Merging are always protected, as are other started or unstarted states outside configured active states. Blocked,
backlog and canceled destinations remain available without successful review; they do not
represent completion or handoff. It performs the Linear mutation only
after a matching `complete` result with all evidence fields and a successful runner exit. Comments,
workspace files, prior accepted events, cached completion, and exit status alone cannot authorize
handoff.

## Review-enabled Linear tools

The session advertises only `symphony_review`, `linear_read`, `linear_comment`, `linear_attach_pr`,
and `linear_transition`. Inputs reject extra fields and bind mutations to the active issue, team,
workspace repository, and session. The legacy `linear_graphql` name is rejected at execution too.
Review-disabled deployments retain their existing provider tools unchanged. Linked-document reads
require a document attached to this issue or its canonical URL in the current issue description.
Comment updates require matching issue and viewer ownership; replies require matching issue.
Missing session context and invalid arguments return bounded failures before any provider call.
Missing or mismatched repository identity rejects review, PR attachment, and protected transitions
with a repository-specific reason. Issue reads, workpad comments, and non-handoff transitions remain
available so the worker can report the failure and move the issue to Blocked.

The repository is captured before the issue's first Codex turn from the hook-created `workspace/repo` clone,
or from the workspace itself when it is a repository. HTTPS, Git SSH and SSH-URL GitHub origins
normalize to lowercase `owner/repository`. Parent checkouts and non-GitHub remotes are not accepted.
The owner pins this identity in the issue's existing runtime binding before any review starts.
Later sessions compare their capture against that durable identity and fail closed on disagreement,
including after a runtime restart. Rewriting the workspace's Git remote cannot rebind the issue.
The runner must reject a live repository or published PR subject that disagrees with this binding.
It alone parses/hashes the plan and resolves current Git/GitHub base/head: the runtime does not
substitute cached worker claims for that fresh verification.
