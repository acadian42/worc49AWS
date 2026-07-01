#!/usr/bin/env bash
# =============================================================================
# resolve-versions.sh — query live upstream APIs and compare against versions.yml.
#
# Writes:
#   .cache/versions.resolved.yml   (human-readable snapshot of live values)
#   .cache/versions.resolved.env   (VER_* overrides; applied only when
#                                    AWX_ALLOW_VERSION_DRIFT=1)
#
# This NEVER fails the build: pins in versions.yml remain authoritative. Set
# AWX_OFFLINE=1 to skip all network calls.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
setup_err_trap
load_versions
mkdir -p "$CACHE_DIR"

RESOLVED_YML="${CACHE_DIR}/versions.resolved.yml"
RESOLVED_ENV="${CACHE_DIR}/versions.resolved.env"

# safe_curl_json <url> <jq-filter> -> prints value or empty on any failure
safe_curl_json() {
  local url="$1" filter="$2" out
  out="$(curl -fsSL -m 20 "$url" 2>/dev/null | jq -r "$filter" 2>/dev/null || true)"
  [[ "$out" == "null" ]] && out=""
  printf '%s' "$out"
}

if [[ "${AWX_OFFLINE:-0}" == "1" ]]; then
  log_warn "AWX_OFFLINE=1 — skipping live version resolution; using versions.yml pins."
  exit 0
fi

log_step "Resolving live upstream versions (pins remain authoritative)"

R_OPERATOR="$(safe_curl_json 'https://api.github.com/repos/ansible/awx-operator/releases/latest' '.tag_name')"
R_K3S="$(safe_curl_json 'https://update.k3s.io/v1-release/channels' '.data[] | select(.name=="stable") | .latest')"
R_UTILITY="$(curl -fsSL -m 20 'https://releases.hashicorp.com/vagrant-vmware-utility/index.json' 2>/dev/null \
  | jq -r '.versions | keys[]' 2>/dev/null | grep -viE 'beta|rc|alpha|pkgs' | sort -V | tail -1 || true)"
R_PLUGIN="$(safe_curl_json 'https://rubygems.org/api/v1/versions/vagrant-vmware-desktop.json' '[.[] | select(.prerelease==false)] | .[0].number')"
R_BOX="$(curl -fsSL -m 20 'https://app.vagrantup.com/api/v2/box/bento/ubuntu-24.04' 2>/dev/null \
  | jq -r '.versions[] | select(.providers[].name=="vmware_desktop") | .version' 2>/dev/null | sort -V | tail -1 || true)"

# kube-rbac-proxy digest for the PINNED tag (validate the pin is still correct).
R_PROXY_DIGEST="$(safe_curl_json \
  "https://quay.io/api/v1/repository/brancz/kube-rbac-proxy/tag/?onlyActiveTags=true&specificTag=${VER_PROXY_TAG}" \
  '.tags[0].manifest_digest')"
# Also the newest brancz tag, for drift awareness.
R_PROXY_LATEST="$(safe_curl_json \
  'https://quay.io/api/v1/repository/brancz/kube-rbac-proxy/tag/?onlyActiveTags=true&limit=100' \
  '[.tags[].name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))] | sort | last')"

# ---- Report ----------------------------------------------------------------
printf '%-26s %-26s %-26s %s\n' "COMPONENT" "PINNED" "LIVE" "MATCH?"
_row() {
  local name="$1" pin="$2" live="$3" m="—"
  [[ -n "$live" ]] && { [[ "$pin" == "$live" ]] && m="yes" || m="DRIFT"; }
  printf '%-26s %-26s %-26s %s\n' "$name" "$pin" "${live:-<unresolved>}" "$m"
}
_row "awx-operator"        "$VER_OPERATOR"    "$R_OPERATOR"
_row "k3s (stable)"        "$VER_K3S"         "$R_K3S"
_row "vmware-utility"      "$VER_UTILITY"     "$R_UTILITY"
_row "vmware-desktop plug" "$VER_PLUGIN"      "$R_PLUGIN"
_row "bento box"           "$VER_BOX_VERSION" "$R_BOX"
_row "rbac-proxy digest"   "$VER_PROXY_DIGEST" "$R_PROXY_DIGEST"
_row "rbac-proxy newest"   "$VER_PROXY_TAG"   "$R_PROXY_LATEST"

# ---- Persist snapshots ------------------------------------------------------
{
  echo "---"
  echo "# Live-resolved upstream versions (snapshot). Pins live in versions.yml."
  echo "resolved:"
  echo "  awx_operator: \"${R_OPERATOR}\""
  echo "  k3s_stable: \"${R_K3S}\""
  echo "  vmware_utility: \"${R_UTILITY}\""
  echo "  vmware_desktop_plugin: \"${R_PLUGIN}\""
  echo "  bento_box: \"${R_BOX}\""
  echo "  kube_rbac_proxy_pinned_tag: \"${VER_PROXY_TAG}\""
  echo "  kube_rbac_proxy_pinned_tag_digest: \"${R_PROXY_DIGEST}\""
  echo "  kube_rbac_proxy_newest_tag: \"${R_PROXY_LATEST}\""
} > "$RESOLVED_YML"

# Env overlay (only consumed when AWX_ALLOW_VERSION_DRIFT=1).
{
  [[ -n "$R_OPERATOR" ]] && echo "VER_OPERATOR=${R_OPERATOR}"
  [[ -n "$R_K3S"      ]] && echo "VER_K3S=${R_K3S}"
  [[ -n "$R_UTILITY"  ]] && echo "VER_UTILITY=${R_UTILITY}"
  [[ -n "$R_PLUGIN"   ]] && echo "VER_PLUGIN=${R_PLUGIN}"
  [[ -n "$R_BOX"      ]] && echo "VER_BOX_VERSION=${R_BOX}"
} > "$RESOLVED_ENV"

# ---- Sanity checks on the pins ---------------------------------------------
if [[ -n "$R_PROXY_DIGEST" && "$R_PROXY_DIGEST" != "$VER_PROXY_DIGEST" ]]; then
  log_warn "kube-rbac-proxy ${VER_PROXY_TAG} digest changed upstream:"
  log_warn "  pinned: ${VER_PROXY_DIGEST}"
  log_warn "  live  : ${R_PROXY_DIGEST}"
  log_warn "Update versions.yml kube_rbac_proxy.new_digest if this is expected."
else
  [[ -n "$R_PROXY_DIGEST" ]] && log_ok "kube-rbac-proxy digest pin verified against quay.io."
fi

log_ok "Version resolution complete -> ${RESOLVED_YML}"
if [[ "${AWX_ALLOW_VERSION_DRIFT:-0}" == "1" ]]; then
  log_warn "AWX_ALLOW_VERSION_DRIFT=1: resolved values will override pins this run."
fi
