#!/usr/bin/env bash
# =============================================================================
# bootstrap-host.sh — host preflight + automatable dependency installation.
#
# Idempotent: every step checks current state and skips when already satisfied.
# Hard blockers (VMware not installed / not enough resources / no internet) exit
# with code 2 and a single exact corrective action.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
setup_err_trap

REQ_CPUS=4
REQ_MEM_MB=8000        # ~8 GiB
REQ_DISK_GB=40

# ---------------------------------------------------------------------------
preflight_os_arch() {
  log_step "Host: OS / architecture / resources"
  [[ -r /etc/os-release ]] || die "/etc/os-release not readable"
  # shellcheck disable=SC1091
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}" codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ "$id" == "ubuntu" || "$id" == "linuxmint" || "$like" == *ubuntu* || "$like" == *debian* ]]; then
    log_ok "Host is ${PRETTY_NAME:-$id} (upstream codename: ${codename:-unknown})"
  else
    log_warn "Host ID='${id}' is not Ubuntu/Mint; proceeding best-effort (apt assumed)."
  fi

  local arch; arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || blocker "This installer requires x86_64. Detected: ${arch}."
  log_ok "Architecture: x86_64"

  local cpus; cpus="$(nproc)"
  (( cpus >= REQ_CPUS )) || blocker "Need >= ${REQ_CPUS} CPUs for the VM; host has ${cpus}."
  local mem_mb; mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  (( mem_mb >= REQ_MEM_MB )) || blocker "Need >= ${REQ_MEM_MB} MB RAM; host has ${mem_mb} MB."
  local disk_gb; disk_gb=$(df -BG --output=avail "$PROJECT_DIR" | awk 'NR==2{gsub(/G/,"");print $1}')
  (( disk_gb >= REQ_DISK_GB )) || blocker "Need >= ${REQ_DISK_GB} GB free at ${PROJECT_DIR}; have ${disk_gb} GB."
  log_ok "Resources: ${cpus} CPU / ${mem_mb} MB RAM / ${disk_gb} GB free"

  if grep -Eqc 'vmx|svm' /proc/cpuinfo; then
    log_ok "CPU virtualization extensions present ($(grep -Eo 'vmx|svm' /proc/cpuinfo | sort -u | tr '\n' ' '))"
  else
    blocker "No hardware virtualization (vmx/svm) found. Enable VT-x/AMD-V in firmware."
  fi
}

# ---------------------------------------------------------------------------
preflight_internet() {
  log_step "Host: internet reachability"
  local ok=0
  for u in https://releases.hashicorp.com/ https://github.com/ https://get.k3s.io; do
    if curl -fsS -m 10 -o /dev/null "$u" 2>/dev/null; then ok=1; break; fi
  done
  (( ok == 1 )) || blocker "No internet access to required endpoints (hashicorp/github/k3s). Check connectivity and retry."
  log_ok "Internet reachable."
}

