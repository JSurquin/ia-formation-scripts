#!/usr/bin/env bash
# Lab formation : n8n local (Docker) + liens Make / Zapier (cloud, compte navigateur)
set -euo pipefail

N8N_PORT="${N8N_PORT:-5678}"
N8N_CONTAINER="${N8N_CONTAINER:-formation-n8n}"
N8N_VOLUME="${N8N_VOLUME:-n8n_formation_data}"
MAKE_URL="${MAKE_URL:-https://www.make.com/en/register}"
ZAPIER_URL="${ZAPIER_URL:-https://zapier.com/sign-up}"
NO_BROWSER=0
SKIP_N8N=0
SKIP_CLOUDFLARED=0
CONTAINER_ENGINE="docker"

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-automation-lab.sh [options]

  --no-browser        N'ouvre pas make.com / zapier.com dans le navigateur
  --skip-n8n          Affiche seulement les liens Make/Zapier (sans Docker / n8n)
  --skip-cloudflared  N'installe pas cloudflared (tunnel Cloudflare)
  -h, --help          Aide

Variables : N8N_PORT, N8N_CONTAINER, MAKE_URL, ZAPIER_URL, SKIP_CLOUDFLARED=1

Recommandé (depuis un clone du dépôt formation) :
  bash scripts/setup-automation-lab.sh

Une ligne curl (Linux / macOS) — dépôt public ia-formation-scripts :
  curl -fsSL https://raw.githubusercontent.com/JSurquin/ia-formation-scripts/main/setup-automation-lab.sh | bash

Make et Zapier ne s'installent pas en local : le script ouvre les pages d'inscription.
n8n tourne sur http://127.0.0.1:5678 après le premier lancement réussi.
cloudflared est installé si absent (pour un tunnel : cloudflared tunnel --url http://127.0.0.1:5678).
EOF
}

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32mOK\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mErreur :\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-browser) NO_BROWSER=1; shift ;;
    --skip-n8n) SKIP_N8N=1; shift ;;
    --skip-cloudflared) SKIP_CLOUDFLARED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
done

if [ "${SKIP_CLOUDFLARED:-}" = "1" ]; then
  SKIP_CLOUDFLARED=1
fi

OS="$(uname -s)"
case "$OS" in
  Linux)  PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Git Bash / Cygwin : utilisez scripts/setup-automation-lab.ps1 dans PowerShell"
    ;;
  *) die "Système non géré : $OS" ;;
esac

need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ "${1:-}" = "-E" ]; then shift; fi
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    die "Il faut sudo (ou root) pour installer Docker : $*"
  fi
}

pkg_install() {
  if have apt-get; then
    need_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
    need_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif have dnf; then
    need_sudo dnf install -y "$@"
  elif have yum; then
    need_sudo yum install -y "$@"
  elif have pacman; then
    need_sudo pacman -Sy --noconfirm "$@"
  elif have zypper; then
    need_sudo zypper --non-interactive install "$@"
  elif have brew; then
    brew install "$@"
  else
    die "Installez Docker manuellement, puis relancez ce script."
  fi
}

ensure_homebrew() {
  if have brew; then return; fi
  log "Installation de Homebrew (mot de passe admin possible)"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  have brew || die "Homebrew introuvable. Ouvrez un nouveau terminal et relancez."
}

refresh_path() {
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  if [ -d "$HOME/.local/bin" ]; then export PATH="$HOME/.local/bin:$PATH"; fi
}

docker_ready() { docker info >/dev/null 2>&1; }
sudo_docker_ready() { have sudo && sudo docker info >/dev/null 2>&1; }
podman_ready() { have podman && podman info >/dev/null 2>&1; }

resolve_container_engine() {
  if docker_ready || sudo_docker_ready; then
    CONTAINER_ENGINE="docker"
    return 0
  fi
  if podman_ready; then
    CONTAINER_ENGINE="podman"
    return 0
  fi
  return 1
}

container_cmd() {
  if [ "$CONTAINER_ENGINE" = "podman" ]; then
    podman "$@"
  elif docker_ready; then
    docker "$@"
  elif sudo_docker_ready; then
    sudo docker "$@"
  else
    die "Docker / Podman ne répond pas. Démarrez le moteur, puis relancez."
  fi
}

