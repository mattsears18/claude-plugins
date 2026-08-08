#!/usr/bin/env bash
# do-work-supervisor.sh — keep a `/shipyard:do-work` burndown running across
# session deaths (issue #1083).
#
# WHY THIS EXISTS
#
# `/do-work` is specified as a terminating batch job but used as a continuous
# burndown loop. When a session ends the backlog simply stalls until a human
# types the command again. The tombstones say most sessions do not even reach
# the drain: a clean termination runs cleanup-summary.md's cleanup step, which
# RETIRES the session state file — so a session file that still exists is, by
# construction, a session that died before cleanup. Four of the five files
# found in ~/.shipyard/sessions/ when #1083 was filed had `in_flight > 0` at
# their last write.
#
# That reframes the fix. A session that runs out of context, hits a turn
# boundary, or crashes cannot be talked out of it by more "don't stop early"
# prose in the spec. The spec already assumes a next run exists — #662's
# bounded-exit concessions are "surfaced for the next run", setup step 3c
# triages orphan worktrees, and setup step 5.7 / #373 seeds inherited DIRTY
# PRs as an explicit cross-session hand-off. Restart-and-resume is already
# designed and built. The only missing piece was the thing that starts the
# next run.
#
# WHAT MAKES THIS SAFE
#
# A naive "if not running, restart" loop is an unattended token furnace. Five
# guards, all of which must pass before a launch:
#
#   1. Single instance      — atomic mkdir lock (macOS has no flock).
#   2. Liveness             — a session file for this repo whose mtime is
#                             within the liveness window means alive; skip.
#   3. Circuit breaker      — N consecutive unproductive sessions trips it and
#                             stops launching until `reset` is run by hand.
#   4. Daily budget         — a hard ceiling on launches per calendar day.
#   5. Work-exists gate     — never spend tokens to discover an empty backlog.
#
# Plus the instrumentation that motivated the whole thing: every observed
# session death is classified (abandoned / clean / failed-launch) and appended
# to a ledger, so "why do sessions die" becomes data rather than a guess. If
# deaths turn out to be predictable context exhaustion, restarting is exactly
# right; if it is a crash loop, restarting makes it worse — and the ledger is
# what tells the difference.
#
# USAGE
#
#   do-work-supervisor.sh tick      --repo owner/name [--workdir PATH] [--dry-run]
#   do-work-supervisor.sh status    --repo owner/name
#   do-work-supervisor.sh install   --repo owner/name --workdir PATH [--interval SECONDS]
#   do-work-supervisor.sh uninstall --repo owner/name
#   do-work-supervisor.sh reset     --repo owner/name
#   do-work-supervisor.sh reap      [--repo owner/name]
#
# `tick` is the launchd entry point; everything else is for humans.

set -u

# shellcheck source=lib/common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SCRIPT_NAME="do-work-supervisor.sh"

# --------------------------------------------------------------------------
# Tunables. All env-overridable so the launchd plist (and the test suite) can
# set them without editing this file.
# --------------------------------------------------------------------------

# A session file touched within this window means the session is alive. The
# orchestrator write-throughs on every state change, so the mtime is a live
# heartbeat. Generous by default: a worker doing a long implementation can go
# quiet for a while, and a false "dead" verdict launches a SECOND session
# against the same repo — the expensive mistake, so bias toward "alive".
LIVENESS_S="${SHIPYARD_SUPERVISOR_LIVENESS_S:-900}"

# How long a launch has to produce a session file before we call it a failed
# launch rather than a slow start.
STARTUP_GRACE_S="${SHIPYARD_SUPERVISOR_STARTUP_GRACE_S:-300}"

