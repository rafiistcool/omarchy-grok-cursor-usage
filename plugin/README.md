# Agents (Omarchy bar plugin)

This directory contains the QML display, assets, and history recorder.
The installable plugin is the **repository root**, whose `manifest.json`
points at `plugin/Panel.qml`.

Install and update through Omarchy:

```bash
omarchy plugin add https://github.com/rafiistcool/omarchy-grok-cursor-usage.git --enable
omarchy plugin update rafi.agents
```

`rafi.agents` is a stable plugin id, not a username placeholder.
`Main.qml` resolves `../collectors/run-usage-update` relative to itself, so
collectors always come from the same checkout as the widget. No generated
files, username substitution, or external collector installation is needed.

For development, edit the source repository, run its tests and
`omarchy plugin validate .`, commit, then use `./install.sh --force` to
replace the installed checkout with a backup. Apply it with
`omarchy shell shell rescanPlugins`. Uncommitted installed edits can prevent
native updates; commit them in your source repository first.

See [../README.md](../README.md) for migration, collector precedence, and settings.
