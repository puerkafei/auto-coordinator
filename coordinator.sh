#!/bin/bash
# coordinator.sh — Automated Coordination Scheduler
# <!-- V5 v2026.05.29.1 -->
#
# Polls agent status, detects status.json changes, commits/pushes to git,
# sends blocker alerts to the master (主公), and manages timed reminders.
#
# Usage:
#   ./coordinator.sh {poll|watch|notify|reminder|validate|all|init-cron|relay}
#
# Subcommands:
#   poll        Poll all agents & report status
#   watch       Check status.json for changes (sha256 diff)
#   notify      Test notification channel
#   reminder    Fire a timed reminder
#   validate    Validate status.json schema (reserved for validate-status.sh)
#   all         Run poll + watch
#   init-cron   Print recommended crontab entries
#   relay       Workflow auto-handoff (agent task relay)
#   upload      Git push + GitHub Release (prepare|push|release|auto)
#

set -euo pipefail

# --- CONFIG ----------------------------------------------------------------
CONFIG_FILE="${COORDINATOR_CONFIG:-$(dirname "$0")/coordinator.conf}"

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

# Auto-load environment secrets (~/.openclaw/.env never pushed to git)
if [[ -f "$HOME/.openclaw/.env" ]]; then
  set -a
  source "$HOME/.openclaw/.env"
  set +a
fi

: "${COORDINATOR_LOG:=/tmp/coordinator.log}"
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

# Relay config
: "${RELAY_CONF:=$(dirname "$0")/relay.conf}"
: "${RELAY_WORKFLOW_PATH:=team-workflow}"
: "${RELAY_STATUS_JSON:=${STATUS_JSON_PATH}}"
: "${RELAY_STEPS:=}"
: "${RELAY_DEDUP_FILE:=/tmp/coordinator-relay-dedup.txt}"

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

# --- 8. RELAY — AUTO HANDOFF (subcommands: check | notify | auto | check-session) ---
# Reads status.json steps to detect completed steps and auto-notify next agent.
# Uses relay.conf for role→agentId mapping.
# READ-ONLY: does NOT write to status.json; notifies 甄宓(main) to update.

relay_find_next() {
  python3 -c "
import sys, json, os
status_path = os.environ.get('STATUS_JSON_PATH', '${STATUS_JSON_PATH}')
try:
    with open(status_path) as f:
        data = json.load(f)
except Exception as e:
    print(json.dumps({'action': 'error', 'reason': str(e)}))
    sys.exit(0)

steps = data.get('steps', [])
if not steps:
    print(json.dumps({'action': 'none', 'reason': 'no_steps'}))
    sys.exit(0)

work_id = data.get('current_task', {}).get('work_id', 'unknown')

# Find last completed step where reported_next is not true
last_completed = None
last_completed_idx = -1
for i, s in enumerate(steps):
    if s.get('status') == 'completed' and not s.get('reported_next', False):
        last_completed = s
        last_completed_idx = i

if last_completed is None:
    all_done = all(s.get('status') == 'completed' for s in steps)
    if all_done:
        print(json.dumps({'action': 'all_done', 'work_id': work_id}))
    else:
        running = [s for s in steps if s.get('status') == '执行中']
        print(json.dumps({
            'action': 'none',
            'reason': 'all_completed_already_relayed',
            'work_id': work_id,
            'running_count': len(running)
        }))
    sys.exit(0)

next_idx = last_completed_idx + 1
if next_idx >= len(steps):
    print(json.dumps({'action': 'all_done', 'work_id': work_id}))
    sys.exit(0)

next_step = steps[next_idx]
print(json.dumps({
    'action': 'notify',
    'work_id': work_id,
    'current_step_id': last_completed.get('id'),
    'current_step_name': last_completed.get('name', ''),
    'next_step': next_step,
    'next_step_id': next_step.get('id'),
    'next_assignee': next_step.get('assignee', ''),
    'next_name': next_step.get('name', '')
}))
" 2>/dev/null || echo '{"action":"error","reason":"python_failed"}'
}