# A session is productive if it touched at least this many PRs (opened,
# fix-checks-touched, or adopted — `session_prs` counts all three).
#
# Deliberately NOT gated on duration. An earlier version excused a session
# with zero PRs if it had run long enough, on the theory that a long session
# must have been doing something. Real ledger data killed that idea: a
# 6-hour session with `session_prs: 0` is the WORST outcome the breaker
# exists to catch — maximum tokens, nothing shipped — and the duration guard
# classified it as productive. Zero PRs is zero PRs.
#
# The work-exists gate already guarantees we only launch when GitHub says
# there is work, so a session that shipped nothing anyway is a real signal:
# either the backlog is not actually workable or something is broken. Three
# of those in a row SHOULD stop the loop and ask for a human.
MIN_PRODUCTIVE_PRS="${SHIPYARD_SUPERVISOR_MIN_PRODUCTIVE_PRS:-1}"

# Consecutive unproductive sessions that trip the breaker.
BREAKER_THRESHOLD="${SHIPYARD_SUPERVISOR_BREAKER_THRESHOLD:-3}"

# Hard ceiling on launches per calendar day (UTC).
MAX_SESSIONS_PER_DAY="${SHIPYARD_SUPERVISOR_MAX_SESSIONS_PER_DAY:-12}"

# Permission mode for the headless session. `auto` matches the posture
# do-work-RATIONALE.md recommends (#763: Auto mode over full bypass).
# Deliberately NOT defaulted to bypassPermissions — an unattended loop is
# exactly the context where silently escalating permissions is worst.
PERMISSION_MODE="${SHIPYARD_SUPERVISOR_PERMISSION_MODE:-auto}"

CLAUDE_BIN="${SHIPYARD_SUPERVISOR_CLAUDE_BIN:-claude}"
GH_BIN="${SHIPYARD_SUPERVISOR_GH_BIN:-gh}"
# Injectable the same way, so a test never registers a real job in the
# developer's launchd domain (#1097 — install/uninstall previously called
# `launchctl` directly, and a fake $HOME only redirects the plist *file*,
# not launchd itself).
LAUNCHCTL_BIN="${SHIPYARD_SUPERVISOR_LAUNCHCTL_BIN:-launchctl}"
EXTRA_ARGS="${SHIPYARD_SUPERVISOR_EXTRA_ARGS:-}"

# Labels that make an open issue NOT dispatch-eligible, for the work-exists
# gate. Intentionally excludes `agent-console` — that label means "the agent
# does it, outside the build", not "hand it to a human". `blocked:agent` and
# `blocked:agent-hard` were dropped from the default (#1082) — both were
# eliminated by #521 (a refuse now carries `needs-human-review`, already in
# this list; a dependency-wait carries no label), have zero all-time usage,
# and nothing applies them anymore, so matching on them here was dead code.
GATE_LABELS="${SHIPYARD_SUPERVISOR_GATE_LABELS:-needs-human-review,blocked:ci}"

usage() {
  cat <<'EOF'
do-work-supervisor.sh — keep a /shipyard:do-work burndown running across
session deaths.

  tick      --repo owner/name [--workdir PATH] [--dry-run]
            Decide whether to launch a session. The launchd entry point.
  status    --repo owner/name
            Show breaker state, launch counts, and recent ledger events.
  install   --repo owner/name --workdir PATH [--interval SECONDS]
            Write and load the launchd agent (default interval: 600s).
  uninstall --repo owner/name
  reset     --repo owner/name
            Clear a tripped circuit breaker.
  reap      [--repo owner/name]
            Archive abandoned session files without launching anything.

Environment:
  SHIPYARD_SUPERVISOR_LIVENESS_S           alive if session mtime newer (900)
  SHIPYARD_SUPERVISOR_STARTUP_GRACE_S      launch->session-file window (300)
  SHIPYARD_SUPERVISOR_MIN_PRODUCTIVE_PRS   PRs for a session to count (1)
  SHIPYARD_SUPERVISOR_BREAKER_THRESHOLD    unproductive sessions to trip (3)
  SHIPYARD_SUPERVISOR_MAX_SESSIONS_PER_DAY daily launch ceiling (12)
  SHIPYARD_SUPERVISOR_PERMISSION_MODE      claude --permission-mode (auto)
  SHIPYARD_SUPERVISOR_CLAUDE_BIN           claude binary (claude)
  SHIPYARD_SUPERVISOR_GH_BIN               gh binary (gh)
  SHIPYARD_SUPERVISOR_LAUNCHCTL_BIN        launchctl binary (launchctl)
  SHIPYARD_SUPERVISOR_EXTRA_ARGS           extra args appended to claude
  SHIPYARD_SUPERVISOR_GATE_LABELS          labels that make an issue ineligible
  SHIPYARD_HOME                            state base dir ($HOME/.shipyard)
EOF
}

