# frozen_string_literal: true
require_relative '../orchid_pipeline'

module OrchidPipeline
  module Discovery
    # Only metadata is normalized. No cookies, history, telemetry or stream URLs persist.
    module Metadata
      TOPICS = {
        'cpop'=>'genre:cpop', 'pop'=>'genre:pop', 'kpop'=>'genre:kpop', 'jpop'=>'genre:jpop',
        'hk'=>'region:hong-kong', 'never_go_out'=>'era:evergreen', 'hiphop'=>'genre:hip-hop',
        'rock'=>'genre:rock', 'electronic_dance'=>'genre:electronic-dance', 'jazz'=>'genre:jazz',
        'country'=>'genre:country', 'soundtrack'=>'genre:soundtrack', 'relax'=>'mood:chill',
        'good_mood'=>'mood:good', 'party'=>'mood:party', 'travel'=>'mood:travel',
        'romance'=>'mood:romance', 'sleep'=>'mood:sleep', 'focus'=>'mood:focus',
        'sad'=>'mood:sad', 'commute'=>'mood:commute', 'chill'=>'mood:chill',
        'workout'=>'mood:workout', 'energy'=>'mood:energy', 'gaming'=>'mood:gaming',
        'dinner'=>'mood:dinner', 'themed'=>'mood:themed'
      }.freeze
      TAGS = TOPICS.merge('good'=>'mood:good', 'indie'=>'genre:indie', '嘻哈饒舌'=>'genre:hip-hop',
                         '提神醒腦'=>'mood:energy', '經典金曲'=>'era:evergreen').freeze
      CHART_TOPICS = {
        '10086761'=>'genre:cpop', '18731187'=>'genre:cpop', '10088896'=>'genre:pop',
        '28406176'=>'genre:pop', '15296535'=>'genre:kpop', '10102106'=>'genre:jpop',
        '18731188'=>'genre:jpop', '74405929'=>'genre:pop', '18731189'=>'genre:pop'
      }.freeze
      SHELVES = {'topChart'=>'charts', 'featured'=>'featured', 'newRelease'=>'latest',
                 'recommendPlaylists'=>'discovery', 'genreMoodPlaylists'=>'curated'}.freeze
      module_function

      def ranking(vector: nil, shelf: nil, tags: [], id: nil)
        suffix = vector.to_s.sub(/\Avector_systemlist_zh_(genre|mood)_/, '')
        topics = [TOPICS[suffix], CHART_TOPICS[id]] + Array(tags).filter_map { |t| TAGS[t.to_s.downcase] }
        signal = SHELVES[shelf] || {'vector_latest_zh'=>'latest', 'vector_featured_zh'=>'featured',
          'vector_systemlist_zh_top_charts'=>'charts'}[vector]
        {'topics'=>topics.compact.uniq.sort, 'editorialSignals'=>[signal].compact}
      end

      def merge(*values)
        {'topics'=>values.flat_map { |x| Array(x&.fetch('topics', nil)) }.uniq.sort,
         'editorialSignals'=>values.flat_map { |x| Array(x&.fetch('editorialSignals', nil)) }.uniq.sort}
      end
    end

    class MBPlayerSource
      attr_reader :transport
      def initialize(transport)
        @transport = transport
      end

      def page(name)
        path = name == 'Home' ? '/api/getPage' : '/api/page/getSearch'
        root = json(method: 'POST', path: path, query: {'page'=>name}, body: '{}')
        items = items!(root)
        vectors = PayloadParser.vector_ids(root)
        collections = []
        visit = lambda do |rows, shelf, vector|
          rows.each do |raw|
            next unless raw.is_a?(Hash)
            if %w[carousel wrapContainer].include?(raw['type'])
              child_vector = raw['vectorId']
              vectors << child_vector if valid_vector?(child_vector)
              visit.call(Array(raw['items']), raw['id'] || shelf, child_vector || vector)
            elsif raw['type'] == 'playlist'
              collection = PayloadParser.collections({'items'=>[raw]}).first
              next unless collection
              collection['rankingMetadata'] = Metadata.ranking(vector: vector, shelf: shelf, tags: raw['tags'], id: collection['id'])
              collections << [collection, "#{name}:#{shelf || 'other'}"]
            end
          end
        end
        visit.call(items, nil, nil)
        {collections: collections, vectors: vectors.select { |id| valid_vector?(id) }.uniq}
      end

      def vector(id, offset:, limit:)
        root = json(method: 'GET', path: '/api/getVector', query: {
          'vectorId'=>id, 'type'=>'vector', 'skip'=>offset.to_s, 'limit'=>limit.to_s
        })
        items = items!(root)
        collections = PayloadParser.collections(root).map do |collection|
          raw = items.find { |x| x.is_a?(Hash) && x['ref'].to_s == collection['id'] } || {}
          collection['rankingMetadata'] = Metadata.ranking(vector: id, tags: raw['tags'], id: collection['id'])
          [collection, "vector:#{id}"]
        end
        {collections: collections, count: items.length}
      end

      def playlist(id, etag: nil)
        result = @transport.request(method: 'GET', path: '/api/playlist',
          query: {'reverse'=>'true', 'type'=>'playlist', 'vectorId'=>id}, etag: etag)
        return {not_modified: true} if result.status == 304
        root = JSON.parse(result.body)
        error = root.is_a?(Hash) && root['error']
        if root.is_a?(Hash) && (root['deleted'] == true || (error.is_a?(Hash) && error['code'].to_i == 106))
          raise UnavailableCollection, 'Playlist is unavailable.'
        end
        rows = items!(root)
        page = root['getPlaylist'] || root['getVector'] || root
        raise HTTPError, 'Playlist identity mismatch.' if page['id'] && page['id'].to_s != id
        # The observed endpoint returns the entire list (next:null). Never certify a truncated page.
        raise HTTPError, 'Playlist pagination requires an adapter update.' if page['next']
        expected = Integer(page['itemCount'], exception: false)
        raise HTTPError, 'Playlist response is incomplete.' if expected && rows.length < expected
        tracks = PayloadParser.tracks(root)
        raise UnavailableCollection, 'Playlist has no usable tracks.' if tracks.empty?
        {tracks: tracks, etag: result.headers['etag'], metadata: {
          'sourceUpdatedAt'=>page['lastUpdate'], 'createdAt'=>page['created'], 'sourceTitle'=>page['name'],
          'rawTrackCount'=>rows.length, 'filteredTrackCount'=>rows.length-tracks.length
        }.compact}
      end

      private
      def json(**args)
        JSON.parse(@transport.request(**args).body)
      end

      def items!(root)
        raise HTTPError, 'Malformed upstream response.' unless root.is_a?(Hash) && !root['error']
        page = root['getPage'] || root['getVector'] || root['getPlaylist'] || root
        raise HTTPError, 'Missing upstream items array.' unless page.is_a?(Hash) && page['items'].is_a?(Array)
        page['items']
      end

      def valid_vector?(id)
        id.is_a?(String) && id.match?(/\Avector_[A-Za-z0-9_]+\z/) && !id.start_with?('vector_artists_')
      end
    end
  end
end
