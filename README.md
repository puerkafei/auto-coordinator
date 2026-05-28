# Coordinator — Automated Agent Coordination Scheduler

> **Version**: v2026.05.29.1

`coordinator.sh` is a shell-based coordination scheduler for OpenClaw multi-agent workflows. It polls agent status, detects `status.json` changes, auto-commits and pushes to git, sends blocker alerts, manages timed reminders, handles workflow relay (auto handoff between agents), and orchestrates GitHub uploads (prepare → push → release).

## Features

- **Agent Status Polling** — Polls `zhugeliang`, `caozhi`, `simayi`, `opencode` via `openclaw sessions --json`
- **Status Change Detection** — Monitors `status.json` with SHA-256 hash comparison
- **Auto Git Push** — Automatically commits and pushes changes to the configured branch
- **Blocker Notification** — Multi-channel alerts via `openclaw agent --agent main`, webhook, and Telegram fallback
- **Timed Reminders** — Supports absolute time (`HH:MM`), relative time (`+10min`), and ISO 8601 timestamps
- **Workflow Relay** — Auto handoff between agents on task completion, with anti-jump validation
- **GitHub Upload** — Four-mode upload pipeline: prepare manifest, git push, create release, or all-in-one auto
- **Status Validation** — JSON syntax check and required field validation for `status.json`
- **Cron Integration** — Built-in `init-cron` command generates recommended crontab entries

## Requirements

| Dependency | Purpose |
|-----------|---------|
| Bash 4+ | Runtime shell |
| `sha256sum` (coreutils) | Status hash comparison |
| `python3` | JSON processing & validation |
| `openclaw` CLI | OpenClaw agent integration |
| `curl` | Telegram / webhook / GitHub API notifications |
| `jq` | Optional — recommended for JSON parsing |

## Quick Start

```bash
# 1. Edit configuration
cp coordinator.conf.example coordinator.conf
vim coordinator.conf

# 2. Poll all agents
./coordinator.sh poll

# 3. Watch for status.json changes
./coordinator.sh watch

# 4. Full check (poll + watch)
./coordinator.sh all

# 5. Print crontab entries
./coordinator.sh init-cron
```

## Usage

```
./coordinator.sh {poll|watch|notify|reminder|validate|all|init-cron|relay|upload|help}
```

### Subcommands

| Command | Description |
|---------|-------------|
| `poll` | Poll all configured agents and report their status |
| `watch` | Check `status.json` for changes using SHA-256 diff |
| `notify [agent] [status]` | Test notification channels with a custom message |
| `reminder <time> [message]` | Schedule a one-shot reminder |
| `validate` | Validate `status.json` — JSON syntax and required fields |
| `all` | Run `poll` + `watch` in sequence |
| `init-cron` | Print recommended system crontab entries |
| `relay` | Workflow auto handoff — relay task completion to the next agent |
| `upload` | GitHub upload pipeline — prepare, push, release, or auto |
| `help` | Show usage information |

### Upload Subcommand

The `upload` subcommand provides a four-mode pipeline for uploading deliverables to GitHub. Each mode handles a distinct stage of the process.

```
./coordinator.sh upload {prepare|push|release|auto} [options]
```

#### Modes

| Mode | Description |
|------|-------------|
| `prepare` | Scan working tree and build a file manifest. Sources: `--files` flag, `status.json` manifest, or `git diff` as fallback. Also includes untracked files. Prints the manifest as a comma-separated list. |
| `push` | Git `add`, `commit`, `tag`, and `push` to remote. Auto-generates tag from work ID or date. Force-updates existing tags. |
| `release` | Create or update a GitHub Release for the current tag. Uploads manifest files as release assets. Requires `GITHUB_TOKEN`. |
| `auto` | Convenience mode — runs `prepare` → `push` → `release` in sequence with a single command. |

#### Options

| Option | Applies To | Description |
|--------|-----------|-------------|
| `--work-id <id>` | all | Work ID for commit message and tag generation |
| `--repo <owner/repo>` | release, auto | GitHub repository (auto-detected from git remote if omitted) |
| `--tag <tag>` | push, release, auto | Custom tag (default: `vYYYY.MM.DD` or `vYYYY.MM.DD-<work-id>`) |
| `--files <file1,file2,…>` | prepare, auto | Comma-separated file list for the manifest |
| `--msg <message>` | push, auto | Custom commit message |

#### Examples

```bash
# Prepare file manifest from status.json
./coordinator.sh upload prepare

# Prepare with explicit files
./coordinator.sh upload prepare --files "README.md,coordinator.sh,coordinator.conf"

# Git add, commit, tag, and push
./coordinator.sh upload push --work-id TASK-20260528-upload-module --msg "Add upload module"

# Create or update GitHub Release
./coordinator.sh upload release --repo org/repo

# All-in-one: prepare + push + release
./coordinator.sh upload auto --work-id TASK-20260528-upload-module --msg "Upload coordinator module"
```

> **Note**: `upload release` and `upload auto` require the `GITHUB_TOKEN` environment variable to be set. The token must have `repo` scope for private repos or `public_repo` scope for public repos.

### Relay Subcommand

The `relay` subcommand handles automatic workflow handoff between agents:

