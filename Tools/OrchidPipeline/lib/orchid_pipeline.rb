# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

module OrchidPipeline
  class Error < StandardError; end
  class HTTPError < Error; end
  class RequestBudgetExceeded < Error; end
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
  class QualityGateError < Error; end
  class UnavailableCollection < Error; end

  HTTPResult = Struct.new(:status, :headers, :body, keyword_init: true)

  module CanonicalJSON
    module_function

    def dump(value)
      JSON.generate(sort(value))
    end

    def pretty(value)
      JSON.pretty_generate(sort(value)) + "\n"
    end

    def sha256(value)
      Digest::SHA256.hexdigest(dump(value))
    end

    def sort(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = sort(value.fetch(original_key))
        end
      when Array
        value.map { |item| sort(item) }
      else
        value
      end
    end
  end

  class PayloadParser
    class << self
      def vector_ids(root)
        ids = []
        collect_vector_ids(root, ids, {})
        ids
      end

      def collections(root)
        result = []
        collect_collections(page_items(root), result, {})
        result
      end

      def tracks(root)
        seen = {}
        page_items(root).each_with_object([]) do |item, result|
          next unless item.is_a?(Hash)

          track = track_from(item)
          next unless track
          next if seen[track.fetch("id")]

          seen[track.fetch("id")] = true
          result << track
        end
      end

      def raw_item_count(root)
        page_items(root).length
      end

      private

      def collect_vector_ids(value, ids, seen)
        if value.is_a?(Array)
          value.each { |item| collect_vector_ids(item, ids, seen) }
          return
        end
        return unless value.is_a?(Hash)

        api_info = value["apiInfo"]
        if api_info.is_a?(Hash) && string_value(api_info["funcName"]) == "getVector"
          arguments = api_info["arguments"]
          append_vector_id(string_value(arguments["vectorId"]), ids, seen) if arguments.is_a?(Hash)
        end

        append_vector_id(string_value(value["ref"]), ids, seen) if string_value(value["type"])&.downcase == "genre"
        value.each_value { |nested| collect_vector_ids(nested, ids, seen) }
      end

      def append_vector_id(identifier, ids, seen)
        return if blank?(identifier)
        return unless identifier.start_with?("vector_")
        return if identifier.include?("vector_artists_") || seen[identifier]

        seen[identifier] = true
        ids << identifier
      end

      def collect_collections(values, result, seen)
        values.each do |value|
          next unless value.is_a?(Hash)

          if string_value(value["type"])&.downcase == "carousel"
            collect_collections(Array(value["items"]), result, seen)
            next
          end

          collection = collection_from(value)
          next unless collection
          next if seen[collection.fetch("id")]

          seen[collection.fetch("id")] = true
          result << collection
        end
      end

      def collection_from(value)
        return unless string_value(value["type"])&.downcase == "playlist"
        return if bool_value(value["deleted"]) == true

        identifier = present(string_value(value["ref"]) || string_value(value["id"]))
        title = present(string_value(value["title"]) || string_value(value["name"]))
        return unless identifier && title

        count = int_value(value["size"]) || int_value(value["itemCount"])
        thumbnail = best_thumbnail(value) || inline_thumbnail(value)
        {
          "id" => identifier,
          "title" => title,
          "subtitle" => count ? "#{count} 首" : nil,
          "thumbnailURL" => thumbnail&.fetch("url", nil),
          "thumbnailSize" => thumbnail&.fetch("size", nil),
          "kind" => bool_value(value["isAlbum"]) == true ? "album" : "playlist"
        }
      end

      def track_from(value)
        type = string_value(value["type"])&.downcase
        return unless ["music", "video"].include?(type) || string_value(value["t"]) == "yt"

        status = int_value(value["statusCode"])
        return if status && status != 0
        return unless string_value(value["t"]).nil? || string_value(value["t"]) == "yt"

        identifier = present(string_value(value["f"]) || string_value(value["id"]) || string_value(value["_id"]))
        title = present(string_value(value["tt"]) || string_value(value["title"]) || string_value(value["name"]))
        return unless identifier && title && valid_video_id?(identifier)

        thumbnail = best_thumbnail(value) || {
          "url" => "https://i.ytimg.com/vi/#{identifier}/mqdefault.jpg",
          "size" => { "width" => 320, "height" => 180 }
        }
        {
          "id" => identifier,
          "title" => title,
          "durationText" => duration_text(int_value(value["tm"])),
          "thumbnailURL" => thumbnail.fetch("url"),
          "thumbnailSize" => thumbnail["size"]
        }
      end

      def page_items(root)
        return [] unless root.is_a?(Hash)

        page = root["getVector"] || root["getPage"] || root["getPlaylist"] || root
        page.is_a?(Hash) ? Array(page["items"]) : []
      end

      def inline_thumbnail(value)
        Array(value["inlineItems"]).each do |item|
          next unless item.is_a?(Hash)

          video_id = present(string_value(item["f"]))
          next unless video_id && valid_video_id?(video_id)

          return {
            "url" => "https://i.ytimg.com/vi/#{video_id}/mqdefault.jpg",
            "size" => { "width" => 320, "height" => 180 }
          }
        end
        nil
      end

      def best_thumbnail(value)
        %w[thumbnailHQ coverhq coverImage imageUrl thumbnail cover].each do |field|
          raw_url = present(string_value(value[field]))
          next unless raw_url

          url = normalized_url(raw_url)
          next unless url

          return { "url" => url, "size" => thumbnail_size(raw_url) }
        end
        nil
      end

      def normalized_url(raw_url)
        candidate = if raw_url.start_with?("//")
                      "https:#{raw_url}"
                    elsif raw_url.start_with?("http://")
                      raw_url.sub("http://", "https://")
                    else
                      raw_url
                    end
        uri = URI(candidate)
        return unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo

        candidate
      rescue URI::InvalidURIError
        nil
      end

      def valid_video_id?(value)
        value.match?(/\A[A-Za-z0-9_-]{6,32}\z/)
      end

      def thumbnail_size(raw_url)
        return { "width" => 1280, "height" => 720 } if raw_url.include?("maxresdefault")
        return { "width" => 640, "height" => 480 } if raw_url.include?("sddefault")
        return { "width" => 480, "height" => 360 } if raw_url.include?("hqdefault")
        return { "width" => 320, "height" => 180 } if raw_url.include?("mqdefault")
        return { "width" => 120, "height" => 90 } if raw_url.include?("default")

        nil
      end

      def duration_text(seconds)
        return unless seconds && seconds.positive?

        hours = seconds / 3600
        minutes = (seconds % 3600) / 60
        remaining = seconds % 60
        return format("%d:%02d:%02d", hours, minutes, remaining) if hours.positive?

        format("%d:%02d", minutes, remaining)
      end

      def string_value(value)
        return value if value.is_a?(String)
        return value.to_s if value.is_a?(Numeric)

        nil
      end

      def int_value(value)
        Integer(value, exception: false)
      end

      def bool_value(value)
        return value if value == true || value == false
        return !value.zero? if value.is_a?(Numeric)
        return true if value == "true"
        return false if value == "false"

        nil
      end

      def present(value)
        stripped = value&.strip
        stripped unless stripped.nil? || stripped.empty?
      end

      def blank?(value)
        present(value).nil?
      end
    end
  end

  class HTTPSession
    DEFAULT_USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " \
                         "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " \
                         "Mobile/15E148 Safari/604.1"

    def initialize(
      base_url:,
      region_code:,
      language_tag:,
      browser_language:,
      minimum_request_interval: 1.0,
      maximum_requests: 40,
      maximum_response_bytes: 10 * 1024 * 1024,
      sleeper: ->(seconds) { sleep(seconds) },
      monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @base_uri = URI(base_url)
      @region_code = region_code
      @language_tag = language_tag
      @browser_language = browser_language
      @sleeper = sleeper
      @minimum_request_interval = minimum_request_interval
      @maximum_requests = maximum_requests
      @maximum_response_bytes = maximum_response_bytes
      @request_count = 0
      @monotonic_clock = monotonic_clock
      @last_request_at = nil
      @cookies = {}
      @http = nil
    end

    def close
      @http&.finish if @http&.active?
    rescue IOError
      nil
    ensure
      @http = nil
    end

    def request(method:, path:, query:, body: nil, etag: nil, attempts: 3)
      uri = @base_uri.dup
      uri.path = path
      uri.query = URI.encode_www_form(query)
      request = method == "POST" ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["User-Agent"] = DEFAULT_USER_AGENT
      request["Accept"] = "application/json, text/plain, */*"
      request["Accept-Language"] = "#{@language_tag},zh-TW;q=0.9,zh;q=0.8,en;q=0.6"
      request["browser-lang"] = @browser_language
      request["country-code"] = @region_code
      request["Origin"] = "#{@base_uri.scheme}://#{@base_uri.host}"
      request["Referer"] = "#{@base_uri.scheme}://#{@base_uri.host}/"
      request["If-None-Match"] = etag if etag
      request["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ") unless @cookies.empty?
      if body
        request.body = body
        request["Content-Type"] = "text/plain;charset=UTF-8"
      end

      perform(request, attempts: attempts)
    end

    private

    def perform(request, attempts:)
      attempt = 0
      loop do
        attempt += 1
        begin
          pace_request
          response = connection.request(request)
          capture_cookies(response.get_fields("set-cookie"))
          status = response.code.to_i
          if status == 304 || status.between?(200, 299)
            body = response.body.to_s
            if body.bytesize > @maximum_response_bytes
              raise HTTPError, "Upstream response exceeded #{@maximum_response_bytes} bytes for #{request.path}"
            end
            return HTTPResult.new(
              status: status,
              headers: response.each_header.to_h,
              body: body
            )
          end
          if status == 429
            retry_after = Integer(response["retry-after"], exception: false)
            raise RateLimitError.new(
              "Upstream rate limited #{request.path}",
              retry_after: retry_after
            )
          end
          unless retryable_status?(status) && attempt < attempts
            raise HTTPError, "Upstream returned HTTP #{status} for #{request.path}"
          end
        rescue IOError, EOFError, SocketError, SystemCallError, Timeout::Error => error
          close
          raise HTTPError, error.message if attempt >= attempts
        end

        @sleeper.call(2**(attempt - 1))
      end
    end

    def connection
      return @http if @http&.active?

      @http = Net::HTTP.new(@base_uri.host, @base_uri.port)
      @http.use_ssl = @base_uri.scheme == "https"
      @http.open_timeout = 12
      @http.read_timeout = 20
      @http.keep_alive_timeout = 30
      @http.start
      @http
    end

    def capture_cookies(headers)
      Array(headers).each do |header|
        pair = header.split(";", 2).first
        key, value = pair.split("=", 2)
        @cookies[key] = value if key && value
      end
    end

    def pace_request
      raise RequestBudgetExceeded, "The per-run request budget of #{@maximum_requests} was exhausted." if @request_count >= @maximum_requests

      now = @monotonic_clock.call
      if @last_request_at
        remaining = @minimum_request_interval - (now - @last_request_at)
        @sleeper.call(remaining) if remaining.positive?
      end
      @last_request_at = @monotonic_clock.call
      @request_count += 1
    end

    def retryable_status?(status)
      status >= 500
    end
  end

  class Builder
    PREFERRED_VECTOR_IDS = %w[
      vector_systemlist_zh_top_charts
      vector_latest_zh
      vector_featured_zh
      vector_systemlist_zh_genre_cpop
      vector_systemlist_zh_genre_pop
      vector_systemlist_zh_genre_kpop
      vector_systemlist_zh_genre_jpop
      vector_systemlist_zh_genre_hk
      vector_systemlist_zh_genre_never_go_out
      vector_systemlist_zh_genre_hiphop
      vector_systemlist_zh_genre_rock
      vector_systemlist_zh_genre_electronic_dance
      vector_systemlist_zh_mood_good_mood
      vector_systemlist_zh_mood_party
      vector_systemlist_zh_mood_travel
      vector_systemlist_zh_mood_romance
      vector_systemlist_zh_mood_sleep
    ].freeze

    VECTOR_TOPICS = {
      "vector_systemlist_zh_genre_cpop" => ["genre:cpop"],
      "vector_systemlist_zh_genre_pop" => ["genre:pop"],
      "vector_systemlist_zh_genre_kpop" => ["genre:kpop"],
      "vector_systemlist_zh_genre_jpop" => ["genre:jpop"],
      "vector_systemlist_zh_genre_hk" => ["region:hong-kong"],
      "vector_systemlist_zh_genre_never_go_out" => ["era:evergreen"],
      "vector_systemlist_zh_genre_hiphop" => ["genre:hip-hop"],
      "vector_systemlist_zh_genre_rock" => ["genre:rock"],
      "vector_systemlist_zh_genre_electronic_dance" => ["genre:electronic-dance"],
      "vector_systemlist_zh_mood_good_mood" => ["mood:good"],
      "vector_systemlist_zh_mood_party" => ["mood:party"],
      "vector_systemlist_zh_mood_travel" => ["mood:travel"],
      "vector_systemlist_zh_mood_romance" => ["mood:romance"],
      "vector_systemlist_zh_mood_sleep" => ["mood:sleep"]
    }.freeze

    VECTOR_EDITORIAL_SIGNALS = {
      "vector_systemlist_zh_top_charts" => ["charts"],
      "vector_latest_zh" => ["latest"],
      "vector_featured_zh" => ["featured"]
    }.freeze

    attr_reader :summary

    def initialize(
      transport:,
      output_directory:,
      state_path:,
      region_code: "TW",
      language_tag: "zh-TW",
      page_size: 12,
      max_vectors: nil,
      max_pages_per_vector: nil,
      vector_batch_size: 4,
      vector_request_budget: 24,
      playlist_batch_size: 8,
      minimum_collections: 20,
      minimum_playlist_success_rate: 0.8,
      verified_only: false,
      track_max_age: 7 * 24 * 60 * 60,
      first_launch: nil,
      now: -> { Time.now.utc },
      logger: ->(message) { puts(message) }
    )
      @verified_only = verified_only
      @track_max_age = track_max_age
      @transport = transport
      @output_directory = File.expand_path(output_directory)
      @state_path = File.expand_path(state_path)
      @region_code = region_code
      @language_tag = language_tag
      @page_size = page_size
      @max_vectors = max_vectors
      @max_pages_per_vector = max_pages_per_vector
      @vector_batch_size = vector_batch_size
      @vector_request_budget = vector_request_budget
      @playlist_batch_size = playlist_batch_size
      @minimum_collections = minimum_collections
      @minimum_playlist_success_rate = minimum_playlist_success_rate
      @first_launch = first_launch || (now.call.to_f * 1000).to_i.to_s
      @now = now
      @logger = logger
      @state = load_state
      @summary = {}
      @halt = nil
      @object_files_changed = false
    end

    def build
      vectors = discover_vectors
      vectors = vectors.first(@max_vectors) if @max_vectors
      selected_vectors = select_vector_batch(vectors)
      vector_stats = crawl_vectors(selected_vectors)
      collections = cached_collections(vectors)
      raise QualityGateError, "Only #{collections.length} collections parsed; minimum is #{@minimum_collections}." if collections.length < @minimum_collections

      playlist_stats = crawl_playlists(collections)
      enforce_playlist_gate!(playlist_stats)
      enriched_collections = enrich_collections(collections)
      if @verified_only && enriched_collections.length < @minimum_collections
        write_json_atomic(@state_path, @state)
        raise QualityGateError, "Only #{enriched_collections.length} verified nonempty collections; retaining the last published catalog."
      end
      coverage = {
        "vectorCount" => vectors.length,
        "cachedVectorCount" => cached_vector_count(vectors),
        "collectionCount" => enriched_collections.length,
        "hydratedPlaylistCount" => enriched_collections.count { |item| item.key?("tracks") }
      }
      catalog = {
        "schemaVersion" => 1,
        "region" => { "regionCode" => @region_code, "languageTag" => @language_tag },
        "coverage" => coverage,
        "collections" => enriched_collections
      }
      catalog_object = write_object(catalog)
      content_version = catalog_object.fetch("sha256")
      previous_manifest = load_json(File.join(@output_directory, "manifest.json"))
      changed = previous_manifest&.fetch("contentVersion", nil) != content_version || @object_files_changed

      if changed
        manifest = {
          "schemaVersion" => 1,
          "contentVersion" => content_version,
          "generatedAt" => @now.call.iso8601,
          "source" => @verified_only ? "orchid-discovery-v2" : "orchid-v1",
          "deliveryPolicy" => @verified_only ? "verified-only" : "legacy",
          "region" => { "regionCode" => @region_code, "languageTag" => @language_tag },
          "catalog" => catalog_object.merge("collectionCount" => enriched_collections.length)
        }
        write_json_atomic(File.join(@output_directory, "manifest.json"), manifest)
      end

      if @verified_only
        write_json_atomic(File.join(@output_directory, "health.json"), {
          "schemaVersion" => 1, "checkedAt" => @now.call.iso8601,
          "contentVersion" => content_version, "deliveryPolicy" => "verified-only",
          "collectionCount" => enriched_collections.length,
          "excludedCollectionCount" => collections.length - enriched_collections.length,
          "upstreamFailures" => vector_stats.fetch("failures") + playlist_stats.fetch("failures"),
          "halted" => !@halt.nil?, "haltReason" => @halt
        })
      end
      write_json_atomic(@state_path, @state)
      @summary = {
        "changed" => changed || @verified_only,
        "contentChanged" => changed,
        "excludedCollectionCount" => collections.length - enriched_collections.length,
        "unavailableCollectionCount" => playlist_stats.fetch("unavailable", 0),
        "contentVersion" => content_version,
        "vectorCount" => vectors.length,
        "refreshedVectorCount" => selected_vectors.length,
        "collectionCount" => enriched_collections.length,
        "hydratedPlaylistCount" => coverage.fetch("hydratedPlaylistCount"),
        "trackCount" => enriched_collections.sum { |item| item.dig("tracks", "trackCount").to_i },
        "notModifiedCount" => vector_stats.fetch("notModified") + playlist_stats.fetch("notModified"),
        "staleFallbackCount" => vector_stats.fetch("staleFallback") + playlist_stats.fetch("staleFallback"),
        "playlistFailureCount" => playlist_stats.fetch("failures"),
        "halted" => !@halt.nil?,
        "haltReason" => @halt
      }
      @logger.call(CanonicalJSON.pretty(@summary))
      @summary
    end

    private

    def discover_vectors
      retry_at = @state["retryAfterUntil"]
      if retry_at && Time.iso8601(retry_at) > @now.call
        @halt = "Upstream Retry-After cooldown is active."
        return Array(@state.dig("discovery", "vectorIDs"))
      end
      @state.delete("retryAfterUntil")
      result = @transport.request(
        method: "POST",
        path: "/api/page/getSearch",
        query: { "page" => "Search", "firstLaunch" => @first_launch },
        body: "{}"
      )
      root = parse_json(result.body)
      discovered = PayloadParser.vector_ids(root)
      discovered = @state.dig("discovery", "vectorIDs") || PREFERRED_VECTOR_IDS if discovered.empty?
      ordered = order_vectors(discovered)
      raise QualityGateError, "No Upstream feed vectors were discovered." if ordered.empty?

      @state["discovery"] = {
        "hash" => CanonicalJSON.sha256(ordered),
        "vectorIDs" => ordered
      }
      ordered
    rescue RateLimitError, RequestBudgetExceeded, HTTPError, JSON::ParserError => error
      cached = Array(@state.dig("discovery", "vectorIDs"))
      raise error if cached.empty?

      halt!(error) if error.is_a?(RateLimitError) || error.is_a?(RequestBudgetExceeded)
      @logger.call("Discovery failed; using #{cached.length} cached vector IDs: #{error.message}")
      cached
    end

    def crawl_vectors(vector_ids)
      stats = base_stats
      vector_requests = 0
      allocation_exhausted = false

      vector_ids.each do |vector_id|
        break if @halt || allocation_exhausted

        progress = @state["vectors"][vector_id] ||= { "complete" => false, "nextOffset" => 0 }
        offset = if @max_pages_per_vector
                   0
                 elsif progress["complete"]
                   0
                 else
                   progress["nextOffset"].to_i
                 end
        page = 0
        seen_page_hashes = {}
        completed = false
        did_download = false
        @logger.call("Refreshing vector #{vector_id}")
        loop do
          break if @max_pages_per_vector && page >= @max_pages_per_vector
          if vector_requests >= @vector_request_budget
            @logger.call("Vector request allocation reached #{@vector_request_budget}; preserving capacity for playlists.")
            allocation_exhausted = true
            break
          end

          key = "vector:#{vector_id}:#{offset}:#{@page_size}"
          vector_requests += 1
          payload, item_count, outcome = fetch_parsed_resource(
            key: key,
            method: "GET",
            path: "/api/getVector",
            query: {
              "vectorId" => vector_id,
              "type" => "vector",
              "skip" => offset.to_s,
              "limit" => @page_size.to_s,
              "firstLaunch" => @first_launch
            },
            parser: ->(root) { PayloadParser.collections(root) },
            item_counter: ->(root) { PayloadParser.raw_item_count(root) }
          )
          stats[outcome] += 1 if stats.key?(outcome)
          did_download = true if outcome == "downloaded"
          page_hash = CanonicalJSON.sha256(payload)
          if seen_page_hashes[page_hash]
            @logger.call("Vector #{vector_id} repeated a previous page at offset #{offset}; stopping pagination.")
            completed = true
            break
          end
          seen_page_hashes[page_hash] = true
          page += 1
          progress["complete"] = false
          progress["nextOffset"] = offset + @page_size
          if item_count < @page_size
            completed = true
            break
          end

          offset += @page_size
        rescue RateLimitError, RequestBudgetExceeded => error
          halt!(error)
          break
        rescue HTTPError, JSON::ParserError => error
          stats["failures"] += 1
          @logger.call("Vector #{vector_id} offset #{offset} failed: #{error.message}")
          break
        end
        if completed
          progress["complete"] = true
          progress["nextOffset"] = 0
          progress["lastCompletedAt"] = @now.call.iso8601 if did_download || !progress.key?("lastCompletedAt")
          prune_vector_pages_after(vector_id, offset) if @max_pages_per_vector.nil?
        end
      end
      stats
    end

    def crawl_playlists(collections)
      stats = base_stats
      return stats if @halt

      selected_playlists(collections).each do |collection|
        identifier = collection.fetch("id")
        key = "playlist:#{identifier}"
        _tracks, _item_count, outcome = fetch_parsed_resource(
          key: key,
          method: "GET",
          path: "/api/playlist",
          query: {
            "reverse" => "true",
            "type" => "playlist",
            "vectorId" => identifier,
            "firstLaunch" => @first_launch
          },
          parser: ->(root) { PayloadParser.tracks(root) },
          item_counter: ->(root) { PayloadParser.raw_item_count(root) }
        )
        stats[outcome] += 1 if stats.key?(outcome)
        stats["successes"] += 1
      rescue UnavailableCollection => error
        @state["resources"].delete(key)
        @state["tombstones"] ||= {}
        @state["tombstones"][identifier] = { "retryAt" => (@now.call + 24 * 60 * 60).iso8601 }
        stats["unavailable"] = stats.fetch("unavailable", 0) + 1
        @logger.call("Excluded unavailable playlist #{identifier}.")
      rescue RateLimitError, RequestBudgetExceeded => error
        halt!(error)
        break
      rescue HTTPError, JSON::ParserError => error
        stats["failures"] += 1
        @logger.call("Playlist #{identifier} failed: #{error.message}")
      end
      stats
    end

    def enrich_collections(collections)
      seen_tracks = {}
      collections.filter_map do |collection|
        identifier = collection.fetch("id")
        resource = @state.dig("resources", "playlist:#{identifier}")
        tracks = resource&.fetch("payload", nil)
        if @verified_only
          next if tombstoned?(identifier)
          next unless tracks.is_a?(Array) && !tracks.empty? && fresh_resource?(resource)
          fingerprint = CanonicalJSON.sha256(tracks.map { |track| track.fetch("id") }.sort)
          next if seen_tracks[fingerprint]
          seen_tracks[fingerprint] = true
          collection = collection.merge("subtitle" => "#{tracks.length} 首")
        else
          next collection unless tracks.is_a?(Array) && !tracks.empty?
        end

        object = write_object({ "schemaVersion" => 1, "collectionID" => identifier, "tracks" => tracks })
        collection.merge("tracks" => object.merge("trackCount" => tracks.length))
      end
    end

    def cached_collections(vector_ids)
      allowed = vector_ids.each_with_object({}) { |identifier, result| result[identifier] = true }
      pages = @state.fetch("resources", {}).each_with_object([]) do |(key, resource), result|
        match = key.match(/\Avector:(.+):(\d+):(\d+)\z/)
        next unless match && allowed[match[1]]
        next if @verified_only && match[2].to_i != 0

        result << [vector_ids.index(match[1]), match[1], match[2].to_i, resource.fetch("payload", [])]
      end

      result = []
      indexes_by_id = {}
      pages.sort_by { |vector_index, _vector_id, offset, _payload| [vector_index, offset] }.each do |(_vector_index, vector_id, _offset, payload)|
        metadata = ranking_metadata(vector_id)
        Array(payload).each do |collection|
          identifier = collection["id"]
          next unless identifier

          if (existing_index = indexes_by_id[identifier])
            result[existing_index] = merge_ranking_metadata(result.fetch(existing_index), metadata)
            next
          end

          indexes_by_id[identifier] = result.length
          result << merge_ranking_metadata(collection.dup, metadata)
        end
      end
      result
    end

    def ranking_metadata(vector_id)
      topics = VECTOR_TOPICS.fetch(vector_id, [])
      editorial_signals = VECTOR_EDITORIAL_SIGNALS.fetch(vector_id, [])
      return {} if topics.empty? && editorial_signals.empty?

      { "topics" => topics, "editorialSignals" => editorial_signals }
    end

    def merge_ranking_metadata(collection, metadata)
      return collection if metadata.empty?

      existing = collection.fetch("rankingMetadata", {})
      collection.merge(
        "rankingMetadata" => {
          "topics" => (Array(existing["topics"]) + Array(metadata["topics"])).uniq,
          "editorialSignals" => (Array(existing["editorialSignals"]) + Array(metadata["editorialSignals"])).uniq
        }.reject { |_key, values| values.empty? }
      )
    end

    def cached_vector_count(vector_ids)
      vector_ids.count do |identifier|
        @state.fetch("resources", {}).keys.any? { |key| key.start_with?("vector:#{identifier}:") }
      end
    end

    def select_vector_batch(vector_ids)
      if @verified_only
        hot = vector_ids.first([3, @vector_batch_size].min)
        rest = vector_ids - hot
        count = [@vector_batch_size - hot.length, 0].max
        cursor = @state.fetch("crawl", {}).fetch("discoveryVectorCursor", 0) % [rest.length, 1].max
        rotated = rest.length.times.map { |i| rest[(cursor + i) % rest.length] }
        @state["crawl"]["discoveryVectorCursor"] = cursor + count
        return hot + rotated.first(count)
      end
      return vector_ids if vector_ids.length <= @vector_batch_size

      incomplete = vector_ids.select do |identifier|
        progress = @state.fetch("vectors", {})[identifier]
        progress.is_a?(Hash) && progress["complete"] == false
      end
      uncached = vector_ids.select do |identifier|
        @state.fetch("resources", {}).keys.none? { |key| key.start_with?("vector:#{identifier}:") }
      end
      bootstrap = (incomplete + uncached).uniq.first(@vector_batch_size)
      return bootstrap if bootstrap.length == @vector_batch_size

      cursor = (time_slot * @vector_batch_size) % vector_ids.length
      rotated = vector_ids.length.times.map { |index| vector_ids[(cursor + index) % vector_ids.length] }
      (bootstrap + rotated).uniq.first(@vector_batch_size)
    end

    def selected_playlists(collections)
      if @verified_only
        candidates = collections.reject { |item| tombstoned?(item.fetch("id")) }
        due = candidates.reject { |item| fresh_resource?(@state.dig("resources", "playlist:#{item.fetch("id")}")) }
        # Rotate unsuccessful/unknown endpoints so a damaged head cannot starve the tail.
        cursor = @state.fetch("crawl", {}).fetch("discoveryPlaylistCursor", 0) % [due.length, 1].max
        rotated = due.length.times.map { |i| due[(cursor + i) % due.length] }
        @state["crawl"]["discoveryPlaylistCursor"] = cursor + @playlist_batch_size
        return rotated.first(@playlist_batch_size)
      end
      resources = @state.fetch("resources", {})
      missing, existing = collections.partition { |item| !resources.dig("playlist:#{item.fetch("id")}", "payload").is_a?(Array) }
      return missing.first(@playlist_batch_size) unless missing.empty?
      return existing if existing.length <= @playlist_batch_size

      cursor = (time_slot * @playlist_batch_size) % existing.length
      @playlist_batch_size.times.map { |index| existing[(cursor + index) % existing.length] }
    end

    def prune_vector_pages_after(vector_id, terminal_offset)
      prefix = "vector:#{vector_id}:"
      @state.fetch("resources", {}).delete_if do |key, _resource|
        match = key.match(/\A#{Regexp.escape(prefix)}(\d+):\d+\z/)
        match && match[1].to_i > terminal_offset
      end
    end

    def fetch_parsed_resource(key:, method:, path:, query:, parser:, item_counter:)
      previous = @state.fetch("resources", {})[key]
      result = @transport.request(
        method: method,
        path: path,
        query: query,
        etag: previous&.fetch("etag", nil)
      )
      if result.status == 304
        if previous&.key?("payload")
          previous["validatedAt"] = @now.call.iso8601 if @verified_only
          return [previous.fetch("payload"), previous.fetch("itemCount"), "notModified"]
        end

        result = @transport.request(method: method, path: path, query: query)
      end

      root = parse_json(result.body)
      validate_response!(root, playlist: key.start_with?("playlist:"))
      payload = parser.call(root)
      if key.start_with?("playlist:") && payload.empty?
        raise UnavailableCollection, "Playlist has no usable tracks."
      end
      item_count = item_counter.call(root)
      @state["resources"][key] = {
        "etag" => result.headers["etag"],
        "hash" => CanonicalJSON.sha256(payload),
        "itemCount" => item_count,
        "payload" => payload
      }
      @state["resources"][key]["validatedAt"] = @now.call.iso8601 if @verified_only
      if key.start_with?("playlist:")
        @state.fetch("tombstones", {}).delete(key.delete_prefix("playlist:"))
      end
      [payload, item_count, "downloaded"]
    rescue HTTPError, JSON::ParserError
      raise unless previous&.key?("payload")

      [previous.fetch("payload"), previous.fetch("itemCount"), "staleFallback"]
    end

    def validate_response!(root, playlist:)
      raise HTTPError, "Malformed upstream response." unless root.is_a?(Hash)
      error = root["error"]
      if playlist && (root["deleted"] == true || (error.is_a?(Hash) && error["code"].to_i == 106))
        raise UnavailableCollection, "Playlist no longer exists."
      end
      raise HTTPError, "Upstream returned an application error." if error
      page = root["getVector"] || root["getPage"] || root["getPlaylist"] || root
      raise HTTPError, "Upstream response has no items array." unless page.is_a?(Hash) && page["items"].is_a?(Array)
    end

    def tombstoned?(identifier)
      timestamp = @state.dig("tombstones", identifier, "retryAt")
      timestamp && Time.iso8601(timestamp) > @now.call
    rescue ArgumentError
      false
    end

    def fresh_resource?(resource)
      return false unless resource.is_a?(Hash) && resource["payload"].is_a?(Array) && !resource["payload"].empty?
      checked = resource["validatedAt"]
      checked && @now.call - Time.iso8601(checked) <= @track_max_age
    rescue ArgumentError
      false
    end

    def enforce_playlist_gate!(stats)
      attempted = stats.fetch("successes") + stats.fetch("failures")
      return if attempted.zero?

      rate = stats.fetch("successes").to_f / attempted
      return if rate >= @minimum_playlist_success_rate

      raise QualityGateError,
            format("Playlist success rate %.1f%% is below %.1f%%.", rate * 100, @minimum_playlist_success_rate * 100)
    end

    def order_vectors(vector_ids)
      unique = vector_ids.compact.map(&:to_s).reject(&:empty?).uniq
      (PREFERRED_VECTOR_IDS + unique).uniq
    end

    def parse_json(body)
      JSON.parse(body)
    end

    def load_state
      loaded = load_json(@state_path)
      if loaded.is_a?(Hash) && loaded["schemaVersion"] == 1
        loaded["resources"] ||= {}
        loaded["discovery"] ||= {}
        loaded["crawl"] ||= { "vectorCursor" => 0 }
        loaded["vectors"] ||= {}
        return loaded
      end

      {
        "schemaVersion" => 1,
        "discovery" => {},
        "resources" => {},
        "vectors" => {},
        "crawl" => { "vectorCursor" => 0 }
      }
    end

    def load_json(path)
      return unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write_object(value)
      contents = CanonicalJSON.dump(value)
      sha = Digest::SHA256.hexdigest(contents)
      relative_path = File.join("objects", "#{sha}.json")
      path = File.join(@output_directory, relative_path)
      unless File.file?(path) && File.binread(path) == contents.b
        write_text_atomic(path, contents)
        @object_files_changed = true
      end
      { "path" => relative_path, "sha256" => sha }
    end

    def write_json_atomic(path, value)
      write_text_atomic(path, CanonicalJSON.pretty(value))
    end

    def write_text_atomic(path, contents)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp-#{Process.pid}"
      File.binwrite(temporary, contents)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary)
    end

    def base_stats
      { "downloaded" => 0, "notModified" => 0, "staleFallback" => 0, "successes" => 0, "failures" => 0 }
    end

    def time_slot
      @now.call.to_i / (6 * 60 * 60)
    end

    def halt!(error)
      retry_after = error.respond_to?(:retry_after) ? error.retry_after : nil
      if error.is_a?(RateLimitError)
        @state["retryAfterUntil"] = (@now.call + [retry_after.to_i, 3600].max).iso8601
      end
      @halt = retry_after ? "#{error.message}; retry after #{retry_after} seconds" : error.message
      @logger.call("Crawl paused: #{@halt}")
    end
  end
end
