#!/bin/sh
# Installe SysInfo depuis ce dossier (archive décompressée).
#   ./install.sh               pour l'utilisateur courant : ~/.local/lib/SysInfo, commande ~/.local/bin/sysinfo, menu
#   sudo ./install.sh --system pour tous : /opt/SysInfo, commande /usr/local/bin/sysinfo, menu
#   ./install.sh --uninstall   (avec --system pour une installation système)
# Les réglages, l'historique et le journal d'audit (~/.config/SysInfo, ~/.local/share/SysInfo) ne sont jamais touchés.
set -eu

src=$(cd "$(dirname "$0")" && pwd)
mode=user
action=install
for arg in "$@"; do
    case "$arg" in
        --system) mode=system ;;
        --uninstall) action=uninstall ;;
        -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Argument inconnu : $arg" >&2; exit 2 ;;
    esac
done

if [ "$mode" = system ]; then
    [ "$(id -u)" -eq 0 ] || { echo "--system demande les droits root (sudo)." >&2; exit 1; }
    dest=/opt/SysInfo
    bin=/usr/local/bin
    apps=/usr/share/applications
    icons=/usr/share/icons/hicolor/256x256/apps
else
    dest=$HOME/.local/lib/SysInfo
    bin=$HOME/.local/bin
    apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
    icons=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps
fi

remove() {
    rm -f "$bin/sysinfo" "$apps/sysinfo.desktop" "$icons/sysinfo.png"
    rm -rf "$dest"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$apps" 2>/dev/null || true
}

if [ "$action" = uninstall ]; then
    remove
    echo "SysInfo désinstallé ($dest). Réglages et historique conservés."
    exit 0
fi

[ -x "$src/SysInfo" ] || { echo "Lancer ce script depuis le dossier décompressé de SysInfo." >&2; exit 1; }
[ "$src" = "$dest" ] && { echo "Déjà installé ici ($dest)." >&2; exit 1; }

# Mise à jour : l'ancienne version est remplacée entièrement (un module retiré ne doit pas rester).
remove
mkdir -p "$dest" "$bin" "$apps" "$icons"
cp -R "$src"/. "$dest"/
rm -f "$dest/install.sh" "$dest/sysinfo.desktop"
chmod +x "$dest/SysInfo"
ln -sf "$dest/SysInfo" "$bin/sysinfo"
cp "$src/sysinfo.png" "$icons/sysinfo.png"
sed -e "s|@EXEC@|$dest/SysInfo|" -e "s|@ICON@|sysinfo|" "$src/sysinfo.desktop" > "$apps/sysinfo.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$apps" 2>/dev/null || true

echo "SysInfo installé dans $dest"
echo "  Lancer : menu des applications, ou « sysinfo » dans un terminal"
case ":$PATH:" in *":$bin:"*) ;; *) echo "  ($bin n'est pas dans le PATH : utiliser $dest/SysInfo)" ;; esac
echo "  Serveur MCP (Claude Code) : claude mcp add sysinfo -- $dest/SysInfo --mcp"
