#!/usr/bin/env bash
# First-time setup for the halo sandbox. Safe to re-run; it never overwrites
# values you have already set in .env.
#
# Run as your normal user (the one that owns this directory), not with sudo.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
warn() { printf 'WARNING: %s\n' "$*" >&2; }

if [[ $(id -u) -eq 0 ]]; then
  echo "Run this as your normal user, not root: containers run as the UID that runs setup." >&2
  exit 1
fi

# --- prerequisites -----------------------------------------------------------
for cmd in docker openssl; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "missing: docker compose plugin" >&2; exit 1; }
server=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
if [[ -z "$server" ]]; then
  warn "cannot talk to the Docker daemon as $(id -un); add yourself to the docker group or use rootless Docker"
elif (( ${server%%.*} < 28 )); then
  warn "Docker $server is older than 28; upgrade before running this stack"
fi

# --- .env --------------------------------------------------------------------
[[ -f .env ]] || { cp .env.example .env; chmod 600 .env; echo "created .env"; }
set_if_empty() {  # set_if_empty KEY VALUE
  local key=$1 value=$2
  if grep -qE "^${key}=$" .env; then
    sed -i "s|^${key}=$|${key}=${value}|" .env
    echo "  set $key"
  fi
}
gid_of() { getent group "$1" | cut -d: -f3; }
sed -i "s|^HALO_UID=.*|HALO_UID=$(id -u)|; s|^HALO_GID=.*|HALO_GID=$(id -g)|" .env
render_gid=$(gid_of render || true)
video_gid=$(gid_of video || true)
if [[ -n "$render_gid" ]]; then set_if_empty HALO_RENDER_GID "$render_gid"; else warn "no 'render' group on this host"; fi
if [[ -n "$video_gid" ]]; then set_if_empty HALO_VIDEO_GID "$video_gid"; else warn "no 'video' group on this host"; fi
set_if_empty LLM_API_KEY "$(openssl rand -hex 32)"
node=$(sed -n 's/^HALO_RENDER_NODE=//p' .env)
[[ -e "${node:-/dev/dri/renderD128}" ]] || warn "GPU render node ${node:-/dev/dri/renderD128} not found (check HALO_RENDER_NODE)"
id -nG | tr ' ' '\n' | grep -qx render || warn "$(id -un) is not in the 'render' group; the model server needs it (sudo usermod -aG render,video $(id -un))"

# --- directories and files compose expects ------------------------------------
mkdir -p workspace
[[ -f build-ca.pem ]] || : > build-ca.pem

# --- gateway CA ------------------------------------------------------------------
scripts/make-ca.sh

# --- host firewall ----------------------------------------------------------------
if command -v nft >/dev/null && sudo -n true 2>/dev/null; then
  sudo nft list table inet halo >/dev/null 2>&1 || warn "host firewall not loaded (see README: Host firewall)"
else
  echo "Reminder: install and enable host/halo-firewall.service before starting the stack (README: Host firewall)."
fi

grep -qE '^LLM_MODEL_FILE=.+$' .env || warn "set LLM_MODEL_FILE (and HALO_MODELS_DIR) in .env"
cat <<'EOF'

Next:
  1. Edit allowed-domains.txt (empty = no web access), then: scripts/make-ca.sh
  2. docker compose up -d && docker compose logs -f llm     (wait for the model to load)
  3. scripts/verify.sh                                        (proves the boundary)
  4. docker compose run --rm agent claude                     (start working)
EOF
