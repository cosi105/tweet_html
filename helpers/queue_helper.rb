@rabbit.start
channel = @rabbit.create_channel
RABBIT_EXCHANGE = channel.default_exchange
new_tweet = channel.queue('new_tweet.tweet_data')
follower_ids = channel.queue('new_tweet.follower_ids.timeline_html')
seed = channel.queue('timeline.data.seed.tweet_html')
new_follow_sorted_tweets = channel.queue('new_follow.sorted_tweets')
search_html = channel.queue('searcher.html')
SEARCH_TWEET = channel.queue('new_tweet.searcher.tweet_data')
SEARCH_TWEET_SEED = channel.queue('searcher.data.seed')
cache_purge = channel.queue('cache.purge.tweet_html')

require 'pry-byebug'

def cache_tokens(body)
  tweet_id = body['tweet_id'].to_i
  shard = get_shard(tweet_id)
  tweet_html = shard.get(tweet_id)
  tokens = body['tokens']
  tokens.each do |token|
    REDIS_SEARCH_HTML.lpush(token, tweet_html)
    REDIS_SEARCH_HTML.ltrim(token, 0, PAGE_SIZE - 1)
    REDIS_SEARCH_HTML.set("#{token}:joined", REDIS_SEARCH_HTML.lrange(token, 0, -1).join)
  end
  puts "Cached search results for tweet: #{tweet_id}"
end

# Given a payload with a Timeline Owner/Follower ID & new Timeline Tweet IDs,
# renders & publishes new Timeline HTML.
def cache_new_timeline_html(body)
  sorted_tweet_ids = body['sorted_tweet_ids'].map(&:to_i)[0..PAGE_SIZE - 1]
  evens = sorted_tweet_ids.select(&:even?)
  odds = sorted_tweet_ids.select(&:odd?)
  even_html_map = REDIS_EVEN.mapped_mget(evens)
  odd_html_map = REDIS_ODD.mapped_mget(odds)
  all_html = even_html_map.merge(odd_html_map).sort_by { |k, v| k }.map(&:last)
  new_html = all_html.join
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
    puts "Rendered tweet #{tweet['tweet_id']}"
  end
end

# Generates & returns a Tweet's (timeline piece) HTML
def render_html(body)
  tweet_body = body['tweet_body']
  tweet_created = body['tweet_created']
  author_handle = body['author_handle']
  "<div class=\"tweet-container\"><div class=\"tweet-body\">#{tweet_body}</div><div class=\"tweet-signature\">#{author_handle}</div><div class=\"tweet-created\">#{DateTime.strptime(tweet_created, '%Y-%m-%dT%H:%M:%S.%LZ').strftime("%-m/%-d/%Y %-l:%M %p")}</div></div>"
end

# Fetches a Tweet's HTML from the appropriate Redis shard, then
# enqueues it in a payload with the IDs of the Tweet's followers.
def fanout_to_html(body)
  tweet_id = body['tweet_id'].to_i
  redis_shard = get_shard(tweet_id)
  tweet_html = redis_shard.get(tweet_id)
  body['follower_ids'].each do |f_id|
    existing_html = REDIS_TIMELINE_HTML.get(f_id.to_i) || ''
    REDIS_TIMELINE_HTML.set(f_id.to_i, tweet_html + existing_html)
  end
end

def seed_tweets(body)
  timeline_owner_id = body['owner_id']
  tweets = body['sorted_tweets']
  tweets_as_html = []
  tweets.each do |tweet|
    json_to_html(tweet)
    tweet_id = tweet['tweet_id'].to_i
    tweets_as_html << get_shard(tweet_id).get(tweet_id)
  end
  RABBIT_EXCHANGE.publish(tweets.to_json, routing_key: SEARCH_TWEET_SEED.name)
  REDIS_TIMELINE_HTML.set(timeline_owner_id.to_i, tweets_as_html[0..PAGE_SIZE].join) unless timeline_owner_id == -1
end

# Re-renders & publishes the HTML upon receiving new/modified Timeline Tweet IDs.
new_follow_sorted_tweets.subscribe(block: false) do |_delivery_info, _properties, body|
  cache_new_timeline_html(JSON.parse(body))
end

# Takes a new_tweet payload, generates the Tweet's html & caches it.
new_tweet.subscribe(block: false) do |_delivery_info, _properties, body|
  json_to_html(JSON.parse(body))
  RABBIT_EXCHANGE.publish(body, routing_key: SEARCH_TWEET.name)
end

# Generates a payload containing a new tweet's HTML & the IDs of followers
# who need to have the new Tweet added to their timeline HTML.
follower_ids.subscribe(block: false) do |_delivery_info, _properties, body|
  fanout_to_html(JSON.parse(body))
end

seed.subscribe(block: false) do |_delivery_info, _properties, body|
  seed_tweets(JSON.parse(body))
end

cache_purge.subscribe(block: false) { [REDIS_EVEN, REDIS_ODD].flushall }

search_html.subscribe(block: false) do |_delivery_info, _properties, body|
  cache_tokens(JSON.parse(body))
end
