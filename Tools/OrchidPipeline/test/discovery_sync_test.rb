# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/discovery/sync'

class DiscoverySyncTest < Minitest::Test
  D = OrchidPipeline::Discovery
  class Transport
    attr_accessor :handler
    attr_reader :requests
    def initialize(&handler)
      @handler, @requests = handler, []
    end
    def request(**args)
      @requests << args
      @handler.call(args)
    end
  end

  def setup
    @now = Time.utc(2026,9,23,9)
    @dir = Dir.mktmpdir
    @out = File.join(@dir,'public')
    @state = File.join(@dir,'state.json')
  end
  def teardown = FileUtils.remove_entry(@dir)
  def response(body, status: 200)
    OrchidPipeline::HTTPResult.new(status:status,headers:{'etag'=>'fixture'},body:JSON.generate(body))
  end
  def raw(id, title = id)
    {'type'=>'playlist','ref'=>id,'title'=>title,'size'=>100}
  end
  def track(id = 'abcdefghijk')
    {'type'=>'music','t'=>'yt','f'=>id,'tt'=>"Song #{id}",'tm'=>180,'statusCode'=>0}
  end
  def transport
    Transport.new do |r|
      case r[:path]
      when '/api/getPage'
        response({'getPage'=>{'items'=>[{'type'=>'carousel','id'=>'featured','items'=>[raw('a'),raw('b')]}]}})
      when '/api/page/getSearch'
        response({'items'=>[{'type'=>'genre','ref'=>'vector_systemlist_zh_genre_cpop'},
          {'type'=>'carousel','id'=>'genreShelfCommute','vectorId'=>'vector_systemlist_zh_mood_commute','items'=>[raw('c')]}]})
      when '/api/getVector'
        response({'getVector'=>{'items'=>[raw('d')]}})
      when '/api/playlist'
        id=r[:query]['vectorId']
        response({'id'=>id,'itemCount'=>1,'next'=>nil,'items'=>[track(id.ljust(11,'x'))]})
      else; raise "Unexpected request #{r}"
      end
    end
  end
  def sync(t = transport, **opts)
    D::Sync.new(transport:t, output:@out,state:@state,now:-> {@now},minimum:1,logger:-> (_) {},**opts)
  end
  def store = D::Store.new(@state,output:@out,now:-> {@now})
  def catalog
    m=JSON.parse(File.read(File.join(@out,'manifest.json')))
    JSON.parse(File.read(File.join(@out,m['catalog']['path'])))
  end

  def test_recorded_mbplayer_contract_handles_unavailable_total_and_song_seed_order
    {'featured'=>11,'cpop'=>69,'seed_mix'=>25}.each do |name,count|
      body=JSON.parse(File.read(File.join(__dir__,"fixtures/mbplayer_#{name}.json")))
      source=D::MBPlayerSource.new(Transport.new { |_| response(body) })
      parsed=source.playlist(body.fetch('id'))
      assert_equal count,parsed[:tracks].length
      assert_equal body['items'][0]['f'],parsed[:tracks][0]['id']
      assert_operator body['total'],:>,count
    end
  end

  def test_page_adapter_keeps_music_only_and_source_topics
    t=transport
    source=D::MBPlayerSource.new(t)
    page=source.page('Search')
    assert_includes page[:vectors], 'vector_systemlist_zh_mood_commute'
    assert_equal ['c'], page[:collections].map { |x| x.first['id'] }
    assert_equal ['mood:commute'], page[:collections][0][0]['rankingMetadata']['topics']
    assert_equal '{}', t.requests[0][:body]
  end

  def test_full_build_publishes_complete_graph_with_topics_and_no_preview_as_full_list
    result=sync.run
    assert_equal 4, result['collectionCount']
    assert_equal 4, result['uniqueTrackCount']
    assert_equal 1, result['topicCoverage']['genre:cpop']
    assert_equal 2, result['topicCoverage']['mood:commute']
    catalog['collections'].each do |c|
      path=File.join(@out,c['tracks']['path'])
      assert_equal c['tracks']['sha256'], Digest::SHA256.file(path).hexdigest
      assert_equal 1, c['tracks']['trackCount']
      assert_equal JSON.parse(File.read(path))['tracks'].first(3), c['previewTracks']
    end
  end

  def test_rotating_discovery_does_not_remove_prior_vectors_or_recent_candidates
    sync.run
    @now+=7200
    t=transport
    base=t.handler
    t.handler=->(r) { r[:path]=='/api/page/getSearch' ? response({'items'=>[{'type'=>'genre','ref'=>'vector_systemlist_zh_genre_jazz'}]}) : base.call(r) }
    sync(t,vector_limit:0).run
    assert store.vectors.key?('vector_systemlist_zh_genre_cpop')
    assert store.vectors.key?('vector_systemlist_zh_genre_jazz')
    assert catalog['collections'].any? { |c| c['id']=='c' }
  end

  def test_manual_reruns_share_the_two_hour_upstream_budget
    sync.run
    @now += 60
    t=Transport.new { |_| flunk 'A manual rerun must not bypass the sync cadence' }
    result=sync(t).run
    assert_empty t.requests
    assert result['syncDeferredUntil']
    assert_equal 4,result['collectionCount']
  end

  def test_missing_groups_get_capacity_and_failed_attempts_do_not_starve_others
    s=store
    rows=(0...30).map do |i|
      c=OrchidPipeline::PayloadParser.collections({'items'=>[raw("p#{i}")]}).first
      c['rankingMetadata']={'topics'=>[i<20 ? 'genre:pop' : 'genre:cpop']}
      [c,'fixture']
    end
    s.ingest(rows)
    scheduler=D::Scheduler.new(s,now:-> {@now})
    first=scheduler.playlists(4)
    assert_equal 2, first.count { |x| s.ranking(x)['topics']==['genre:cpop'] }
    first.each { |x| x['lastAttemptAt']=s.timestamp }
    next_ids=scheduler.playlists(4).map { |x| x['collection']['id'] }
    assert_empty(next_ids & first.map { |x| x['collection']['id'] })
  end

  def test_playlist_rejects_identity_mismatch_partial_pages_and_deleted_records
    bodies=[{'id'=>'wrong','items'=>[track]}, {'id'=>'x','items'=>[track],'next'=>'page2'},
      {'id'=>'x','items'=>[track],'itemCount'=>2}, {'error'=>{'code'=>106}}]
    bodies.each_with_index do |body,i|
      t=Transport.new { |_| response(body) }
      assert_raises(i==3 ? OrchidPipeline::UnavailableCollection : OrchidPipeline::HTTPError) { D::MBPlayerSource.new(t).playlist('x') }
    end
  end

  def test_rate_limit_is_checkpointed_and_next_run_makes_zero_requests
    sync.run
    @now+=7200
    t=Transport.new { |_| raise OrchidPipeline::RateLimitError.new('limited',retry_after:7200) }
    result=sync(t).run
    assert_equal 1,t.requests.length
    assert_equal true,result['halted']
    @now+=60
    t=Transport.new { |_| flunk 'Cooldown must not call upstream' }
    sync(t).run
    assert_empty t.requests
    assert_equal 4,catalog['collections'].length
  end

  def test_transient_error_does_not_extend_track_validation_and_reports_degradation
    sync.run
    before=store.candidates['a']['tracks']['validatedAt']
    @now+=49*3600
    t=transport;base=t.handler
    t.handler=->(r) { r[:path]=='/api/playlist' ? (raise OrchidPipeline::HTTPError,'temporary') : base.call(r) }
    result=sync(t).run
    assert_operator result['upstreamFailures'], :>, 0
    assert_equal before,store.candidates['a']['tracks']['validatedAt']
    assert_equal 4,result['refreshDueCollectionCount']
  end

  def test_unavailable_playlist_is_removed_without_erasing_valid_neighbors
    sync.run
    @now+=49*3600
    t=transport;base=t.handler
    t.handler=->(r) { r[:path]=='/api/playlist' && r[:query]['vectorId']=='a' ? response({'error'=>{'code'=>106}}) : base.call(r) }
    sync(t).run
    refute catalog['collections'].any? { |x| x['id']=='a' }
    assert_equal 'unavailable',store.candidates['a']['status']
    refute store.candidates['a'].key?('tracks')
  end

  def test_duplicate_track_sets_merge_topics_but_keep_distinct_source_identities_in_state
    t=transport;base=t.handler
    t.handler=->(r) { r[:path]=='/api/playlist' ? response({'items'=>[track],'next'=>nil}) : base.call(r) }
    result=sync(t).run
    assert_equal 1,result['collectionCount']
    assert_equal 4,store.candidates.length
    assert_equal ['genre:cpop','mood:commute'],catalog['collections'][0]['rankingMetadata']['topics']
  end

  def test_expired_catalog_retains_manifest_and_writes_failed_health
    sync.run
    old=File.read(File.join(@out,'manifest.json'))
    @now+=8*86400
    t=Transport.new { |_| raise OrchidPipeline::HTTPError,'offline' }
    assert_raises(OrchidPipeline::QualityGateError) { sync(t).run }
    assert_equal old,File.read(File.join(@out,'manifest.json'))
    health=JSON.parse(File.read(File.join(@out,'health.json')))
    assert_equal 'retained',health['publication']
    assert_operator health['upstreamFailures'],:>,0
    assert_equal 2,store.data['schemaVersion']
  end

  def test_migration_keeps_verified_catalog_and_cooldown_but_does_not_trust_old_unverified_tracks
    sync.run
    generated=JSON.parse(File.read(@state))
    old={'schemaVersion'=>1,'discovery'=>{'vectorIDs'=>['vector_test']},'resources'=>{},
      'retryAfterUntil'=>(@now+3600).iso8601}
    generated['candidates'].each { |id,item| old['resources']["playlist:#{id}"]=item['tracks'] }
    old['resources']['playlist:orphan']={'payload'=>[track]}
    File.write(@state,JSON.generate(old))
    migrated=store
    assert_equal 4,migrated.candidates.length
    assert_equal old['retryAfterUntil'],migrated.data['retryAfterUntil']
    assert migrated.vectors.key?('vector_test')
    refute migrated.candidates.key?('orphan')
  end
end