# Progress goes to stderr, never stdout. Several helpers return a VALUE on
# stdout via command substitution (launch_session returns a pid,
# reap_abandoned returns counts); logging to stdout would splice narration
# into those values and corrupt every downstream `jq --argjson`.
log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  echo "${SCRIPT_NAME}: $*" >&2
  exit 64
}

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

supervisor_dir() {
  printf '%s/supervisor\n' "$(shipyard_home)"
}

# owner/name -> owner-name, so it is safe as a filename component.
repo_slug() {
  printf '%s\n' "${1//\//-}"
}

state_path() {
  printf '%s/%s.state.json\n' "$(supervisor_dir)" "$(repo_slug "$1")"
}

ledger_path() {
  printf '%s/%s.ledger.jsonl\n' "$(supervisor_dir)" "$(repo_slug "$1")"
}

lock_path() {
  printf '%s/%s.lock\n' "$(supervisor_dir)" "$(repo_slug "$1")"
}

# Abandoned session files are ARCHIVED here, never deleted (#1084). The stale
# file is the only evidence that a session died rather than exiting cleanly —
# deleting it would destroy the very signal this supervisor is built on.
abandoned_dir() {
  printf '%s/abandoned\n' "$(sessions_dir)"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --------------------------------------------------------------------------
# Locking. macOS ships no flock(1), so use an atomic mkdir with PID-based
# stale detection — a supervisor killed mid-tick must not wedge the loop
# forever.
# --------------------------------------------------------------------------

LOCK_HELD=""

release_lock() {
  [[ -n "$LOCK_HELD" ]] && rm -rf "$LOCK_HELD"
  LOCK_HELD=""
}

acquire_lock() {
  local lock="$1"
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    LOCK_HELD="$lock"
    trap release_lock EXIT
    return 0
  fi
  # Held — but by a live process?
  local holder
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
    return 1
  fi
  # Stale lock from a killed tick. Take it over.
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    LOCK_HELD="$lock"
    trap release_lock EXIT
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

default_state() {
  local repo="$1" workdir="$2"
  jq -n --arg repo "$repo" --arg workdir "$workdir" '{
    repo: $repo,
    workdir: $workdir,
    consecutive_unproductive: 0,
    breaker: { tripped: false, tripped_at: null, reason: null },
    last_tick_at: null,
    last_launch_at: null,
    launches_today: { date: null, count: 0 },
    pending: null
  }'
}

read_state() {
  local repo="$1" workdir="${2:-}"
  local path
  path=$(state_path "$repo")
  if [[ -f "$path" ]] && jq -e . "$path" >/dev/null 2>&1; then
    cat "$path"
  else
    default_state "$repo" "$workdir"
  fi
}

write_state() {
  local repo="$1"
  atomic_write "$(state_path "$repo")" "$SCRIPT_NAME"
}

ledger_append() {
  local repo="$1" json="$2"
  local path
  path=$(ledger_path "$repo")
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$json" >> "$path"
}

# --------------------------------------------------------------------------
# Session inspection
# --------------------------------------------------------------------------

# Print one TSV row per session file belonging to $repo:
#   <path>\t<mtime_epoch>\t<started_at>\t<session_prs_count>\t<in_flight_count>
sessions_for_repo() {
  local repo="$1"
  local dir
  dir=$(sessions_dir)
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    local file_repo
    file_repo=$(jq -r '.repo // empty' "$f" 2>/dev/null || true)
    [[ "$file_repo" == "$repo" ]] || continue
    local mtime started prs inflight
    mtime=$(file_mtime "$f")
    started=$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)
    prs=$(jq -r '(.session_prs // []) | length' "$f" 2>/dev/null || echo 0)
    inflight=$(jq -r '(.in_flight // {}) | length' "$f" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$mtime" "$started" "$prs" "$inflight"
  done
}

# Portable stat(1) mtime in epoch seconds. BSD (macOS) and GNU disagree on
# the flag, and the probe order is load-bearing:
#
#   GNU  `stat -c %Y <file>`  -> mtime.       BSD has no -c, errors cleanly.
#   BSD  `stat -f %m <file>`  -> mtime.       GNU's -f means --file-system,
#                                             so it reads `%m` as a FILE
#                                             ARGUMENT and prints multi-line
#                                             filesystem info -- with exit 0.
#
# That last part is why BSD-first is wrong: on Linux the BSD probe SUCCEEDS
# with garbage instead of failing over, and the garbage ("  File: ...")
# reaches `(( now - mtime ))`, where bash resolves the bare word as a
# variable name and `set -u` aborts the whole tick.
#
# The numeric guard makes the result trustworthy regardless of which probe
# answered, or of any future platform quirk: anything that is not a run of
# digits degrades to 0, i.e. "epoch zero, therefore very old". A session
# whose mtime cannot be read is treated as dead rather than silently
# wedging the supervisor.
file_mtime() {
  local f="$1" m
  m=$(stat -c %Y "$f" 2>/dev/null) || m=$(stat -f %m "$f" 2>/dev/null) || m=""
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s\n' "$m"
}

# Is any session for this repo currently alive? Echoes the live session path.
live_session() {
  local repo="$1" now="$2"
  local path mtime
  while IFS=$'\t' read -r path mtime _ _ _; do
    [[ -n "$path" ]] || continue
    if (( now - mtime < LIVENESS_S )); then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(sessions_for_repo "$repo")
  return 1
}

# Archive every stale (abandoned) session file for $repo, appending a
# classified ledger entry for each. Echoes the number archived.
#
# Returns the count of abandoned sessions that were UNPRODUCTIVE, so the
# caller can advance the breaker counter.
reap_abandoned() {
  local repo="$1" now="$2"
  local archived=0 unproductive=0
  local path mtime started prs inflight
  while IFS=$'\t' read -r path mtime started prs inflight; do
    [[ -n "$path" ]] || continue
    (( now - mtime < LIVENESS_S )) && continue

    local started_epoch duration
    started_epoch=$(iso_to_epoch "$started")
    if (( started_epoch > 0 )); then
      duration=$(( mtime - started_epoch ))
    else
      duration=-1
    fi

    # Duration is recorded for forensics but is NOT part of the verdict —
    # see MIN_PRODUCTIVE_PRS above for why.
    local productive="true"
    if (( prs < MIN_PRODUCTIVE_PRS )); then
      productive="false"
      unproductive=$(( unproductive + 1 ))
    fi

    ledger_append "$repo" "$(jq -n -c \
      --arg at "$(now_iso)" \
      --arg repo "$repo" \
      --arg session "$(basename "$path")" \
      --arg started "$started" \
      --argjson duration "$duration" \
      --argjson prs "$prs" \
      --argjson in_flight "$inflight" \
      --argjson productive "$productive" \
      '{
         at: $at, repo: $repo, event: "session-death",
         classification: "abandoned",
         session: $session, started_at: $started,
         duration_s: $duration, session_prs: $prs,
         in_flight_at_death: $in_flight,
         productive: $productive,
         note: "session file outlived the liveness window — cleanup never ran"
       }')"

    mkdir -p "$(abandoned_dir)"
    mv -f "$path" "$(abandoned_dir)/$(basename "$path")" 2>/dev/null || true
    archived=$(( archived + 1 ))
  done < <(sessions_for_repo "$repo")

  printf '%s %s\n' "$archived" "$unproductive"
}

