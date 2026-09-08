# hermes-healthcheck

A Claude Code skill that installs and runs two read-only health checks on a box
running the Hermes agent.

| Script | Checks |
|---|---|
| `fleet-health-summary.sh` | RAM, swap, filesystems, `*hermes*gateway*.service` units |
| `parentping-health-check.sh` | One HTTPS endpoint + its TLS expiry |

Both print and exit `0` (healthy) / `1` (warning) / `2` (critical). **They do not
alert anyone** — no cron, no timer, no notifications. Scheduling and routing are
deliberately out of scope.

## Install

```sh
git clone https://github.com/whoisdhana/hermes-healthcheck.git \
  ~/.claude/skills/hermes-healthcheck
```

Then, in Claude Code:

> set up the Hermes health checks on my box

Claude probes your machine, reports what it finds, installs both scripts, asks
for your healthz URL, writes `~/.config/hermes-health.env`, and runs both checks.

To update later: `git pull` in that directory.

## Read this before your first run

**`PARENTPING_HEALTH_URL` must be set for your box.** It ships as the placeholder
`https://example.com/healthz`, so an unset install reports on a URL unrelated to
your service. The install procedure asks for it rather than guessing.

**A gateway can read `inactive (dead)` while running fine**, if it is started
outside its systemd unit. That produces a WARNING (exit 1) that is not an
outage. `reference/interpreting-results.md` has the five-signal table for
telling a never-started unit from a genuinely broken one.

## Requirements

Linux with systemd. Needs `bash` >= 4, plus `curl openssl date mktemp timeout tr
awk`. Not macOS — the scripts use `free`, `df -P -B1`, and GNU `date -d`.

## Layout

```
SKILL.md                           # trigger + 5-step install procedure
scripts/fleet-health-summary.sh    # installed to ~/.hermes/work/
scripts/parentping-health-check.sh
reference/interpreting-results.md  # exit codes, severity tables, false warnings
```

Per-box differences belong in `~/.config/hermes-health.env`. The scripts
themselves are never edited.

## Provenance

These scripts run in production on the author's box. The public copies differ
from those originals in one respect only: hostnames, profile names and the
default health URL have been replaced with placeholders. Check logic is
unchanged.
