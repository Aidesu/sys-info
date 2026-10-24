<#
.SYNOPSIS
    Installe SysInfo depuis ce dossier (archive décompressée), pour l'utilisateur courant.
.DESCRIPTION
    Copie l'application dans %LOCALAPPDATA%\Programs\SysInfo et crée un raccourci dans le menu Démarrer.
    -Uninstall la retire. Les réglages, l'historique et le journal d'audit (%APPDATA%\SysInfo, %LOCALAPPDATA%\SysInfo)
    ne sont jamais touchés. Fonctionne avec Windows PowerShell 5.1 :
        powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\SysInfo'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'SysInfo.lnk'

function Remove-SysInfo {
    if (Get-Process SysInfo -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dest\*" }) {
        throw 'SysInfo est ouvert : le fermer (et arrêter le serveur MCP) avant de continuer.'
    }
    if (Test-Path $shortcut) { Remove-Item $shortcut -Force }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
}

if ($Uninstall) {
    Remove-SysInfo
    Write-Output "SysInfo désinstallé ($dest). Réglages et historique conservés."
    return
}

$src = $PSScriptRoot
if (-not (Test-Path (Join-Path $src 'SysInfo.exe'))) { throw 'Lancer ce script depuis le dossier décompressé de SysInfo.' }
if ((Resolve-Path $src).Path.TrimEnd('\') -eq $dest) { throw "Déjà installé ici ($dest)." }

# Mise à jour : l'ancienne version est remplacée entièrement (un module retiré ne doit pas rester).
Remove-SysInfo
$null = New-Item -ItemType Directory -Force $dest
Copy-Item (Join-Path $src '*') $dest -Recurse -Force
Remove-Item (Join-Path $dest 'install.ps1') -Force
# Fichiers téléchargés : marque « venant d'Internet » retirée (sinon avertissements à chaque lancement).
Get-ChildItem $dest -Recurse -File | Unblock-File

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = Join-Path $dest 'SysInfo.exe'
$link.WorkingDirectory = $dest
$link.Description = 'Informations système, diagnostic et maintenance'
$link.Save()

Write-Output "SysInfo installé dans $dest"
Write-Output '  Lancer : menu Démarrer › SysInfo'
Write-Output "  Serveur MCP (Claude Code) : claude mcp add sysinfo -- `"$dest\SysInfo.exe`" --mcp"
