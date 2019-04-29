require 'bundler'
require 'json'
Bundler.require

set :port, 8082 unless Sinatra::Base.production?

if Sinatra::Base.production?
  configure do
    redis_even_uri = URI.parse(ENV['REDIS_URL'])
    redis_odd_uri = URI.parse(ENV['HEROKU_REDIS_PURPLE_URL'])
    REDIS_EVEN = Redis.new(host: redis_even_uri.host, port: redis_even_uri.port, password: redis_even_uri.password)
    REDIS_ODD = Redis.new(host: redis_odd_uri.host, port: redis_odd_uri.port, password: redis_odd_uri.password)
  end
  rabbit = Bunny.new(ENV['CLOUDAMQP_URL'])
else
  REDIS_EVEN = Redis.new
  REDIS_ODD = Redis.new(port: 6380)
  rabbit = Bunny.new(automatically_recover: false)
end

rabbit.start
channel = rabbit.create_channel
RABBIT_EXCHANGE = channel.default_exchange
new_tweet = channel.queue('new_tweet.tweet_data')
follower_ids = channel.queue('new_tweet.follower_ids')
HTML_FANOUT = channel.queue('new_tweet.html_fanout')
seed = channel.queue('tweet.data.seed')
TIMELINE_SEED = channel.queue('timeline.html.seed')
new_follow_sorted_tweets = channel.queue('new_follow.sorted_tweets')
SORTED_HTML = channel.queue('new_follow.sorted_html')

# Re-renders & publishes the HTML upon receiving new/modified Timeline Tweet IDs.
new_follow_sorted_tweets.subscribe(block: false) do |delivery_info, properties, body|
  publish_new_timeline_html(JSON.parse(body))
end

# Takes a new_tweet payload, generates the Tweet's html & caches it.
new_tweet.subscribe(block: false) do |delivery_info, properties, body|
  json_to_html(JSON.parse(body))
end

# Generates a payload containing a new tweet's HTML & the IDs of followers
# who need to have the new Tweet added to their timeline HTML.
follower_ids.subscribe(block: false) do |delivery_info, properties, body|
  fanout_to_html(JSON.parse(body))
end

seed.subscribe(block: false) do |delivery_info, properties, body|
  seed_tweets(JSON.parse(body))
end

# Given a payload with a Timeline Owner/Follower ID & new Timeline Tweet IDs,
# renders & publishes new Timeline HTML.
def publish_new_timeline_html(body)
  sorted_tweet_ids = body['sorted_tweet_ids'].map(&:to_i)
  evens = sorted_tweet_ids.select(&:even?)
  odds = sorted_tweet_ids.select(&:odd?)
  even_html_map = REDIS_EVEN.mapped_mget(evens)
  odd_html_map = REDIS_ODD.mapped_mget(odds)
  new_html = even_html_map.merge(odd_html_map).sort_by { |k, v| k }.map(&:last).join
  payload = {
    owner_id: body['follower_id'],
    new_timeline_html: new_html
  }.to_json
  RABBIT_EXCHANGE.publish(payload, routing_key: SORTED_HTML.name)
end

def get_shard(tweet_id)
  tweet_id.even? ? REDIS_EVEN : REDIS_ODD # Thread safe?
end

def json_to_html(tweet)
  tweet_id = tweet['tweet_id'].to_i
  redis_shard = get_shard(tweet_id)
  unless redis_shard.exists(tweet_id)
    tweet_html = render_html(tweet)
    redis_shard.set(tweet_id, tweet_html)
  end
end

# Generates & returns a Tweet's (timeline piece) HTML
def render_html(body)
  tweet_body = body['tweet_body']
  tweet_created = body['tweet_created']
  author_handle = body['author_handle']
  "<li>#{tweet_body}<br>- #{author_handle} #{tweet_created}</li>"
end

# Fetches a Tweet's HTML from the appropriate Redis shard, then
# enqueues it in a payload with the IDs of the Tweet's followers.
def fanout_to_html(body)
  tweet_id = body['tweet_id'].to_i
  redis_shard = get_shard(tweet_id)
  payload = {
    tweet_html: redis_shard.get(tweet_id),
    user_ids: body['follower_ids']
  }.to_json
  RABBIT_EXCHANGE.publish(payload, routing_key: HTML_FANOUT.name)
end

def seed_tweets(body)
  payload = []
  body.each do |timeline|
    timeline_owner_id = timeline['owner_id']
    tweets = timeline['sorted_tweets']
    tweets_as_html = []
    tweets.each do |tweet|
      json_to_html(tweet)
      tweet_id = tweet['tweet_id'].to_i
      tweets_as_html << get_shard(tweet_id).get(tweet_id)
    end
    payload << { owner_id: timeline_owner_id, sorted_tweets: tweets_as_html } unless timeline_owner_id == -1
  end
  RABBIT_EXCHANGE.publish(payload.to_json, routing_key: TIMELINE_SEED.name)
end
