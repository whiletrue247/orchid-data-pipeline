# frozen_string_literal: true
require_relative 'source'

module OrchidPipeline
  module Discovery
    class Store
      attr_reader :data
      def initialize(path, output:, now:)
        @path, @now = path, now
        loaded = read(path)
        @data = loaded && loaded['schemaVersion'] == 2 ? loaded : migrate(loaded, output)
      end

      def candidates = @data['candidates']
      def vectors = @data['vectors']
      def timestamp = @now.call.iso8601
      def time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        Time.at(0).utc
      end

      def register_vectors(ids)
        ids.each { |id| (vectors[id] ||= {'nextOffset'=>0})['lastSeenAt'] = timestamp }
      end

      def ingest(rows)
        rows.each do |collection, source|
          id = collection.fetch('id')
          item = candidates[id] ||= {'firstSeenAt'=>timestamp, 'sources'=>{}}
          item['lastSeenAt'] = timestamp
          item['collection'] = collection.reject { |k,_| k == 'rankingMetadata' }
          item['sources'][source] = {'lastSeenAt'=>timestamp, 'ranking'=>collection.fetch('rankingMetadata', {})}
          item['collection']['rankingMetadata'] = ranking(item)
        end
      end

      def ranking(item)
        active = item.fetch('sources', {}).values.select { |s| @now.call - time(s['lastSeenAt']) <= 14*86400 }
        Metadata.merge(*active.map { |s| s['ranking'] })
      end

      def fresh?(item, max_age: 7*86400)
        tracks = item['tracks']
        tracks.is_a?(Hash) && tracks['payload'].is_a?(Array) && !tracks['payload'].empty? &&
          @now.call - time(tracks['validatedAt']) <= max_age && item['status'] != 'unavailable'
      end

      def eligible?(item)
        fresh?(item) && @now.call - time(item['lastSeenAt']) <= 14*86400
      end

      def checkpoint
        # Bound state without discarding published/healthy records. Favorites retain immutable objects.
        if candidates.length > 1500
          disposable = candidates.reject { |_,v| eligible?(v) }.sort_by { |_,v| time(v['lastSeenAt']) }
          disposable.first(candidates.length-1500).each { |id,_| candidates.delete(id) }
        end
        atomic(@path, @data)
      end

      def atomic(path, value)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.tmp-#{Process.pid}"
        File.write(temporary, CanonicalJSON.pretty(value))
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary)
      end

      private
      def read(path)
        JSON.parse(File.read(path)) if File.file?(path)
      end

      def migrate(old, output)
        @data = {'schemaVersion'=>2, 'candidates'=>{}, 'vectors'=>{}, 'pages'=>{}}
        return @data unless old.is_a?(Hash)
        @data['retryAfterUntil'] = old['retryAfterUntil'] if old['retryAfterUntil']
        ids = Array(old.dig('discovery', 'vectorIDs')) + Builder::PREFERRED_VECTOR_IDS
        register_vectors(ids.uniq)
        manifest = read(File.join(output, 'manifest.json'))
        if manifest && manifest.dig('catalog', 'path')&.match?(/\Aobjects\/[0-9a-f]{64}\.json\z/)
          catalog = read(File.join(output, manifest.dig('catalog','path')))
          Array(catalog&.fetch('collections', nil)).each do |collection|
            id = collection.fetch('id')
            resource = old.dig('resources', "playlist:#{id}")
            next unless resource && resource['validatedAt']
            observed = manifest.fetch('generatedAt')
            candidates[id] = {'collection'=>collection.reject { |k,_| k == 'tracks' },
              'firstSeenAt'=>observed, 'lastSeenAt'=>observed, 'status'=>'ready',
              'sources'=>{'migration'=>{'lastSeenAt'=>observed, 'ranking'=>collection['rankingMetadata']}},
              'tracks'=>{'payload'=>resource['payload'], 'validatedAt'=>resource['validatedAt'], 'etag'=>resource['etag']}}
          end
        end
        # Recent category membership can restore useful topics, but unverified legacy pages are not fresh evidence.
        old.fetch('resources',{}).each do |key, resource|
          match = key.match(/\Avector:(.+):0:\d+\z/)
          next unless match && resource['validatedAt'] && @now.call-time(resource['validatedAt']) <= 7*86400
          Array(resource['payload']).each do |collection|
            item = candidates[collection['id']]
            next unless item
            item['sources']["vector:#{match[1]}"] = {'lastSeenAt'=>resource['validatedAt'],
              'ranking'=>Metadata.ranking(vector: match[1], id: collection['id'])}
            item['collection']['rankingMetadata'] = ranking(item)
          end
        end
        @data
      end
    end
  end
end
