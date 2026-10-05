# Adding an agent

The panel never talks to Grok, Cursor, Codex, or anyone else. It only
renders JSON files in `~/.local/state/omarchy/agents/usage/<id>.json`.
A new provider is a collector that prints one of those records. It may supply
quotas, token statistics, a balance, or a combination.

## 1. Write a collector

Name it `omarchy-agent-usage-<id>` (`<id>` is the record `id`, for example
`grok`). It must print one JSON object to stdout. Optional flags:

| Flag | Meaning |
|---|---|
| `--force` | ignore caches, hit the network |
| `--limits-only` | refresh rate limits / plan, reuse recent token statistics where possible |
| `--write` | also write the record to the usage directory |

Install it executable at `~/.config/omarchy/agents/omarchy-agent-usage-<id>`.
`collectors/run-usage-update` discovers additions there before packaged
collectors. Bundled collectors win over user copies with the same id, so
legacy copies cannot shadow updated code. Give the executable a valid shebang;
the runner executes it directly and allows 90 seconds per collector.

`--limits-only` may reuse recently cached token statistics rather than skip
them entirely. Keep the existing statistics in the emitted record so the
display does not lose them. `--write` is optional: the runner writes stdout
atomically and keeps the prior snapshot if the process fails or prints
invalid JSON. Nonzero exit status means collection failed; unavailable auth
can instead be represented by a successful status record with no data.

## 2. Record contract

```json
{
  "schemaVersion": 1,
  "id": "myagent",
  "name": "My Agent",
  "updatedAt": "2026-10-05T12:00:00Z",
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
      "startsAt": "2026-10-01T00:00:00Z",
      "resetsAt": "2026-10-08T00:00:00Z"
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
- `schemaVersion` — currently `1`; the runner checks it and the record's `id`.
- `updatedAt` — snapshot timestamp in ISO-8601, used by the refresh cooldown.
- `ready` — collection status. Provider visibility depends on usable data:
  quotas, a balance, token totals, or recorded activity. `ready` alone does
  not create a visible provider.
- `percent` — **used** fraction in `0..1` (0.42 means 42% used, 58% left).
- `title` — `Weekly` / `Monthly` (or any label). Session / 5-hour windows are
  shown as meters but **not** charted. Remaining charts start at 7-day windows.
- `startsAt` / `resetsAt` — ISO-8601. Needed for even-burn pace and the
  leftover-vs-time chart. If `startsAt` is missing, a Weekly/Monthly title
  infers it from `resetsAt`.
- `scope`: `"account"` means stats are account-global (do not sum across
  synced machines; take the maximum per field). Omit it or use `"device"`
  for machine-local transcripts. Quotas and balances are never merged.
- `hasLocalStats` — whether the collector supplies token/activity statistics.
  Account API token data may set it too; use `scope` to control aggregation.
- `authHelpText` — shown when the user needs to sign in. Leave empty when
  `ready` is true.
- `balance` — optional prepaid ledger `{ remaining, funded, spent, currency, estimated }`.
- `recentDays` — recent seven-day token history as `{ date: "YYYY-MM-DD", messageCount: <tokens> }`.
  Despite its name, `messageCount` holds the day's token total.
- `modelUsage` — model ids mapped to recorded-history totals:
  `{ inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens }`.
  The panel shows the top four models by the sum of these fields. Count cached
  tokens separately from uncached input and include reasoning in output only
  once. These totals cover the history available to the collector, which may
  be shorter than the account's lifetime. They are not tied to the chart
  range or quota cycle.
- `todayTotalTokens` / `todayTokensByModel` — today's total and totals by
  model; use the same local-date convention as `recentDays`.
- `todayPrompts` / `todaySessions` — counts shown in today's tooltip only
  when `hasPromptStats` is not false. `totalPrompts` / `totalSessions`
  describe the collector's recorded history.
- `activeDates` — dates with recorded activity, used to merge active days
  across devices; `activeDays` is the corresponding count.
- `retryAdvised` — optional `true` after a transport failure to request an
  early retry. Clear it on success. Retries start after 30 seconds and back
  off to the refresh interval, with a 15-minute maximum.
- Leave `recentDays` empty and `modelUsage` as `{}` when token data is unavailable.
  Set `hasPromptStats: false` when prompt/session counts are unavailable.

Do not put authentication tokens, emails, or cookie values in the record.

For token data, populate the fields above, for example:

```json
{
  "hasLocalStats": true,
  "hasPromptStats": false,
  "scope": "device",
  "todayTotalTokens": 155,
  "todayTokensByModel": { "my-model": 155 },
  "recentDays": [{ "date": "2026-10-05", "messageCount": 155 }],
  "activeDays": 1,
  "activeDates": ["2026-10-05"],
  "modelUsage": {
    "my-model": {
      "inputTokens": 100,
      "outputTokens": 20,
      "cacheReadInputTokens": 30,
      "cacheCreationInputTokens": 5
    }
  }
}
```

Merge these fields into the full record; this snippet alone is not a valid
collector response. Daily bars scale to that provider's busiest day, while
model rows scale to its heaviest model. A provider can show token tables
without any quota windows.

## 3. Optional mark

Drop `plugin/assets/<id>.svg`. A dark-on-light twin is `<id>-light.svg`.
The popup loads the provider's SVG and colorizes it to the theme foreground;
include a mark for custom providers to avoid a missing popup icon. Grok and
Codex use the Omarchy icon font. Unknown provider ids use the generic bar glyph.

## 4. Remaining history (optional)

`plugin/history.py` appends leftover samples for `grok`, `grokbot`, `cursor`,
`codex`, and `antigravity` into `~/.local/state/omarchy/agents/history/<id>.json`.
To chart another 7-day+ window, add its id to `AGENT_IDS`, add a history
`FileView` in `plugin/Main.qml` that calls `applyHistory`, and expose that
history in `plugin/Panel.qml`. Include the id in `remainingSeriesFor`,
`firstChartProviderIndex`, and the `ProviderBlock` chart visibility check.
Token tables and quota meters
need no chart registration. History retains up to 21 days and 500 points per
series; short session windows remain meters only.

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

The plugin id is always `rafi.agents`. The widget does not poll disabled providers.

## 6. Verify and install

Run `python3 -m unittest discover -s tests -v` and `omarchy plugin validate .`.
Check zero-token days, the model/cache split, missing token data, and quota
reset dates using a representative record. Commit bundled changes before
running `./install.sh --force`, then rescan with
`omarchy shell shell rescanPlugins`. If cached QML still shows the old layout,
run `omarchy restart shell`. Usage records and history are runtime data and
must not be committed.
