#!/usr/bin/env bash
# Install the agents panel plus Grok / Cursor / Codex collectors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${USER:-$(id -un)}"
PLACEHOLDER="yourname"
PLUGIN_ID="${USER_NAME}.agents"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/${PLUGIN_ID}"
AGENTS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/agents"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
FORCE=0
APPLY_LAYOUT=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --apply-layout) APPLY_LAYOUT=1 ;;
    -h|--help)
      printf '%s\n' \
        "Usage: ./install.sh [--force] [--apply-layout]" \
        "  --force          overwrite an existing <user>.agents plugin" \
        "  --apply-layout   point bar.layout at <user>.agents (backs up shell.json)"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [[ -e $PLUGIN_DIR && $FORCE -eq 0 ]]; then
  log "plugin exists, skipping: $PLUGIN_DIR (./install.sh --force to replace)"
else
  mkdir -p "$PLUGIN_DIR"
  find "$ROOT/plugin" -type f | while read -r file; do
    rel="${file#$ROOT/plugin/}"
    mkdir -p "$PLUGIN_DIR/$(dirname "$rel")"
    sed "s/${PLACEHOLDER}\./${USER_NAME}./g" "$file" > "$PLUGIN_DIR/$rel"
  done
  chmod +x "$PLUGIN_DIR/history.py"
  python3 - "$PLUGIN_DIR/manifest.json" "$PLUGIN_ID" <<'PY'
import json, sys
path, plugin_id = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["id"] = plugin_id
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
PY
  log "installed plugin: $PLUGIN_DIR"
fi

mkdir -p "$AGENTS_DIR"
for name in omarchy-agent-usage-grok omarchy-agent-usage-cursor omarchy-agent-usage-codex omarchy-agent-usage-antigravity run-usage-update omarchy-grok-usage-watch; do
  install -m 0755 "$ROOT/collectors/$name" "$AGENTS_DIR/$name"
done
log "installed collectors: $AGENTS_DIR"

if (( APPLY_LAYOUT )); then
  if [[ ! -f $SHELL_JSON ]]; then
    echo "shell.json not found at $SHELL_JSON; skipping layout." >&2
  else
    backup="$SHELL_JSON.bak.$(date +%s)"
    cp "$SHELL_JSON" "$backup"
    log "backed up shell.json -> $backup"
    PLUGIN_ID="$PLUGIN_ID" python3 - "$SHELL_JSON" <<'PY'
import json, os, sys

path = sys.argv[1]
plugin_id = os.environ["PLUGIN_ID"]

with open(path) as f:
    cfg = json.load(f)

bar = cfg.setdefault("bar", {})
layout = bar.setdefault("layout", {})
changed = False
for section in ("left", "center", "right"):
    entries = layout.setdefault(section, [])
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        eid = str(entry.get("id") or "")
        if eid in ("omarchy.agents", plugin_id) or eid.endswith(".agents"):
            if eid != plugin_id:
                entry["id"] = plugin_id
                changed = True
            break
    else:
        continue
    break
else:
    layout.setdefault("right", []).insert(0, {"id": plugin_id})
    changed = True

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("layout updated" if changed else "layout already pointed at this plugin")
PY
    log "layout applied ($PLUGIN_ID)"
  fi
else
  cat <<EOF

If the bar still uses omarchy.agents, change that id to ${PLUGIN_ID}
in ~/.config/omarchy/shell.json, or rerun:

  ./install.sh --apply-layout

Then:

  omarchy restart shell
EOF
fi
