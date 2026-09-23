# frozen_string_literal: true
require_relative 'publisher'

module OrchidPipeline
  module Discovery
    class Sync
      attr_reader :store
      def initialize(transport:, output:, state:, now: -> { Time.now.utc }, minimum: 20,
                     vector_limit: 2, playlist_limit: 18, page_size: 24, logger: ->(line) { puts(line) })
        @source = MBPlayerSource.new(transport)
        @now, @output, @minimum, @vector_limit, @playlist_limit, @page_size, @logger =
          now, output, minimum, vector_limit, playlist_limit, page_size, logger
        @store = Store.new(state, output: output, now: now)
        @scheduler = Scheduler.new(store, now: now)
        @publisher = Publisher.new(store, output: output, now: now, minimum: minimum)
      end

      def run
        @stats = {'upstreamFailures'=>0, 'unavailableCount'=>0, 'validatedPlaylistCount'=>0,
          'pageReadCount'=>0, 'vectorReadCount'=>0, 'halted'=>false, 'failures'=>[]}
        if store.time(store.data['retryAfterUntil']) > @now.call
          @stats.merge!('halted'=>true, 'haltReason'=>'upstream_cooldown')
        elsif store.time(store.data['nextSyncAt']) > @now.call
          @stats['syncDeferredUntil'] = store.data['nextSyncAt']
        else
          store.data['nextSyncAt'] = (@now.call + 2*3600).iso8601
          store.data.delete('retryAfterUntil')
          %w[Home Search].each do |name|
            attempt("page:#{name}") do
              page = @source.page(name)
              store.ingest(page[:collections])
              store.register_vectors(page[:vectors])
              store.data['pages'][name] = {'lastSuccessAt'=>store.timestamp, 'collectionCount'=>page[:collections].length}
              @stats['pageReadCount'] += 1
            end
          end
          @scheduler.vectors(@vector_limit).each do |id|
            attempt("vector:#{id}") do
              progress = store.vectors.fetch(id)
              progress['lastAttemptAt'] = store.timestamp
              offset = progress.fetch('nextOffset',0)
              page = @source.vector(id, offset: offset, limit: @page_size)
              store.ingest(page[:collections])
              progress['lastSuccessAt'] = store.timestamp
              # Explore at most three current pages; never resurrect the unbounded historical archive.
              progress['nextOffset'] = page[:count] < @page_size || offset >= @page_size*2 ? 0 : offset+@page_size
              @stats['vectorReadCount'] += 1
            end
          end
          @scheduler.playlists(@playlist_limit).each do |item|
            id = item.dig('collection','id')
            attempt("playlist:#{id}", item: item) do
              item['lastAttemptAt'] = store.timestamp
              response = @source.playlist(id, etag: item.dig('tracks','etag'))
              if response[:not_modified]
                raise HTTPError, '304 without a validated track payload.' unless item.dig('tracks','payload').is_a?(Array) && !item['tracks']['payload'].empty?
                item['tracks']['validatedAt'] = store.timestamp
              else
                item['tracks'] = {'payload'=>response[:tracks], 'etag'=>response[:etag], 'metadata'=>response[:metadata], 'validatedAt'=>store.timestamp}
              end
              item['status'] = 'ready'
              item.delete('retryAt'); item.delete('failureCount')
              @stats['validatedPlaylistCount'] += 1
            end
          end
        end
        result = @publisher.publish(@stats)
        @logger.call(CanonicalJSON.pretty(result))
        result
      ensure
        store.checkpoint
      end

      private
      def attempt(key, item: nil)
        return if @stats['halted']
        yield
      rescue RateLimitError => error
        store.data['retryAfterUntil'] = (@now.call + [error.retry_after.to_i,3600].max).iso8601
        @stats.merge!('halted'=>true, 'haltReason'=>'upstream_rate_limit')
      rescue RequestBudgetExceeded
        @stats.merge!('halted'=>true, 'haltReason'=>'request_budget')
      rescue UnavailableCollection
        item['status'] = 'unavailable'
        item.delete('tracks')
        item['retryAt'] = (@now.call+86400).iso8601
        @stats['unavailableCount'] += 1
      rescue HTTPError, JSON::ParserError => error
        @stats['upstreamFailures'] += 1
        @stats['failures'] << {'resource'=>key,'reason'=>error.message[0,180]}
        if item
          item['failureCount'] = item.fetch('failureCount',0)+1
          item['retryAt'] = (@now.call+[3600*(2**[item['failureCount']-1,5].min),86400].min).iso8601
        end
      end
    end
  end
end