# ---------------------------------------------------------------------------
verify_vmware() {
  log_step "Host: VMware Workstation + kernel modules"
  if ! have_cmd vmware; then
    blocker "VMware Workstation is not installed (no 'vmware' binary).
This installer will not perform a Broadcom-authenticated download / EULA / reboot.
ACTION: Install VMware Workstation Pro from Broadcom, then re-run ./install.sh"
  fi
  local ver; ver="$(vmware -v 2>/dev/null | grep -oE 'Workstation [0-9.]+' || true)"
  log_ok "VMware ${ver:-detected}"

  # Modules health (pipefail-safe). Repair ONLY with official tooling if absent;
  # never auto-overwrite working modules with community builds.
  if module_loaded vmmon && module_loaded vmnet; then
    log_ok "Kernel modules vmmon + vmnet are loaded."
  else
    log_warn "vmmon/vmnet not loaded for kernel $(uname -r); rebuilding with official VMware tooling..."
    sudo_init
    sudo vmware-modconfig --console --install-all >/dev/null 2>&1 || true
    if ! (module_loaded vmmon && module_loaded vmnet); then
      sudo modprobe vmmon 2>/dev/null || true
      sudo modprobe vmnet 2>/dev/null || true
    fi
    if module_loaded vmmon && module_loaded vmnet; then
      log_ok "vmmon + vmnet built and loaded via vmware-modconfig."
    else
      blocker "Could not load vmmon & vmnet for kernel $(uname -r).
ACTION (run once, then re-run ./install.sh):
  sudo vmware-modconfig --console --install-all
If that still fails on this kernel, build modules matching your Workstation
version from https://github.com/mkubecek/vmware-host-modules , then verify:
  sudo modprobe vmmon && sudo modprobe vmnet"
    fi
  fi

  # Networks must be up AND DURABLE. A healthy vmware.service (possible now that
  # modules build) keeps vmnet8 up; ad-hoc 'vmware-networks --start' alone has
  # been observed to drop, which silently breaks the SSH + AWX port forwards.
  # The authoritative health signal is: vmnet8 (the NAT adapter) HAS its IPv4.
  sudo_init
  if ! sudo systemctl is-active --quiet vmware.service; then
    log_info "Activating vmware.service (clears stale 'failed' state so networking persists)..."
    sudo systemctl restart vmware.service >/dev/null 2>&1 || true
  fi
  sudo vmware-networks --start >/dev/null 2>&1 || true   # idempotent: starts stopped vmnets
  local v8; v8="$(ip -4 addr show vmnet8 2>/dev/null || true)"
  if grep -q 'inet ' <<<"$v8"; then
    log_ok "VMware NAT network up: vmnet8 $(awk '/inet /{print $2}' <<<"$v8")"
  else
    log_warn "vmnet8 has no IPv4; restarting vmware.service + networks..."
    sudo systemctl restart vmware.service >/dev/null 2>&1 || true
    sudo vmware-networks --start >/dev/null 2>&1 || true
    v8="$(ip -4 addr show vmnet8 2>/dev/null || true)"
    if grep -q 'inet ' <<<"$v8"; then
      log_ok "VMware NAT network up after restart: vmnet8 $(awk '/inet /{print $2}' <<<"$v8")"
    else
      blocker "VMware NAT network (vmnet8) has no IPv4 address and could not be started.
ACTION: sudo systemctl restart vmware.service && sudo vmware-networks --start
then verify: ip -4 addr show vmnet8"
    fi
  fi
}

# ---------------------------------------------------------------------------
install_apt_essentials() {
  log_step "Host: base packages"
  local want=(curl git jq unzip ca-certificates openssl gnupg shellcheck python3-venv)
  local missing=()
  for p in "${want[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    log_ok "All base packages already present."
    return 0
  fi
  log_info "Installing missing packages: ${missing[*]}"
  sudo_init
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  log_ok "Base packages installed."
}

# ---------------------------------------------------------------------------
ensure_vagrant() {
  log_step "Host: Vagrant"
  if have_cmd vagrant; then
    log_ok "Vagrant present: $(vagrant --version)"
    return 0
  fi
  log_warn "Vagrant not found; installing from the official HashiCorp apt repository..."
  sudo_init
  install -d -m0755 /etc/apt/keyrings 2>/dev/null || sudo install -d -m0755 /etc/apt/keyrings
  local kr=/usr/share/keyrings/hashicorp-archive-keyring.gpg
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o "$kr"
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [signed-by=${kr}] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME:-noble} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vagrant
  log_ok "Vagrant installed: $(vagrant --version)"
}

# ---------------------------------------------------------------------------
install_vmware_utility() {
  log_step "Host: Vagrant VMware Utility (pinned ${VER_UTILITY})"
  # Detect the installed version reliably via dpkg (the binary's -v prints nothing
  # parseable), so we skip re-install when it is already current.
  local cur=""
  cur="$(dpkg-query -W -f='${Version}' vagrant-vmware-utility 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [[ "$cur" == "$VER_UTILITY" ]]; then
    log_ok "vagrant-vmware-utility ${cur} already installed."
  else
    [[ -n "$cur" ]] && log_info "Found utility ${cur}; installing pinned ${VER_UTILITY}."
    sudo_init
    mkdir -p "$CACHE_DIR"
    local base="https://releases.hashicorp.com/vagrant-vmware-utility/${VER_UTILITY}"
    local deb="vagrant-vmware-utility_${VER_UTILITY}-1_amd64.deb"
    local sums="vagrant-vmware-utility_${VER_UTILITY}_SHA256SUMS"
    log_info "Downloading ${deb} and checksums..."
    retry 3 5 curl -fsSL -o "${CACHE_DIR}/${deb}"  "${base}/${deb}"
    retry 3 5 curl -fsSL -o "${CACHE_DIR}/${sums}" "${base}/${sums}"
    log_info "Verifying SHA256..."
    ( cd "$CACHE_DIR" && grep " ${deb}\$" "${sums}" | sha256sum -c - ) \
      || die "checksum verification failed for ${deb}"
    log_ok "Checksum verified."
    sudo dpkg -i "${CACHE_DIR}/${deb}" >/dev/null 2>&1 \
      || { sudo apt-get -f install -y -qq; sudo dpkg -i "${CACHE_DIR}/${deb}"; }
    log_ok "Installed vagrant-vmware-utility ${VER_UTILITY}."
  fi
  # Service must be enabled + active.
  sudo_init
  sudo systemctl enable --now vagrant-vmware-utility.service >/dev/null 2>&1 || true
  if sudo systemctl is-active --quiet vagrant-vmware-utility.service; then
    log_ok "vagrant-vmware-utility.service is active."
  else
    log_warn "vagrant-vmware-utility.service not active; restarting..."
    sudo systemctl restart vagrant-vmware-utility.service || true
    sudo systemctl is-active --quiet vagrant-vmware-utility.service \
      && log_ok "service active after restart" \
      || die "vagrant-vmware-utility.service failed to start (check: systemctl status vagrant-vmware-utility)"
  fi
}

