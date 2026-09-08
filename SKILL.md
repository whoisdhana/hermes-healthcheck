---
name: hermes-healthcheck
description: Use when installing, running, or interpreting the Hermes fleet + service health checks on a box running the Hermes agent. Covers "set up the health checks on my box", "is my Hermes fleet healthy", a gateway showing inactive/dead, RAM or disk warnings, a healthz endpoint failing, or a TLS certificate nearing expiry.
---

# Hermes health checks

Two read-only scripts, shipped in `scripts/`. They print and exit. **They do not
alert anyone** — no cron, no timer, no notification channel. Scheduling and
routing are deliberately out of scope.

| Script | Checks | Exit |
|---|---|---|
| `fleet-health-summary.sh` | RAM, swap, filesystems, `*hermes*gateway*.service` units | 0/1/2 |
| `parentping-health-check.sh` | One HTTPS endpoint + its TLS expiry | 0/1/2 |

0 = healthy, 1 = warning, 2 = critical. Full severity tables and the
false-WARNING guide: `reference/interpreting-results.md`.

## Write surface — do not exceed

This skill writes in exactly **three** places:

1. `$HERMES_HEALTH_DIR/fleet-health-summary.sh` (default `~/.hermes/work/`)
2. `$HERMES_HEALTH_DIR/parentping-health-check.sh`
3. `~/.config/hermes-health.env`

Everything else is read-only probing. Show a diff and confirm before
overwriting any existing file. Never install a scheduler. Never edit the two
scripts — all per-box variation goes in the env file.

## Install: five steps, in order

### 1. Probe (read-only)

Run on the target box and print a findings table. Nothing is written yet.

```sh
uname -sr; bash --version | head -1        # need bash >= 4 (${var,,}, mapfile)
for c in curl openssl date mktemp timeout tr awk; do
  command -v "$c" >/dev/null || echo "MISSING: $c"
done
systemctl --user show-environment >/dev/null 2>&1 && echo "systemd --user: yes" \
  || echo "systemd --user: NO"
systemctl --user list-units --all --type=service --no-legend --no-pager 2>/dev/null \
  | grep -iE 'hermes.*gateway|gateway.*hermes' || echo "no user gateway units"
pgrep -af -i hermes | head -20
ss -ltnp 2>/dev/null | head -20
```

macOS is not a target: the scripts need `free`, `df -P -B1`, GNU `date -d`, and
systemd. Stop and say so if `uname` is Darwin.

### 2. Report the gateway-discovery verdict

Compare units found against Hermes processes and listening ports found.

- **Units match processes** → discovery will work; say so.
- **Processes with no matching unit** → `fleet-health-summary.sh` will report
  WARNING for them. Say this out loud *now*, before install, so the first run's
  exit 1 is expected rather than alarming. Cite the worked example in
  `reference/interpreting-results.md`.
- **No units at all** → the script exits 1 (`none discovered`) by design.

**Report only. Do not adapt the script, and do not silently widen
`HEALTH_UNIT_DIRS_*` to make a warning disappear.** A gateway started outside
systemd is a fact about their setup, not a bug in the check.

### 3. Install the scripts

Copy both from this skill's `scripts/` to `$HERMES_HEALTH_DIR` (default
`~/.hermes/work/`), then `chmod +x`. If a file already exists, diff it and
confirm before overwriting. Verify after copying:

```sh
bash -n <each script>     # must parse
sha256sum <each script>   # must match this skill's copies
```

### 4. Write the env file

`~/.config/hermes-health.env`. Write **only** values that differ from the
script defaults, and only values you were given or confirmed — never a guess.

```sh
# REQUIRED — the built-in default is a placeholder, not your service.
PARENTPING_HEALTH_URL=https://<their-host>/healthz
```

`PARENTPING_HEALTH_URL` must be **asked for**, never guessed. It defaults to
the placeholder `https://example.com/healthz`, so leaving it unset means the
check reports on a URL that has nothing to do with their box. Never point it at
a third party's endpoint either — this script polls on every run.

Optional, all with sane defaults — omit unless there is a reason:

| Var | Default | Use when |
|---|---|---|
| `RAM_WARN_PERCENT` / `RAM_CRIT_PERCENT` | 80 / 90 | Box runs hot by design |
| `DISK_WARN_PERCENT` / `DISK_CRIT_PERCENT` | 80 / 90 | Large disk, different tolerance |
| `HEALTH_UNIT_DIRS_USER` | `~/.config/systemd/user` | Non-standard unit location |
| `HEALTH_UNIT_DIRS_SYSTEM` | `/etc/systemd/system:...` | Non-standard unit location |
| `PARENTPING_WARN_LATENCY` | 5 | Endpoint is legitimately slow |
| `PARENTPING_WARN_TLS_DAYS` | 14 | Different renewal window |
| `PARENTPING_CONNECT_TIMEOUT` / `PARENTPING_TOTAL_TIMEOUT` | 5 / 15 | Slow link |
| `PARENTPING_RETRIES` | 2 | Flaky link |

Warn thresholds must be ≤ crit thresholds, or the fleet script exits 2 on a
config error.

### 5. Verify — run both, show real output

```sh
set -a; . ~/.config/hermes-health.env; set +a
bash "$HERMES_HEALTH_DIR/fleet-health-summary.sh";     echo "exit=$?"
bash "$HERMES_HEALTH_DIR/parentping-health-check.sh";  echo "exit=$?"
```

Paste actual output and actual exit codes. A WARNING that step 2 predicted is a
**pass** — call it that explicitly, and restate why. Do not chase it.

## Running it later

```sh
set -a; . ~/.config/hermes-health.env; set +a
bash ~/.hermes/work/fleet-health-summary.sh
```

Without sourcing the env file, the parentping check silently reverts to the
reference deployment's URL.

## Sharing this skill

Copy the whole directory to `~/.claude/skills/hermes-healthcheck/` on the other
machine — zip it, or keep it in a small git repo the recipient clones (better,
since fixes propagate instead of forking). The scripts are byte-identical to the
reference box's copies and must stay that way; per-box differences belong in the
env file. Verify with `sha256sum` after any move.