relay_lookup_agent() {
  local role="$1"
  python3 -c "
import configparser, sys, json
conf_path = '${RELAY_CONF}'
try:
    config = configparser.ConfigParser()
    config.read(conf_path)
    if config.has_section('${role}'):
        agent_id = config.get('${role}', 'agentId', fallback='')
        agent_type = config.get('${role}', 'type', fallback='native')
        print(json.dumps({'agentId': agent_id, 'type': agent_type}))
    else:
        print(json.dumps({'error': 'role_not_found', 'role': '${role}'}))
except Exception as e:
    print(json.dumps({'error': str(e)}))
"
}

relay_notify_step() {
  local next_assignee="$1" work_id="$2" next_step_id="$3" current_step_id="$4" step_name="$5"

  if [[ -z "$next_assignee" ]]; then
    error "relay notify: empty next_assignee"; return 1
  fi

  info "relay: looking up agent for role '${next_assignee}'"
  local agent_info
  agent_info=$(relay_lookup_agent "$next_assignee")

  local agent_id agent_type
  agent_id=$(echo "$agent_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agentId',''))" 2>/dev/null || echo "")
  agent_type=$(echo "$agent_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','native'))" 2>/dev/null || echo "native")

  if [[ -z "$agent_id" ]]; then
    local err_role
    err_role=$(echo "$agent_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('role','${next_assignee}'))" 2>/dev/null || echo "${next_assignee}")
    error "relay: agent not found for role '${err_role}' in relay.conf"
    notify_blocker "relay" "agent_not_found: ${err_role}"
    return 1
  fi

  local message
  message="[Auto-Relay] 接力通知：${step_name}（step #${next_step_id}）\nwork_id=${work_id}\n上一步 #${current_step_id} 已完成，请开始本环节"

  if [[ "$agent_type" == "acp" ]]; then
    # ACP Agent（opencode）→ 通知曹操代发 sessions_spawn
    info "relay: ACP agent '${agent_id}' (${next_assignee}) → routing through caocao"
    local caocao_msg
    caocao_msg="【ACP接力请求】请向 ${agent_id}（${next_assignee}）派发任务：\nwork_id=${work_id}, step=${next_step_id} (${step_name})\n请使用 sessions_spawn(runtime:'acp', agentId:'${agent_id}', ...)\n上一步 #${current_step_id} 已完成"

    if openclaw agent --agent caocao --message "$caocao_msg" --deliver --json 2>/dev/null; then
      info "relay: ACP relay sent to caocao for '${agent_id}'"
    else
      error "relay: failed to notify caocao for ACP relay to '${agent_id}'"
      notify_blocker "relay" "acp_relay_failed: ${agent_id}"
      return 1
    fi
  else
    # Native Agent → 直接 openclaw agent CLI 通知
    info "relay: native agent '${agent_id}' (${next_assignee}) → direct notification"
    if openclaw agent --agent "$agent_id" --message "$message" --deliver --json 2>/dev/null; then
      info "relay: notified '${agent_id}' (${next_assignee}) via openclaw agent"
    else
      error "relay: failed to notify '${agent_id}'"
      notify_blocker "relay" "notify_failed: ${agent_id}"
      return 1
    fi
  fi

  # Dedup record
  local dedup_ts
  dedup_ts=$(date +%s)
  echo "${current_step_id}:${work_id}:${dedup_ts}" >> "$RELAY_DEDUP_FILE"

  # 通知甄宓更新 status.json
  local update_msg
  update_msg="【relay完成】step #${current_step_id} 已接力至 step #${next_step_id}（${next_assignee}：${step_name}）\n请更新 status.json:\n- steps[${current_step_id}].reported_next=true\n- steps[${next_step_id}].status='执行中'"

  if openclaw agent --agent main --message "$update_msg" --deliver --json 2>/dev/null; then
    info "relay: notified 甄宓(main) to update status.json"
  else
    warn "relay: failed to notify 甄宓 — status.json update must be done manually"
  fi

  return 0
}

