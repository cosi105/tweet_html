# This file is a DRY way to set all of the requirements
# that our tests will need, as well as a before statement
# that purges the database and creates fixtures before every test

ENV['APP_ENV'] = 'test'
require 'simplecov'
SimpleCov.start
require 'minitest/autorun'
require './app'
require 'pry-byebug'

def app
  Sinatra::Application
end

def publish_tweet(tweet)
  RABBIT_EXCHANGE.publish(tweet, routing_key: 'new_tweet.tweet_data')
  sleep 3
end


describe 'NanoTwitter' do
  include Rack::Test::Methods
  before do
    REDIS_EVEN.flushall
    REDIS_ODD.flushall
    REDIS_SEARCH_HTML.flushall
    REDIS_TIMELINE_HTML.flushall
    RABBIT_EXCHANGE.publish('', routing_key: 'cache.purge.timeline_data')
    RABBIT_EXCHANGE.publish('', routing_key: 'cache.purge.searcher')
    @tweet_id = 1
    @tweet_body = 'Scalability is the best'
    @author_handle = 'Ari'
    @tweet_created = DateTime.now.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    @tweet = { tweet_id: @tweet_id, tweet_body: @tweet_body, author_handle: @author_handle, tweet_created: @tweet_created }.to_json

    @expected_html = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(@tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>"
  end

  it 'can render a tweet as HTML' do
    render_html(JSON.parse(@tweet)).must_equal @expected_html
  end

  it 'can get a tweet from a queue' do
    publish_tweet(@tweet)
    REDIS_EVEN.keys.count.must_equal 0
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
  end

  it 'can shard caches properly' do
    publish_tweet(@tweet)
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    publish_tweet(tweet2.to_json)
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(@tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>"
  end

  it 'can fan out a tweet to followers' do
    publish_tweet @tweet
    follow_payload = {
      'tweet_id': '1',
      'follower_ids': %w[2 3 4]
    }.to_json
    fanout_to_html JSON.parse(follow_payload)
    %w[2 3 4].each { |i| REDIS_TIMELINE_HTML.get(i).must_equal @expected_html }
  end

  it 'can fan out a tweet from a queue' do
    publish_tweet @tweet
    follow_payload = {
      'tweet_id': '1',
      'follower_ids': %w[2 3 4]
    }.to_json
    RABBIT_EXCHANGE.publish(follow_payload, routing_key: 'new_tweet.follower_ids.timeline_html')
    sleep 3
    %w[2 3 4].each { |i| REDIS_TIMELINE_HTML.get(i).must_equal @expected_html }
  end

  it 'can publish a new timeline' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(@tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>"
    [@tweet, tweet2.to_json].each { |t| json_to_html(JSON.parse t) }

    payload = {
      follower_id: 2,
      sorted_tweet_ids: [1, 2]
    }.to_json
    cache_new_timeline_html(JSON.parse(payload))
    expected_timeline_html = @expected_html + expected_html2
    REDIS_TIMELINE_HTML.get(2).must_equal expected_timeline_html
  end

  it 'can publish a new timeline from queue' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(@tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>"
    [@tweet, tweet2.to_json].each { |t| json_to_html(JSON.parse t) }

    payload = {
      follower_id: 2,
      sorted_tweet_ids: [1, 2]
    }.to_json
    RABBIT_EXCHANGE.publish(payload, routing_key: 'new_follow.sorted_tweets')
    sleep 3
    expected_timeline_html = @expected_html + expected_html2
    REDIS_TIMELINE_HTML.get(2).must_equal expected_timeline_html
  end

  it 'can cache search results' do
    publish_tweet(@tweet)
    sleep 1
    %w[scalability is the best].each do |token|
      REDIS_SEARCH_HTML.lrange(token, 0, -1).must_equal([@expected_html])
      REDIS_SEARCH_HTML.get("#{token}:joined").must_equal @expected_html
    end
  end

  it 'can get a new page of a timeline' do
    tweets = Array.new(100) { |i| { tweet_id: i, tweet_body: i.to_s, author_handle: @author_handle, tweet_created: @tweet_created } }
    tweets.each do |t|
      RABBIT_EXCHANGE.publish(t.to_json, routing_key: 'new_tweet.tweet_data')
      follower_id_payload = {
        tweet_id: t[:tweet_id],
        follower_ids: [2]
      }.to_json
      %w[new_tweet.follower_ids.timeline_data new_tweet.follower_ids.timeline_html].each { |queue| RABBIT_EXCHANGE.publish(follower_id_payload, routing_key: queue) }
      puts "Published tweet #{t[:tweet_id]}"
    end

    sleep 3

    expected_page_2 = tweets[50..99].map { |t| "<div class=\"tweet-container\"><div class=\"tweet-body\">#{t[:tweet_body]}</div><div class=\"tweet-signature\">#{t[:author_handle]}</div><div class=\"tweet-created\">#{DateTime.strptime(t[:tweet_created], '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>" }.join

    (get '/timeline?user_id=2&page_num=2').body.must_equal expected_page_2
  end

  it 'can get a new page of search results' do
    tweets = Array.new(100) { |i| { tweet_id: i, tweet_body: "scalability", author_handle: @author_handle, tweet_created: @tweet_created } }
    tweets.each do |t|
      RABBIT_EXCHANGE.publish(t.to_json, routing_key: 'new_tweet.tweet_data')
    end

    sleep 3

    resp_body = (get '/search?token=scalability&page_num=2').body

    resp_body.gsub!("<div class=\"tweet-container\"><div class=\"tweet-body\">", '')
    resp_body.gsub!("</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(@tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>", "")

    resp_body.length.must_equal 'scalability'.length * 50
  end
end
