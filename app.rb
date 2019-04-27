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

# Takes a new_tweet payload, generates the tweet's html & caches it
new_tweet.subscribe(block: false) do |delivery_info, properties, body|
  tweet_json = JSON.parse(body)
  tweet_id = tweet_json['tweet_id'].to_i
  tweet_html = render_html(tweet_json)
  redis_shard = tweet_id.even? ? REDIS_EVEN : REDIS_ODD # Thread safe?
  redis_shard.set(tweet_id, tweet_html)
end

# Generates a payload containing a new tweet's HTML & the IDs of followers
# who need to have the new Tweet added to their timeline HTML.
follower_ids.subscribe(block: false) do |delivery_info, properties, body|
  fanout_to_html(JSON.parse(body))
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
  redis_shard = tweet_id.even? ? REDIS_EVEN : REDIS_ODD # Thread safe?
  payload = {
    tweet_html: redis_shard.get(tweet_id),
    user_ids: body['follower_ids']
  }.to_json
  RABBIT_EXCHANGE.publish(payload, routing_key: HTML_FANOUT.name)
end