# --------------------------------------------------------------------------
# Work-exists gate
# --------------------------------------------------------------------------

# Echo the count of dispatchable units of work (eligible open issues + open
# PRs authored by the current user that still need driving to merged).
#
# Deliberately cheap — two `gh` calls. The whole point is to avoid paying for
# a session start just to discover an empty backlog.
count_work() {
  local repo="$1"
  local issues prs gate_json
  gate_json=$(printf '%s' "$GATE_LABELS" | jq -R -c 'split(",")')

  issues=$("$GH_BIN" issue list --repo "$repo" --state open --limit 200 \
    --json number,labels 2>/dev/null \
    | jq --argjson gates "$gate_json" \
        '[.[] | select((.labels // []) | map(.name) | any(. as $l | $gates | index($l)) | not)] | length' \
        2>/dev/null || echo "")

  prs=$("$GH_BIN" pr list --repo "$repo" --state open --author "@me" --limit 200 \
    --json number 2>/dev/null | jq 'length' 2>/dev/null || echo "")

  # A `gh` failure (network, auth, rate limit) must NOT read as "no work" —
  # that would silently park the loop. Report -1 so the caller can skip this
  # tick without touching the breaker.
  if [[ -z "$issues" || -z "$prs" ]]; then
    printf '%s\n' "-1"
    return
  fi
  printf '%s\n' "$(( issues + prs ))"
}

