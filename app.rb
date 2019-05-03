# TweetHTML Micro-Service (port 8080)
# Caches:
#   - EvenTweetsHTML (port 6384)
#   - OddTweetsHTML (port 6383)
#   - TimelineHTML (port 6379)

require 'bundler'
require 'json'
Bundler.require

set :port, 8080 unless Sinatra::Base.production?

def redis_from_uri(key)
  uri = URI.parse(ENV[key])
  Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

if Sinatra::Base.production?
  configure do
    REDIS_EVEN = redis_from_uri('REDIS_EVEN_URL')
    REDIS_ODD = redis_from_uri('REDIS_ODD_URL')
    REDIS_TIMELINE_HTML = redis_from_uri('TIMELINE_HTML_URL')
    REDIS_SEARCH_HTML = redis_from_uri('SEARCH_HTML_URL')
  end
  @rabbit = Bunny.new(ENV['CLOUDAMQP_URL'])
else
  Dotenv.load 'local_vars.env'
  REDIS_EVEN = Redis.new(port: 6384)
  REDIS_ODD = Redis.new(port: 6383)
  REDIS_TIMELINE_HTML = Redis.new # port 6379
  REDIS_SEARCH_HTML = Redis.new(port: 6382)
  @rabbit = Bunny.new(automatically_recover: false)
end

Dir["#{__dir__}/helpers/*rb"].each { |file| require file }

PAGE_SIZE = 50