relay_signal_all_done() {
  local work_id="$1"
  info "relay: all steps completed for work_id=${work_id}"

  local message
  message="【Auto-Relay】所有步骤已完成！work_id=${work_id}\n请更新 status.json: current_task 归档，no_task=true"

  if openclaw agent --agent main --message "$message" --deliver --json 2>/dev/null; then
    info "relay: notified 甄宓(main) about all steps done"
  else
    error "relay: failed to notify 甄宓 about all steps done"
    notify_blocker "relay" "all_done_notify_failed: ${work_id}"
    return 1
  fi
}

# --- relay subcommand handlers ---

relay_check_handler() {
  info "relay check: reading status.json at ${STATUS_JSON_PATH}"

  if [[ ! -f "$STATUS_JSON_PATH" ]]; then
    error "relay check: status.json not found"; return 1
  fi

  local result
  result=$(relay_find_next)

  local action
  action=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo "")

  case "$action" in
    notify)
      local next_assignee next_step_id current_step_id work_id step_name
      next_assignee=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_assignee',''))" 2>/dev/null || echo "")
      next_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_step_id',''))" 2>/dev/null || echo "")
      current_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current_step_id',''))" 2>/dev/null || echo "")
      work_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id',''))" 2>/dev/null || echo "")
      step_name=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_name',''))" 2>/dev/null || echo "")
      info "relay check: step #${current_step_id} → next step #${next_step_id} (${next_assignee}: ${step_name}) [work_id=${work_id}]"
      echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
      ;;
    all_done)
      work_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id','unknown'))" 2>/dev/null || echo "unknown")
      info "relay check: ALL STEPS COMPLETED for work_id=${work_id}"
      echo "$result"
      ;;
    none)
      local reason
      reason=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null || echo "")
      info "relay check: no relay needed (${reason})"
      echo "$result"
      ;;
    error)
      local err
      err=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null || echo "unknown")
      error "relay check: error — ${err}"
      return 1
      ;;
    *)
      error "relay check: unexpected action '${action}'"
      return 1
      ;;
  esac
}

relay_notify_handler() {
  # Optional: accept explicit step params; auto-detect if not provided
  local target_assignee="${1:-}"

  if [[ -n "$target_assignee" ]]; then
    # Manual notify: relay notify <assignee>
    info "relay notify: manual notify for role '${target_assignee}'"
    local agent_info
    agent_info=$(relay_lookup_agent "$target_assignee")
    local agent_id
    agent_id=$(echo "$agent_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agentId',''))" 2>/dev/null || echo "")
    if [[ -z "$agent_id" ]]; then
      error "relay notify: role '${target_assignee}' not found in relay.conf"
      return 1
    fi
    echo "Role: ${target_assignee} → Agent: ${agent_id}"
    echo "To send notification: coordinator.sh relay auto"
    return 0
  fi

  # Auto-detect from status.json
  info "relay notify: auto-detecting relay target from status.json..."
  local result
  result=$(relay_find_next)

  local action
  action=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo "")

  if [[ "$action" != "notify" ]]; then
    if [[ "$action" == "all_done" ]]; then
      local wid
      wid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id','unknown'))" 2>/dev/null || echo "unknown")
      info "relay notify: all steps done, notifying 甄宓"
      relay_signal_all_done "$wid"
      return $?
    fi
    error "relay notify: no pending relay (action=${action})"
    return 1
  fi

  local next_assignee work_id current_step_id next_step_id step_name
  next_assignee=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_assignee',''))" 2>/dev/null || echo "")
  work_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id',''))" 2>/dev/null || echo "")
  current_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current_step_id',''))" 2>/dev/null || echo "")
  next_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_step_id',''))" 2>/dev/null || echo "")
  step_name=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_name',''))" 2>/dev/null || echo "")

  relay_notify_step "$next_assignee" "$work_id" "$next_step_id" "$current_step_id" "$step_name"
}