# ---------------------------------------------------------------------------
remove_legacy_plugins() {
  # Only remove the documented obsolete commercial plugins, if present.
  local gemroot="${HOME}/.vagrant.d/gems"
  local plugins; plugins="$(vagrant plugin list 2>/dev/null || true)"
  for legacy in vagrant-vmware-fusion vagrant-vmware-workstation; do
    if grep -q "^${legacy} " <<<"$plugins"; then
      log_warn "Removing obsolete plugin: ${legacy}"
      vagrant plugin uninstall "${legacy}" >/dev/null 2>&1 || true
    fi
    # Stray gem dirs from very old installs.
    find "$gemroot" -maxdepth 3 -type d -name "${legacy}*" 2>/dev/null | while read -r d; do
      log_warn "Removing legacy plugin dir: ${d}"; rm -rf "$d"
    done
  done
}

install_vmware_plugin() {
  log_step "Host: vagrant-vmware-desktop plugin (pinned ${VER_PLUGIN}, must be >= 1.0.0)"
  remove_legacy_plugins
  local cur
  cur="$(vagrant plugin list 2>/dev/null | sed -nE 's/^vagrant-vmware-desktop \(([0-9.]+).*/\1/p' | head -1)"
  if [[ "$cur" == "$VER_PLUGIN" ]]; then
    log_ok "vagrant-vmware-desktop ${cur} already installed."
  else
    [[ -n "$cur" ]] && log_info "Found plugin ${cur}; installing pinned ${VER_PLUGIN}."
    log_info "Installing vagrant-vmware-desktop ${VER_PLUGIN} (uses Vagrant's embedded Ruby)..."
    retry 2 5 vagrant plugin install vagrant-vmware-desktop --plugin-version "${VER_PLUGIN}"
    cur="$(vagrant plugin list 2>/dev/null | sed -nE 's/^vagrant-vmware-desktop \(([0-9.]+).*/\1/p' | head -1)"
    log_ok "Installed vagrant-vmware-desktop ${cur}."
  fi
  # Enforce >= 1.0.0.
  local major="${cur%%.*}"
  (( major >= 1 )) || die "vagrant-vmware-desktop must be >= 1.0.0; got ${cur}"
}

# ---------------------------------------------------------------------------
setup_venv() {
  log_step "Host: project Python venv (${VENV_DIR})"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    python3 -m venv "${VENV_DIR}"
    log_ok "Created venv."
  else
    log_ok "venv already exists."
  fi
  log_info "Installing pinned Python deps (ansible-core, ansible-lint, yamllint)..."
  "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip wheel
  "${VENV_DIR}/bin/python" -m pip install --quiet -r "${PROJECT_DIR}/requirements.txt"
  "${VENV_DIR}/bin/python" -m pip freeze > "${CACHE_DIR}/pip-freeze.txt" 2>/dev/null || true
  local acore; acore="$("${VENV_DIR}/bin/ansible" --version 2>/dev/null | head -1 || true)"
  [[ -n "$acore" ]] || die "ansible failed to install into venv"
  log_ok "Ansible ready: ${acore}"
}

# ---------------------------------------------------------------------------
main() {
  mkdir -p "$CACHE_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"
  load_versions
  preflight_os_arch
  preflight_internet
  sudo_init
  verify_vmware
  install_apt_essentials
  ensure_vagrant
  install_vmware_utility
  install_vmware_plugin
  setup_venv
  log_step "Host bootstrap complete."
  log_ok "All host prerequisites satisfied."
}

main "$@"
