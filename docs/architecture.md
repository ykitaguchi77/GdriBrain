# Architecture

## Overview

```
[iPhone — single source of compute]
 ├─ SwiftUI App
 │   ├─ Memo / Notes / Graph / Settings
 │   ├─ NotesPipeline ─┬─▶ AnthropicClient (Haiku/Sonnet/Opus)
 │   │                 └─▶ DriveAPI (drive.file scope)
 │   └─ SwiftData index (cache of Drive contents)
 └─ Share Extension
     ├─ VisionKit OCR (on-device)
     └─ App Group queue → main app drains via NotesPipeline
```

No servers, no Tailscale, no Mac.

## Why this shape

We previously had a Mac-side FastAPI backend that called Claude through the
`claude` CLI under a Max subscription. That works, but the operational cost
(Tailscale, launchd, caffeinate, network reliability) became the dominant
friction. The Anthropic API used directly from iOS removes every one of
those moving parts in exchange for a per-call cost.

## Folder layout on Drive

```
GdriBrain/
├── notes/        (one .md per note, YAML frontmatter)
└── attachments/  (PNGs referenced from md)
```

Flat is intentional. Subfolder hierarchies inevitably break the moment a note
touches more than one category — and they fight Drive's "search-first"
model. Tags + keywords in YAML carry the categorical signal instead.

## Local index

SwiftData mirrors Drive metadata. We need it for:

1. **Merge candidate lookup** — Jaccard over body + keywords + tags.
   Without the cache, every new note would download all existing md from
   Drive: O(N) API calls per write.
2. **List / Graph** — render the Notes tab without a round trip.
3. **Idempotency** — `clientID` (the Draft id) marks already-processed
   drafts so retries don't double-create.

Drive remains the source of truth. If the index is deleted, it can be
rebuilt by re-reading Drive (not implemented yet — listed in TODOs).

## Tier policy

| Tier      | Model                | Use                                              |
|-----------|----------------------|--------------------------------------------------|
| `cheap`   | `claude-haiku-4-5`   | Title / summary / keyword extraction (per-note)  |
| `default` | `claude-sonnet-4-6`  | Merge decision, related-note picking, summaries  |
| `premium` | `claude-opus-4-7`    | Cluster summaries — only when user opts in       |

Per-call costs at current pricing:
- Haiku 4.5: $1 / $5 per 1M input/output tokens (~$0.005 per ingest)
- Sonnet 4.6: $3 / $15 per 1M (used for the merge JSON, ~$0.005)
- Opus 4.7: $5 / $25 per 1M (Deep summary only)

A typical ingest of one note is two API calls (Haiku + Sonnet), summing to
roughly half a cent. Heavy daily use (~50 notes) is ~$0.25/day.

## Security boundaries

- The Anthropic API key lives in the **main app's Keychain only**
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud sync, no app
  group access).
- The Share Extension can only **enqueue** drafts to the App Group
  container. It cannot read the API key or touch Drive directly.
- The Google refresh token also lives in Keychain (same accessibility) and
  is used only by `DriveAPI.swift` to mint short-lived access tokens.

## Open future work

- Index rebuild from Drive (force-resync after device wipe)
- Periodic "find related" job that asks Sonnet to pick related notes for
  recent additions and persists `IndexedEdge` records
- Streaming for long Opus summaries (current code reads the full response)
