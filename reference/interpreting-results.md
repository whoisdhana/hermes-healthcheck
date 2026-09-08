# Interpreting health-check results

## Exit codes (both scripts)

| Code | Meaning |
|---|---|
| 0 | HEALTHY / OK |
| 1 | WARNING — degraded, or a check the script could not complete |
| 2 | CRITICAL — hard failure |

Neither script alerts anyone. They print and exit. Routing is deliberately out
of scope — `parentping-health-check.sh`'s own header says so.

## fleet-health-summary.sh

Reports RAM, swap, filesystems, and every unit matching `*hermes*gateway*.service`
(user scope + system scope). Severity is the max across all checks.

| Trigger | Severity |
|---|---|
| RAM ≥ `RAM_WARN_PERCENT` (default 80) | WARNING |
| RAM ≥ `RAM_CRIT_PERCENT` (default 90) | CRITICAL |
| Any filesystem ≥ `DISK_WARN_PERCENT` (default 80) | WARNING |
| Any filesystem ≥ `DISK_CRIT_PERCENT` (default 90) | CRITICAL |
| Unit `activating` / `inactive` / `deactivating` / `reloading` | WARNING |
| Unit `failed`, or unit file missing | CRITICAL |
| **Zero** gateway units discovered | WARNING |

Swap percentage is printed but never affects severity.

### The false WARNING you will probably hit

A gateway can be running perfectly while its systemd unit reads `inactive
(dead)` — because the unit is not how that gateway is actually started.

Worked example, observed on a real deployment:

```
user/hermes-gateway-alpha.service: inactive (dead)     → Overall: WARNING (exit 1)
```

But the unit was never started, let alone crashed:

```
UnitFileState=disabled   Result=success   NRestarts=0
ExecMainStatus=0         ExecMainExitTimestamp=(empty)
journalctl -u ... → "-- No entries --"
```

The `alpha` gateway was in fact up, via two other paths:

- `hermes --profile alpha serve --isolated` (started by a Desktop SSH session)
- a separate web server process listening on a localhost port

**How to tell a false WARNING from a real one:**

| Signal | Never started (false alarm) | Actually broken |
|---|---|---|
| `UnitFileState` | `disabled` | `enabled` |
| `Result` | `success` | `exit-code`, `signal`, `timeout` |
| `NRestarts` | `0` | `> 0` |
| `ExecMainExitTimestamp` | empty | a real timestamp |
| `journalctl -u <unit>` | no entries | logs, usually a stack trace |

Confirm the gateway is genuinely alive before dismissing it:

```sh
pgrep -af -i <profile>          # a serve process for that profile?
ss -ltnp | grep <port>          # something listening?
```

If the process is there, the WARNING is a discovery artifact, not an outage.
Do not "fix" it by editing the script. Either remove the stale unit file or
accept exit 1 as this box's normal.

## parentping-health-check.sh

One line, one URL. `PARENTPING_HEALTH_URL` **must** be set per-box — the
built-in default points at the reference deployment.

| Trigger | Severity |
|---|---|
| HTTP 2xx + healthy body + cert valid ≥ 14d | OK |
| Latency > `PARENTPING_WARN_LATENCY` (default 5s) | WARNING |
| Cert expires < `PARENTPING_WARN_TLS_DAYS` (default 14) | WARNING |
| TLS read failed but HTTP fine | WARNING (`certificate_check_failed`) |
| Non-2xx status | CRITICAL |
| Body not recognizably healthy | CRITICAL (`unhealthy_body`) |
| Cert already expired | CRITICAL |
| curl failed entirely | CRITICAL (`curl_failed`) |
| Missing `curl`/`openssl`/… | CRITICAL (`missing_dependency`) |
| URL not `https://` | CRITICAL (`invalid_https_url`) |

Accepted healthy bodies: bare `ok`/`healthy`, or JSON with
`"status":"ok|healthy|up|pass|passing"`, `"healthy":true`, or `"ok":true`.
The words `unhealthy`, `degraded`, `failed`, or an `"error"` key veto all of
the above — a 200 with a sad body is still CRITICAL.

HTTPS is required, not preferred: TLS expiry is part of the contract, so there
is no way to check a plain-HTTP endpoint with this script.

## Reading a run

```
OK url=https://example.com/healthz http=200 latency=1.09s tls_days=61 \
   tls_expiry=2026-11-08T11:55:15Z body=healthy
```

`tls_days` is the field worth watching over time — it is the only one that
degrades silently and on a predictable schedule.
