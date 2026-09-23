# frozen_string_literal: true
require_relative 'store'

module OrchidPipeline
  module Discovery
    class Scheduler
      def initialize(store, now:)
        @store, @now = store, now
      end

      def vectors(limit)
        # Home already supplies charts/latest/featured. Rotate genre coverage, including a bounded second page.
        @store.vectors.select { |id,v| id.include?('_genre_') || id.include?('_mood_') }
          .sort_by { |id,v| [@store.time(v['lastAttemptAt']), id] }.first(limit).map(&:first)
      end

      def playlists(limit)
        ready = @store.candidates.values.select { |item| @store.eligible?(item) }
        coverage = ready.each_with_object(Hash.new(0)) { |item,h| h[bucket(item)] += 1 }
        due = @store.candidates.values.select do |item|
          @store.time(item['retryAt']) <= @now.call &&
            @now.call - @store.time(item['lastSeenAt']) <= 14*86400 &&
            !@store.fresh?(item, max_age: refresh_interval(item))
        end
        # Reserve maintenance capacity before expanding. Attempt timestamps prevent moving-list cursor starvation.
        existing, unknown = due.partition { |item| @store.fresh?(item) }
        maintenance = existing.sort_by { |item| [@store.time(item.dig('tracks','validatedAt')) + refresh_interval(item), item.dig('collection','id')] }
        chosen = maintenance.shift([limit/3, existing.length].min)
        groups = (unknown + maintenance).group_by { |item| bucket(item) }
        groups.each_value { |items| items.sort_by! { |x| [@store.time(x['lastAttemptAt']), -@store.time(x['lastSeenAt']).to_i, x.dig('collection','id')] } }
        allocated = Hash.new(0)
        while chosen.length < limit && !groups.empty?
          key = groups.keys.min_by { |k| [allocated[k], coverage[k], k] }
          chosen << groups[key].shift
          allocated[key] += 1
          groups.delete(key) if groups[key].empty?
        end
        chosen
      end

      def refresh_interval(item)
        signals = @store.ranking(item)['editorialSignals']
        return 6*3600 if signals.include?('charts')
        return 24*3600 if item.dig('collection','id').to_s.match?(/\ARD[A-Za-z0-9_-]{11}\z/)
        48*3600
      end

      def bucket(item)
        ranking = @store.ranking(item)
        topics = ranking['topics']
        return topics.find { |t| t.start_with?('genre:') } || topics.first unless topics.empty?
        ranking['editorialSignals'].first || 'other'
      end
    end
  end
end