```bash
# Relay an agent completion to advance the workflow
./coordinator.sh relay --agent zhugeliang --status completed --work-id TASK-20260528-auto-relay

# With a completion message
./coordinator.sh relay --agent opencode --status completed --work-id TASK-20260528-auto-relay --message "Coding done, ready for review"

# Via stdin (JSON payload)
echo '{"agent":"zhugeliang","status":"completed","work_id":"TASK-20260528-auto-relay"}' | ./coordinator.sh relay
```

**Anti-jump protection** — The relay validates that the reporting agent matches the current in-progress step in `status.json`, preventing out-of-order handoffs.

**Agent notification routing**:

| Agent | Notification Method |
|-------|-------------------|
| `caocao`, `simayi`, `caozhi`, `zhugeliang` | `openclaw agent --agent <id> --message` |
| `opencode` | Notifies `caocao` to `sessions_spawn` opencode |

### Examples

```bash
# Poll agents
./coordinator.sh poll

# Watch for status.json changes
./coordinator.sh watch

# Relay a task completion
./coordinator.sh relay --agent zhugeliang --status completed --work-id TASK-20260528-auto-relay

# Upload auto pipeline
./coordinator.sh upload auto --work-id TASK-20260528-upload-module

# Schedule a reminder at 14:30
./coordinator.sh reminder "14:30" "Team standup"

# Schedule a reminder in 10 minutes
./coordinator.sh reminder "+10min" "Check on zhugeliang"

# Validate status.json
./coordinator.sh validate

# Generate crontab entries
./coordinator.sh init-cron
```

## Configuration

Configuration is loaded from `coordinator.conf` (or the path in `$COORDINATOR_CONFIG`). All settings can be overridden via environment variables.

### Config File Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COORDINATOR_LOG` | `/var/log/coordinator.log` | Log file path |
| `COORDINATOR_STATUS_DIR` | `../team-share` | Directory containing `status.json` |
| `COORDINATOR_STATUS_FILE` | `status.json` | Status file name |
| `COORDINATOR_AGENTS` | `zhugeliang caozhi simayi opencode` | Space-separated agent list |
| `COORDINATOR_BLOCKER_TIMEOUT` | `30` | Minutes before an agent is considered stale |
| `COORDINATOR_GIT_BRANCH` | `main` | Git branch for auto-push |
| `COORDINATOR_NOTIFY_METHOD` | `primary` | Notification channel (primary / webhook / telegram) |
| `RELAY_WORKFLOW_PATH` | `team-workflow` | Workflow template name (from team-workflow skill) |
| `RELAY_STATUS_JSON` | *(same as status.json)* | Status JSON path for relay operations |
| `RELAY_STEPS` | *(empty)* | Step → agentId routing map (optional, pipe-delimited) |
| `GITHUB_TOKEN` | *(env var)* | GitHub personal access token for release creation |

> **Note**: `GITHUB_TOKEN` is read from the environment, not from `coordinator.conf`. Set it via your shell profile, `.env` file, or CI secrets.

## Notification Channels

| Priority | Channel | Command |
|----------|---------|---------|
| Primary | `openclaw agent --agent main --message "..."` | Recommended default |
| Fallback 1 | Webhook — `http://127.0.0.1:18789/hooks/agent` | OpenClaw webhook endpoint |
| Fallback 2 | Telegram Bot API | Direct Telegram fallback |

Channels fall back automatically if the primary method fails.

## Cron Integration

### System Crontab

```crontab
# Poll agents every 10 minutes
*/10 * * * * /path/to/coordinator.sh poll >> /var/log/coordinator.log 2>&1

# Check status.json every 5 minutes
*/5 * * * * /path/to/coordinator.sh watch >> /var/log/coordinator.log 2>&1

# Full check every 30 minutes
*/30 * * * * /path/to/coordinator.sh all >> /var/log/coordinator.log 2>&1
```

### OpenClaw Cron

```bash
openclaw cron add \
  --name "coordinator-poll" \
  --every 600000 \
  --session isolated \
  --message "Run coordinator poll" \
  --announce \
  --channel telegram
```

## Architecture

```
                    ┌──────────────────────────┐
                    │     coordinator.sh        │
                    │    (core scheduler)       │
                    └──────┬────────┬──────────┘
                           │        │
            ┌──────────────┼────────┼──────────────────┐
            │              │        │                  │
     ┌──────▼──────┐ ┌────▼─────┐  │          ┌───────▼──────┐
     │ poll agents │ │ watch    │  │          │ notify       │
     │ (sessions)  │ │ status   │  │          │ (main/       │
     │             │ │ .json    │  │          │  webhook/    │
     │             │ │ → git    │  │          │  telegram)   │
     └─────────────┘ └──────────┘  │          └──────────────┘
                                   │
                          ┌────────▼────────┐     ┌──────────────────┐
                          │  relay          │     │   upload         │
                          │  (workflow      │     │ (prepare / push  │
                          │   auto handoff) │     │  / release / auto)│
                          └─────────────────┘     └──────────────────┘
```

## Integration: validate-status.sh

The `validate` subcommand can absorb the logic of a hypothetical `validate-status.sh` script. It currently performs:

- JSON syntax validation via `python3 -m json.tool`
- Required field presence check (`no_task`, `last_updated`, `current_task`, `steps`)
- Blocker notification on validation failure

## License

Internal tool — OpenClaw Team.