# --------------------------------------------------------------------------
# Launch
# --------------------------------------------------------------------------

launch_session() {
  local repo="$1" workdir="$2" dry_run="$3"
  local ts log_file prompt
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  log_file="$(supervisor_dir)/logs/$(repo_slug "$repo")-${ts}.log"
  mkdir -p "$(dirname "$log_file")"
  prompt="/shipyard:do-work --repo ${repo}"

  if [[ "$dry_run" == "1" ]]; then
    log "DRY RUN — would launch: $CLAUDE_BIN -p '$prompt' --permission-mode $PERMISSION_MODE (cwd=$workdir, log=$log_file)"
    printf '%s\n' "0"
    return 0
  fi

  # nohup + background so the session outlives this tick. The launchd plist
  # sets AbandonProcessGroup so launchd does not reap the child when the tick
  # job exits — without it the session dies seconds after it starts.
  local pid
  # shellcheck disable=SC2086
  # rationale: EXTRA_ARGS is a user-supplied argument STRING and must word-split.
  (
    cd "$workdir" || exit 1
    exec nohup "$CLAUDE_BIN" -p "$prompt" \
      --permission-mode "$PERMISSION_MODE" \
      $EXTRA_ARGS
  ) >"$log_file" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true

  log "launched session pid=$pid log=$log_file"
  printf '%s\n' "$pid"
}

# --------------------------------------------------------------------------
# tick — the launchd entry point
# --------------------------------------------------------------------------

