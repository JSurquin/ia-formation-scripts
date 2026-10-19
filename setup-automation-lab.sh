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

usage() {
  cat <<'EOF'
Usage: bash scripts/setup-automation-lab.sh [options]

  --no-browser     N'ouvre pas make.com / zapier.com dans le navigateur
  --skip-n8n       Affiche seulement les liens Make/Zapier (sans Docker / n8n)
  -h, --help       Aide

Variables : N8N_PORT, N8N_CONTAINER, MAKE_URL, ZAPIER_URL

Recommandé (depuis un clone du dépôt formation) :
  bash scripts/setup-automation-lab.sh

Une ligne curl (Linux / macOS) — seulement si le dépôt GitHub est public :
  curl -fsSL https://raw.githubusercontent.com/JSurquin/ia-formation/main/scripts/setup-automation-lab.sh | bash

Make et Zapier ne s'installent pas en local : le script ouvre les pages d'inscription.
n8n tourne sur http://127.0.0.1:5678 après le premier lancement réussi.
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
    -h|--help) usage; exit 0 ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
done

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

docker_ready() { docker info >/dev/null 2>&1; }
sudo_docker_ready() { have sudo && sudo docker info >/dev/null 2>&1; }

docker_cmd() {
  if docker_ready; then docker "$@"
  elif sudo_docker_ready; then sudo docker "$@"
  else die "Docker ne répond pas. Démarrez Docker Desktop / le service, puis relancez."
  fi
}

wait_docker() {
  local i
  log "Attente du moteur Docker (jusqu'à 3 minutes)…"
  for i in $(seq 1 60); do
    if docker_ready || sudo_docker_ready; then
      ok "Docker prêt"
      return 0
    fi
    sleep 3
  done
  return 1
}

ensure_docker() {
  if docker_ready || sudo_docker_ready; then
    ok "Docker déjà opérationnel"
    return
  fi

  if [ "$PLATFORM" = "macos" ]; then
    if [ -d /Applications/Docker.app ]; then
      open -a Docker || true
      wait_docker && return
    fi
    ensure_homebrew
    log "Installation de Docker Desktop"
    brew install --cask docker
    open -a Docker || true
    warn "Acceptez les droits macOS au premier lancement de Docker Desktop."
    wait_docker || die "Docker Desktop pas prêt. Ouvrez-le, attendez la baleine, relancez."
    return
  fi

  if have docker; then
    need_sudo systemctl start docker 2>/dev/null || need_sudo service docker start 2>/dev/null || true
    wait_docker && return
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
  if docker_cmd ps --format '{{.Names}}' 2>/dev/null | grep -qx "$N8N_CONTAINER"; then
    ok "Conteneur n8n déjà actif ($N8N_CONTAINER)"
    return
  fi
  if docker_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$N8N_CONTAINER"; then
    log "Redémarrage de n8n"
    docker_cmd start "$N8N_CONTAINER"
  else
    log "Premier lancement de n8n (image officielle)"
    docker_cmd volume create "$N8N_VOLUME" >/dev/null
    docker_cmd run -d \
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
  fi
  print_cloud
  echo
  ok "Prêt pour le module 7 (Make / Zapier / n8n)."
  echo "    Arrêter n8n : docker stop $N8N_CONTAINER"
  echo "    Relancer    : bash scripts/setup-automation-lab.sh"
}

main
