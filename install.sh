#!/usr/bin/env bash
# Compatibility installer: install a git-managed, self-contained plugin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${USER:-$(id -un)}"
PLUGIN_ID="rafi.agents"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/${PLUGIN_ID}"
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
        "  --force          back up and replace an existing rafi.agents plugin" \
        "  --apply-layout   point bar.layout at rafi.agents (backs up shell.json)"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

if [[ "$(realpath -m "$PLUGIN_DIR")" == "$ROOT" ]]; then
  log "already running from the installed plugin"
elif [[ -e $PLUGIN_DIR && $FORCE -eq 0 ]]; then
  echo "Plugin exists: $PLUGIN_DIR. Use omarchy plugin update rafi.agents, or --force to back up and replace it." >&2
  exit 1
else
  # Clone committed source so native plugin updates can fast-forward it.
  if [[ -n $(git -C "$ROOT" status --porcelain) ]]; then
    echo "Commit source changes before installing; the installer clones committed files." >&2
    exit 1
  fi
  stage=$(mktemp -d)
  trap 'rm -rf -- "$stage"' EXIT
  git clone --quiet --no-hardlinks "$ROOT" "$stage/plugin"
  origin=$(git -C "$ROOT" remote get-url origin)
  git -C "$stage/plugin" remote set-url origin "$origin"
  omarchy plugin validate "$stage/plugin"
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  if [[ -e $PLUGIN_DIR ]]; then
    backup_root="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/plugin-backups"
    mkdir -p "$backup_root"
    backup=$(mktemp -d "$backup_root/rafi.agents.XXXXXXXX")
    mv -- "$PLUGIN_DIR" "$backup/plugin"
    log "previous plugin backed up: $backup/plugin"
  fi
  mv -- "$stage/plugin" "$PLUGIN_DIR"
  log "installed git-managed plugin: $PLUGIN_DIR"
fi

if (( APPLY_LAYOUT )); then
  if [[ ! -f $SHELL_JSON ]]; then
    echo "shell.json not found at $SHELL_JSON; skipping layout." >&2
  else
    backup="$SHELL_JSON.bak.$(date +%s)"
    cp "$SHELL_JSON" "$backup"
    log "backed up shell.json -> $backup"
    PLUGIN_ID="$PLUGIN_ID" LEGACY_PLUGIN_ID="${USER_NAME}.agents" python3 - "$SHELL_JSON" <<'PY'
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
        if eid in ("omarchy.agents", plugin_id, os.environ["LEGACY_PLUGIN_ID"]):
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

  omarchy shell shell rescanPlugins
EOF
fi
