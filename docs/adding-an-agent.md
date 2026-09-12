# Adding an agent

The panel never talks to Grok, Cursor, Codex, or anyone else. It only
renders JSON files in `~/.local/state/omarchy/agents/usage/<id>.json`.
A new subscription is a collector that prints one of those files.

## 1. Write a collector

Name it `omarchy-agent-usage-<id>` (`<id>` is the record `id`, for example
`grok`). It must print one JSON object to stdout. Optional flags:

| Flag | Meaning |
|---|---|
| `--force` | ignore caches, hit the network |
| `--limits-only` | refresh rate limits / plan, skip walking session logs |
| `--write` | also write the record to the usage directory |

Install it executable at `~/.config/omarchy/agents/omarchy-agent-usage-<id>`.
`run-usage-update` prefers that directory over packaged collectors.

## 2. Record contract

```json
{
  "schemaVersion": 1,
  "id": "myagent",
  "name": "My Agent",
  "updatedAt": "2026-08-24T00:00:00Z",
  "ready": true,
  "hasLocalStats": false,
  "hasPromptStats": false,
  "scope": "account",
  "tierLabel": "Pro",
  "usageStatusText": "",
  "authHelpText": "",
  "limits": [
    {
      "label": "Weekly limit",
      "title": "Weekly",
      "percent": 0.42,
      "startsAt": "2026-08-18T00:00:00Z",
      "resetsAt": "2026-08-25T00:00:00Z"
    }
  ],
  "balance": null,
  "todayPrompts": 0,
  "todaySessions": 0,
  "todayTotalTokens": 0,
  "todayTokensByModel": {},
  "recentDays": [],
  "totalPrompts": 0,
  "totalSessions": 0,
  "activeDays": 0,
  "activeDates": [],
  "modelUsage": {}
}
```

Field notes:

- `id` — file stem and settings key. Lowercase, no spaces.
- `percent` — **used** fraction in `0..1` (0.42 means 42% used, 58% left).
- `title` — `Weekly` / `Monthly` (or any label). Session / 5-hour windows are
  shown as meters but **not** charted. Remaining charts start at 7-day windows.
- `startsAt` / `resetsAt` — ISO-8601. Needed for even-burn pace and the
  leftover-vs-time chart. If `startsAt` is missing, a Weekly/Monthly title
  infers it from `resetsAt`.
- `scope`: `"account"` means stats are account-global (do not sum across
  synced machines). Omit or use another value for machine-local transcripts.
- `authHelpText` — shown when the user needs to sign in. Leave empty when
  `ready` is true.
- `balance` — optional prepaid ledger `{ remaining, funded, spent, currency, estimated }`.

Do not put tokens, emails, or cookie values in the record. Percents and
plan names are enough.

Example in this repo: `omarchy-agent-usage-grokbot` reads the signed-in Cursor
session and reports the weekly Sand pool for Grok Bot as a separate allowance
from SuperGrok.

## 3. Optional mark

Drop `plugin/assets/<id>.svg`. A dark-on-light twin is `<id>-light.svg`.
Without a file, the bar uses the generic agents glyph.

## 4. Remaining history (optional)

`plugin/history.py` appends leftover samples for `grok`, `grokbot`, `cursor`,
and `codex` into `~/.local/state/omarchy/agents/history/<id>.json`. To chart
another 7-day+ window, add its id to `AGENT_IDS` there and to the
`FileView` / `remainingHistory` map in `plugin/Main.qml` and
`plugin/Panel.qml`.

## 5. Enable it

The collector is picked up on the next panel refresh (`r`, or the 15-minute
timer). To hide one:

```bash
omarchy bar set yourname.agents providers '{
  "grok": { "enabled": true },
  "cursor": { "enabled": true },
  "codex": { "enabled": false }
}' --json
```

Use the plugin id `install.sh` created (`$USER.agents`).