relay_auto_handler() {
  info "relay auto: check + notify in one step"

  local result
  result=$(relay_find_next)

  local action
  action=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''))" 2>/dev/null || echo "")

  case "$action" in
    notify)
      local next_assignee work_id current_step_id next_step_id step_name
      next_assignee=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_assignee',''))" 2>/dev/null || echo "")
      work_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id',''))" 2>/dev/null || echo "")
      current_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('current_step_id',''))" 2>/dev/null || echo "")
      next_step_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_step_id',''))" 2>/dev/null || echo "")
      step_name=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('next_name',''))" 2>/dev/null || echo "")

      info "relay auto: step #${current_step_id} → step #${next_step_id} (${next_assignee}: ${step_name})"
      relay_notify_step "$next_assignee" "$work_id" "$next_step_id" "$current_step_id" "$step_name"
      ;;
    all_done)
      local wid
      wid=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('work_id','unknown'))" 2>/dev/null || echo "unknown")
      info "relay auto: all steps done for work_id=${wid}"
      relay_signal_all_done "$wid"
      ;;
    none)
      info "relay auto: no relay needed"
      echo "$result"
      ;;
    error)
      local err
      err=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null || echo "")
      error "relay auto: error — ${err}"
      return 1
      ;;
    *)
      error "relay auto: unexpected action '${action}'"
      return 1
      ;;
  esac
}

# --- 8b. RELAY — CHECK SESSION STATUS (supplementary) ------------------------
relay_check_session() {
  local agent_id="$1"
  local previous_ended_at="${2:-}"

  if ! command -v openclaw &>/dev/null; then
    error "relay check-session: openclaw CLI not available"; return 1
  fi

  local session_info
  session_info=$(openclaw sessions --json 2>/dev/null | AGENT_ID="$agent_id" python3 -c "
import sys, json, os
agent = os.environ['AGENT_ID']
try:
    data = json.load(sys.stdin)
    sessions = data if isinstance(data, list) else [data]
    for s in sessions:
        if s.get('agentId') == agent:
            ended = s.get('endedAt') or ''
            status = s.get('status', 'unknown')
            print(json.dumps({'endedAt': ended, 'status': status}))
            sys.exit(0)
    print(json.dumps({'endedAt': '', 'status': 'unknown'}))
except Exception:
    print(json.dumps({'endedAt': '', 'status': 'error'}))
" 2>/dev/null || echo '{"endedAt":"","status":"error"}') || true

  local ended_at status
  ended_at=$(echo "$session_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('endedAt',''))" 2>/dev/null || echo "")
  status=$(echo "$session_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

  if [[ -n "$ended_at" ]]; then
    if [[ -z "$previous_ended_at" || "$ended_at" > "$previous_ended_at" ]]; then
      info "relay check-session: agent '${agent_id}' session ended at ${ended_at}"
      echo "SESSION_COMPLETED agent=${agent_id} ended_at=${ended_at}"
      return 0
    fi
  fi

  info "relay check-session: agent '${agent_id}' session running (status=${status})"
  echo "SESSION_RUNNING agent=${agent_id} status=${status}"
  return 1
}

# --- relay handler (entry from main) ---
relay_handler() {
  local subcmd="${1:-help}"

  case "$subcmd" in
    check)
      relay_check_handler "$@"
      ;;
    notify)
      shift
      relay_notify_handler "$@"
      ;;
    auto)
      relay_auto_handler
      ;;
    check-session)
      local agent_id="${2:-}"
      if [[ -z "$agent_id" ]]; then
        echo "Usage: $0 relay check-session <agentId> [previous_ended_at]"
        return 1
      fi
      relay_check_session "$agent_id" "${3:-}"
      ;;
    help|--help|-h)
      cat <<HELP
Relay Subcommands:
  check             Check status.json for completed step → determine next
  notify [role]     Notify next agent (auto-detect or specify role)
  auto              check + notify in one step
  check-session <agentId>  Check if agent's session has ended
  help              Show this help

Examples:
  coordinator.sh relay check
  coordinator.sh relay notify
  coordinator.sh relay notify "诸葛亮"
  coordinator.sh relay auto
  coordinator.sh relay check-session zhugeliang
HELP
      ;;
    *)
      error "Unknown relay subcommand: ${subcmd}"
      echo "Usage: $0 relay {check|notify|auto|check-session|help}"
      return 1
      ;;
  esac
}

