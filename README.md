# NanoTwitter: Tweet HTML

This microservice is responsible for caching new tweets as HTML, such that the client app never has to get the tweet's body from the database.

Production deployment: https://nano-twitter-tweet-html.herokuapp.com/

[![Codeship Status for cosi105/tweet_html](https://app.codeship.com/projects/cfedf360-4ad7-0137-b293-7e643328ef00/status?branch=master)](https://app.codeship.com/projects/338629)
[![Maintainability](https://api.codeclimate.com/v1/badges/0e9369f1900877991f67/maintainability)](https://codeclimate.com/github/cosi105/tweet_html/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/0e9369f1900877991f67/test_coverage)](https://codeclimate.com/github/cosi105/tweet_html/test_coverage)

## Subscribed Queues

### new\_tweet.tweet\_data

- author_id
- tweet_id
- tweet_body

### new\_tweet.follower\_ids

- tweet_id
- follower_ids

## Published Queues

### new\_tweet.html\_fanout

- tweet_html
- follower_ids

## Caches

### tweet\_id: tweet\_html (tweets with even ids)
### tweet\_id: tweet\_html (tweets with odd ids)