cmd_tick() {
  local repo="" workdir="" dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --workdir) workdir="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) die "tick: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$repo" ]] || die "tick: --repo owner/name is required"

  require_jq "$SCRIPT_NAME"
  mkdir -p "$(supervisor_dir)"

  if ! acquire_lock "$(lock_path "$repo")"; then
    log "another tick holds the lock — skipping"
    return 0
  fi

  local state now
  state=$(read_state "$repo" "$workdir")
  now=$(date -u +%s)
  [[ -n "$workdir" ]] || workdir=$(printf '%s' "$state" | jq -r '.workdir // empty')

  state=$(printf '%s' "$state" | jq --arg at "$(now_iso)" '.last_tick_at = $at')

  # --- 1. Classify and archive anything that died since the last tick. -----
  local reaped archived unproductive
  reaped=$(reap_abandoned "$repo" "$now")
  archived=$(printf '%s' "$reaped" | cut -d' ' -f1)
  unproductive=$(printf '%s' "$reaped" | cut -d' ' -f2)
  if (( archived > 0 )); then
    log "archived $archived abandoned session file(s); $unproductive unproductive"
    local i=0
    while (( i < unproductive )); do
      state=$(printf '%s' "$state" | jq '.consecutive_unproductive += 1')
      i=$(( i + 1 ))
    done
    if (( archived > unproductive )); then
      # At least one abandoned session did real work — that is not the
      # runaway shape the breaker exists to catch, so clear the streak.
      state=$(printf '%s' "$state" | jq '.consecutive_unproductive = 0')
    fi
  fi

  # --- 2. Resolve a pending launch (clean exit leaves no file to find). ----
  local pending_launched
  pending_launched=$(printf '%s' "$state" | jq -r '.pending.launched_at // empty')
  if [[ -n "$pending_launched" ]]; then
    local pending_epoch pending_pid seen
    pending_epoch=$(iso_to_epoch "$pending_launched")
    pending_pid=$(printf '%s' "$state" | jq -r '.pending.pid // 0')
    seen=$(printf '%s' "$state" | jq -r '.pending.session_seen // false')

    if live_session "$repo" "$now" >/dev/null; then
      state=$(printf '%s' "$state" | jq '.pending.session_seen = true')
    elif [[ "$seen" == "true" ]]; then
      # We watched a session file appear and it is now gone entirely — the
      # cleanup step ran, which only happens on a clean termination.
      ledger_append "$repo" "$(jq -n -c --arg at "$(now_iso)" --arg repo "$repo" \
        '{at:$at, repo:$repo, event:"session-death", classification:"clean",
          productive:true, note:"session file retired by cleanup — clean termination"}')"
      log "previous session terminated cleanly"
      state=$(printf '%s' "$state" | jq '.consecutive_unproductive = 0 | .pending = null')
    elif (( now - pending_epoch > STARTUP_GRACE_S )) \
         && ! kill -0 "$pending_pid" 2>/dev/null; then
      # Launched, never produced a session file, and the process is gone.
      ledger_append "$repo" "$(jq -n -c --arg at "$(now_iso)" --arg repo "$repo" \
        --argjson pid "${pending_pid:-0}" \
        '{at:$at, repo:$repo, event:"session-death", classification:"failed-launch",
          pid:$pid, productive:false,
          note:"no session file appeared within the startup grace window"}')"
      log "previous launch never started a session — counting as unproductive"
      state=$(printf '%s' "$state" | jq '.consecutive_unproductive += 1 | .pending = null')
    fi
  fi

  # --- 3. Circuit breaker. ------------------------------------------------
  local streak tripped
  streak=$(printf '%s' "$state" | jq -r '.consecutive_unproductive')
  tripped=$(printf '%s' "$state" | jq -r '.breaker.tripped')
  if [[ "$tripped" != "true" ]] && (( streak >= BREAKER_THRESHOLD )); then
    state=$(printf '%s' "$state" | jq --arg at "$(now_iso)" --argjson n "$streak" \
      '.breaker = { tripped: true, tripped_at: $at,
                    reason: ("\($n) consecutive unproductive sessions") }')
    ledger_append "$repo" "$(jq -n -c --arg at "$(now_iso)" --arg repo "$repo" \
      --argjson n "$streak" \
      '{at:$at, repo:$repo, event:"breaker-tripped", consecutive_unproductive:$n}')"
    log "CIRCUIT BREAKER TRIPPED after $streak unproductive sessions — no further launches until 'reset'"
    tripped="true"
  fi
  if [[ "$tripped" == "true" ]]; then
    printf '%s' "$state" | write_state "$repo"
    log "breaker tripped — skipping launch (run: $SCRIPT_NAME reset --repo $repo)"
    return 0
  fi

  # --- 4. Already running? ------------------------------------------------
  local alive
  if alive=$(live_session "$repo" "$now"); then
    log "session alive ($(basename "$alive")) — nothing to do"
    printf '%s' "$state" | write_state "$repo"
    return 0
  fi

  # --- 5. Daily budget. ---------------------------------------------------
  local today count_today
  today=$(date -u +%Y-%m-%d)
  count_today=$(printf '%s' "$state" | jq -r --arg d "$today" \
    'if .launches_today.date == $d then .launches_today.count else 0 end')
  if (( count_today >= MAX_SESSIONS_PER_DAY )); then
    log "daily budget reached ($count_today/$MAX_SESSIONS_PER_DAY) — skipping launch"
    printf '%s' "$state" | write_state "$repo"
    return 0
  fi

  # --- 6. Work-exists gate. -----------------------------------------------
  local work
  work=$(count_work "$repo")
  if [[ "$work" == "-1" ]]; then
    log "could not reach GitHub — skipping this tick without penalty"
    printf '%s' "$state" | write_state "$repo"
    return 0
  fi
  if (( work == 0 )); then
    log "no eligible issues and no open PRs — backlog is drained, skipping launch"
    printf '%s' "$state" | write_state "$repo"
    return 0
  fi

  # --- 7. Launch. ---------------------------------------------------------
  [[ -n "$workdir" ]] || die "tick: --workdir PATH is required for the first launch"
  [[ -d "$workdir" ]] || die "tick: workdir '$workdir' does not exist"

  log "$work unit(s) of work and no live session — launching"
  local pid
  pid=$(launch_session "$repo" "$workdir" "$dry_run")

  if [[ "$dry_run" != "1" ]]; then
    state=$(printf '%s' "$state" | jq \
      --arg at "$(now_iso)" --arg d "$today" --arg wd "$workdir" \
      --argjson pid "${pid:-0}" --argjson work "$work" \
      '.last_launch_at = $at
       | .workdir = $wd
       | .launches_today = (if .launches_today.date == $d
                            then { date: $d, count: (.launches_today.count + 1) }
                            else { date: $d, count: 1 } end)
       | .pending = { launched_at: $at, pid: $pid, session_seen: false, work_at_launch: $work }')
    ledger_append "$repo" "$(jq -n -c --arg at "$(now_iso)" --arg repo "$repo" \
      --argjson pid "${pid:-0}" --argjson work "$work" \
      '{at:$at, repo:$repo, event:"launch", pid:$pid, work_at_launch:$work}')"
  fi

  printf '%s' "$state" | write_state "$repo"
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

cmd_status() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "status: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$repo" ]] || die "status: --repo owner/name is required"
  require_jq "$SCRIPT_NAME"

  local path
  path=$(state_path "$repo")
  if [[ ! -f "$path" ]]; then
    echo "No supervisor state for $repo (never ticked)."
    return 0
  fi

  local now
  now=$(date -u +%s)
  echo "Supervisor — $repo"
  jq -r '"  workdir:        \(.workdir // "—")
  last tick:      \(.last_tick_at // "never")
  last launch:    \(.last_launch_at // "never")
  launches today: \(.launches_today.count // 0) (\(.launches_today.date // "—"))
  unproductive:   \(.consecutive_unproductive)
  breaker:        \(if .breaker.tripped then "TRIPPED — \(.breaker.reason)" else "ok" end)"' "$path"

  local alive
  if alive=$(live_session "$repo" "$now"); then
    echo "  live session:   $(basename "$alive")"
  else
    echo "  live session:   none"
  fi

  local ledger
  ledger=$(ledger_path "$repo")
  if [[ -f "$ledger" ]]; then
    echo ""
    echo "Recent events:"
    tail -n 10 "$ledger" | jq -r '"  \(.at)  \(.event)\(if .classification then " (\(.classification))" else "" end)"'
  fi
}

# --------------------------------------------------------------------------
# reset
# --------------------------------------------------------------------------

cmd_reset() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "reset: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$repo" ]] || die "reset: --repo owner/name is required"
  require_jq "$SCRIPT_NAME"

  local path
  path=$(state_path "$repo")
  [[ -f "$path" ]] || { echo "No supervisor state for $repo."; return 0; }

  jq '.breaker = { tripped: false, tripped_at: null, reason: null }
      | .consecutive_unproductive = 0' "$path" | write_state "$repo"
  ledger_append "$repo" "$(jq -n -c --arg at "$(now_iso)" --arg repo "$repo" \
    '{at:$at, repo:$repo, event:"breaker-reset"}')"
  echo "Breaker reset for $repo."
}

