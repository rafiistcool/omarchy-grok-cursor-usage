# Agents (Omarchy bar plugin)

Stacked leftover meters and remaining-over-time charts for AI coding
subscriptions.

## Source vs installed copy

| | Path |
|---|---|
| **Source (edit here)** | `plugin/` in this repository |
| **Runtime (Omarchy loads this)** | `~/.config/omarchy/plugins/$USER.agents/` |

`install.sh` copies **from** `plugin/` **to** the runtime directory. That
copy is **not** a git repository and is **not** kept in sync automatically.

- Editing `~/.config/omarchy/plugins/solary.agents/` (or any
  `$USER.agents`) does **not** update this repo.
- `omarchy plugin update` only works for plugins installed with
  `omarchy plugin add <git-url>`. This project uses `install.sh` instead,
  so you must reinstall or copy files manually after pulling.

Treat **`plugin/` as the only place to make durable changes.**

## Development workflow

From the repository root:

```bash
# 1. Edit sources
$EDITOR plugin/Panel.qml

# 2. Install to ~/.config/omarchy/plugins/$USER.agents/
./install.sh --force

# 3. Reload the shell
omarchy restart shell

# 4. Commit and push when happy
git add plugin/
git commit -m "…"
git push
```

After `git pull`, run `./install.sh --force` again to refresh the installed
plugin.

Collectors under `collectors/` are installed separately by the same
`install.sh` into `~/.config/omarchy/agents/` (also one-way copy).

## Placeholder ids in source

Files in `plugin/` use the placeholder **`yourname.agents`** (for example
`moduleName` / `ipcTarget` in `Panel.qml`, and `"id"` in `manifest.json`).

`install.sh` rewrites `yourname.` → `$USER.` when copying. Do **not**
commit your login name into `plugin/` — keep `yourname.agents`.

## If you edited the installed copy by mistake

Copy changed files back into `plugin/`, then restore placeholders:

```bash
cp ~/.config/omarchy/plugins/solary.agents/Panel.qml plugin/
sed -i 's/solary\./yourname./g' plugin/Panel.qml
# repeat for other touched files; skip manifest.json id if already yourname.agents
```

Verify with `git diff plugin/` before committing.

## More

Install, screenshots, collectors, and adding agents: [../README.md](../README.md).
