#!/usr/bin/env bash
# Install EIU into Omarchy from this checkout (for hacking on it).
# End users can instead run:  omarchy plugin add https://github.com/Malekabokhatwa/EIU.git --enable --yes
#
#   ./install.sh            link the plugin, put `eiu` on PATH, add it to the bar
#   ./install.sh --uninstall
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$HOME/.config/omarchy/plugins/eiu"
bin="$HOME/.local/bin/eiu"

if [[ ${1:-} == --uninstall ]]; then
  omarchy plugin disable eiu 2>/dev/null || true
  [[ -L $plugin ]] && rm "$plugin"
  [[ -L $bin ]] && rm "$bin"
  echo "EIU removed. Your data is still in ~/.local/share/eiu and ~/.config/eiu."
  exit 0
fi

mkdir -p "$(dirname "$plugin")" "$(dirname "$bin")"
if [[ -e $plugin && ! -L $plugin ]]; then
  echo "$plugin exists and is not a link (installed with 'omarchy plugin add'?). Leaving it."
else
  ln -sfn "$here" "$plugin"
fi
ln -sfn "$plugin/bin/eiu" "$bin"
chmod +x "$here/bin/eiu"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
grep -q '"eiu"' "$HOME/.config/omarchy/shell.json" 2>/dev/null || omarchy plugin enable eiu --before omarchy.network
echo "EIU installed. Click the pyramid on the bar to set it up, or run: eiu setup"
