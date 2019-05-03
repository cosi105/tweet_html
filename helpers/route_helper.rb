def paginate_from_url(url, params)
  new_params = params.clone # expected params: user id or token id, page number
  new_params[:page_size] = PAGE_SIZE
  tweet_ids = HTTParty.get(url, query: new_params).parsed_response
  JSON.parse(tweet_ids).map(&:to_i).map { |i| get_shard(i).get(i) }.join
end

get '/timeline' do
  paginate_from_url("#{ENV['TIMELINE_DATA_URL']}/timeline", params)
end

get '/search' do
  paginate_from_url("#{ENV['SEARCHER_URL']}/search", params)
end
