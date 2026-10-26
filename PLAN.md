# Plan: health check + Coolify template

## Where we are

- `Dockerfile` has a `HEALTHCHECK` that only checks `/state/heartbeat` was modified in the last 20 min.
- `docker-compose.yml` defines **no** healthcheck for either service, so Coolify shows no meaningful status for the stack.
- The heartbeat is touched once per *finished* pass. Two gaps:
  1. A long pass (many images x `SCAN_TIMEOUT=900`) can exceed 20 min and flip to unhealthy while working normally.
  2. A pass where Dependency-Track is down, or every upload fails, still touches the heartbeat. "Healthy" only means "loop is alive".

## Part 1: health check

**Goal:** Docker/Coolify status reflects "the agent is alive and making progress", while "uploads are failing" is visible
without restart loops.

1. **Progress signal.** Touch `/state/heartbeat` at the start and end of every `process_target`, not only per pass, so a long
   pass stays healthy.
2. **Status file.** At the end of each pass write `/state/status.json`:
   `{finished_at, dt_reachable, targets, ok, failed, backoff, consecutive_failed_passes}` (atomic write via tmp + mv).
3. **Health script** `scripts/healthcheck.sh` (replaces the inline `find`):
   - **unhealthy** if the heartbeat is older than `HEALTH_MAX_AGE` (default `3 x RECONCILE_INTERVAL + SCAN_TIMEOUT`);
   - **unhealthy** if `consecutive_failed_passes >= HEALTH_FAIL_PASSES` (default 10: DT unreachable or every target failing for ~10 min);
   - otherwise healthy. A single failing service (in backoff) must **not** make the container unhealthy.
4. **Compose.** Add an explicit `healthcheck:` to `agent` (`CMD /opt/sbom/healthcheck.sh`, interval 60s, timeout 5s,
   retries 3, start_period 120s). Needed because Coolify reads compose health, and a template should not rely on the image.
5. **Proxy.** Add a healthcheck to `docker-proxy` and `depends_on: condition: service_healthy` on the agent.
   *Unverified:* the tecnativa image's available tooling (`wget`/`nc`); check inside the container first. Fallback: TCP check
   with the shell built-in `/dev/tcp` if a shell exists, otherwise skip and keep plain `depends_on`.
6. **Tests (local, stubs as before).** Fresh heartbeat -> 0; stale -> 1; `consecutive_failed_passes=10` -> 1;
   one failing target among healthy ones -> 0; long pass (sleeping stub) keeps heartbeat fresh.
7. **Docs.** README section "Health": what healthy means, `docker inspect --format '{{json .State.Health}}'`, `status.json` fields.

**Done when:** `docker ps` shows `(healthy)` on both services in Coolify, stopping Dependency-Track for ~10 min turns the
agent `unhealthy`, and one broken image does not.

## Part 2: Coolify template

**Possible: yes. Needed: not for our own use** (the repo-based Docker Compose deployment works), but it gives one-click
deploys and a shareable compose. Reference format: `templates/compose/trigger.yaml` in coollabsio/coolify (header
comments `documentation`, `slogan`, `category`, `tags`, `logo`, `port`, then a plain compose `services:` block).

**Blockers / differences vs. our current compose**

| Topic | Today | Template |
|---|---|---|
| Image | `build: .` | Must be a prebuilt `image:` -> publish to `ghcr.io/frank-netkey/sbom-agent:<version>` first (see TODO) |
| Top-level `name:` | set | omit |
| Required vars | `${VAR:?msg}` | keep `:?` for `DTRACK_URL`, `DTRACK_API_KEY`, `HOST_ID`; verify Coolify renders them as required fields |
| Secrets | plain env | `DTRACK_API_KEY` is user-supplied (no `SERVICE_PASSWORD_*` magic var applies) |
| Port header | n/a (no web UI) | verify whether `port:` is optional for headless services |
| Limits | `deploy.resources.limits` incl. `pids` | worked in Coolify after the earlier fix; re-verify |
| Internal network | custom `internal: true` network | verify Coolify keeps it; otherwise drop it and rely on the proxy ACL |
| Docker socket | mounted in proxy only | allowed in other templates, but expect review scrutiny; keep the README explanation and link it in `documentation:` |

**Steps**

1. Finish Part 1 (health checks are required for a good template).
2. Add GitHub Action: build, tag (`vX.Y.Z` + `latest`), push to ghcr.io, make the package public. Pin base images by digest here.
3. Create `coolify-template/sbom-agent.yaml` in this repo: header comments + compose with `image:` (no `build:`).
   Test it via Coolify "Docker Compose Empty" on a real host. This is already shareable with colleagues.
4. Re-check the contribution guide in the Coolify repo (format may have changed since the example commit), then open a PR adding
   `templates/compose/sbom-agent.yaml` plus a logo. Upstream acceptance is the maintainers' call; the self-hosted template from step 3 is the fallback.

**Done when:** a fresh Coolify host can deploy the stack from the template with only the three variables filled in, and both
containers report healthy.

## Order

Part 1 (steps 1-7) -> image publishing (Part 2 step 2) -> template file (step 3) -> upstream PR (step 4).
