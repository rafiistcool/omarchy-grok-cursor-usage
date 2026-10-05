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
`collectors/run-usage-update` discovers additions there before packaged
collectors. Bundled collectors win over user copies with the same id, so
legacy copies cannot shadow updated code. Give the executable a valid shebang;
the runner executes it directly and allows 90 seconds per collector.

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
- `recentDays` — recent seven-day token history as `{ date: "YYYY-MM-DD", messageCount: <tokens> }`.
  Despite its name, `messageCount` holds the day's token total.
- `modelUsage` — model ids mapped to recorded-history totals:
  `{ inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens }`.
  The panel shows the top four models by the sum of these fields. Count cached
  tokens separately from uncached input and include reasoning in output only
  once. These totals are not limited to the current quota cycle.
- Leave `recentDays` empty and `modelUsage` as `{}` when token data is unavailable.
  Set `hasPromptStats: false` when prompt/session counts are unavailable.

Do not put authentication tokens, emails, or cookie values in the record.

## 3. Optional mark

Drop `plugin/assets/<id>.svg`. A dark-on-light twin is `<id>-light.svg`.
Without a file, the bar uses the generic agents glyph.

## 4. Remaining history (optional)

`plugin/history.py` appends leftover samples for `grok`, `grokbot`, `cursor`,
`codex`, and `antigravity` into `~/.local/state/omarchy/agents/history/<id>.json`.
To chart another 7-day+ window, add its id to `AGENT_IDS` there and to the
`FileView` / remaining-history map in `plugin/Main.qml` and `plugin/Panel.qml`.

## 5. Enable it

The collector is picked up on the next panel refresh (`r`, or the 15-minute
timer). To hide one:

```bash
omarchy bar set rafi.agents providers '{
  "grok": { "enabled": true },
  "cursor": { "enabled": true },
  "codex": { "enabled": false }
}' --json
```

The plugin id is always `rafi.agents`. Disabled providers are not polled.
