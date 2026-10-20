<#
.SYNOPSIS
  Lab formation : n8n local (Docker) + liens Make / Zapier (cloud).

.DESCRIPTION
  Make et Zapier ne s'installent pas en local : le script ouvre les pages d'inscription.
  n8n écoute sur http://127.0.0.1:5678 après un lancement réussi.
  Installe cloudflared si absent (tunnel : cloudflared tunnel --url http://127.0.0.1:5678).

  .\scripts\setup-automation-lab.ps1 [-NoBrowser] [-SkipN8n] [-SkipCloudflared]
#>

$ErrorActionPreference = "Stop"
$NoBrowser = $false
$SkipN8n = $false
$SkipCloudflared = $false
for ($i = 0; $i -lt $args.Count; $i++) {
  switch -Regex ($args[$i]) {
    "^-NoBrowser$" { $NoBrowser = $true }
    "^-SkipN8n$" { $SkipN8n = $true }
    "^-SkipCloudflared$" { $SkipCloudflared = $true }
    "^-Help$" { $ShowHelp = $true }
  }
}

if ($ShowHelp) {
  @"
Usage: .\scripts\setup-automation-lab.ps1 [-NoBrowser] [-SkipN8n] [-SkipCloudflared]

  -NoBrowser        N'ouvre pas make.com / zapier.com
  -SkipN8n          Liens cloud uniquement (pas de conteneur n8n)
  -SkipCloudflared  N'installe pas cloudflared

Une ligne (dépôt public ia-formation-scripts) :
  irm https://raw.githubusercontent.com/JSurquin/ia-formation-scripts/main/setup-automation-lab.ps1 | iex

Dépôt Windows dédié (partage élèves) :
  irm https://raw.githubusercontent.com/JSurquin/ia-formation-automation-lab-windows/main/setup-automation-lab.ps1 | iex
"@ | Write-Host
  exit 0
}

if ($env:SKIP_CLOUDFLARED -eq "1") { $SkipCloudflared = $true }

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
    "$env:ProgramFiles\Git\cmd",
    "$env:ProgramFiles\cloudflared",
    "$env:LocalAppData\Microsoft\WinGet\Links"
  )
  foreach ($p in $extra) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) { $env:Path = "$p;$env:Path" }
  }
}

function Install-WingetPackage([string]$Id) {
  if (-not (Test-Command "winget")) {
    Fail "winget est introuvable. Ouvrez le Microsoft Store, installez « Programme d'installation d'application », puis relancez."
  }
  Write-Step "winget install $Id"
  & winget install --id $Id -e --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    Write-Warn "winget a renvoyé le code $LASTEXITCODE pour $Id (souvent déjà installé). On continue."
  }
  Update-SessionPath
}