# --------------------------------------------------------------------------
# reap — archive abandoned session files without launching anything (#1084)
# --------------------------------------------------------------------------

cmd_reap() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "reap: unknown arg '$1'" ;;
    esac
  done
  require_jq "$SCRIPT_NAME"

  local now repos
  now=$(date -u +%s)
  if [[ -n "$repo" ]]; then
    repos="$repo"
  else
    repos=$(sessions_dir_repos)
  fi
  [[ -n "$repos" ]] || { echo "No session files found."; return 0; }

  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    local out
    out=$(reap_abandoned "$r" "$now")
    echo "$r: archived $(printf '%s' "$out" | cut -d' ' -f1) abandoned session file(s)"
  done <<< "$repos"
}

# Distinct `.repo` values across every session file.
sessions_dir_repos() {
  local dir
  dir=$(sessions_dir)
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*.json; do
    [[ -e "$f" ]] || continue
    jq -r '.repo // empty' "$f" 2>/dev/null || true
  done | sort -u
}

# --------------------------------------------------------------------------
# install / uninstall — launchd
# --------------------------------------------------------------------------

plist_label() {
  printf 'com.shipyard.do-work-supervisor.%s\n' "$(repo_slug "$1")"
}

plist_file() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(plist_label "$1")"
}

cmd_install() {
  local repo="" workdir="" interval=600
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --workdir) workdir="${2:-}"; shift 2 ;;
      --interval) interval="${2:-}"; shift 2 ;;
      *) die "install: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$repo" ]] || die "install: --repo owner/name is required"
  [[ -n "$workdir" ]] || die "install: --workdir PATH is required"
  [[ -d "$workdir" ]] || die "install: workdir '$workdir' does not exist"

  local script_abs label plist
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  label=$(plist_label "$repo")
  plist=$(plist_file "$repo")
  mkdir -p "$(dirname "$plist")"

  # AbandonProcessGroup is load-bearing: without it launchd reaps the whole
  # process group when the tick exits, killing the `claude` session seconds
  # after it launches.
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_abs}</string>
        <string>tick</string>
        <string>--repo</string>
        <string>${repo}</string>
        <string>--workdir</string>
        <string>${workdir}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${PATH}</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$(supervisor_dir)/launchd-$(repo_slug "$repo").out.log</string>
    <key>StandardErrorPath</key>
    <string>$(supervisor_dir)/launchd-$(repo_slug "$repo").err.log</string>