# --- 9. UPLOAD — Git Push + GitHub Release (subcommands: prepare | push | release | auto) ---

upload_parse_args() {
  UPLOAD_WORK_ID=""
  UPLOAD_REPO=""
  UPLOAD_TAG=""
  UPLOAD_FILES=""
  UPLOAD_MSG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --work-id) UPLOAD_WORK_ID="$2"; shift 2 ;;
      --repo)    UPLOAD_REPO="$2"; shift 2 ;;
      --tag)     UPLOAD_TAG="$2"; shift 2 ;;
      --files)   UPLOAD_FILES="$2"; shift 2 ;;
      --msg)     UPLOAD_MSG="$2"; shift 2 ;;
      *)         break ;;
    esac
  done
}

upload_prepare() {
  info "upload prepare: preparing file manifest"
  local manifest_files=""

  if [[ -n "$UPLOAD_FILES" ]]; then
    manifest_files="$UPLOAD_FILES"
    info "upload prepare: using --files: ${manifest_files}"
  elif [[ -f "$STATUS_JSON_PATH" ]]; then
    info "upload prepare: reading manifest from status.json"
    manifest_files=$(python3 -c "
import sys, json
try:
    with open('${STATUS_JSON_PATH}') as f:
        data = json.load(f)
    manifest = data.get('upload', {}).get('files', [])
    if not manifest:
        manifest = data.get('current_task', {}).get('deliverables', [])
    print(','.join(manifest) if manifest else '')
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [[ -z "$manifest_files" ]]; then
      warn "upload prepare: no manifest in status.json, falling back to git diff"
      manifest_files=$(git diff --name-only 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi
  fi

  local untracked
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')
  if [[ -n "$untracked" ]]; then
    if [[ -n "$manifest_files" ]]; then
      manifest_files="${manifest_files},${untracked}"
    else
      manifest_files="$untracked"
    fi
  fi

  if [[ -z "$manifest_files" ]]; then
    warn "upload prepare: no files to upload"
  else
    info "upload prepare: manifest files: ${manifest_files}"
  fi

  UPLOAD_FILES="$manifest_files"
  echo "$manifest_files"
}

upload_push() {
  info "upload push: starting git add/commit/tag/push"

  local repo_dir
  repo_dir="$(cd "$(dirname "$0")" && pwd)"

  # git add
  git -C "$repo_dir" add -A 2>&1 | tee -a "$COORDINATOR_LOG"

  if git -C "$repo_dir" diff --cached --quiet; then
    info "upload push: no changes to commit"
  else
    local commit_msg="${UPLOAD_MSG:-auto: upload for ${UPLOAD_WORK_ID:-unknown}}"
    git -C "$repo_dir" commit -m "$commit_msg" 2>&1 | tee -a "$COORDINATOR_LOG"
    info "upload push: committed changes"
  fi

  local tag="${UPLOAD_TAG}"
  if [[ -z "$tag" && -n "$UPLOAD_WORK_ID" ]]; then
    tag="v$(date +%Y.%m.%d)-${UPLOAD_WORK_ID}"
  fi
  if [[ -z "$tag" ]]; then
    tag="v$(date +%Y.%m.%d)"
  fi

  if git -C "$repo_dir" tag -l | grep -q "^${tag}$"; then
    info "upload push: tag '${tag}' exists, force updating"
    git -C "$repo_dir" tag -f "$tag" 2>&1 | tee -a "$COORDINATOR_LOG"
  else
    git -C "$repo_dir" tag "$tag" 2>&1 | tee -a "$COORDINATOR_LOG"
    info "upload push: created tag '${tag}'"
  fi

  if git -C "$repo_dir" push origin "$COORDINATOR_GIT_BRANCH" --tags 2>&1 | tee -a "$COORDINATOR_LOG"; then
    info "upload push: git push successful (branch: ${COORDINATOR_GIT_BRANCH}, tag: ${tag})"
  else
    error "upload push: git push failed"
    return 1
  fi
}

upload_release() {
  info "upload release: processing GitHub Release"

  local token="${GITHUB_TOKEN:-}"
  if [[ -z "$token" ]]; then
    error "upload release: GITHUB_TOKEN not set (env var required)"
    return 1
  fi

  local repo="${UPLOAD_REPO}"
  if [[ -z "$repo" ]]; then
    repo=$(git remote get-url origin 2>/dev/null | sed -n 's|.*github.com[/:]\(.*\)\.git|\1|p')
    if [[ -z "$repo" ]]; then
      error "upload release: --repo required or git remote must point to GitHub"
      return 1
    fi
    info "upload release: auto-detected repo: ${repo}"
  fi

  local tag="${UPLOAD_TAG}"
  if [[ -z "$tag" ]]; then
    tag="v$(date +%Y.%m.%d)"
    info "upload release: auto-generated tag: ${tag}"
  fi

  local body
  body="Upload for ${UPLOAD_WORK_ID:-${tag}}"
  if [[ -n "$UPLOAD_FILES" ]]; then
    body="${body}\n\nFiles: ${UPLOAD_FILES}"
  fi

  info "upload release: checking existing release for tag '${tag}'"
  local existing_release_id
  existing_release_id=$(curl -s -H "Authorization: token ${token}" \
    "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

  local release_id="$existing_release_id"

  if [[ -n "$existing_release_id" ]]; then
    info "upload release: updating existing release #${existing_release_id}"
    local update_result
    update_result=$(curl -s -X PATCH "https://api.github.com/repos/${repo}/releases/${existing_release_id}" \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "
import json
d = {'tag_name': '${tag}', 'body': '${body}', 'draft': False, 'prerelease': False}
print(json.dumps(d))
")" 2>&1)

    local release_url
    release_url=$(echo "$update_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || echo "")
    info "upload release: updated release at ${release_url}"
  else
    info "upload release: creating new release for tag '${tag}'"
    local create_result
    create_result=$(curl -s -X POST "https://api.github.com/repos/${repo}/releases" \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      -d "$(python3 -c "
import json
d = {'tag_name': '${tag}', 'name': '${tag}', 'body': '${body}', 'draft': False, 'prerelease': False}
print(json.dumps(d))
")" 2>&1)

    local release_url
    release_url=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || echo "")
    if [[ -n "$release_url" ]]; then
      info "upload release: created release at ${release_url}"
      release_id=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    else
      local err_msg
      err_msg=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))" 2>/dev/null || echo "unknown")
      error "upload release: failed to create release — ${err_msg}"
      return 1
    fi
  fi

  if [[ -n "$UPLOAD_FILES" && -n "$release_id" ]]; then
    echo "$UPLOAD_FILES" | tr ',' '\n' | while IFS= read -r single_file; do
      single_file="$(echo "$single_file" | xargs)"
      if [[ -f "$single_file" ]]; then
        local filename asset_url
        filename=$(basename "$single_file")
        info "upload release: uploading asset '${filename}'"
        asset_url="https://uploads.github.com/repos/${repo}/releases/${release_id}/assets?name=${filename}"
        curl -s -X POST "$asset_url" \
          -H "Authorization: token ${token}" \
          -H "Content-Type: application/octet-stream" \
          --data-binary @"$single_file" \
          &>/dev/null \
        && info "upload release: uploaded asset '${filename}'" \
        || warn "upload release: failed to upload '${filename}'"
      else
        warn "upload release: asset file not found: ${single_file}"
      fi
    done
  fi

  info "upload release: completed"
}

upload_auto() {
  info "upload auto: prepare + push + release (one command)"
  upload_prepare
  upload_push
  upload_release
}

upload_handler() {
  local subcmd="${1:-help}"
  shift 2>/dev/null || true

  case "$subcmd" in
    prepare|push|release|auto)
      upload_parse_args "$@"
      ;;
  esac

  case "$subcmd" in
    prepare)
      upload_prepare
      ;;
    push)
      upload_push
      ;;
    release)
      upload_release
      ;;
    auto)
      upload_auto
      ;;
    help|--help|-h)
      cat <<HELP
