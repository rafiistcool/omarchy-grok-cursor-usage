#!/usr/bin/env bash
# Install the Grok + Cursor collectors and the customized agents panel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${USER:-$(id -un)}"
PLUGIN_ID="${USER_NAME}.agents"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/${PLUGIN_ID}"
AGENTS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/agents"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$PLUGIN_DIR" "$AGENTS_DIR" "$UNIT_DIR"

cp -a "$ROOT/plugin/." "$PLUGIN_DIR/"
if [[ -f "$PLUGIN_DIR/manifest.json" ]]; then
  python3 - "$PLUGIN_DIR/manifest.json" "$PLUGIN_ID" <<'PY'
import json, sys
path, plugin_id = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["id"] = plugin_id
json.dump(data, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
fi

install -m 0755 "$ROOT/collectors/omarchy-agent-usage-grok" "$AGENTS_DIR/"
install -m 0755 "$ROOT/collectors/omarchy-agent-usage-cursor" "$AGENTS_DIR/"
install -m 0755 "$ROOT/collectors/omarchy-grok-usage-watch" "$AGENTS_DIR/"
install -m 0644 "$ROOT/systemd/omarchy-grok-usage.service" "$UNIT_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now omarchy-grok-usage.service

echo "Installed plugin: $PLUGIN_DIR"
echo "Collectors:       $AGENTS_DIR"
echo "Watcher:          systemctl --user status omarchy-grok-usage.service"
echo
echo "If the bar still uses omarchy.agents, change that id to ${PLUGIN_ID}"
echo "in ~/.config/omarchy/shell.json, then: omarchy restart shell"
