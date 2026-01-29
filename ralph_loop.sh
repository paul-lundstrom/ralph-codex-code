#!/bin/bash

# Codex Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Codex with usage management

set -e  # Exit on any error

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/timeout_utils.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
SLEEP_DURATION=3600     # 1 hour in seconds
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-}"
_env_CODEX_OUTPUT_FORMAT="${CODEX_OUTPUT_FORMAT:-}"
_env_CODEX_ALLOWED_TOOLS="${CODEX_ALLOWED_TOOLS:-}"
_env_CODEX_USE_CONTINUE="${CODEX_USE_CONTINUE:-}"
_env_CODEX_SESSION_EXPIRY_HOURS="${CODEX_SESSION_EXPIRY_HOURS:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_SUBAGENTS_ENABLED="${SUBAGENTS_ENABLED:-}"
_env_SUBAGENT_MAX_PARALLEL="${SUBAGENT_MAX_PARALLEL:-}"
_env_SUBAGENT_TIMEOUT_MINUTES="${SUBAGENT_TIMEOUT_MINUTES:-}"
_env_SUBAGENT_LOOP_INTERVAL="${SUBAGENT_LOOP_INTERVAL:-}"
_env_SUBAGENT_PROMPT_DIR="${SUBAGENT_PROMPT_DIR:-}"
_env_SUBAGENT_PROMPT_GLOB="${SUBAGENT_PROMPT_GLOB:-}"
_env_SUBAGENT_APPEND_TO_PROMPT="${SUBAGENT_APPEND_TO_PROMPT:-}"
_env_SUBAGENT_MAX_OUTPUT_CHARS="${SUBAGENT_MAX_OUTPUT_CHARS:-}"
_env_SUBAGENT_SANDBOX="${SUBAGENT_SANDBOX:-}"
_env_SUBAGENT_FULL_AUTO="${SUBAGENT_FULL_AUTO:-}"

# Now set defaults (only if not already set by environment)
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
# Codex execution timeout (minutes).
CODEX_TIMEOUT_MINUTES="${CODEX_TIMEOUT_MINUTES:-120}"

# Modern Codex CLI configuration (Phase 1.1)
CODEX_OUTPUT_FORMAT="${CODEX_OUTPUT_FORMAT:-json}"
CODEX_ALLOWED_TOOLS="${CODEX_ALLOWED_TOOLS:-Write,Bash(git *),Read}"
CODEX_USE_CONTINUE="${CODEX_USE_CONTINUE:-true}"
CODEX_SESSION_FILE="$RALPH_DIR/.codex_session_id" # Session ID persistence file
CODEX_MIN_VERSION="2.0.76"              # Minimum required Codex CLI version

# Session management configuration (Phase 1.2)
# Note: SESSION_EXPIRATION_SECONDS is defined in lib/response_analyzer.sh (86400 = 24 hours)
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CODEX_SESSION_EXPIRY_HOURS=${CODEX_SESSION_EXPIRY_HOURS:-24}

# Codex execution defaults
CODEX_FULL_AUTO="${CODEX_FULL_AUTO:-true}"
CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"

# Prompt enhancement (one-time, pre-loop)
ENHANCE_PROMPT="${ENHANCE_PROMPT:-false}"
ENHANCE_PROMPT_MODEL="${ENHANCE_PROMPT_MODEL:-gpt-5.2}"
ENHANCE_PROMPT_REASONING="${ENHANCE_PROMPT_REASONING:-xhigh}"

