<#
.SYNOPSIS
  Lab formation : n8n local (Docker) + liens Make / Zapier (cloud).

.DESCRIPTION
  Make et Zapier ne s'installent pas en local : le script ouvre les pages d'inscription.
  n8n écoute sur http://127.0.0.1:5678 après un lancement réussi.

  .\scripts\setup-automation-lab.ps1 [-NoBrowser] [-SkipN8n]
#>

$ErrorActionPreference = "Stop"
$NoBrowser = $false
$SkipN8n = $false
for ($i = 0; $i -lt $args.Count; $i++) {
  switch -Regex ($args[$i]) {
    "^-NoBrowser$" { $NoBrowser = $true }
    "^-SkipN8n$" { $SkipN8n = $true }
  }
}

$N8nPort = if ($env:N8N_PORT) { $env:N8N_PORT } else { "5678" }
$N8nContainer = if ($env:N8N_CONTAINER) { $env:N8N_CONTAINER } else { "formation-n8n" }
$N8nVolume = if ($env:N8N_VOLUME) { $env:N8N_VOLUME } else { "n8n_formation_data" }
$MakeUrl = if ($env:MAKE_URL) { $env:MAKE_URL } else { "https://www.make.com/en/register" }
$ZapierUrl = if ($env:ZAPIER_URL) { $env:ZAPIER_URL } else { "https://zapier.com/sign-up" }

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "!!  $Message" -ForegroundColor Yellow }
function Fail([string]$Message) {
  Write-Host "Erreur : $Message" -ForegroundColor Red
  throw $Message
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machine;$user"
  $extra = @(
    "$env:ProgramFiles\Docker\Docker\resources\bin",
    "$env:ProgramFiles\Git\cmd"
  )
  foreach ($p in $extra) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path = "$p;$env:Path" }
  }
}

function Test-DockerReady {
  try {
    & docker info 2>$null | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Wait-Docker {
  Write-Step "Attente de Docker Desktop (jusqu'à 3 minutes)…"
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-DockerReady) {
      Write-Ok "Docker prêt"
      return
    }
    Start-Sleep -Seconds 3
  }
  Fail "Docker ne répond pas. Ouvrez Docker Desktop, attendez qu'il soit vert, relancez."
}

function Ensure-Docker {
  Update-SessionPath
  if (Test-DockerReady) {
    Write-Ok "Docker déjà opérationnel"
    return
  }
  if (Test-Path "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe") {
    Write-Step "Ouverture de Docker Desktop"
    Start-Process "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
    Wait-Docker
    return
  }
  if (Test-Command "winget") {
    Write-Step "Installation de Docker Desktop (winget)"
    & winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements
    Update-SessionPath
    Start-Process "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
    Write-Warn "Acceptez l'installation au premier lancement, puis relancez ce script si besoin."
    Wait-Docker
    return
  }
  Fail "Installez Docker Desktop, puis relancez scripts/setup-automation-lab.ps1"
}

function Start-N8nLab {
  Ensure-Docker
  $running = docker ps --format "{{.Names}}" 2>$null | Select-String -Pattern "^$([regex]::Escape($N8nContainer))$" -Quiet
  if ($running) {
    Write-Ok "Conteneur n8n déjà actif ($N8nContainer)"
    return
  }
  $exists = docker ps -a --format "{{.Names}}" 2>$null | Select-String -Pattern "^$([regex]::Escape($N8nContainer))$" -Quiet
  if ($exists) {
    Write-Step "Redémarrage de n8n"
    docker start $N8nContainer | Out-Null
  } else {
    Write-Step "Premier lancement de n8n"
    docker volume create $N8nVolume | Out-Null
    docker run -d `
      --name $N8nContainer `
      --restart unless-stopped `
      -p "127.0.0.1:${N8nPort}:5678" `
      -e GENERIC_TIMEZONE=Europe/Paris `
      -e TZ=Europe/Paris `
      -v "${N8nVolume}:/home/node/.n8n" `
      docker.n8n.io/n8nio/n8n | Out-Null
  }
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:${N8nPort}/" -UseBasicParsing -TimeoutSec 2
      if ($r.StatusCode -ge 200) {
        Write-Ok "n8n : http://127.0.0.1:${N8nPort} (compte admin à la première visite)"
        return
      }
    } catch { }
    Start-Sleep -Seconds 2
  }
  Write-Warn "n8n démarre encore. Ouvrez http://127.0.0.1:${N8nPort} dans quelques secondes."
}

function Show-CloudLinks {
  Write-Step "Make et Zapier (cloud — pas d'installation locale)"
  Write-Host "  1. Compte gratuit ou d'essai sur make.com et zapier.com"
  Write-Host "  2. Connectez vos apps (Gmail, Slack…) une par une"
  Write-Host "  3. Les scénarios tournent chez l'éditeur, pas sur ce PC"
  Write-Host ""
  Write-Host "  Make   : $MakeUrl"
  Write-Host "  Zapier : $ZapierUrl"
  if (-not $NoBrowser) {
    Start-Process $MakeUrl
    Start-Sleep -Seconds 1
    Start-Process $ZapierUrl
  }
}

Write-Step "Lab automatisation — formation assistants IA (2026)"
if (-not $SkipN8n) {
  Start-N8nLab
} else {
  Write-Warn "Mode -SkipN8n : pas de conteneur Docker"
}
Show-CloudLinks
Write-Host ""
Write-Ok "Prêt pour le module 7 (Make / Zapier / n8n)."
Write-Host "    Arrêter n8n : docker stop $N8nContainer"
Write-Host "    Relancer    : .\scripts\setup-automation-lab.ps1"