wait_docker() {
  local i
  log "Attente du moteur conteneurs (jusqu'à 3 minutes)…"
  for i in $(seq 1 60); do
    if resolve_container_engine; then
      if [ "$CONTAINER_ENGINE" = "podman" ]; then
        ok "Podman prêt ($(podman --version 2>/dev/null | head -n1))"
      else
        ok "Docker prêt ($(docker_cmd --version 2>/dev/null | head -n1))"
      fi
      return 0
    fi
    sleep 3
  done
  return 1
}

macos_runtime_detected() {
  have orb || [ -d /Applications/OrbStack.app ] \
    || have colima \
    || [ -d /Applications/Docker.app ] \
    || [ -d "/Applications/Rancher Desktop.app" ] \
    || have podman \
    || have rancher \
    || (have brew && brew list --cask orbstack >/dev/null 2>&1) \
    || (have brew && brew list --cask docker >/dev/null 2>&1)
}

start_macos_runtime() {
  refresh_path
  if have orb || [ -d /Applications/OrbStack.app ]; then
    log "OrbStack détecté — démarrage"
    if have orb; then orb start || true; else open -a OrbStack 2>/dev/null || true; fi
    wait_docker && return 0
    warn "OrbStack est là mais le moteur Docker ne répond pas encore. Ouvrez OrbStack, attendez qu'il soit prêt."
    return 1
  fi
  if have colima; then
    log "Colima détecté — démarrage"
    colima start 2>/dev/null || colima start --cpu 2 --memory 4 || true
    wait_docker && return 0
    return 1
  fi
  if [ -d /Applications/Docker.app ]; then
    log "Docker Desktop déjà installé — ouverture"
    open -a Docker || true
    wait_docker && return 0
    return 1
  fi
  if [ -d "/Applications/Rancher Desktop.app" ]; then
    log "Rancher Desktop détecté — ouverture"
    open -a "Rancher Desktop" || true
    wait_docker && return 0
    return 1
  fi
  if have podman; then
    log "Podman détecté — démarrage de la machine"
    podman machine start 2>/dev/null || podman machine init --now 2>/dev/null || true
    wait_docker && return 0
    return 1
  fi
  return 1
}

linux_runtime_start() {
  if have docker; then
    need_sudo systemctl start docker 2>/dev/null || need_sudo service docker start 2>/dev/null || true
    wait_docker && return 0
  fi
  if have podman; then
    systemctl --user start podman.socket 2>/dev/null || true
    wait_docker && return 0
  fi
  return 1
}

ensure_docker() {
  if resolve_container_engine; then
    ok "Moteur conteneurs déjà opérationnel ($CONTAINER_ENGINE)"
    return
  fi

  if [ "$PLATFORM" = "macos" ]; then
    if macos_runtime_detected; then
      start_macos_runtime && return
      die "Un runtime conteneurs est installé (OrbStack, Colima, Docker Desktop…) mais ne répond pas. Ouvrez-le, attendez qu'il soit prêt, relancez ce script — sans installer Docker Desktop en double."
    fi
    ensure_homebrew
    log "Aucun runtime détecté — installation de Docker Desktop"
    brew install --cask docker
    open -a Docker || true
    warn "Acceptez les droits macOS au premier lancement de Docker Desktop."
    wait_docker || die "Docker Desktop pas prêt. Ouvrez-le, attendez la baleine, relancez."
    return
  fi

  if linux_runtime_start; then
    return
  fi

  log "Installation de Docker Engine"
  if ! have curl; then pkg_install curl ca-certificates; fi
  curl -fsSL https://get.docker.com | need_sudo sh
  need_sudo systemctl enable --now docker 2>/dev/null || need_sudo service docker start 2>/dev/null || true
  if have sudo && [ "$(id -u)" -ne 0 ]; then
    need_sudo usermod -aG docker "$USER" || true
    warn "Compte ajouté au groupe docker. Déconnexion/reconnexion si « permission denied »."
  fi
  wait_docker || die "Docker installé mais pas prêt. Relancez le script."
}

install_cloudflared_linux() {
  if have cloudflared; then return; fi
  log "Installation de cloudflared (Linux)"
  if have apt-get; then
    if ! dpkg -s cloudflared >/dev/null 2>&1; then
      local deb="/tmp/cloudflared.deb"
      local arch
      arch="$(uname -m)"
      case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "Architecture Linux non gérée pour cloudflared : $arch" ;;
      esac
      curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" -o "$deb"
      need_sudo dpkg -i "$deb" || need_sudo apt-get install -f -y
      rm -f "$deb"
    fi
    return
  fi
  if have dnf || have yum; then
    pkg_install cloudflared 2>/dev/null || true
    have cloudflared && return
  fi
  local bin="${HOME}/.local/bin/cloudflared"
  mkdir -p "${HOME}/.local/bin"
  local arch raw
  raw="$(uname -m)"
  case "$raw" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Architecture non gérée pour cloudflared : $raw" ;;
  esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "$bin"
  chmod +x "$bin"
  export PATH="${HOME}/.local/bin:$PATH"
}

