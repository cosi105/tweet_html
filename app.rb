require 'bundler'
require 'json'
Bundler.require

set :port, 8082 unless Sinatra::Base.production?

if Sinatra::Base.production?
  configure do
    redis_uri = URI.parse(ENV['REDISCLOUD_URL'])
    REDIS = Redis.new(host: redis_uri.host, port: redis_uri.port, password: redis_uri.password)
  end
  rabbit = Bunny.new(ENV['CLOUDAMQP_URL'])
else
  Dotenv.load 'local_vars.env'
  REDIS = Redis.new
  rabbit = Bunny.new(automatically_recover: false)
end

rabbit.start
channel = rabbit.create_channel
RABBIT_EXCHANGE = channel.default_exchange

NEW_TWEET = channel.queue('new_tweet.tweet_data')
FOLLOWER_IDS = channel.queue('new_tweet.follower_ids')
HTML_FANOUT = channel.queue('new_tweet.html_fanout')
EVEN = channel.queue('new_tweet.tweet_html.even')
ODD = channel.queue('new_tweet.tweet_html.odd')

NEW_TWEET.subscribe(block: false) do |delivery_info, properties, body|
  route_tweet(JSON.parse(body))
end

FOLLOWER_IDS.subscribe(block: false) do |delivery_info, properties, body|
  fanout_to_html(JSON.parse(body))
end

def route_tweet(body)
  tweet_id = body['tweet_id'].to_i
  shard = tweet_id.even? ? EVEN : ODD
  RABBIT_EXCHANGE.publish(body, routing_key: shard.name)
end

def fanout_to_html(body)
  tweet_id = body['tweet_id'].to_i
  shard = tweet_id.even? ? 'EVEN_URL' : 'ODD_URL'
  shard = ENV[shard]
  get_resp = nil
  loop do
    get_resp = HTTParty.post "#{shard}/get_tweet/#{tweet_id}"
    break #TODO: unless get_resp fails
  end
  payload = {
    tweet_html: get_resp, #TODO: get body of get_resp
    user_ids: body['follower_ids']
  }
  RABBIT_EXCHANGE.publish(payload, routing_key: HTML_FANOUT.name)
end