</dict>
</plist>
PLIST

  mkdir -p "$(supervisor_dir)"
  "$LAUNCHCTL_BIN" unload "$plist" 2>/dev/null || true
  if "$LAUNCHCTL_BIN" load "$plist" 2>/dev/null; then
    echo "Installed and loaded $label (every ${interval}s)."
  else
    echo "Wrote $plist but 'launchctl load' failed — load it by hand." >&2
  fi
  echo "  plist:   $plist"
  echo "  status:  $SCRIPT_NAME status --repo $repo"
  echo "  stop:    $SCRIPT_NAME uninstall --repo $repo"
}

cmd_uninstall() {
  local repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) die "uninstall: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$repo" ]] || die "uninstall: --repo owner/name is required"

  local plist
  plist=$(plist_file "$repo")
  "$LAUNCHCTL_BIN" unload "$plist" 2>/dev/null || true
  rm -f "$plist"
  echo "Uninstalled $(plist_label "$repo")."
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    tick) cmd_tick "$@" ;;
    status) cmd_status "$@" ;;
    reset) cmd_reset "$@" ;;
    reap) cmd_reap "$@" ;;
    install) cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    -h | --help | help | "") usage ;;
    *) die "unknown subcommand '$sub' (try --help)" ;;
  esac
}

main "$@"
