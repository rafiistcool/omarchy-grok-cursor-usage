#!/usr/bin/env python3
"""Append Grok/Cursor/Codex remaining-quota samples for the agents panel chart.

Reads the latest usage JSON written by omarchy-agent-usage-update and merges
unchanged remaining values into a plateau (t .. until) so idle 15-minute
polls do not pile up duplicate points.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True

AGENT_IDS = ("grok", "cursor", "codex", "antigravity")
REMAINING_DECIMALS = 4
MAX_AGE_DAYS = 21
MAX_POINTS = 500
# Charts skip 5h/session pools. A window has to last about a week.
MIN_CHART_WINDOW = timedelta(days=7) - timedelta(hours=2)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def slug(text: str, fallback: str) -> str:
    raw = "".join(ch.lower() if ch.isalnum() else "-" for ch in text.strip())
    while "--" in raw:
        raw = raw.replace("--", "-")
    raw = raw.strip("-")
    return raw or fallback


def quantize(value: float) -> float:
    return round(max(0.0, min(1.0, value)), REMAINING_DECIMALS)


def state_dir() -> Path:
    root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return root / "omarchy/agents"


def inferred_window_span(title: str, starts: str, resets: str) -> timedelta | None:
    start = parse_iso(starts)
    end = parse_iso(resets)
    if start and end and end > start:
        return end - start
    low = (title or "").lower()
    if "month" in low or "30-day" in low:
        return timedelta(days=30)
    if "week" in low or "7-day" in low or "seven" in low:
        return timedelta(days=7)
    return None


def limit_is_chartable(title: str, starts: str, resets: str) -> bool:
    span = inferred_window_span(title, starts, resets)
    return span is not None and span >= MIN_CHART_WINDOW


def series_from_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    limits = record.get("limits") or []
    out: list[dict[str, Any]] = []
    if not isinstance(limits, list):
        return out
    for i, entry in enumerate(limits):
        if not isinstance(entry, dict):
            continue
        try:
            percent = float(entry.get("percent"))
        except (TypeError, ValueError):
            continue
        if percent < 0 or not (percent == percent):  # NaN
            continue
        title = str(entry.get("title") or entry.get("label") or f"Limit {i + 1}")
        starts = str(entry.get("startsAt") or "")
        resets = str(entry.get("resetsAt") or "")
        if not starts and resets:
            end = parse_iso(resets)
            low = title.lower()
            days = 7 if "week" in low else 30 if "month" in low else 0
            if end and days:
                starts = iso(end - timedelta(days=days))
        if not limit_is_chartable(title, starts, resets):
            continue
        out.append({
            "id": slug(title, f"limit-{i}"),
            "title": title,
            "remaining": quantize(1.0 - percent),
            "percent": round(percent, REMAINING_DECIMALS),
            "startsAt": starts,
            "resetsAt": resets,
        })
    return out


def window_key(point: dict[str, Any]) -> str:
    return f"{point.get('startsAt') or ''}|{point.get('resetsAt') or ''}"


def trim_points(points: list[dict[str, Any]], now: datetime) -> list[dict[str, Any]]:
    cutoff = now - timedelta(days=MAX_AGE_DAYS)
    kept: list[dict[str, Any]] = []
    for point in points:
        end = parse_iso(point.get("until") or point.get("t")) or now
        if end >= cutoff:
            kept.append(point)
    if len(kept) > MAX_POINTS:
        kept = kept[-MAX_POINTS:]
    return kept


def merge_sample(points: list[dict[str, Any]], sample: dict[str, Any], now_iso: str) -> list[dict[str, Any]]:
    point = {
        "t": now_iso,
        "remaining": sample["remaining"],
        "percent": sample["percent"],
        "startsAt": sample["startsAt"],
        "resetsAt": sample["resetsAt"],
    }
    if points:
        last = points[-1]
        last_end = parse_iso(last.get("until") or last.get("t"))
        incoming = parse_iso(now_iso)
        same_window = window_key(last) == window_key(point)
        same_remaining = last.get("remaining") == point["remaining"]
        if last_end and incoming and incoming < last_end:
            return points
        if same_window and same_remaining:
            last["until"] = now_iso
            return points
    points.append(point)
    return points


def update_agent(usage_path: Path, history_path: Path) -> None:
    record = load_json(usage_path)
    if not record:
        return
    samples = series_from_record(record)
    if not samples:
        return
    fetched = parse_iso(record.get("updatedAt")) or utcnow()
    now_iso = iso(fetched)
    hist = load_json(history_path)
    existing = {str(s.get("id")): s for s in (hist.get("series") or []) if isinstance(s, dict)}
    series_out: list[dict[str, Any]] = []
    for sample in samples:
        prev = existing.get(sample["id"]) or {}
        points = list(prev.get("points") or [])
        points = [p for p in points if isinstance(p, dict) and "t" in p]
        points = merge_sample(points, sample, now_iso)
        points = trim_points(points, fetched)
        series_out.append({
            "id": sample["id"],
            "title": sample["title"],
            "points": points,
        })
    payload = {
        "schemaVersion": 1,
        "id": str(record.get("id") or usage_path.stem),
        "updatedAt": now_iso,
        "series": series_out,
    }
    tmp = history_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(history_path)


def main() -> int:
    root = state_dir()
    usage_dir = root / "usage"
    history_dir = root / "history"
    history_dir.mkdir(parents=True, exist_ok=True)
    lock_path = history_dir / ".lock"
    lock_fh = open(lock_path, "a+", encoding="utf-8")
    try:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    for agent in AGENT_IDS:
        usage_path = usage_dir / f"{agent}.json"
        if usage_path.is_file():
            update_agent(usage_path, history_dir / f"{agent}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