Upload Subcommands:
  prepare            Prepare file manifest (from --files or status.json)
  push               Git add/commit/tag/push
  release            Create/update GitHub Release
  auto               prepare + push + release (one command)
  help               Show this help

Options:
  --work-id <id>     Work ID for commit message & release body
  --repo <owner/repo> GitHub repository (auto-detected from git remote)
  --tag <tag>        Git tag (auto-generated if omitted)
  --files <f1,f2>    Comma-separated file list (auto-detect if omitted)
  --msg <message>    Commit message (auto-generated if omitted)

Environment:
  GITHUB_TOKEN       GitHub personal access token (required for release)

Examples:
  coordinator.sh upload prepare --work-id TASK-123
  coordinator.sh upload push --tag v2026.05.29 --msg "upload module"
  coordinator.sh upload release --repo owner/repo --tag v2026.05.29
  coordinator.sh upload auto --work-id TASK-123 --repo owner/repo
HELP
      ;;
    *)
      error "Unknown upload subcommand: ${subcmd}"
      echo "Usage: $0 upload {prepare|push|release|auto|help}"
      return 1
      ;;
  esac
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
    relay)
      shift
      relay_handler "$@"
      ;;
    upload)
      shift
      upload_handler "$@"
      ;;
    init-cron)
      init_cron
      ;;
    help|--help|-h)
      cat <<USAGE
