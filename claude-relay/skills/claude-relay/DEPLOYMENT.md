# Deployment phase

Assign this phase only after the user authorizes deployment. The Opus
coordinator gives a bounded Claude Code subagent the settled release plan; the
child does not invent a deployment strategy. If production evidence invalidates
the plan, stop the release and return the evidence to Opus for a new route.

1. Use the repository's shared deployment lock and wait for an active release
   to finish.
2. After acquiring the lock, fetch the integrated target branch again.
3. In a dedicated clean deployment checkout with an attached branch and
   configured upstream, run `git pull --ff-only`.
4. Stop without discarding local work if the checkout is dirty, detached,
   missing its upstream, diverged, or cannot pull.
5. Verify the authorized task commit is an ancestor of the pulled revision.
6. Build complete artifacts for the affected services from that integrated
   revision. Never deploy from a task worktree, feature branch, dirty checkout,
   or partial file overlay.
7. Hold the deployment lock through production health verification.
8. Never deploy an older revision after a newer one unless the user explicitly
   authorizes a rollback.

The release passes only with the integrated revision, affected services,
deployment result, and production health evidence recorded.
