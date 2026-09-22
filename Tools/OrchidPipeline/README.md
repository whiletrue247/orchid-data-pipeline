# Orchid Discovery

The playlist delivery service for Music 日常. Maintained under **whiletrue247**.

The server discovers current catalog entries, validates full track lists, and publishes
immutable JSON. The iPhone downloads verified data and ranks playlists locally; it does
not crawl historical catalog pages while a listener waits. Audio resolution/playback is
separate and is not proxied, downloaded, or hosted by this repository.

## Delivery architecture

`scheduled sync → bounded upstream adapters → normalized source state → availability/age/dedup gates → immutable objects → manifest + health → CDN → iPhone cache + ranking`

- Refresh the three current chart/latest/featured heads plus one rotating genre head.
  Historical vector pages remain in migration state but are excluded from discovery.
- Only publish playlists with a nonempty validated track resource. Every published
  collection has a working JSON dependency; content hashes, IDs and counts are checked.
  This validates metadata, not the global playability or licensing of every audio track.
- Classify HTTP 200 application errors. Deleted/empty collections get a 24-hour retry
  cooldown, and their cached track records are removed. Transient failures can reuse
  previously verified records only within the 48-hour validation window.
- Deduplicate identical track sets and use actual track counts in subtitles. Source IDs
  remain stable so local favorites survive migration. A shared title is not an identity.
- Run every two hours: at most four vector reads, twelve playlist reads, and 24 total
  requests including retries. Space requests by at least one second. These conservative
  starting limits follow an observed 429 during the September 22 live probe; adjust from
  measured completion/freshness, not from the desire for a bigger catalog.
- Persist Retry-After across runs. A cooldown run makes zero upstream calls. Never switch
  accounts, hosts or endpoints to evade upstream limits.
- At least 20 verified playlists must survive before replacing the manifest. A failed
  publication retains the previous deployment. `health.json` records validation time,
  exclusions, degraded state and the served content version even when content is unchanged.
- The catalog is finite. The app can append new ranked cycles without pretending every
  card is unique. A small healthy feed is preferred during recovery; coverage expands as
  later bounded syncs validate more entries.

## Validation and operation

```sh
ruby Tools/OrchidPipeline/test/orchid_pipeline_test.rb
ORCHID_SOURCE_URL='<configured upstream>' ruby Tools/OrchidPipeline/bin/build_orchid \
  --output .build/orchid/public --state .build/orchid/source-state.json \
  --summary .build/orchid/summary.json --verified-only --max-pages 1 \
  --vector-batch-size 4 --vector-request-budget 4 --playlist-batch-size 12 \
  --request-budget 24 --track-max-age 48 --minimum-collections 20
ruby Tools/OrchidPipeline/bin/validate_snapshot .build/orchid/public
```

Ruby 3.3 with Minitest is used in CI. One serialized workflow is the publisher. Public
objects and normalized source state are checkpointed on `orchid-data`; only `public/`
is deployed to Pages. This is a public repository: state must contain no credentials,
session cookies or user behavior. The source URL is supplied as a repository secret.

Current delivery is GitHub Pages for development validation. Production hosting and
content provider contracts must be reviewed before commercial distribution. The static
contract is portable to object storage/CDN; it does not require changing the iOS ranking
engine. Provider authorization and API terms are separate from a successful HTTP response.

## Failure and recovery

- Failed sync / malformed JSON / too few eligible playlists: retain last manifest;
  investigate the Action annotation and health age. Do not publish an empty feed.
- 429: obey persisted cooldown; no immediate retry loop. Quality gates still apply.
- Outdated feed (>24 hours without a successful validation): degraded operating condition;
  investigate GitHub email verification, disabled jobs, source limits and parse failures.
- Bad release: redeploy the preceding `orchid-data` public snapshot with force_deploy.
  Immutable objects keep previous manifests resolvable. Retain old objects until a
  separately designed retention/rollback window permits garbage collection.

The September 22 migration starts with the successful bounded local probe and its active
upstream cooldown. The first cloud run publishes that validated snapshot without crawling.