coordinator.sh — Automated Coordination Scheduler

Usage:
  $(basename "$0") {poll|watch|notify|reminder|validate|all|init-cron|relay|upload|help}

Subcommands:
  poll              Poll all agents & report status
  watch             Check status.json for changes (sha256 diff)
  notify [a] [s]    Test notification (agent, status)
  reminder <t> [m]  Schedule a reminder (time, message)
  validate          Validate status.json schema
  all               Run poll + watch
  init-cron         Print recommended crontab entries
  relay             Workflow auto-handoff — see "relay --help"
  upload            Git push + GitHub Release — see "upload --help"
  help              Show this help message

Relay Subcommands:
  check             Check status.json for completed step → determine next
  notify [role]     Notify next agent (auto-detect or specify role name)
  auto              check + notify in one step (automatic handoff)
  check-session <agentId>  Check if agent's session has ended via sessions API

Relay Notes:
  - Uses relay.conf for role → agentId mapping (native vs ACP type)
  - ACP agents (opencode) route through caocao for sessions_spawn
  - READ-ONLY on status.json — notifies 甄宓(main) to update

Upload Subcommands:
  prepare           Prepare file manifest (from --files or status.json)
  push              Git add/commit/tag/push
  release           Create/update GitHub Release
  auto              prepare + push + release (one command)

Upload Options:
  --work-id <id>    Work ID for commit message & release body
  --repo <owner/repo>  GitHub repository (auto-detected from git remote)
  --tag <tag>       Git tag (auto-generated if omitted)
  --files <f1,f2>   Comma-separated file list (auto-detect if omitted)
  --msg <message>   Commit message (auto-generated if omitted)

Upload Environment:
  GITHUB_TOKEN      GitHub personal access token (required for release)

Configuration:
  COORDINATOR_CONFIG    Config file path (default: ./coordinator.conf)
  COORDINATOR_LOG       Log file path (default: /var/log/coordinator.log)
  RELAY_CONF            Relay config path (default: ./relay.conf)

Examples:
  $(basename "$0") relay check
  $(basename "$0") relay notify
  $(basename "$0") relay auto
  $(basename "$0") relay check-session zhugeliang
  $(basename "$0") upload prepare --work-id TASK-123
  $(basename "$0") upload push --tag v2026.05.29
  $(basename "$0") upload release --repo owner/repo --tag v2026.05.29
  $(basename "$0") upload auto --work-id TASK-123 --repo owner/repo
USAGE
      ;;
    *)
      error "Unknown command: ${cmd}"
      echo "Usage: $(basename "$0") {poll|watch|notify|reminder|validate|all|init-cron|relay|upload|help}"
      exit 1
      ;;
  esac
}

main "$@"
