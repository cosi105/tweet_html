require 'csv'
require 'open-uri'
def seed_caches
  seed_from_csv(REDIS_EVEN, 'even')
  seed_from_csv(REDIS_ODD, 'odd')
end

post '/seed/tweets' do
  puts 'Caching tweet HTML...'
  [REDIS_EVEN, REDIS_ODD].each(&:flushall)
  csv = CSV.parse(open(params[:csv_url]))
  csv.each do |line|
    key = line[0].to_i
    value = line[1]
    get_shard(key).set(key, value)
  end
  puts 'Cached tweet HTML!'
end

post '/seed/timeline' do
  puts 'Caching timeline HTML...'
  REDIS_TIMELINE_HTML.flushall
  csv = CSV.parse(open(params[:csv_url]))
  csv.each do |line|
    key = line[0].to_i
    value = line[1]
    REDIS_TIMELINE_HTML.set(key, value)
  end
  puts 'Cached tweet HTML!'
end

post '/seed/search' do
  puts 'Caching search HTML...'
  REDIS_SEARCH_HTML.flushall
  csv = CSV.parse(open(params[:csv_url]))
  csv.each do |line|
    key = line[0]
    if key.include? ':joined'
      REDIS_SEARCH_HTML.push(key, line[1])
    else
      values = line.drop(1)
      REDIS_SEARCH_HTML.lpush(key, values)
    end
  end
  puts 'Seeded tweet HTML!'
end