ensure_cloudflared() {
  if [ "$SKIP_CLOUDFLARED" = "1" ]; then
    warn "cloudflared ignoré (--skip-cloudflared)"
    return
  fi
  refresh_path
  if have cloudflared; then
    ok "cloudflared déjà installé ($(cloudflared --version 2>/dev/null | head -n1))"
    return
  fi
  if [ "$PLATFORM" = "macos" ]; then
    ensure_homebrew
    log "Installation de cloudflared (Homebrew)"
    brew install cloudflared
  else
    install_cloudflared_linux
  fi
  refresh_path
  have cloudflared || warn "cloudflared introuvable après installation. Installez-le à la main : https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  have cloudflared && ok "cloudflared installé ($(cloudflared --version 2>/dev/null | head -n1))"
}

print_tunnel_hint() {
  if [ "$SKIP_CLOUDFLARED" = "1" ] || ! have cloudflared; then
    return
  fi
  echo
  log "Tunnel Cloudflare (webhooks n8n depuis Internet)"
  echo "  Exemple rapide (URL temporaire) :"
  echo "    cloudflared tunnel --url http://127.0.0.1:${N8N_PORT}"
  echo "  Copiez l'URL https://*.trycloudflare.com affichée dans le terminal."
}

open_url() {
  [ "$NO_BROWSER" = "1" ] && return 0
  case "$OS" in
    Darwin) open "$1" 2>/dev/null || true ;;
    Linux)
      if have xdg-open; then xdg-open "$1" 2>/dev/null || true
      elif have sensible-browser; then sensible-browser "$1" 2>/dev/null || true
      fi
      ;;
  esac
}

start_n8n() {
  ensure_docker
  if container_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$N8N_CONTAINER"; then
    ok "Conteneur n8n déjà actif ($N8N_CONTAINER)"
    return
  fi
  if container_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$N8N_CONTAINER"; then
    log "Redémarrage de n8n"
    container_cmd start "$N8N_CONTAINER"
  else
    log "Premier lancement de n8n (image officielle)"
    container_cmd volume create "$N8N_VOLUME" >/dev/null
    container_cmd run -d \
      --name "$N8N_CONTAINER" \
      --restart unless-stopped \
      -p "127.0.0.1:${N8N_PORT}:5678" \
      -e GENERIC_TIMEZONE=Europe/Paris \
      -e TZ=Europe/Paris \
      -v "${N8N_VOLUME}:/home/node/.n8n" \
      docker.n8n.io/n8nio/n8n
  fi
  local i
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${N8N_PORT}/" >/dev/null 2>&1; then
      ok "n8n : http://127.0.0.1:${N8N_PORT} (créez un compte admin à la première visite)"
      return
    fi
    sleep 2
  done
  warn "n8n démarre encore. Ouvrez http://127.0.0.1:${N8N_PORT} dans quelques secondes."
}

print_cloud() {
  log "Make et Zapier (cloud — pas d'installation locale)"
  echo "  1. Compte gratuit ou d'essai sur make.com et zapier.com"
  echo "  2. Connectez vos apps (Gmail, Slack…) une par une"
  echo "  3. Les scénarios tournent chez l'éditeur, pas sur ce PC"
  echo
  echo "  Make   : $MAKE_URL"
  echo "  Zapier : $ZAPIER_URL"
  open_url "$MAKE_URL"
  sleep 1
  open_url "$ZAPIER_URL"
}

main() {
  log "Lab automatisation — formation assistants IA (2026)"
  if [ "$SKIP_N8N" = "1" ]; then
    warn "Mode --skip-n8n : pas de conteneur Docker"
  else
    start_n8n
    ensure_cloudflared
    print_tunnel_hint
  fi
  print_cloud
  echo
  ok "Prêt pour le module 7 (Make / Zapier / n8n)."
  echo "    Arrêter n8n : docker stop $N8N_CONTAINER  (ou podman stop si Podman)"
  echo "    Relancer    : bash scripts/setup-automation-lab.sh"
}

main
