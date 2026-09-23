# Orchid Discovery

Music 日常's metadata service, maintained on **whiletrue247**. Version 3 follows
MBPlayer's current Home/Search surfaces and genre lists, then validates complete
track lists before publishing. The static contract and Pages URL remain compatible
with the installed iOS client.

The product objective is a listener choosing music and successfully starting playback.
Catalog size is a coverage diagnostic, not the product KPI. Orchid supplies meaningful
songs, category evidence and verified playlist metadata; the device owns personal ranking
and playback. No listening history, cookies, credentials or audio streams are published.

## Flow

`MBPlayer Home + Search + rotating genres → persistent candidate registry → balanced hydration + maintenance → integrity/dedup gates → immutable JSON + manifest/health → iPhone`

- Read Home and Search independently. Collect real playlist cards from music carousels,
  skip artists, podcasts, ads and navigation wrappers. Anonymous recommendation mixes are
  source candidates, not personal recommendations for the app's listener.
- Preserve the union of discovered genres; Search displays rotating subsets. Two genre
  pages per run rotate by oldest attempt, with at most three pages per genre (24 items/page).
  This bounded exploration includes useful items beyond the first 12 without recrawling
  the entire historical featured archive.
- Keep candidate membership for 14 days, so a random shelf change cannot remove a healthy
  playlist overnight. Normalize only evidenced source tags, genre membership and chart IDs.
- Hydrate up to 18 lists/run. Reserve one third for maintenance, then balance new coverage
  across topics. Sort by last attempt rather than advancing an index into a shrinking list.
- Refresh charts after 6 hours, short song-seeded mixes after 24 hours, other lists after
  48 hours. A temporarily failing but previously validated resource may remain eligible
  up to 7 days; `refreshDueCollectionCount` exposes that grace, without falsifying its age.
  Metadata validation is not proof every video will play in every region.
- HTTP 200 errors/deletion/zero usable tracks create a 24-hour tombstone; transient errors
  use bounded backoff. Mismatched IDs, unfinished pagination and truncated payloads are
  rejected. Source `total` can include unavailable items and is not the usable track count.
- Publish all complete, eligible lists. Merge metadata when identical track sets are
  deduplicated; preserve source IDs and previously published immutable resources.
- Publish the first three actual tracks as `previewTracks`. These previews cannot substitute
  for complete track resources; the old client safely ignores the additional optional field.
- Enforce at most 24 HTTP attempts per run, at least two seconds apart. Persist a two-hour
  sync cadence even for manual reruns, plus upstream Retry-After across jobs. Never rotate
  hosts/accounts or change endpoints to bypass a source rate limit.
- At least 20 verified lists are needed to replace the manifest. A failed gate retains the
  previous manifest and checkpoints state. The failed Action is authoritative for that failure;
  Pages remains the last successful deployment. `health.json` in the checkpoint records failure.

## Running

Ruby 3.3+ with Minitest. The serialized GitHub Action is the only production writer.

```sh
ruby Tools/OrchidPipeline/test/orchid_pipeline_test.rb
ruby Tools/OrchidPipeline/test/discovery_sync_test.rb
ORCHID_SOURCE_URL='https://www.mbplayer.com' ruby Tools/OrchidPipeline/bin/sync_discovery \
  --output .build/orchid/public --state .build/orchid/source-state.json \
  --summary .build/orchid/summary.json
ruby Tools/OrchidPipeline/bin/validate_snapshot .build/orchid/public
```

The `orchid-data` branch checkpoints normalized state (schema 2) and public objects.
Only `public/` is deployed. Schema 1 state migrates using the last verified published
catalog; unverified legacy track caches are not certified by migration. Old code remains
for migration/regression tests, but the Action now runs `sync_discovery`.

Pages: https://whiletrue247.github.io/orchid-data-pipeline/manifest.json
Health: https://whiletrue247.github.io/orchid-data-pipeline/health.json

## Operation and rollback

Check `publication`, `upstreamFailures`, `failures`, `validatedPlaylistCount`,
`refreshDueCollectionCount`, `topicCoverage`, `retryAfterUntil` and `syncDeferredUntil`.
`checkedAt` means the job evaluated the catalog, not that it refetched every playlist.
`generatedAt` is publication time, never a song release date. GitHub schedule execution
can be delayed; the cron expression is not a real-time freshness guarantee.

Rollback must restore **both source code and the matching state/public checkpoint**.
The old builder cannot read schema 2; reverting only the code is not a safe rollback.
Retain immutable objects until a separately approved retention policy permits removal.

[September 23 source research](Docs/MBPlayer-2026-09-23.md) records the observations and
limits behind this implementation. Audio provider authorization and commercial distribution
remain separate from metadata delivery. This repository does not proxy or host audio.
