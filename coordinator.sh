#!/bin/bash
# coordinator.sh — Automated Coordination Scheduler
# <!-- V5 v2026.05.28.1 -->
#
# Polls agent status, detects status.json changes, commits/pushes to git,
# sends blocker alerts to the master (主公), and manages timed reminders.
#
# Usage:
#   ./coordinator.sh {poll|watch|notify|reminder|validate|all|init-cron}
#
# Subcommands:
#   poll        Poll all agents & report status
#   watch       Check status.json for changes (sha256 diff)
#   notify      Test notification channel
#   reminder    Fire a timed reminder
#   validate    Validate status.json schema (reserved for validate-status.sh)
#   all         Run poll + watch
#   init-cron   Print recommended crontab entries
#

set -euo pipefail

# --- CONFIG ----------------------------------------------------------------
CONFIG_FILE="${COORDINATOR_CONFIG:-$(dirname "$0")/coordinator.conf}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

: "${COORDINATOR_LOG:=/var/log/coordinator.log}"
: "${COORDINATOR_STATUS_DIR:=$(dirname "$0")/../team-share}"
: "${COORDINATOR_STATUS_FILE:=status.json}"
: "${COORDINATOR_AGENTS:=zhugeliang caozhi simayi opencode}"
: "${COORDINATOR_POLL_INTERVAL:=600}"
: "${COORDINATOR_BLOCKER_TIMEOUT:=30}"
: "${COORDINATOR_GIT_BRANCH:=main}"
: "${COORDINATOR_HASH_FILE:=/tmp/coordinator-status.hash}"
: "${COORDINATOR_LOCK_FILE:=/tmp/coordinator.lock}"
: "${COORDINATOR_NOTIFY_METHOD:=primary}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${OPENCLAW_HOST:=127.0.0.1}"
: "${OPENCLAW_PORT:=18789}"
: "${OPENCLAW_HOOK_TOKEN:=}"

STATUS_JSON_PATH="${COORDINATOR_STATUS_DIR}/${COORDINATOR_STATUS_FILE}"

# --- HELPERS ---------------------------------------------------------------
log() {
  local level="$1" msg="$2"
  echo "[$(date -Iseconds)] [${level}] ${msg}" | tee -a "$COORDINATOR_LOG"
}

info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

acquire_lock() {
  if ! mkdir "$COORDINATOR_LOCK_FILE" 2>/dev/null; then
    warn "Another instance is running (lock held at ${COORDINATOR_LOCK_FILE})"
    exit 1
  fi
  trap 'rm -rf "$COORDINATOR_LOCK_FILE"' EXIT
}

