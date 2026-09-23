# Orchid Discovery

Music 日常's metadata supply, maintained on **whiletrue247**. Version 4 preserves
MBPlayer Home's music shelves and ordering, and treats the published catalog as a
verified fallback rather than the entire available inventory.

The product objective is a listener choosing music and successfully starting playback.
Catalog size is a coverage diagnostic. No listening history, cookies, credentials or audio
streams are published. Anonymous MBPlayer recommendations are source selections, not
personal recommendations for the app's listener.

## Two delivery paths

1. **On-demand discovery on iPhone:** read anonymous Taiwan/Traditional Chinese Home,
   preserve section, item position and song preview; expand through discovered music
   vectors using real offsets. The session cursor retains every served playlist ID, so
   scroll never recycles the initial catalog. Complete song lists load when selected.
2. **GitHub prewarming and fallback:** periodically discover current Home/Search,
   prioritize Home selections for full track validation, maintain healthy prior lists,
   publish immutable objects with placement metadata. Source failure can fall back to
   this verified catalog; it is not a pagination ceiling.

The active adapter currently runs in `MusicFeedKit/OrchidDiscoverySource` in the iOS
repository. GitHub Pages is static and does **not** host a dynamic recommendation API.
A shared edge gateway can later implement the same source/cursor contract without changing
feed presentation. A hosting account has not been configured for that service.

The app keeps current-session cards stable. Short foreground returns preserve scroll;
explicit refresh or a long absence starts a new session. Source order owns three of every
four ranking slots, with eligible learned preferences filling at most one. Recently shown
openings and failed content can be lowered. This replaces the old rule that stopped local
cold-start curation after one listening event. The 3:1 mix is an initial product policy,
not a measured optimum or a reproduction of MBPlayer's private algorithm.

## Prewarming pipeline

`Home + Search + vector pages → membership registry → Home-priority hydration + maintenance → verified immutable catalog + health`

- Read Home and Search independently. Exclude podcasts, artists, ads and navigation cards.
  Keep actual Home shelf IDs, titles, section positions and item positions. Two different
  `recommendPlaylists` shelves retain distinct placement, even though their IDs match.
- Replace Home membership only after a successful, nonempty Home parse. Yesterday's
  selections may remain useful catalog candidates, but no longer claim today's Home rank.
- Keep the union of discovered music vectors. Read two vector pages/run, rotating by oldest
  attempt and preferring Asian categories on ties. Continue until actual source exhaustion;
  no three-page cap. The per-run request budget bounds work, not catalog depth.
- Keep candidates for 14 days. Normalize evidenced genre membership, explicit genre labels
  and known chart IDs. A mood or a Chinese playlist title alone does not prove song language.
- Hydrate up to 18 lists/run. Reserve one third for due maintenance, then prioritize current
  Home in source order; remaining capacity balances unverified topics.
- Refresh charts after 6 hours, song-seeded mixes after 24 hours, other lists after 48 hours.
  Previously validated resources can remain eligible for up to 7 days during transient
  failure. `validatedAt` never advances on a failed request.
- Reject mismatched IDs, incomplete lists and unfinished pagination. Source playlist `total`
  can include unavailable entries; it is not the number of playable tracks. HTTP 200 errors,
  deleted lists and zero usable tracks receive a 24-hour tombstone; transient failures back off.
- Deduplicate identical track sets, keeping the highest source placement as representative
  and merging membership evidence. Publish the first three actual tracks as previews.
- Enforce at most 24 HTTP attempts/run and at least two seconds between attempts. Persist
  the two-hour sync cadence and Retry-After across jobs, including manual reruns.
- Require at least 20 verified lists to replace the manifest. A failed gate retains the
  previous manifest and checkpoints failure state. Pages remains the last successful deploy.

The app separately coalesces requests, paces them two seconds apart, caches source responses
and persists upstream cooldowns. Its cursor never invents a Home next page: Home has no
continuation, so expansion uses discovered category routes. Once the source is exhausted,
it shows an explicit refresh action instead of repeating cards. The app's request budget
is per installation; aggregate traffic control belongs to a future shared gateway.

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

`orchid-data` checkpoints normalized state (schema 2) and public objects. Only `public/`
is deployed. Public schema 1 and the Pages URL remain backward compatible; placements
are additive. Schema 1 state migrates from the last verified catalog, not arbitrary caches.

[Manifest](https://whiletrue247.github.io/orchid-data-pipeline/manifest.json) ·
[Health](https://whiletrue247.github.io/orchid-data-pipeline/health.json)

## Operation

Check `publication`, `upstreamFailures`, `validatedPlaylistCount`, `homeObservedCount`,
`homeVerifiedCount`, `homeOpeningMissingIDs`, `refreshDueCollectionCount`, `topicCoverage`,
`retryAfterUntil` and `syncDeferredUntil`. Home coverage exposes whether the fallback
actually contains source recommendations, instead of only reporting a large list count.
`checkedAt` is evaluation time; `generatedAt` is publication time, not a song release date.
GitHub cron can be delayed and is not a real-time freshness guarantee.

Retain immutable objects so saved playlists keep their published references. Rollback
must use a compatible source/state pair; pre-v3 code cannot read schema 2 state.

[Source research](Docs/MBPlayer-2026-09-23.md) documents public observations and their
limits. Metadata validation is not proof every video can play in every region. This
repository does not proxy or host audio.
