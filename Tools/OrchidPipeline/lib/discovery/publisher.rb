# frozen_string_literal: true
require_relative 'scheduler'

module OrchidPipeline
  module Discovery
    class Publisher
      def initialize(store, output:, now:, minimum:)
        @store, @output, @now, @minimum = store, output, now, minimum
      end

      def publish(stats)
        grouped = @store.candidates.values.select { |x| @store.eligible?(x) }
          .sort_by { |x| [Metadata.home_order(@store.ranking(x)), x['firstSeenAt'], x.dig('collection','id')] }
          .group_by { |x| CanonicalJSON.sha256(x['tracks']['payload'].map { |t| t['id'] }.sort) }
        collections = grouped.values.map do |group|
          item = group.first
          ranking = Metadata.merge(*group.map { |x| @store.ranking(x) })
          tracks = item['tracks']['payload']
          object = write_object({'schemaVersion'=>1, 'collectionID'=>item['collection']['id'], 'tracks'=>tracks})
          item['collection'].merge('rankingMetadata'=>ranking, 'subtitle'=>"#{tracks.length} 首",
            'previewTracks'=>tracks.first(3),
            'tracks'=>object.merge('trackCount'=>tracks.length))
        end
        previous = manifest
        if collections.length < @minimum
          health(stats.merge('publication'=>'retained', 'reason'=>'insufficient_verified_collections'), previous)
          raise QualityGateError, "Only #{collections.length} verified collections; retaining the previous catalog."
        end
        # Preserve the existing schema and URL so installed clients receive the update without reinstalling.
        catalog = write_object({'schemaVersion'=>1, 'region'=>{'regionCode'=>'TW','languageTag'=>'zh-TW'},
          'collections'=>collections, 'coverage'=>{'collectionCount'=>collections.length,
          'hydratedPlaylistCount'=>collections.length, 'vectorCount'=>@store.vectors.length}})
        version = catalog.fetch('sha256')
        current = {'schemaVersion'=>1, 'contentVersion'=>version, 'generatedAt'=>@now.call.iso8601,
          'source'=>'orchid-discovery-v4', 'deliveryPolicy'=>'verified-only',
          'region'=>{'regionCode'=>'TW','languageTag'=>'zh-TW'},
          'catalog'=>catalog.merge('collectionCount'=>collections.length)}
        content_changed = previous&.fetch('contentVersion', nil) != version
        @store.atomic(File.join(@output,'manifest.json'), current) if content_changed || previous['source'] != current['source']
        scheduler = Scheduler.new(@store, now: @now)
        result = stats.merge('changed'=>true, 'contentChanged'=>content_changed, 'publication'=>'published',
          'contentVersion'=>version, 'collectionCount'=>collections.length,
          'trackCount'=>collections.sum { |x| x['tracks']['trackCount'] },
          'uniqueTrackCount'=>grouped.values.flat_map { |g| g.first['tracks']['payload'].map { |t| t['id'] } }.uniq.length,
          'topicCoverage'=>collections.flat_map { |x| x['rankingMetadata']['topics'] }.tally,
          'duplicateCollectionCount'=>grouped.values.sum { |g| g.length-1 },
          'refreshDueCollectionCount'=>@store.candidates.values.count { |x| @store.eligible?(x) && !@store.fresh?(x,max_age:scheduler.refresh_interval(x)) })
        health(result, content_changed ? current : previous)
        result
      end

      def health(stats, current = manifest)
        @store.atomic(File.join(@output, 'health.json'), stats.merge('schemaVersion'=>2,
          'homeObservedCount'=>@store.candidates.values.count { |x| Metadata.home_order(@store.ranking(x)) < 1_000_000 },
          'homeVerifiedCount'=>@store.candidates.values.count { |x| Metadata.home_order(@store.ranking(x)) < 1_000_000 && @store.eligible?(x) },
          'homeOpeningMissingIDs'=>@store.candidates.values.select { |x| Array(@store.ranking(x)['placements']).any? { |p| p['surface']=='Home' && p['sectionID']=='recommendPlaylists' } && !@store.eligible?(x) }.map { |x| x.dig('collection','id') },
          'checkedAt'=>@now.call.iso8601, 'contentVersion'=>current&.fetch('contentVersion', nil),
          'collectionCount'=>current&.dig('catalog','collectionCount') || 0,
          'candidateCount'=>@store.candidates.length, 'knownVectorCount'=>@store.vectors.length,
          'retryAfterUntil'=>@store.data['retryAfterUntil'], 'deliveryPolicy'=>'verified-only'))
      end

      private
      def manifest
        path = File.join(@output,'manifest.json')
        JSON.parse(File.read(path)) if File.file?(path)
      end
      def write_object(value)
        bytes = CanonicalJSON.dump(value)
        hash = Digest::SHA256.hexdigest(bytes)
        relative = "objects/#{hash}.json"
        path = File.join(@output, relative)
        FileUtils.mkdir_p(File.dirname(path))
        unless File.file?(path) && File.binread(path) == bytes.b
          tmp = "#{path}.tmp-#{Process.pid}"
          File.binwrite(tmp, bytes)
          File.rename(tmp, path)
        end
        {'path'=>relative, 'sha256'=>hash}
      end
    end
  end
end
