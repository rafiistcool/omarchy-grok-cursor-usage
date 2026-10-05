# Agents (Omarchy bar plugin)

This directory contains the QML display, assets, and history recorder.
The installable plugin is the **repository root**, whose `manifest.json`
points at `plugin/Panel.qml`.

The popup stacks every enabled provider that has quota, balance, or activity
data. Quotas and remaining charts come first; **TOKENS BY DAY** and
**TOKENS BY MODEL** follow when the collector supplies their data. Daily
rows highlight today in the local timezone. Model rows show the top four
models across collector-supplied history, with input/output/cache counts on
hover. They do not identify the model currently running in an app.

Grok, Grok Bot, Cursor, and Antigravity currently supply quotas only. Codex
supplies local token history; Claude and Fireworks use the packaged Omarchy
collectors. Missing token data leaves those sections hidden.

Install and update through Omarchy:

```bash
omarchy plugin add https://github.com/rafiistcool/omarchy-grok-cursor-usage.git --enable
omarchy plugin update rafi.agents
```

`rafi.agents` is a stable plugin id, not a username placeholder.
`Main.qml` resolves `../collectors/run-usage-update` relative to itself, so
collectors always come from the same checkout as the widget. No generated
files, username substitution, or external collector installation is needed.

## Backend and display

- `UsageService.qml` is a singleton backed by `Main.qml`, shared across monitor
  bars. It discovers usage records, runs collectors, watches quota history,
  schedules retries, and optionally merges synced token statistics.
- `Agent.qml` watches one usage JSON file. `Panel.qml` renders each provider's
  quotas, chart, and token rows; daily tooltips receive that row's provider.
- `history.py` records long-window remaining percentages, merges plateaus,
  and retains up to 21 days / 500 points per series.
- The backend continues collecting while the popup is closed. Countdown
  updates and chart geometry pause until it is opened.

The data contract is in [../docs/adding-an-agent.md](../docs/adding-an-agent.md).
Adding token tables requires only collector data; adding a new remaining
chart id also requires registration in the recorder, backend, and panel.

## Development and reloads

For development, edit the source repository, run its tests and
`omarchy plugin validate .`, commit, then use `./install.sh --force` to
replace the installed checkout with a backup. Apply it with
`omarchy shell shell rescanPlugins`. Uncommitted installed edits can prevent
native updates; commit them in your source repository first.

If a rescan leaves the old QML layout visible, run `omarchy restart shell`.
The source and installed checkouts are separate; editing this source tree
does not update the desktop until the committed change is installed.

```bash
python3 -m unittest discover -s tests -v
omarchy plugin validate .
# After committing:
./install.sh --force
omarchy shell shell rescanPlugins
```

The panel regression test loads the real panel with isolated fake collectors.
It verifies separate provider counts, cache-token totals, token-only provider
visibility, zero-token days, top-four ordering, long-name elision, and
scrolling. It needs Omarchy, Quickshell, and an active Wayland session; other
tests skip their runtime-specific checks when those tools are unavailable.

See [../README.md](../README.md) for migration, collector precedence, and settings.
