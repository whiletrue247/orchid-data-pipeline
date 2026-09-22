# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/orchid_pipeline"

class OrchidPipelineTest < Minitest::Test
  def test_parser_matches_orchid_contract
    root = JSON.parse(<<~JSON)
      {
        "getVector": {
          "items": [
            {
              "type": "playlist",
              "ref": "playlist-1",
              "title": "Taiwan Hits",
              "size": 24,
              "thumbnailHQ": "//i.ytimg.com/vi/abc/maxresdefault.jpg"
            }
          ]
        }
      }
    JSON

    collection = OrchidPipeline::PayloadParser.collections(root).first

    assert_equal("playlist-1", collection.fetch("id"))
    assert_equal("24 首", collection.fetch("subtitle"))
    assert_equal("https://i.ytimg.com/vi/abc/maxresdefault.jpg", collection.fetch("thumbnailURL"))
    assert_equal({ "width" => 1280, "height" => 720 }, collection.fetch("thumbnailSize"))
  end

  def test_vector_discovery_deduplicates_and_ignores_artist_vectors
    root = {
      "items" => [
        { "type" => "genre", "ref" => "vector_custom" },
        { "type" => "genre", "ref" => "vector_artists_zh" },
        {
          "apiInfo" => {
            "funcName" => "getVector",
            "arguments" => { "vectorId" => "vector_custom" }
          }
        }
      ]
    }

    assert_equal(["vector_custom"], OrchidPipeline::PayloadParser.vector_ids(root))
  end

  def test_parser_rejects_unsafe_artwork_and_malformed_youtube_ids
    root = {
      "getPlaylist" => {
        "items" => [
          {
            "type" => "music",
            "t" => "yt",
            "f" => "../../escape",
            "tt" => "Unsafe",
            "thumbnailHQ" => "javascript:alert(1)"
          },
          {
            "type" => "music",
            "t" => "yt",
            "f" => "valid_id-01",
            "tt" => "Safe",
            "thumbnailHQ" => "javascript:alert(1)"
          }
        ]
      }
    }

    tracks = OrchidPipeline::PayloadParser.tracks(root)

    assert_equal(1, tracks.length)
    assert_equal("valid_id-01", tracks.first.fetch("id"))
    assert_equal("https://i.ytimg.com/vi/valid_id-01/mqdefault.jpg", tracks.first.fetch("thumbnailURL"))
  end

  def test_first_build_then_conditional_build_reuses_payloads
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      first_launches = []
      transport.handler = lambda do |request|
        first_launches << request.fetch(:query).fetch("firstLaunch")
        response_for(request, conditional: false)
      end

      first = build(transport, output, state, now: Time.utc(2026, 7, 10, 8, 16, 0))
      assert_equal(true, first.fetch("changed"))
      assert_equal(1, first.fetch("collectionCount"))
      assert_equal(1, first.fetch("trackCount"))
      assert_equal(1, first_launches.uniq.length)
      manifest_before = File.read(File.join(output, "manifest.json"))
      manifest = JSON.parse(manifest_before)
      catalog_path = File.join(output, manifest.dig("catalog", "path"))
      assert_equal(
        manifest.dig("catalog", "sha256"),
        Digest::SHA256.hexdigest(File.binread(catalog_path))
      )
      state_before = File.read(state)

      transport.handler = ->(request) { response_for(request, conditional: true) }
      second = build(transport, output, state, now: Time.utc(2026, 7, 10, 14, 16, 0))

      assert_equal(false, second.fetch("changed"))
      assert_equal(2, second.fetch("notModifiedCount"))
      assert_equal(manifest_before, File.read(File.join(output, "manifest.json")))
      assert_equal(state_before, File.read(state))
      assert(transport.requests.any? { |request| request[:etag] == '"vector-etag"' })
      assert(transport.requests.any? { |request| request[:etag] == '"playlist-etag"' })

      File.write(catalog_path, OrchidPipeline::CanonicalJSON.pretty(JSON.parse(File.read(catalog_path))))
      repaired = build(transport, output, state, now: Time.utc(2026, 7, 10, 20, 16, 0))
      repaired_manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      repaired_path = File.join(output, repaired_manifest.dig("catalog", "path"))

      assert_equal(true, repaired.fetch("changed"))
      assert_equal(
        repaired_manifest.dig("catalog", "sha256"),
        Digest::SHA256.hexdigest(File.binread(repaired_path))
      )
    end
  end

  def test_quality_gate_does_not_replace_last_known_good_manifest
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      transport.handler = ->(request) { response_for(request, conditional: false) }
      build(transport, output, state)
      manifest_before = File.read(File.join(output, "manifest.json"))

      assert_raises(OrchidPipeline::QualityGateError) do
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 1,
          max_pages_per_vector: 1,
          minimum_collections: 2,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal(manifest_before, File.read(File.join(output, "manifest.json")))
    end
  end

  def test_vector_batches_rotate_and_accumulate_cached_collections
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      requested_vectors = []
      transport.handler = lambda do |request|
        if request.fetch(:path) == "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        elsif request.fetch(:path) == "/api/getVector"
          vector_id = request.fetch(:query).fetch("vectorId")
          requested_vectors << vector_id
          json_result(
            {
              "getVector" => {
                "items" => [{ "type" => "playlist", "ref" => vector_id, "title" => vector_id }]
              }
            },
            etag: "\"#{vector_id}\""
          )
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      2.times do |index|
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 2,
          max_pages_per_vector: 1,
          vector_batch_size: 1,
          playlist_batch_size: 0,
          minimum_collections: 1,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) + (index * 6 * 60 * 60) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal(2, requested_vectors.uniq.length)
      assert_equal(
        ["vector_latest_zh", "vector_systemlist_zh_top_charts"].sort,
        requested_vectors.sort
      )
      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      catalog = JSON.parse(File.read(File.join(output, manifest.dig("catalog", "path"))))
      assert_equal(2, catalog.fetch("collections").length)
    end
  end

  def test_catalog_merges_reliable_metadata_for_duplicate_vector_membership
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      transport.handler = lambda do |request|
        case request.fetch(:path)
        when "/api/page/getSearch"
          json_result(
            {
              "getPage" => {
                "items" => [
                  { "type" => "genre", "ref" => "vector_systemlist_zh_genre_cpop" },
                  { "type" => "genre", "ref" => "vector_systemlist_zh_mood_party" }
                ]
              }
            },
            etag: '"discovery"'
          )
        when "/api/getVector"
          json_result(
            {
              "getVector" => {
                "items" => [{ "type" => "playlist", "ref" => "shared", "title" => "Shared Playlist" }]
              }
            },
            etag: "\"#{request.fetch(:query).fetch("vectorId")}\""
          )
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      OrchidPipeline::Builder.new(
        transport: transport,
        output_directory: output,
        state_path: state,
        max_vectors: 4,
        max_pages_per_vector: 1,
        vector_batch_size: 4,
        playlist_batch_size: 0,
        minimum_collections: 1,
        first_launch: "fixed",
        now: -> { Time.utc(2026, 7, 14, 8, 16, 0) },
        logger: ->(_message) {}
      ).build

      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      catalog = JSON.parse(File.read(File.join(output, manifest.dig("catalog", "path"))))
      collection = catalog.fetch("collections").fetch(0)

      assert_equal(5, transport.requests.length)
      refute(transport.requests.any? { |request| request.fetch(:path) == "/api/playlist" })
      assert_equal(1, catalog.fetch("collections").length)
      assert_equal(
        ["genre:cpop"],
        collection.dig("rankingMetadata", "topics")
      )
      assert_equal(
        ["charts", "latest", "featured"],
        collection.dig("rankingMetadata", "editorialSignals")
      )
    end
  end

  def test_rate_limit_publishes_cached_feed_without_tracks_and_stops_requests
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      transport.handler = lambda do |request|
        case request.fetch(:path)
        when "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        when "/api/getVector"
          json_result(
            {
              "getVector" => {
                "items" => [{ "type" => "playlist", "ref" => "playlist-1", "title" => "Playlist" }]
              }
            },
            etag: '"vector"'
          )
        when "/api/playlist"
          raise OrchidPipeline::RateLimitError.new("rate limited", retry_after: 3600)
        end
      end

      summary = build(transport, output, state)

      assert_equal(true, summary.fetch("halted"))
      assert_match(/3600 seconds/, summary.fetch("haltReason"))
      assert_equal(0, summary.fetch("trackCount"))
      assert(File.file?(File.join(output, "manifest.json")))
    end
  end

  def test_incomplete_vector_resumes_from_checkpoint_in_next_run
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      offsets = []
      budget_was_raised = false
      transport.handler = lambda do |request|
        if request.fetch(:path) == "/api/page/getSearch"
          json_result({ "getPage" => { "items" => [] } }, etag: '"discovery"')
        elsif request.fetch(:path) == "/api/getVector"
          offset = request.fetch(:query).fetch("skip").to_i
          offsets << offset
          if offset == 12 && !budget_was_raised
            budget_was_raised = true
            raise OrchidPipeline::RequestBudgetExceeded, "budget exhausted"
          end

          count = offset.zero? ? 12 : 1
          items = count.times.map do |index|
            { "type" => "playlist", "ref" => "playlist-#{offset + index}", "title" => "Playlist" }
          end
          json_result({ "getVector" => { "items" => items } }, etag: "\"offset-#{offset}\"")
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      2.times do
        OrchidPipeline::Builder.new(
          transport: transport,
          output_directory: output,
          state_path: state,
          max_vectors: 1,
          vector_batch_size: 1,
          playlist_batch_size: 0,
          minimum_collections: 1,
          first_launch: "fixed",
          now: -> { Time.utc(2026, 7, 10, 8, 16, 0) },
          logger: ->(_message) {}
        ).build
      end

      assert_equal([0, 12, 12], offsets)
      persisted = JSON.parse(File.read(state))
      progress = persisted.dig("vectors", "vector_systemlist_zh_top_charts")
      assert_equal(true, progress.fetch("complete"))
      assert_equal(0, progress.fetch("nextOffset"))
    end
  end

  def test_vector_request_allocation_preserves_playlist_hydration
    Dir.mktmpdir do |directory|
      transport = FakeTransport.new
      output = File.join(directory, "public")
      state = File.join(directory, "source-state.json")
      vector_offsets = []
      playlist_requests = []
      transport.handler = lambda do |request|
        case request.fetch(:path)
        when "/api/page/getSearch"
          json_result(
            { "getPage" => { "items" => [{ "type" => "genre", "ref" => "vector_systemlist_zh_top_charts" }] } },
            etag: '"discovery"'
          )
        when "/api/getVector"
          offset = request.fetch(:query).fetch("skip").to_i
          vector_offsets << offset
          items = 12.times.map do |index|
            identifier = "playlist-#{offset + index}"
            { "type" => "playlist", "ref" => identifier, "title" => identifier }
          end
          json_result({ "getVector" => { "items" => items } }, etag: "\"vector-#{offset}\"")
        when "/api/playlist"
          playlist_requests << request.fetch(:query).fetch("vectorId")
          json_result(
            {
              "getPlaylist" => {
                "items" => [{ "type" => "music", "t" => "yt", "f" => "video-1", "tt" => "Song One" }]
              }
            },
            etag: '"playlist"'
          )
        else
          raise("Unexpected path #{request.fetch(:path)}")
        end
      end

      summary = OrchidPipeline::Builder.new(
        transport: transport,
        output_directory: output,
        state_path: state,
        max_vectors: 1,
        vector_batch_size: 1,
        vector_request_budget: 2,
        playlist_batch_size: 1,
        minimum_collections: 1,
        minimum_playlist_success_rate: 1.0,
        first_launch: "fixed",
        now: -> { Time.utc(2026, 7, 10, 8, 16, 0) },
        logger: ->(_message) {}
      ).build

      assert_equal([0, 12], vector_offsets)
      assert_equal(["playlist-0"], playlist_requests)
      assert_equal(1, summary.fetch("hydratedPlaylistCount"))
      assert_equal(1, summary.fetch("trackCount"))
      assert_equal(false, summary.fetch("halted"))
      progress = JSON.parse(File.read(state)).dig("vectors", "vector_systemlist_zh_top_charts")
      assert_equal(false, progress.fetch("complete"))
      assert_equal(24, progress.fetch("nextOffset"))
    end
  end

  def test_verified_feed_rejects_missing_empty_and_unhydrated_collections
    Dir.mktmpdir do |dir|
      transport = FakeTransport.new
      transport.handler = lambda do |request|
        if request[:path] == "/api/getVector"
          json_result({ "items" => %w[good gone empty unknown].map { |id| { "type" => "playlist", "ref" => id, "title" => id } } }, etag: "v")
        elsif request[:path] == "/api/playlist"
          case request[:query]["vectorId"]
          when "gone" then json_result({ "error" => { "code" => 106, "message" => "No such vector found." } }, etag: "gone")
          when "empty" then json_result({ "items" => [] }, etag: "empty")
          else response_for(request, conditional: false)
          end
        else response_for(request, conditional: false)
        end
      end
      output = File.join(dir, "public")
      state = File.join(dir, "state.json")
      summary = OrchidPipeline::Builder.new(transport: transport, output_directory: output, state_path: state,
        verified_only: true, max_vectors: 1, max_pages_per_vector: 1, playlist_batch_size: 3,
        minimum_collections: 1, logger: ->(_) {}).build
      manifest = JSON.parse(File.read(File.join(output, "manifest.json")))
      catalog = JSON.parse(File.read(File.join(output, manifest.dig("catalog", "path"))))
      assert_equal(["good"], catalog["collections"].map { |x| x["id"] })
      assert_equal("verified-only", manifest["deliveryPolicy"])
      assert_equal(2, summary["unavailableCollectionCount"])
      assert_equal(3, summary["excludedCollectionCount"])
      assert_equal(1, catalog["collections"][0].dig("tracks", "trackCount"))
      assert(File.exist?(File.join(output, "health.json")))
      persisted = JSON.parse(File.read(state))
      assert_nil(persisted.dig("resources", "playlist:gone"))
      assert(persisted.dig("tombstones", "gone", "retryAt"))
    end
  end

  def test_verified_feed_never_publishes_expired_cached_tracks_on_upstream_failure
    Dir.mktmpdir do |dir|
      transport = FakeTransport.new
      transport.handler = ->(request) { response_for(request, conditional: false) }
      time = Time.utc(2026, 9, 22)
      options = { transport: transport, output_directory: File.join(dir, "public"), state_path: File.join(dir, "state.json"),
        verified_only: true, max_vectors: 1, max_pages_per_vector: 1, minimum_collections: 1,
        now: -> { time }, logger: ->(_) {} }
      OrchidPipeline::Builder.new(**options).build
      manifest = File.read(File.join(dir, "public", "manifest.json"))
      time += 8 * 24 * 3600
      transport.handler = lambda do |request|
        raise OrchidPipeline::HTTPError, "temporary outage" if request[:path] == "/api/playlist"
        response_for(request, conditional: true)
      end
      assert_raises(OrchidPipeline::QualityGateError) { OrchidPipeline::Builder.new(**options).build }
      assert_equal(manifest, File.read(File.join(dir, "public", "manifest.json")))
    end
  end

  def test_retry_after_survives_restart_and_makes_zero_requests
    Dir.mktmpdir do |dir|
      transport = FakeTransport.new
      transport.handler = ->(request) { response_for(request, conditional: false) }
      now = Time.utc(2026, 9, 22)
      state = File.join(dir, "state.json")
      options = { transport: transport, output_directory: File.join(dir, "public"), state_path: state,
        verified_only: true, max_vectors: 1, max_pages_per_vector: 1, minimum_collections: 1,
        now: -> { now }, logger: ->(_) {} }
      OrchidPipeline::Builder.new(**options).build
      data = JSON.parse(File.read(state))
      data["retryAfterUntil"] = (now + 3600).iso8601
      File.write(state, JSON.generate(data))
      transport.handler = ->(_) { raise "No upstream request is allowed in cooldown" }
      summary = OrchidPipeline::Builder.new(**options).build
      assert_equal(true, summary["halted"])
      assert_equal(1, summary["collectionCount"])
    end
  end

  private

  def build(transport, output, state, now: Time.utc(2026, 7, 10, 8, 16, 0))
    OrchidPipeline::Builder.new(
      transport: transport,
      output_directory: output,
      state_path: state,
      max_vectors: 1,
      max_pages_per_vector: 1,
      minimum_collections: 1,
      minimum_playlist_success_rate: 1.0,
      first_launch: "fixed-first-launch",
      now: -> { now },
      logger: ->(_message) {}
    ).build
  end

  def response_for(request, conditional:)
    case request.fetch(:path)
    when "/api/page/getSearch"
      json_result(
        {
          "getPage" => {
            "items" => [{ "type" => "genre", "ref" => "vector_systemlist_zh_top_charts" }]
          }
        },
        etag: '"discovery-etag"'
      )
    when "/api/getVector"
      return not_modified('"vector-etag"') if conditional && request[:etag] == '"vector-etag"'

      json_result(
        {
          "getVector" => {
            "items" => [
              {
                "type" => "playlist",
                "ref" => "playlist-1",
                "title" => "Taiwan Hits",
                "size" => 1
              }
            ]
          }
        },
        etag: '"vector-etag"'
      )
    when "/api/playlist"
      return not_modified('"playlist-etag"') if conditional && request[:etag] == '"playlist-etag"'

      json_result(
        {
          "getPlaylist" => {
            "items" => [
              {
                "type" => "music",
                "t" => "yt",
                "f" => "video-1",
                "tt" => "Song One",
                "tm" => 205
              }
            ]
          }
        },
        etag: '"playlist-etag"'
      )
    else
      raise("Unexpected path #{request.fetch(:path)}")
    end
  end

  def json_result(value, etag:)
    OrchidPipeline::HTTPResult.new(
      status: 200,
      headers: { "etag" => etag },
      body: JSON.generate(value)
    )
  end

  def not_modified(etag)
    OrchidPipeline::HTTPResult.new(status: 304, headers: { "etag" => etag }, body: "")
  end
end

class FakeTransport
  attr_accessor :handler
  attr_reader :requests

  def initialize
    @requests = []
  end

  def request(**request)
    @requests << request
    handler.call(request)
  end
end