# --- 1. AGENT STATUS POLLING ------------------------------------------------
poll_agents() {
  info "Polling agents: ${COORDINATOR_AGENTS}"
  local blocker_found=false

  for agent in $COORDINATOR_AGENTS; do
    local status updated_at
    status="unknown"
    updated_at=""

    if command -v openclaw &>/dev/null; then
      local raw
      raw=$(openclaw sessions --json 2>/dev/null | AGENT_NAME="$agent" python3 -c "
import sys, json, os
agent = os.environ['AGENT_NAME']
try:
    data = json.load(sys.stdin)
    sessions = data if isinstance(data, list) else [data]
    for s in sessions:
        if s.get('agentId') == agent:
            print(json.dumps({'status': s.get('status','unknown'), 'updatedAt': s.get('updatedAt','')}))
            sys.exit(0)
    print(json.dumps({'status':'unknown','updatedAt':''}))
except Exception:
    print(json.dumps({'status':'error','updatedAt':''}))
" 2>/dev/null || echo '{"status":"error","updatedAt":""}') || true

      status=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
      updated_at=$(echo "$raw" | python3 -c "import sys,json; print(json.load(sys.stdin).get('updatedAt',''))" 2>/dev/null || echo "")
    fi

    info "agent=${agent} status=${status} updated_at=${updated_at}"

    # Blocked / error detection
    if [[ "$status" == "blocked" || "$status" == "error" || "$status" == "unknown" ]]; then
      warn "Agent ${agent} is in abnormal state: ${status}"
      blocker_found=true
      notify_blocker "$agent" "$status"
    fi

    # Timeout detection (stale session)
    if [[ -n "$updated_at" ]]; then
      local now_epoch updated_epoch diff_minutes
      now_epoch=$(date +%s)
      updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
      if [[ "$updated_epoch" -gt 0 ]]; then
        diff_minutes=$(( (now_epoch - updated_epoch) / 60 ))
        if [[ "$diff_minutes" -gt "$COORDINATOR_BLOCKER_TIMEOUT" ]]; then
          warn "Agent ${agent} stale: last update ${diff_minutes}m ago (threshold ${COORDINATOR_BLOCKER_TIMEOUT}m)"
          blocker_found=true
          notify_blocker "$agent" "stale:${diff_minutes}m"
        fi
      fi
    fi
  done

  if [[ "$blocker_found" == "false" ]]; then
    info "All agents healthy"
  fi
}

# --- 2. STATUS.JSON CHANGE DETECTION ---------------------------------------
watch_status() {
  info "Checking status.json at: ${STATUS_JSON_PATH}"

  if [[ ! -f "$STATUS_JSON_PATH" ]]; then
    error "status.json not found at ${STATUS_JSON_PATH}"
    return 1
  fi

  local current_hash previous_hash
  current_hash=$(sha256sum "$STATUS_JSON_PATH" | awk '{print $1}')

  if [[ -f "$COORDINATOR_HASH_FILE" ]]; then
    previous_hash=$(cat "$COORDINATOR_HASH_FILE")
  else
    previous_hash=""
  fi

  if [[ "$current_hash" != "$previous_hash" ]]; then
    info "status.json changed: ${previous_hash:+(old)} → ${current_hash} (new)"
    echo "$current_hash" > "$COORDINATOR_HASH_FILE"
    auto_git_push "auto: status.json updated $(date -Iseconds)"
  else
    info "status.json unchanged (hash: ${current_hash})"
  fi
}

# --- 3. AUTO GIT PUSH ------------------------------------------------------
auto_git_push() {
  local commit_msg="${1:-auto: coordinator update}"

  if ! git -C "$COORDINATOR_STATUS_DIR" rev-parse --git-dir &>/dev/null; then
    warn "${COORDINATOR_STATUS_DIR} is not a git repository; skipping push"
    return 0
  fi

  cd "$COORDINATOR_STATUS_DIR"

  git add -A

  if git diff --cached --quiet; then
    info "No changes to commit"
    return 0
  fi

  git commit -m "$commit_msg" 2>&1 | tee -a "$COORDINATOR_LOG"

  if git push origin "$COORDINATOR_GIT_BRANCH" 2>&1 | tee -a "$COORDINATOR_LOG"; then
    info "Git push successful"
  else
    error "Git push failed — check credentials and network"
    notify_blocker "git-push" "push failed"
  fi
}

# --- 4. BLOCKER NOTIFICATION -----------------------------------------------
notify_blocker() {
  local agent="$1" status="$2"
  local message="⚠️ Blocker Alert: Agent ${agent} is abnormal (${status}). Master attention required."

  info "Sending notification: ${message}"

  # Primary: openclaw agent --agent main
  if [[ "$COORDINATOR_NOTIFY_METHOD" == "primary" ]] && command -v openclaw &>/dev/null; then
    if openclaw agent --agent main --message "$message" 2>/dev/null; then
      info "Notification sent via openclaw agent"
      return 0
    else
      warn "openclaw agent notification failed, trying fallback"
    fi
  fi

  # Fallback: OpenClaw Webhook
  if [[ -n "$OPENCLAW_HOOK_TOKEN" ]]; then
    local hook_url="http://${OPENCLAW_HOST}:${OPENCLAW_PORT}/hooks/agent"
    if curl -s -X POST "$hook_url" \
      -H "Authorization: Bearer ${OPENCLAW_HOOK_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"message\":\"${message}\",\"name\":\"blocker-alert\",\"agentId\":\"main\"}" \
      &>/dev/null; then
      info "Notification sent via webhook"
      return 0
    fi
  fi

  # Fallback: Telegram Bot API
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${message}" \
      &>/dev/null; then
      info "Notification sent via Telegram"
      return 0
    fi
  fi

  error "All notification channels failed for agent=${agent} status=${status}"
  return 1
}

# --- 5. TIMED REMINDER -----------------------------------------------------
time_reminder() {
  local remind_at="$1" remind_msg="${2:-Scheduled reminder from coordinator}"

  if [[ -z "$remind_at" ]]; then
    echo "Usage: $0 reminder <HH:MM> [message]"
    echo "       $0 reminder \"+5min\" [message]"
    echo "       $0 reminder \"2026-05-28T14:00:00+08:00\" [message]"
    return 1
  fi

  # Support relative time: +N{min,hour}
  if [[ "$remind_at" == \+* ]]; then
    local sleep_seconds=0
    if [[ "$remind_at" == *min ]]; then
      local num="${remind_at%min}"
      num="${num#+}"
      sleep_seconds=$(( num * 60 ))
    elif [[ "$remind_at" == *hour ]]; then
      local num="${remind_at%hour}"
      num="${num#+}"
      sleep_seconds=$(( num * 3600 ))
    fi

    if [[ "$sleep_seconds" -gt 0 ]]; then
      info "Reminder scheduled in ${sleep_seconds}s: ${remind_msg}"
      sleep "$sleep_seconds"
      notify_blocker "reminder" "${remind_msg}"
      return 0
    fi
  fi

  # Absolute time: HH:MM (today) or ISO 8601
  local target_epoch now_epoch sleep_seconds
  now_epoch=$(date +%s)

  if [[ "$remind_at" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
    target_epoch=$(date -d "${remind_at}" +%s 2>/dev/null || echo 0)
    if [[ "$target_epoch" -le "$now_epoch" ]]; then
      target_epoch=$(( target_epoch + 86400 ))
    fi
  else
    target_epoch=$(date -d "$remind_at" +%s 2>/dev/null || echo 0)
  fi

  if [[ "$target_epoch" -le "$now_epoch" ]]; then
    error "Invalid reminder time: ${remind_at}"
    return 1
  fi

  sleep_seconds=$(( target_epoch - now_epoch ))
  info "Reminder scheduled at ${remind_at} (in ${sleep_seconds}s): ${remind_msg}"
  sleep "$sleep_seconds"
  notify_blocker "reminder" "${remind_msg}"
}

# --- 6. VALIDATE STATUS.JSON (reserved for validate-status.sh integration) --
validate_status() {
  info "Validating status.json at: ${STATUS_JSON_PATH}"

  if [[ ! -f "$STATUS_JSON_PATH" ]]; then
    error "status.json not found"
    return 1
  fi

  # JSON syntax validation
  if python3 -m json.tool "$STATUS_JSON_PATH" &>/dev/null; then
    info "JSON syntax: valid"
  else
    error "JSON syntax: INVALID"
    notify_blocker "validate-status" "status.json has invalid JSON syntax"
    return 1
  fi

  # Required fields check
  local required_fields=("no_task" "last_updated" "current_task" "steps")
  for field in "${required_fields[@]}"; do
    if python3 -c "
import sys, json
with open('${STATUS_JSON_PATH}') as f:
    data = json.load(f)
print('${field}' in data)
" 2>/dev/null | grep -q "True"; then
      info "  field ${field}: present"
    else
      warn "  field ${field}: MISSING"
      notify_blocker "validate-status" "status.json missing field: ${field}"
    fi
  done

  info "Validation complete"
}

# --- 7. CRON INIT ----------------------------------------------------------
init_cron() {
  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  cat <<EOF
# =====================================================
# Recommended crontab entries for coordinator.sh
# Add these to your crontab: crontab -e
# =====================================================

# Poll agents every 10 minutes
*/10 * * * * ${script_path} poll >> ${COORDINATOR_LOG} 2>&1

# Check status.json every 5 minutes
*/5 * * * * ${script_path} watch >> ${COORDINATOR_LOG} 2>&1

# Full check every 30 minutes
*/30 * * * * ${script_path} all >> ${COORDINATOR_LOG} 2>&1

# Validate status.json hourly
0 * * * * ${script_path} validate >> ${COORDINATOR_LOG} 2>&1

# =====================================================
# OpenClaw cron equivalents (run via openclaw CLI):
# =====================================================

# openclaw cron add \\
#   --name "coordinator-poll" \\
#   --every 600000 \\
#   --session isolated \\
#   --message "Run coordinator poll" \\
#   --announce \\
#   --channel telegram

# openclaw cron add \\
#   --name "coordinator-watch" \\
#   --every 300000 \\
#   --session isolated \\
#   --message "Run coordinator watch" \\
#   --announce \\
#   --channel telegram
EOF
}

# --- MAIN ------------------------------------------------------------------
main() {
  local cmd="${1:-help}"

  if [[ "$cmd" != "help" && "$cmd" != "init-cron" ]]; then
    acquire_lock
  fi

  case "$cmd" in
    poll)
      poll_agents
      ;;
    watch)
      watch_status
      ;;
    notify)
      local agent="${2:-test}"
      local status="${3:-manual-test}"
      notify_blocker "$agent" "$status"
      ;;
    reminder)
      shift
      time_reminder "$@"
      ;;
    validate)
      validate_status
      ;;
    all)
      poll_agents
      watch_status
      ;;
    init-cron)
      init_cron
      ;;
    help|--help|-h)
      cat <<USAGE
coordinator.sh — Automated Coordination Scheduler

Usage:
  $(basename "$0") {poll|watch|notify|reminder|validate|all|init-cron|help}

Subcommands:
  poll              Poll all agents & report status
  watch             Check status.json for changes (sha256 diff)
  notify [a] [s]    Test notification (agent, status)
  reminder <t> [m]  Schedule a reminder (time, message)
  validate          Validate status.json schema
  all               Run poll + watch
  init-cron         Print recommended crontab entries
  help              Show this help message

Configuration:
  COORDINATOR_CONFIG   Config file path (default: ./coordinator.conf)
  COORDINATOR_LOG      Log file path (default: /var/log/coordinator.log)

Examples:
  $(basename "$0") poll
  $(basename "$0") watch
  $(basename "$0") reminder "14:30" "Standup meeting""
  $(basename "$0") reminder "+10min" "Check on zhugeliang""
USAGE
      ;;
    *)
      error "Unknown command: ${cmd}"
      echo "Usage: $(basename "$0") {poll|watch|notify|reminder|validate|all|init-cron|help}"
      exit 1
      ;;
  esac
}

main "$@"