function Test-DockerReady {
  try {
    & docker info 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Test-PodmanReady {
  if (-not (Test-Command "podman")) { return $false }
  try {
    & podman info 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Get-ContainerEngine {
  if (Test-DockerReady) { return "docker" }
  if (Test-PodmanReady) { return "podman" }
  return $null
}

function Invoke-Container([string[]]$ContainerArgs) {
  $engine = Get-ContainerEngine
  if (-not $engine) { Fail "Docker / Podman ne répond pas." }
  if ($engine -eq "podman") {
    & podman @ContainerArgs
  } else {
    & docker @ContainerArgs
  }
  if ($LASTEXITCODE -ne 0) { Fail "Commande $engine échouée : $($ContainerArgs -join ' ')" }
}

function Get-ContainerNameList([switch]$All) {
  $engine = Get-ContainerEngine
  if (-not $engine) { return @() }
  $psArgs = if ($All) { @("ps", "-a", "--format", "{{.Names}}") } else { @("ps", "--format", "{{.Names}}") }
  if ($engine -eq "podman") {
    return @(podman @psArgs 2>$null)
  }
  return @(docker @psArgs 2>$null)
}

function Wait-ContainerEngine {
  Write-Step "Attente du moteur conteneurs (jusqu'à 3 minutes)…"
  for ($i = 0; $i -lt 60; $i++) {
    Update-SessionPath
    $engine = Get-ContainerEngine
    if ($engine) {
      if ($engine -eq "podman") {
        Write-Ok ("Podman prêt — " + (podman --version))
      } else {
        Write-Ok ("Docker prêt — " + (docker --version))
      }
      return $true
    }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Test-PendingReboot {
  $paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
  )
  foreach ($p in $paths) {
    if (Test-Path $p) { return $true }
  }
  return $false
}

function Ensure-Wsl {
  try {
    wsl --status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Ok "WSL déjà disponible"
      return
    }
  } catch { }

  Write-Step "Installation de WSL 2 (requis pour Docker Desktop)"
  Write-Warn "Compte administrateur possible, puis redémarrage Windows."
  try {
    wsl --install --no-distribution
  } catch {
    Write-Warn "wsl --install a échoué. PowerShell en administrateur : wsl --install"
  }
  if (Test-PendingReboot) {
    Fail "Redémarrage requis (WSL). Redémarrez le PC, puis relancez la même commande."
  }
}

function Start-DockerDesktop {
  $candidates = @(
    "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
    "$env:LocalAppData\Programs\Docker\Docker\Docker Desktop.exe"
  )
  foreach ($exe in $candidates) {
    if (Test-Path $exe) {
      Start-Process $exe -ErrorAction SilentlyContinue | Out-Null
      return $true
    }
  }
  return $false
}

function Start-PodmanMachine {
  if (-not (Test-Command "podman")) { return $false }
  Write-Step "Podman détecté — démarrage de la machine"
  & podman machine start 2>$null
  if ($LASTEXITCODE -ne 0) {
    & podman machine init --now 2>$null
  }
  return (Wait-ContainerEngine)
}

function Ensure-Docker {
  Update-SessionPath
  if (Get-ContainerEngine) {
    Write-Ok "Moteur conteneurs déjà opérationnel"
    return
  }

  if (Test-Command "podman") {
    if (Start-PodmanMachine) { return }
  }

  Ensure-Wsl

  if (-not (Test-Command "docker")) {
    if (Test-Path "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe") {
      Write-Ok "Docker Desktop installé (binaire présent)"
    } else {
      Write-Step "Installation de Docker Desktop (winget)"
      Install-WingetPackage "Docker.DockerDesktop"
      Update-SessionPath
    }
  }

  Write-Step "Lancement de Docker Desktop"
  Start-DockerDesktop | Out-Null
  Write-Warn "Acceptez les droits au premier lancement si Windows le demande."

  if (Test-PendingReboot) {
    Fail "Redémarrage requis après Docker / WSL. Redémarrez, puis relancez ce script."
  }

  if (-not (Wait-ContainerEngine)) {
    Fail "Docker ne répond pas. Ouvrez Docker Desktop, attendez la baleine verte, relancez."
  }
}

function Ensure-Cloudflared {
  if ($SkipCloudflared) {
    Write-Warn "cloudflared ignoré (-SkipCloudflared)"
    return
  }
  Update-SessionPath
  if (Test-Command "cloudflared") {
    Write-Ok ("cloudflared déjà installé — " + (cloudflared --version 2>$null))
    return
  }
  Write-Step "Installation de cloudflared (winget)"
  Install-WingetPackage "Cloudflare.cloudflared"
  Update-SessionPath
  if (-not (Test-Command "cloudflared")) {
    Write-Warn "cloudflared introuvable après winget. Téléchargement : https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    return
  }
  Write-Ok ("cloudflared installé — " + (cloudflared --version 2>$null))
}

function Show-TunnelHint {
  if ($SkipCloudflared -or -not (Test-Command "cloudflared")) { return }
  Write-Step "Tunnel Cloudflare (webhooks n8n depuis Internet)"
  Write-Host "  Exemple rapide (URL temporaire) :"
  Write-Host "    cloudflared tunnel --url http://127.0.0.1:${N8nPort}"
  Write-Host "  Copiez l'URL https://*.trycloudflare.com affichée dans le terminal."
}

function Start-N8nLab {
  Ensure-Docker
  $running = Get-ContainerNameList | Select-String -Pattern "^$([regex]::Escape($N8nContainer))$" -Quiet
  if ($running) {
    Write-Ok "Conteneur n8n déjà actif ($N8nContainer)"
    return
  }
  $exists = Get-ContainerNameList -All | Select-String -Pattern "^$([regex]::Escape($N8nContainer))$" -Quiet
  if ($exists) {
    Write-Step "Redémarrage de n8n"
    Invoke-Container @("start", $N8nContainer) | Out-Null
  } else {
    Write-Step "Premier lancement de n8n"
    Invoke-Container @("volume", "create", $N8nVolume) | Out-Null
    Invoke-Container @(
      "run", "-d",
      "--name", $N8nContainer,
      "--restart", "unless-stopped",
      "-p", "127.0.0.1:${N8nPort}:5678",
      "-e", "GENERIC_TIMEZONE=Europe/Paris",
      "-e", "TZ=Europe/Paris",
      "-v", "${N8nVolume}:/home/node/.n8n",
      "docker.n8n.io/n8nio/n8n"
    ) | Out-Null
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
  Ensure-Cloudflared
  Show-TunnelHint
} else {
  Write-Warn "Mode -SkipN8n : pas de conteneur Docker"
}
Show-CloudLinks
Write-Host ""
Write-Ok "Prêt pour le module 7 (Make / Zapier / n8n)."
Write-Host "    Arrêter n8n : docker stop $N8nContainer  (ou podman stop si Podman)"
Write-Host "    Relancer    : .\scripts\setup-automation-lab.ps1"
