#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# Shared helpers for the ansible_AWX_installer shell scripts.
# Source this file; do NOT execute it directly.
#   source "$(dirname "$0")/scripts/lib/common.sh"
# =============================================================================

# Resolve project root from this file's location (scripts/lib/common.sh).
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${_LIB_DIR}/../.." && pwd)"
export PROJECT_DIR
VERSIONS_FILE="${PROJECT_DIR}/versions.yml"
# Force the VMware provider for ALL vagrant calls our scripts make, regardless of
# any inherited global VAGRANT_DEFAULT_PROVIDER (this host exports 'docker').
export VAGRANT_DEFAULT_PROVIDER=vmware_desktop
STATE_DIR="${PROJECT_DIR}/.state"
CACHE_DIR="${PROJECT_DIR}/.cache"
ARTIFACTS_DIR="${PROJECT_DIR}/.artifacts"
VENV_DIR="${PROJECT_DIR}/.venv"
export VERSIONS_FILE STATE_DIR CACHE_DIR ARTIFACTS_DIR VENV_DIR

# ---- Colors (respect NO_COLOR and non-tty) ---------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_BOLD=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s %s[INFO]%s %s\n'  "$(_ts)" "$C_BLU"  "$C_RESET" "$*"; }
log_step()  { printf '\n%s %s==>%s %s%s%s\n' "$(_ts)" "$C_CYN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_ok()    { printf '%s %s[ OK ]%s %s\n'  "$(_ts)" "$C_GRN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s %s[WARN]%s %s\n'  "$(_ts)" "$C_YEL"  "$C_RESET" "$*" >&2; }
log_error() { printf '%s %s[FAIL]%s %s\n'  "$(_ts)" "$C_RED"  "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Print a single exact corrective action and exit (used for hard blockers).
blocker() {
  printf '\n%s%s================ BLOCKER ================%s\n' "$C_BOLD" "$C_RED" "$C_RESET" >&2
  printf '%s\n' "$*" >&2
  printf '%s%s========================================%s\n\n' "$C_BOLD" "$C_RED" "$C_RESET" >&2
  exit 2
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
have_cmd()    { command -v "$1" >/dev/null 2>&1; }

# retry <attempts> <delay_seconds> <command...>
retry() {
  local -i attempts="$1" delay="$2"; shift 2
  local -i n=1
  until "$@"; do
    if (( n >= attempts )); then
      log_error "command failed after ${attempts} attempts: $*"
      return 1
    fi
    log_warn "attempt ${n}/${attempts} failed; retrying in ${delay}s: $*"
    sleep "$delay"; (( n++ ))
  done
}

# ---- sudo: authorize once, keep alive --------------------------------------
SUDO_KEEPALIVE_PID=""
SUDO_READY=""
sudo_init() {
  if [[ "${EUID}" -eq 0 ]]; then return 0; fi
  require_cmd sudo
  if sudo -n true 2>/dev/null; then
    # Passwordless sudo: no keepalive needed (and no background process that
    # could hold a pipe/tee open and hang the caller).
    [[ -z "$SUDO_READY" ]] && log_info "sudo: passwordless available."
    SUDO_READY=1
    return 0
  fi
  if [[ -z "$SUDO_READY" ]]; then
    log_info "sudo: requesting authorization once (you may be prompted)..."
    sudo -v || blocker "This step needs sudo. Run 'sudo -v' once, then re-run ./install.sh"
    SUDO_READY=1
  fi
  # Single background keepalive, output detached so it never holds a caller pipe.
  if [[ -z "$SUDO_KEEPALIVE_PID" ]]; then
    ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
  fi
}
sudo_stop() { [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }

# pipefail-safe module check: awk consumes ALL of lsmod's output, so lsmod never
# receives SIGPIPE (which `lsmod | grep -q` can, yielding a false negative).
module_loaded() { lsmod | awk -v m="$1" '$1==m{f=1} END{exit !f}'; }

# ---- Error trap ------------------------------------------------------------
# setup_err_trap [on_error_function]
setup_err_trap() {
  local handler="${1:-}"
  ERR_HANDLER="$handler"
  trap '_on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap 'sudo_stop' EXIT
}
_on_err() {
  local code="$1" line="$2" cmd="$3"
  log_error "error (exit ${code}) at line ${line}: ${cmd}"
  if [[ -n "${ERR_HANDLER:-}" ]] && declare -F "${ERR_HANDLER}" >/dev/null; then
    "${ERR_HANDLER}" "$code" "$line" "$cmd" || true
  fi
  exit "$code"
}

confirm() {
  local prompt="${1:-Are you sure?}"
  read -r -p "${prompt} [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- versions.yml reader (dependency-free awk; 2-level scalars) -------------
# vget <section.key> [file]
vget() {
  local dotted="$1" file="${2:-$VERSIONS_FILE}"
  local section="${dotted%%.*}" leaf="${dotted#*.}"
  awk -v section="$section" -v leaf="$leaf" '
    function strip(s){ sub(/[[:space:]]*#.*$/,"",s); gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
                       gsub(/^"|"$/,"",s); gsub(/^'\''|'\''$/,"",s); return s }
    /^[A-Za-z0-9_]+:/ { insec = ($0 ~ ("^" section ":")); next }
    insec && $0 ~ ("^[[:space:]]+" leaf ":") {
      line=$0; sub(/^[[:space:]]+[^:]+:[[:space:]]*/,"",line); print strip(line); exit
    }' "$file"
}
# vget_list <section.key> [file]  -> one item per line
vget_list() {
  local dotted="$1" file="${2:-$VERSIONS_FILE}"
  local section="${dotted%%.*}" leaf="${dotted#*.}"
  awk -v section="$section" -v leaf="$leaf" '
    function strip(s){ sub(/[[:space:]]*#.*$/,"",s); gsub(/^[[:space:]]*-[[:space:]]*/,"",s);
                       gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); gsub(/^"|"$/,"",s);
                       gsub(/^'\''|'\''$/,"",s); return s }
    /^[A-Za-z0-9_]+:/ { insec=($0 ~ ("^" section ":")); inlist=0; next }
    insec && $0 ~ ("^[[:space:]]+" leaf ":") { inlist=1; next }
    insec && inlist {
      if ($0 ~ /^[[:space:]]+-[[:space:]]/) { print strip($0) }
      else if ($0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) { inlist=0 }
    }' "$file"
}

# Load the pins we need into VER_* env vars. Overlay resolved values only when
# AWX_ALLOW_VERSION_DRIFT=1 and .cache/versions.resolved.env exists.
load_versions() {
  VER_BOX="$(vget vagrant.box)"
  VER_BOX_VERSION="$(vget vagrant.box_version)"
  VER_UTILITY="$(vget vagrant.vmware_utility_version)"
  VER_PLUGIN="$(vget vagrant.vmware_desktop_plugin_version)"
  VER_ANSIBLE_CORE="$(vget ansible.core_version)"
  VER_K3S="$(vget k3s.version)"
  VER_OPERATOR="$(vget awx.operator_version)"
  VER_OPERATOR_IMAGE="$(vget awx.operator_image)"
  VER_AWX="$(vget awx.awx_version)"
  VER_NAMESPACE="$(vget awx.namespace)"
  VER_RESOURCE="$(vget awx.resource_name)"
  VER_ADMIN_USER="$(vget awx.admin_user)"
  VER_NODEPORT="$(vget awx.nodeport)"
  VER_PG_STORAGE="$(vget awx.postgres_storage)"
  VER_PG_SC="$(vget awx.postgres_storage_class)"
  VER_PROXY_OLD="$(vget kube_rbac_proxy.old_image)"
  VER_PROXY_IMAGE="$(vget kube_rbac_proxy.new_image)"
  VER_PROXY_TAG="$(vget kube_rbac_proxy.new_tag)"
  VER_PROXY_DIGEST="$(vget kube_rbac_proxy.new_digest)"
  export VER_BOX VER_BOX_VERSION VER_UTILITY VER_PLUGIN VER_ANSIBLE_CORE VER_K3S \
         VER_OPERATOR VER_OPERATOR_IMAGE VER_AWX VER_NAMESPACE VER_RESOURCE \
         VER_ADMIN_USER VER_NODEPORT VER_PG_STORAGE VER_PG_SC \
         VER_PROXY_OLD VER_PROXY_IMAGE VER_PROXY_TAG VER_PROXY_DIGEST
  if [[ "${AWX_ALLOW_VERSION_DRIFT:-0}" == "1" && -f "${CACHE_DIR}/versions.resolved.env" ]]; then
    # shellcheck disable=SC1091
    source "${CACHE_DIR}/versions.resolved.env"
    log_info "Applied resolved version overlay (AWX_ALLOW_VERSION_DRIFT=1)."
  fi
}

# Redaction filter for diagnostics: scrub secrets from any text stream.
redact() {
  sed -E \
    -e 's/(password|passwd|secret|token|api_key|apikey|authorization|bearer)([\"'\'' :=]+)[^[:space:]\"'\'',}]+/\1\2[REDACTED]/Ig' \
    -e 's#(data:[[:space:]]*\{)[^}]*#\1[REDACTED]#g' \
    -e 's/-----BEGIN [^-]*PRIVATE KEY-----/[REDACTED PRIVATE KEY]/g'
}

# Path to the project Vagrantfile dir (we ONLY run vagrant from here).
vagrant_dir() { printf '%s' "$PROJECT_DIR"; }

# Is the project VM created/running?
vm_state() {
  ( cd "$PROJECT_DIR" && vagrant status --machine-readable 2>/dev/null \
      | awk -F, '$3=="state"{print $4; exit}' )
}

# Discover the actual host port forwarded to guest 30080 (never assume 30080).
discover_host_port() {
  local guest="${1:-30080}"
  ( cd "$PROJECT_DIR" && vagrant port --guest "$guest" 2>/dev/null | tail -n1 | tr -dc '0-9' )
}
