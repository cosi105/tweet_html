require 'bundler'
require 'json'
Bundler.require

set :port, 8082 unless Sinatra::Base.production?

if Sinatra::Base.production?
  configure do
    REDIS_EVEN = redis_from_uri('REDIS_EVEN_URL')
    REDIS_ODD = redis_from_uri('REDIS_ODD_URL')
    REDIS_TIMELINE_HTML = redis_from_uri('TIMELINE_HTML_URL')
  end
  rabbit = Bunny.new(ENV['CLOUDAMQP_URL'])
else
  REDIS_EVEN = Redis.new(port: 6384)
  REDIS_ODD = Redis.new(port: 6383)
  REDIS_TIMELINE_HTML = Redis.new # port 6379
  rabbit = Bunny.new(automatically_recover: false)
end

rabbit.start
channel = rabbit.create_channel
RABBIT_EXCHANGE = channel.default_exchange
new_tweet = channel.queue('new_tweet.tweet_data')
follower_ids = channel.queue('new_tweet.follower_ids')
seed = channel.queue('tweet.data.seed')
new_follow_sorted_tweets = channel.queue('new_follow.sorted_tweets')

# Re-renders & publishes the HTML upon receiving new/modified Timeline Tweet IDs.
new_follow_sorted_tweets.subscribe(block: false) do |delivery_info, properties, body|
  cache_new_timeline_html(JSON.parse(body))
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

def redis_from_uri(key)
  uri = URI.parse(ENV[key])
  Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

# Given a payload with a Timeline Owner/Follower ID & new Timeline Tweet IDs,
# renders & publishes new Timeline HTML.
def cache_new_timeline_html(body)
  sorted_tweet_ids = body['sorted_tweet_ids'].map(&:to_i)
  evens = sorted_tweet_ids.select(&:even?)
  odds = sorted_tweet_ids.select(&:odd?)
  even_html_map = REDIS_EVEN.mapped_mget(evens)
  odd_html_map = REDIS_ODD.mapped_mget(odds)
  new_html = even_html_map.merge(odd_html_map).sort_by { |k, v| k }.map(&:last).join
  REDIS_TIMELINE_HTML.set(body['follower_id'].to_i, new_html)
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
  tweet_html = redis_shard.get(tweet_id)
  body['follower_ids'].each { |f_id| REDIS_TIMELINE_HTML.set(f_id.to_i, tweet_html) }
end

def seed_tweets(body)
  body.each do |timeline|
    timeline_owner_id = timeline['owner_id']
    tweets = timeline['sorted_tweets']
    tweets_as_html = []
    tweets.each do |tweet|
      json_to_html(tweet)
      tweet_id = tweet['tweet_id'].to_i
      tweets_as_html << get_shard(tweet_id).get(tweet_id)
    end
    REDIS_TIMELINE_HTML.set(timeline_owner_id.to_i, tweets_as_html.join) unless timeline_owner_id == -1
  end
end
