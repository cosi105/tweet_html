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
    @tweet_id = 1
    @tweet_body = 'Scalability is the best'
    @author_handle = 'Ari'
    @tweet_created = DateTime.now
    @tweet = { tweet_id: @tweet_id, tweet_body: @tweet_body, author_handle: @author_handle, tweet_created: @tweet_created }.to_json

    @expected_html = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
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
    REDIS_EVEN.get('2').must_equal "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
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
    RABBIT_EXCHANGE.publish(follow_payload, routing_key: 'new_tweet.follower_ids')
    sleep 3
    %w[2 3 4].each { |i| REDIS_TIMELINE_HTML.get(i).must_equal @expected_html }
  end

  it 'can seed tweets' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
    payload = { owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }.to_json
    seed_tweets(JSON.parse(payload))
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal expected_html2
    expected_timeline_html = @expected_html + expected_html2
    REDIS_TIMELINE_HTML.get(2).must_equal expected_timeline_html
  end

  it 'can seed tweets from the seed queue' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
    payload = { owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }.to_json
    RABBIT_EXCHANGE.publish(payload, routing_key: 'timeline.data.seed.tweet_html')
    sleep 3
    REDIS_EVEN.keys.count.must_equal 1
    REDIS_ODD.keys.count.must_equal 1
    REDIS_ODD.get('1').must_equal @expected_html
    REDIS_EVEN.get('2').must_equal expected_html2
    expected_timeline_html = @expected_html + expected_html2
    REDIS_TIMELINE_HTML.get(2).must_equal expected_timeline_html
  end

  it 'can publish a new timeline' do
    tweet2 = JSON.parse @tweet
    tweet2['tweet_id'] = '2'
    tweet2['tweet_body'] = @tweet_body + '!'
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
    seed_payload = { owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }.to_json
    seed_tweets(JSON.parse(seed_payload))

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
    expected_html2 = "<div class=\"tweet-container\"><div class=\"tweet-body\">#{@tweet_body}!</div><div class=\"tweet-signature\">#{@author_handle}</div><div class=\"tweet-created\">#{@tweet_created}</div></div>"
    seed_payload = { owner_id: 2,
                 sorted_tweets: [JSON.parse(@tweet), tweet2] }.to_json
    seed_tweets(JSON.parse(seed_payload))

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
    payload = {
      tweet_id: 1,
      tokens: %w[scalability is the best]
    }.to_json
    cache_tokens(JSON.parse(payload))
    %w[scalability is the best].each { |token| REDIS_SEARCH_HTML.lrange(token, 0, -1).must_equal([@expected_html]) }
  end
end