# Subagent configuration (parallel helpers)
SUBAGENTS_ENABLED="${SUBAGENTS_ENABLED:-auto}"          # true|false|auto
SUBAGENT_PROMPT_DIR="${SUBAGENT_PROMPT_DIR:-$RALPH_DIR/subagents}"
SUBAGENT_PROMPT_GLOB="${SUBAGENT_PROMPT_GLOB:-*.subagent.md}"
SUBAGENT_MAX_PARALLEL="${SUBAGENT_MAX_PARALLEL:-3}"
SUBAGENT_TIMEOUT_MINUTES="${SUBAGENT_TIMEOUT_MINUTES:-10}"
SUBAGENT_LOOP_INTERVAL="${SUBAGENT_LOOP_INTERVAL:-1}"
SUBAGENT_APPEND_TO_PROMPT="${SUBAGENT_APPEND_TO_PROMPT:-true}"
SUBAGENT_MAX_OUTPUT_CHARS="${SUBAGENT_MAX_OUTPUT_CHARS:-2000}"
SUBAGENT_SANDBOX="${SUBAGENT_SANDBOX:-$CODEX_SANDBOX}"
SUBAGENT_FULL_AUTO="${SUBAGENT_FULL_AUTO:-$CODEX_FULL_AUTO}"
SUBAGENT_STATUS_FILE="$RALPH_DIR/subagents_status.json"
SUBAGENT_SUMMARY_FILE="$RALPH_DIR/subagent_summary.md"
SUBAGENT_STATE_DIR="$RALPH_DIR/.subagent_state"

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "NotebookEdit"
)

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# .ralphrc configuration file
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - CODEX_TIMEOUT_MINUTES
#   - CODEX_OUTPUT_FORMAT
#   - ALLOWED_TOOLS (mapped to CODEX_ALLOWED_TOOLS)
#   - SESSION_CONTINUITY (mapped to CODEX_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CODEX_SESSION_EXPIRY_HOURS)
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
        CODEX_ALLOWED_TOOLS="$ALLOWED_TOOLS"
    fi
    if [[ -n "${SESSION_CONTINUITY:-}" ]]; then
        CODEX_USE_CONTINUE="$SESSION_CONTINUITY"
    fi
    if [[ -n "${SESSION_EXPIRY_HOURS:-}" ]]; then
        CODEX_SESSION_EXPIRY_HOURS="$SESSION_EXPIRY_HOURS"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore ONLY values that were explicitly set via environment variables
    # (not script defaults). The _env_* variables were captured BEFORE defaults were set.
    # If _env_* is non-empty, the user explicitly set it in their environment.
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CODEX_TIMEOUT_MINUTES" ]] && CODEX_TIMEOUT_MINUTES="$_env_CODEX_TIMEOUT_MINUTES"
    [[ -n "$_env_CODEX_OUTPUT_FORMAT" ]] && CODEX_OUTPUT_FORMAT="$_env_CODEX_OUTPUT_FORMAT"
    [[ -n "$_env_CODEX_ALLOWED_TOOLS" ]] && CODEX_ALLOWED_TOOLS="$_env_CODEX_ALLOWED_TOOLS"
    [[ -n "$_env_CODEX_USE_CONTINUE" ]] && CODEX_USE_CONTINUE="$_env_CODEX_USE_CONTINUE"
    [[ -n "$_env_CODEX_SESSION_EXPIRY_HOURS" ]] && CODEX_SESSION_EXPIRY_HOURS="$_env_CODEX_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_SUBAGENTS_ENABLED" ]] && SUBAGENTS_ENABLED="$_env_SUBAGENTS_ENABLED"
    [[ -n "$_env_SUBAGENT_MAX_PARALLEL" ]] && SUBAGENT_MAX_PARALLEL="$_env_SUBAGENT_MAX_PARALLEL"
    [[ -n "$_env_SUBAGENT_TIMEOUT_MINUTES" ]] && SUBAGENT_TIMEOUT_MINUTES="$_env_SUBAGENT_TIMEOUT_MINUTES"
    [[ -n "$_env_SUBAGENT_LOOP_INTERVAL" ]] && SUBAGENT_LOOP_INTERVAL="$_env_SUBAGENT_LOOP_INTERVAL"
    [[ -n "$_env_SUBAGENT_PROMPT_DIR" ]] && SUBAGENT_PROMPT_DIR="$_env_SUBAGENT_PROMPT_DIR"
    [[ -n "$_env_SUBAGENT_PROMPT_GLOB" ]] && SUBAGENT_PROMPT_GLOB="$_env_SUBAGENT_PROMPT_GLOB"
    [[ -n "$_env_SUBAGENT_APPEND_TO_PROMPT" ]] && SUBAGENT_APPEND_TO_PROMPT="$_env_SUBAGENT_APPEND_TO_PROMPT"
    [[ -n "$_env_SUBAGENT_MAX_OUTPUT_CHARS" ]] && SUBAGENT_MAX_OUTPUT_CHARS="$_env_SUBAGENT_MAX_OUTPUT_CHARS"
    [[ -n "$_env_SUBAGENT_SANDBOX" ]] && SUBAGENT_SANDBOX="$_env_SUBAGENT_SANDBOX"
    [[ -n "$_env_SUBAGENT_FULL_AUTO" ]] && SUBAGENT_FULL_AUTO="$_env_SUBAGENT_FULL_AUTO"

    RALPHRC_LOADED=true
    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    
    log_status "INFO" "Setting up tmux session: $session_name"
    
    # Create new tmux session detached
    tmux new-session -d -s "$session_name" -c "$(pwd)"
    
    # Split window vertically to create monitor pane on the right
    tmux split-window -h -t "$session_name" -c "$(pwd)"
    
    # Start monitor in the right pane
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:0.1" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:0.1" "'$ralph_home/ralph_monitor.sh'" Enter
    fi
    
    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi
    
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    if [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    if [[ -n "$CODEX_TIMEOUT_MINUTES" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CODEX_TIMEOUT_MINUTES"
    fi
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    if [[ "$ENHANCE_PROMPT" == "true" ]]; then
        ralph_cmd="$ralph_cmd --enhance-prompt"
    fi
    
    tmux send-keys -t "$session_name:0.0" "$ralph_cmd" Enter
    
    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:0.0"
    
    # Set window title
    tmux rename-window -t "$session_name:0" "Ralph: Loop | Monitor"
    
    log_status "SUCCESS" "Tmux session created. Attaching to session..."
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"
    
    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"
    
    exit 0
}

# Initialize call tracking
init_call_tracking() {
    log_status "INFO" "DEBUG: Entered init_call_tracking..."
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

    log_status "INFO" "DEBUG: Completed init_call_tracking successfully"
}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

log_verbose() {
    local message=$1
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "$message"
    fi
}

# Enhance the project prompt once before entering the loop
enhance_prompt() {
    local prompt_file=$1
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Enhance prompt requested but file not found: $prompt_file"
        return 1
    fi

    log_status "INFO" "Enhancing prompt with ${ENHANCE_PROMPT_MODEL} (reasoning: ${ENHANCE_PROMPT_REASONING})"

    local tmp_prompt
    tmp_prompt=$(mktemp)
    cat > "$tmp_prompt" << 'PROMPTEOF'
You are refining a Ralph project prompt. Improve clarity, structure, and priority without changing intent.
- Preserve all constraints, file paths, and tool limits.
- Keep every instruction that is safety/behavior critical.
- Keep the RALPH_STATUS block and its examples unchanged in meaning.
- Do not add new requirements or remove existing ones.
- Output ONLY the full revised prompt text. No commentary, no code fences.
---
PROMPTEOF
    cat "$prompt_file" >> "$tmp_prompt"

    local output_file="$LOG_DIR/prompt_enhanced_${timestamp}.md"
    local events_file="$LOG_DIR/prompt_enhance_events_${timestamp}.log"

    local -a cmd=("codex" "exec" "--skip-git-repo-check" "--output-last-message" "$output_file" "-m" "$ENHANCE_PROMPT_MODEL" "-c" "model_reasoning_effort=\"${ENHANCE_PROMPT_REASONING}\"" "-")

    set +e
    "${cmd[@]}" < "$tmp_prompt" > "$events_file" 2>&1
    local exit_code=$?
    set -e

    rm -f "$tmp_prompt"

    if [[ $exit_code -ne 0 ]]; then
        log_status "WARN" "Prompt enhancement failed (exit $exit_code). See: $events_file"
        return 1
    fi
    if [[ ! -s "$output_file" ]]; then
        log_status "WARN" "Prompt enhancement produced empty output. See: $events_file"
        return 1
    fi

    local original_has_status="false"
    if grep -q -- '---RALPH_STATUS---' "$prompt_file"; then
        original_has_status="true"
    fi
    if [[ "$original_has_status" == "true" ]] && ! grep -q -- '---RALPH_STATUS---' "$output_file"; then
        log_status "WARN" "Enhanced prompt missing RALPH_STATUS block; keeping original. See: $output_file"
        return 1
    fi

    local backup_file="${prompt_file}.pre-enhance.${timestamp}"
    if ! cp "$prompt_file" "$backup_file" 2>/dev/null; then
        log_status "WARN" "Unable to create prompt backup at $backup_file"
    fi

    if ! cat "$output_file" > "$prompt_file"; then
        log_status "ERROR" "Failed to write enhanced prompt to $prompt_file; keeping original."
        return 1
    fi

    log_status "SUCCESS" "Prompt enhanced and saved to $prompt_file"
    if [[ -f "$backup_file" ]]; then
        log_status "INFO" "Backup saved: $backup_file"
    fi

    return 0
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
can_make_call() {
    local calls_made
    calls_made=$(get_calls_made)
    
    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Get current call count
get_calls_made() {
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        cat "$CALL_COUNT_FILE"
    else
        echo "0"
    fi
}

# Increment call counter by delta (default 1)
increment_call_counter() {
    increment_call_counter_by 1
}

increment_call_counter_by() {
    local delta="${1:-1}"
    local calls_made
    calls_made=$(get_calls_made)

    calls_made=$((calls_made + delta))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    log_status "INFO" "DEBUG: Checking exit conditions..." >&2
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        log_status "INFO" "DEBUG: No exit signals file found, continuing..." >&2
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    log_status "INFO" "DEBUG: Exit signals content: $signals" >&2
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")
    
    log_status "INFO" "DEBUG: Exit counts - test_loops:$recent_test_loops, done_signals:$recent_done_signals, completion:$recent_completion_indicators" >&2
    
    # Check for exit conditions
    
    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Safety circuit breaker - force exit after 5 consecutive EXIT_SIGNAL=true responses
    # Note: completion_indicators only accumulates when Codex explicitly sets EXIT_SIGNAL=true
    # (not based on confidence score). This safety breaker catches cases where Codex signals
    # completion 5+ times but the normal exit path (completion_indicators >= 2 + EXIT_SIGNAL=true)
    # didn't trigger for some reason. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Codex's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Codex explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in .response_analysis represents Codex's explicit intent.
    local codex_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        codex_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$codex_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    elif [[ $recent_completion_indicators -ge 2 ]]; then
        log_status "INFO" "DEBUG: Completion indicators ($recent_completion_indicators) present but EXIT_SIGNAL=false, continuing..." >&2
    fi
    
    # 5. Check fix_plan.md for completion
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local total_items=$(grep -cE "^[[:space:]]*- \[" "$RALPH_DIR/fix_plan.md" 2>/dev/null)
        local completed_items=$(grep -cE "^[[:space:]]*- \[x\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null)

        # Handle case where grep returns no matches (exit code 1)
        [[ -z "$total_items" ]] && total_items=0
        [[ -z "$completed_items" ]] && completed_items=0

        log_status "INFO" "DEBUG: .ralph/fix_plan.md check - total_items:$total_items, completed_items:$completed_items" >&2

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    else
        log_status "INFO" "DEBUG: .ralph/fix_plan.md file not found" >&2
    fi
    
    log_status "INFO" "DEBUG: No exit conditions met, continuing loop" >&2
    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# CLI HELPER FUNCTIONS
# =============================================================================

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi

            # Check for Bash(*) pattern - any Bash with parentheses is allowed
            if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return 1
        fi
    done

    return 0
}

# Build loop context for Codex session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix_plan.md
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    # Add circuit breaker state
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary (truncated)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary}"
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    local os_type
    os_type=$(uname)

    local file_mtime
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS (BSD stat)
        file_mtime=$(stat -f %m "$file" 2>/dev/null)
    else
        # Linux (GNU stat)
        file_mtime=$(stat -c %Y "$file" 2>/dev/null)
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Codex session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CODEX_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Codex starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_codex_session() {
    if [[ -f "$CODEX_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CODEX_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            rm -f "$CODEX_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CODEX_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CODEX_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CODEX_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        local session_id=$(cat "$CODEX_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Codex session: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Codex session"
    echo ""
}

# Save session ID after successful execution
save_codex_session() {
    local output_file=$1

    # Try to extract session ID from JSON output
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            echo "$session_id" > "$CODEX_SESSION_FILE"
            log_status "INFO" "Saved Codex session: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # Also clear the Codex session file for consistency
    rm -f "$CODEX_SESSION_FILE" 2>/dev/null

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Clear response analysis to prevent stale EXIT_SIGNAL from previous session
    rm -f "$RESPONSE_ANALYSIS_FILE" 2>/dev/null

    # Log the session transition (non-fatal to prevent script exit under set -e)
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}" || true

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Build combined prompt source for main agent
# Returns the prompt file path (may be the original PROMPT.md or a temp file)
build_prompt_source() {
    local base_prompt=$1
    local loop_context=$2
    local subagent_summary_file=$3

    if [[ -z "$loop_context" && ( -z "$subagent_summary_file" || ! -s "$subagent_summary_file" ) ]]; then
        echo "$base_prompt"
        return 0
    fi

    local tmp_prompt
    tmp_prompt=$(mktemp)
    {
        if [[ -n "$loop_context" ]]; then
            echo "## LOOP CONTEXT"
            echo "$loop_context"
            echo ""
        fi

        cat "$base_prompt"

        if [[ -n "$subagent_summary_file" && -s "$subagent_summary_file" ]]; then
            echo ""
            echo "## SUBAGENT REPORTS (CONTEXT ONLY)"
            cat "$subagent_summary_file"
        fi
    } > "$tmp_prompt"

    echo "$tmp_prompt"
}

# Subagent helpers
sanitize_subagent_name() {
    local file=$1
    local base
    base=$(basename "$file")
    base="${base%.subagent.md}"
    base="${base%.prompt.md}"
    base="${base%.md}"
    base="${base%.txt}"
    echo "$base" | tr '[:space:]/' '__' | tr -c 'A-Za-z0-9._-' '_'
}

list_subagent_prompts() {
    local dir="$SUBAGENT_PROMPT_DIR"
    if [[ ! -d "$dir" ]]; then
        return 1
    fi

    local -a patterns=($SUBAGENT_PROMPT_GLOB)
    local -a files=()
    shopt -s nullglob
    for pattern in "${patterns[@]}"; do
        for file in "$dir"/$pattern; do
            [[ -f "$file" ]] && files+=("$file")
        done
    done
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${files[@]}"
}

resolve_subagents_enabled() {
    case "${SUBAGENTS_ENABLED,,}" in
        true|yes|1|on)
            return 0
            ;;
        false|no|0|off)
            return 1
            ;;
        auto|"")
            if list_subagent_prompts >/dev/null; then
                return 0
            fi
            ;;
    esac
    return 1
}

should_run_subagents() {
    local loop_count=$1

    if ! resolve_subagents_enabled; then
        return 1
    fi

    if [[ "$SUBAGENT_LOOP_INTERVAL" =~ ^[1-9][0-9]*$ ]] && [[ "$SUBAGENT_LOOP_INTERVAL" -gt 1 ]]; then
        if (( loop_count % SUBAGENT_LOOP_INTERVAL != 0 )); then
            return 1
        fi
    fi

    return 0
}

write_subagent_state() {
    local state_file=$1
    local name=$2
    local status=$3
    local prompt_file=${4:-""}
    local output_file=${5:-""}
    local events_file=${6:-""}
    local exit_code=${7:-0}
    local duration_seconds=${8:-0}

    jq -n \
        --arg timestamp "$(get_iso_timestamp)" \
        --arg name "$name" \
        --arg status "$status" \
        --arg prompt_file "$prompt_file" \
        --arg output_file "$output_file" \
        --arg events_file "$events_file" \
        --argjson exit_code "$exit_code" \
        --argjson duration_seconds "$duration_seconds" \
        '{
            timestamp: $timestamp,
            name: $name,
            status: $status,
            prompt_file: $prompt_file,
            output_file: $output_file,
            events_file: $events_file,
            exit_code: $exit_code,
            duration_seconds: $duration_seconds
        }' > "$state_file"
}

write_subagents_status() {
    local overall_status=$1
    local loop_count=$2

    local agents_json="[]"
    if compgen -G "$SUBAGENT_STATE_DIR/*.json" > /dev/null; then
        agents_json=$(jq -s '.' "$SUBAGENT_STATE_DIR"/*.json 2>/dev/null || echo "[]")
    fi

    jq -n \
        --arg timestamp "$(get_iso_timestamp)" \
        --argjson loop_count "$loop_count" \
        --arg status "$overall_status" \
        --argjson agents "$agents_json" \
        '{
            timestamp: $timestamp,
            loop_count: $loop_count,
            status: $status,
            agents: $agents
        }' > "$SUBAGENT_STATUS_FILE"
}

build_subagent_prompt() {
    local agent_name=$1
    local agent_prompt_file=$2
    local loop_context=$3

    local tmp_prompt
    tmp_prompt=$(mktemp)
    {
        echo "## SUBAGENT CONTEXT"
        echo "Role: $agent_name"
        echo "Guidelines:"
        echo "- Work in parallel with the main Ralph loop"
        echo "- Do not modify files or run tests"
        echo "- Provide concise, actionable findings only"
        if [[ -n "$loop_context" ]]; then
            echo ""
            echo "Loop Context: $loop_context"
        fi
        echo ""
        echo "## MAIN PROMPT"
        cat "$PROMPT_FILE"
        echo ""
        echo "## SUBAGENT TASK"
        cat "$agent_prompt_file"
        echo ""
        echo "## OUTPUT FORMAT"
        echo "- Bullet list"
        echo "- Include file paths when referencing code"
        echo "- Do NOT include the RALPH_STATUS block"
    } > "$tmp_prompt"

    echo "$tmp_prompt"
}

build_subagent_summary() {
    local summary_file=$1
    local max_chars="$SUBAGENT_MAX_OUTPUT_CHARS"
    : > "$summary_file"

    if ! compgen -G "$SUBAGENT_STATE_DIR/*.json" > /dev/null; then
        return 1
    fi

    for state_file in "$SUBAGENT_STATE_DIR"/*.json; do
        local name
        local status
        local output_file
        name=$(jq -r '.name // "subagent"' "$state_file" 2>/dev/null)
        status=$(jq -r '.status // "unknown"' "$state_file" 2>/dev/null)
        output_file=$(jq -r '.output_file // ""' "$state_file" 2>/dev/null)

        echo "### ${name}" >> "$summary_file"
        if [[ -n "$output_file" && -s "$output_file" ]]; then
            local size
            size=$(wc -c < "$output_file" 2>/dev/null || echo 0)
            if [[ "$max_chars" =~ ^[1-9][0-9]*$ ]] && [[ $size -gt $max_chars ]]; then
                head -c "$max_chars" "$output_file" >> "$summary_file"
                echo "" >> "$summary_file"
                echo "[truncated: ${size} chars]" >> "$summary_file"
            else
                cat "$output_file" >> "$summary_file"
            fi
        else
            echo "_No output (status: $status)_" >> "$summary_file"
        fi
        echo "" >> "$summary_file"
    done
}

run_subagent_job() {
    set +e
    local agent_name=$1
    local agent_prompt_file=$2
    local loop_context=$3
    local state_file=$4

    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/subagent_${agent_name}_${timestamp}.log"
    local events_file="$LOG_DIR/subagent_events_${agent_name}_${timestamp}.log"
    local prompt_source
    prompt_source=$(build_subagent_prompt "$agent_name" "$agent_prompt_file" "$loop_context")

    local start_time
    start_time=$(date +%s)

    local -a cmd=("codex" "exec" "--json" "--skip-git-repo-check" "--output-last-message" "$output_file")
    if [[ "$SUBAGENT_FULL_AUTO" == "true" ]]; then
        cmd+=("--full-auto")
    fi
    if [[ -n "$SUBAGENT_SANDBOX" ]]; then
        cmd+=("--sandbox" "$SUBAGENT_SANDBOX")
    fi
    cmd+=("-")

    portable_timeout "${SUBAGENT_TIMEOUT_MINUTES}m" "${cmd[@]}" < "$prompt_source" > "$events_file" 2>&1
    local exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    rm -f "$prompt_source"

    local status="completed"
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
    fi

    write_subagent_state "$state_file" "$agent_name" "$status" "$agent_prompt_file" "$output_file" "$events_file" "$exit_code" "$duration"
    set -e
    return 0
}

run_subagents() {
    local loop_count=$1
    local loop_context=$2

    if ! should_run_subagents "$loop_count"; then
        return 1
    fi

    local -a subagent_files=()
    mapfile -t subagent_files < <(list_subagent_prompts 2>/dev/null || true)

    if [[ ${#subagent_files[@]} -eq 0 ]]; then
        return 1
    fi

    # Validate numeric settings
    if [[ ! "$SUBAGENT_MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
        SUBAGENT_MAX_PARALLEL=1
    fi
    if [[ ! "$SUBAGENT_TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
        SUBAGENT_TIMEOUT_MINUTES=10
    fi
    if [[ ! "$SUBAGENT_MAX_OUTPUT_CHARS" =~ ^[1-9][0-9]*$ ]]; then
        SUBAGENT_MAX_OUTPUT_CHARS=2000
    fi

    local calls_made
    calls_made=$(get_calls_made)
    local available_calls=$((MAX_CALLS_PER_HOUR - calls_made))
    local reserve_for_main=1
    local allowed_calls=$((available_calls - reserve_for_main))

    if [[ $allowed_calls -le 0 ]]; then
        log_status "WARN" "Skipping subagents (rate limit: ${calls_made}/${MAX_CALLS_PER_HOUR})"
        return 1
    fi

    local run_count=${#subagent_files[@]}
    if [[ $run_count -gt $allowed_calls ]]; then
        log_status "WARN" "Rate limit allows $allowed_calls subagents; skipping $((run_count - allowed_calls))"
        run_count=$allowed_calls
    fi

    local -a run_files=("${subagent_files[@]:0:$run_count}")
    local -a skipped_files=("${subagent_files[@]:$run_count}")

    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Subagents scheduled: ${#run_files[@]} (skipped: ${#skipped_files[@]})"
        if [[ ${#run_files[@]} -gt 0 ]]; then
            local max_list=10
            local -a display_files=("${run_files[@]:0:$max_list}")
            local list
            list=$(printf '%s, ' "${display_files[@]}")
            list=${list%, }
            log_status "INFO" "Subagent prompt files: $list"
            if [[ ${#run_files[@]} -gt $max_list ]]; then
                log_status "INFO" "Subagent prompt files: +$(( ${#run_files[@]} - $max_list )) more"
            fi
        fi
    fi

    rm -rf "$SUBAGENT_STATE_DIR"
    mkdir -p "$SUBAGENT_STATE_DIR"

    for file in "${skipped_files[@]}"; do
        local name
        local state_file
        name=$(sanitize_subagent_name "$file")
        state_file="$SUBAGENT_STATE_DIR/${name}.json"
        write_subagent_state "$state_file" "$name" "skipped" "$file" "" "" 0 0
    done

    for file in "${run_files[@]}"; do
        local name
        local state_file
        name=$(sanitize_subagent_name "$file")
        state_file="$SUBAGENT_STATE_DIR/${name}.json"
        write_subagent_state "$state_file" "$name" "running" "$file" "" "" 0 0
    done

    log_status "INFO" "Launching ${#run_files[@]} subagents (parallel: $SUBAGENT_MAX_PARALLEL)"
    write_subagents_status "running" "$loop_count"

    local i=0
    while [[ $i -lt ${#run_files[@]} ]]; do
        local -a batch_pids=()
        local j=0
        while [[ $j -lt $SUBAGENT_MAX_PARALLEL && $((i + j)) -lt ${#run_files[@]} ]]; do
            local file="${run_files[$((i + j))]}"
            local name
            local state_file
            name=$(sanitize_subagent_name "$file")
            state_file="$SUBAGENT_STATE_DIR/${name}.json"
            run_subagent_job "$name" "$file" "$loop_context" "$state_file" &
            batch_pids+=($!)
            ((j++))
        done

        for pid in "${batch_pids[@]}"; do
            wait "$pid" || true
        done
        i=$((i + j))
    done

    local success_count=0
    if compgen -G "$SUBAGENT_STATE_DIR/*.json" > /dev/null; then
        for state_file in "$SUBAGENT_STATE_DIR"/*.json; do
            local status
            status=$(jq -r '.status // ""' "$state_file" 2>/dev/null)
            if [[ "$status" == "completed" ]]; then
                success_count=$((success_count + 1))
            fi
        done
    fi

    if [[ $success_count -gt 0 ]]; then
        increment_call_counter_by "$success_count" >/dev/null
    fi

    write_subagents_status "completed" "$loop_count"

    if [[ "$SUBAGENT_APPEND_TO_PROMPT" == "true" ]]; then
        build_subagent_summary "$SUBAGENT_SUMMARY_FILE"
        if [[ -s "$SUBAGENT_SUMMARY_FILE" ]]; then
            echo "$SUBAGENT_SUMMARY_FILE"
            return 0
        fi
    fi

    return 0
}

# Main execution function
execute_codex_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/codex_output_${timestamp}.log"
    local events_file="$LOG_DIR/codex_events_${timestamp}.log"
    local loop_count=$1
    local loop_context_override=${2:-""}
    local subagent_summary_file=${3:-""}
    local calls_made
    calls_made=$(get_calls_made)
    calls_made=$((calls_made + 1))

    log_status "LOOP" "Executing Codex (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CODEX_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Codex execution... (timeout: ${CODEX_TIMEOUT_MINUTES}m)"

    # Build loop context for session continuity
    local loop_context="$loop_context_override"
    if [[ "$CODEX_USE_CONTINUE" == "true" && -z "$loop_context" ]]; then
        loop_context=$(build_loop_context "$loop_count")
    fi
    if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Loop context: $loop_context"
    fi

    # Build prompt source (loop context + optional subagent summary)
    local prompt_source
    prompt_source=$(build_prompt_source "$PROMPT_FILE" "$loop_context" "$subagent_summary_file")
    local tmp_prompt=""
    if [[ "$prompt_source" != "$PROMPT_FILE" ]]; then
        tmp_prompt="$prompt_source"
    fi
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Prompt source: $prompt_source"
        if [[ -n "$subagent_summary_file" ]]; then
            log_status "INFO" "Subagent summary appended: $subagent_summary_file"
        fi
    fi

    # Build Codex CLI command (JSON output for parsing)
    local -a CODEX_CMD_ARGS=("codex" "exec" "--json" "--skip-git-repo-check" "--output-last-message" "$output_file")
    if [[ "$CODEX_FULL_AUTO" == "true" ]]; then
        CODEX_CMD_ARGS+=("--full-auto")
    fi
    if [[ -n "$CODEX_SANDBOX" ]]; then
        CODEX_CMD_ARGS+=("--sandbox" "$CODEX_SANDBOX")
    fi
    if [[ "$CODEX_USE_CONTINUE" == "true" ]]; then
        CODEX_CMD_ARGS+=("resume" "--last")
    fi
    CODEX_CMD_ARGS+=("-")  # read prompt from stdin

    # Execute Codex
    if portable_timeout ${timeout_seconds}s "${CODEX_CMD_ARGS[@]}" < "$prompt_source" > "$events_file" 2>&1 &
    then
        :  # Continue to wait loop
    else
        log_status "ERROR" "❌ Failed to start Codex process"
        [[ -n "$tmp_prompt" ]] && rm -f "$tmp_prompt"
        return 1
    fi

    # Get PID and monitor progress
    local codex_pid=$!
    local progress_counter=0

    # Show progress while Codex is running
    while kill -0 $codex_pid 2>/dev/null; do
        progress_counter=$((progress_counter + 1))
        case $((progress_counter % 4)) in
            1) progress_indicator="⠋" ;;
            2) progress_indicator="⠙" ;;
            3) progress_indicator="⠹" ;;
            0) progress_indicator="⠸" ;;
        esac

        # Get last line from output if available
        local last_line=""
        if [[ -f "$events_file" && -s "$events_file" ]]; then
            last_line=$(tail -1 "$events_file" 2>/dev/null | head -c 80)
        elif [[ -f "$output_file" && -s "$output_file" ]]; then
            last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
        fi

        # Update progress file for monitor
        cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

        # Only log if verbose mode is enabled
        if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
            if [[ -n "$last_line" ]]; then
                log_status "INFO" "$progress_indicator Codex: $last_line... (${progress_counter}0s)"
            else
                log_status "INFO" "$progress_indicator Codex working... (${progress_counter}0s elapsed)"
            fi
        fi

        sleep 10
    done

    # Wait for the process to finish and get exit code
    wait $codex_pid
    local exit_code=$?

    [[ -n "$tmp_prompt" ]] && rm -f "$tmp_prompt"

    # Fallback: if output_file is empty, try extracting from events
    if [[ ! -s "$output_file" && -s "$events_file" ]] && command -v jq &>/dev/null; then
        local extracted=""
        extracted=$(jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' "$events_file" | tail -1)
        if [[ -z "$extracted" || "$extracted" == "null" ]]; then
            extracted=$(jq -r 'select(.type=="response_item" and .payload.type=="message" and .payload.role=="assistant") | .payload.content[]?.text // empty' "$events_file" | tail -1)
        fi
        if [[ -n "$extracted" && "$extracted" != "null" ]]; then
            printf "%s\n" "$extracted" > "$output_file"
        fi
    fi

    # Final fallback: preserve tail of events for error analysis
    if [[ ! -s "$output_file" && -s "$events_file" ]]; then
        tail -n 200 "$events_file" > "$output_file"
    fi

    if [ $exit_code -eq 0 ]; then
        # Only increment counter on successful execution
        increment_call_counter >/dev/null

        # Clear progress file
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Codex execution completed successfully"

        # Analyze the response
        log_status "INFO" "🔍 Analyzing Codex response..."
        analyze_response "$output_file" "$loop_count"
        local analysis_exit_code=$?

        # Update exit signals based on analysis
        update_exit_signals

        # Log analysis summary
        log_analysis_summary

        # Get file change count for circuit breaker
        local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo 0)
        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        local error_source="$events_file"
        if [[ -s "$output_file" ]]; then
            error_source="$output_file"
        fi

        # Check if the failure is due to API usage limits
        if grep -qi "limit.*reached\|usage.*limit" "$error_source"; then
            log_status "ERROR" "🚫 API usage limit reached"
            return 2  # Special return code for API limit
        else
            log_status "ERROR" "❌ Codex execution failed, check: $error_source"
            return 1
        fi
    fi
}

# Cleanup function
cleanup() {
    log_status "INFO" "Ralph loop interrupted. Cleaning up..."
    reset_session "manual_interrupt"
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
        fi
    fi

    log_status "SUCCESS" "🚀 Ralph loop starting with Codex"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"

    # Check if project uses old flat structure and needs migration
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo ""
        echo "Ralph v0.10.0+ uses a .ralph/ subfolder to keep your project root clean."
        echo ""
        echo "To upgrade your project, run:"
        echo "  ralph-migrate"
        echo ""
        echo "This will move Ralph-specific files to .ralph/ while preserving src/ at root."
        echo "A backup will be created before migration."
        exit 1
    fi

    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "$RALPH_DIR/fix_plan.md" ]] || [[ -d "$RALPH_DIR/specs" ]] || [[ -f "$RALPH_DIR/AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing .ralph/PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi

        echo ""
        echo "To fix this:"
        echo "  1. Enable Ralph in existing project: ralph-enable"
        echo "  2. Create a new project: ralph-setup my-project"
        echo "  3. Import existing requirements: ralph-import requirements.md"
        echo "  4. Navigate to an existing Ralph project directory"
        echo "  5. Or create .ralph/PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/, src/, etc."
        exit 1
    fi

    # Optional one-time prompt enhancement before entering the loop
    if [[ "$ENHANCE_PROMPT" == "true" ]]; then
        enhance_prompt "$PROMPT_FILE" || true
    fi

    # Initialize session tracking before entering the loop
    init_session_tracking

    log_status "INFO" "Starting main loop..."
    log_status "INFO" "DEBUG: About to enter while loop, loop_count=$loop_count"
    
    while true; do
        loop_count=$((loop_count + 1))
        log_status "INFO" "DEBUG: Successfully incremented loop_count to $loop_count"
        log_verbose "Loop #$loop_count starting (prompt: $PROMPT_FILE, continue: $CODEX_USE_CONTINUE, timeout: ${CODEX_TIMEOUT_MINUTES}m)"

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        log_verbose "Loop #$loop_count rate limit: $(get_calls_made)/$MAX_CALLS_PER_HOUR calls used"
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"

            break
        fi
        log_verbose "Loop #$loop_count exit checks passed; continuing"
        
        # Update status
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Build loop context once for main + subagents
        local loop_context=""
        if [[ "$CODEX_USE_CONTINUE" == "true" ]]; then
            loop_context=$(build_loop_context "$loop_count")
        fi
        if [[ "$VERBOSE_PROGRESS" == "true" && -n "$loop_context" ]]; then
            log_status "INFO" "Loop context length: ${#loop_context} chars"
        fi

        # Run subagents in parallel (if configured)
        local subagent_summary=""
        if subagent_summary=$(run_subagents "$loop_count" "$loop_context"); then
            if [[ -n "$subagent_summary" && "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "INFO" "Subagent summary: $subagent_summary"
            fi
        else
            subagent_summary=""
        fi
        
        # Execute Codex
        execute_codex_code "$loop_count" "$loop_context" "$subagent_summary"
        local exec_result=$?
        
        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 Codex API 5-hour limit reached!"
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}The Codex API 5-hour usage limit has been reached.${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]] || [[ -z "$user_choice" ]]; then
                log_status "INFO" "User chose to exit (or timed out). Exiting loop..."
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                log_status "INFO" "User chose to wait. Waiting for API limit reset..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Codex

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -t, --timeout MIN       Set Codex execution timeout in minutes (default: $CODEX_TIMEOUT_MINUTES)
    --enhance-prompt         Enhance PROMPT.md once before the loop (gpt-5.2, reasoning: xhigh)
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --reset-session         Reset session state and exit (clears session continuity)

Modern CLI Options (Phase 1.1):
    --output-format FORMAT  Set Codex output format: json or text (default: $CODEX_OUTPUT_FORMAT)
    --allowed-tools TOOLS   Comma-separated list of allowed tools (default: $CODEX_ALLOWED_TOOLS)
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CODEX_SESSION_EXPIRY_HOURS)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --enhance-prompt        # Improve PROMPT.md before starting the loop
    $0 --output-format text     # Use legacy text output format
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration

HELPEOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CODEX_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --enhance-prompt)
            ENHANCE_PROMPT=true
            shift
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            # Reset session state only
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CODEX_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CODEX_ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --no-continue)
            CODEX_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CODEX_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
