#!/bin/bash

# Shared NDJSON logger for the env-checker shell scripts.
#
# Usage:
#   log_json <level> <message> [key value]...
#   log_debug|log_info|log_warn|log_error <message> [key value]...
#
# Each call writes one line to **stderr**:
#   {"time":"...","level":"INFO","message":"...","key":"value"}
#
# stderr, never stdout: run.sh captures the stdout of its helpers with command
# substitution and turns it into metrics and result.yaml, so a log line on
# stdout corrupts that data channel.
#
# Escaping is hand-rolled in pure Bash. The image ships `yq` but not `jq`, and
# spawning a process per log line would be wasteful, so this file has no
# dependency beyond Bash itself.

ENVCHECKER_LOG_LEVEL_VAR="${ENVIRONMENT_CHECKER_LOG_LEVEL:-}"
ENVCHECKER_LOG_FORMAT_VAR="${ENVIRONMENT_CHECKER_LOG_FORMAT:-}"

# The cloud passport mount wins over the environment, as it does in Python.
if [[ -f /etc/cloud-passport/ENVIRONMENT_CHECKER_LOG_LEVEL ]]; then
    ENVCHECKER_LOG_LEVEL_VAR=$(cat /etc/cloud-passport/ENVIRONMENT_CHECKER_LOG_LEVEL 2>/dev/null || echo "")
fi
if [[ -f /etc/cloud-passport/ENVIRONMENT_CHECKER_LOG_FORMAT ]]; then
    ENVCHECKER_LOG_FORMAT_VAR=$(cat /etc/cloud-passport/ENVIRONMENT_CHECKER_LOG_FORMAT 2>/dev/null || echo "")
fi

# ENVIRONMENT_CHECKER_LOG_LEVEL has always been a boolean in practice: every
# call site compares it against the literal 'ERROR', so 'ERROR' and an unset
# value mean "not verbose" rather than "errors only". The thresholds below keep
# that contract — the records suppressed by default are exactly the ones the
# old `if log_level != 'ERROR'` guards suppressed — and give OFF, FATAL, WARN
# and INFO a threshold of their own on top.
log_json_threshold() {
    local level="${ENVCHECKER_LOG_LEVEL_VAR^^}"
    case "${level}" in
    "") echo 20 ;;
    OFF) echo 60 ;;
    FATAL | CRITICAL) echo 50 ;;
    ERROR) echo 20 ;;
    WARN | WARNING) echo 30 ;;
    INFO) echo 20 ;;
    DEBUG | TRACE) echo 10 ;;
    *) echo 10 ;;
    esac
}

log_json_severity() {
    case "${1^^}" in
    FATAL | CRITICAL) echo 50 ;;
    ERROR) echo 40 ;;
    WARN | WARNING) echo 30 ;;
    INFO) echo 20 ;;
    *) echo 10 ;;
    esac
}

# Escape one value for use inside a JSON string: ANSI colors dropped, control
# characters folded, so the record always stays on a single line.
log_json_escape() {
    local s="$1"
    while [[ "${s}" =~ $'\e'\[[0-9\;]*[A-Za-z] ]]; do
        s="${s//${BASH_REMATCH[0]}/}"
    done
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//[$'\x01'-$'\x1f']/}"
    printf '%s' "${s}"
}

# log_json <level> <message> [key value]...
log_json() {
    local level="${1:-INFO}"
    local message="${2:-}"
    shift 2 2>/dev/null || shift $#

    local severity threshold
    severity=$(log_json_severity "${level}")
    threshold=$(log_json_threshold)
    if ((severity < threshold)); then
        return 0
    fi

    case "${level^^}" in
    WARNING) level="WARN" ;;
    CRITICAL) level="FATAL" ;;
    *) level="${level^^}" ;;
    esac

    local timestamp
    timestamp=$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')

    local key value pairs="" text_pairs=""
    while (($# >= 2)); do
        key="$1"
        value="$2"
        shift 2
        # Keys with empty values must not be added.
        if [[ -z "${value}" ]]; then
            continue
        fi
        pairs+=",\"$(log_json_escape "${key}")\":\"$(log_json_escape "${value}")\""
        text_pairs+=" [$(log_json_escape "${key}")=$(log_json_escape "${value}")]"
    done

    if [[ "${ENVCHECKER_LOG_FORMAT_VAR,,}" == "text" ]]; then
        printf '[%s] [%s]%s %s\n' \
            "${timestamp}" "${level}" "${text_pairs}" "$(log_json_escape "${message}")" >&2
    else
        printf '{"time":"%s","level":"%s","message":"%s"%s}\n' \
            "${timestamp}" "${level}" "$(log_json_escape "${message}")" "${pairs}" >&2
    fi
}

log_debug() { log_json DEBUG "$@"; }
log_info() { log_json INFO "$@"; }
log_warn() { log_json WARN "$@"; }
log_error() { log_json ERROR "$@"; }
