# NanoTwitter: Tweet HTML

This microservice is responsible for caching new tweets as HTML, such that the client app never has to get the tweet's body from the database.

Production deployment: https://nano-twitter-tweet-html.herokuapp.com/

[![Codeship Status for cosi105/tweet_html](https://app.codeship.com/projects/cfedf360-4ad7-0137-b293-7e643328ef00/status?branch=master)](https://app.codeship.com/projects/338629)
[![Maintainability](https://api.codeclimate.com/v1/badges/0e9369f1900877991f67/maintainability)](https://codeclimate.com/github/cosi105/tweet_html/maintainability)
[![Test Coverage](https://api.codeclimate.com/v1/badges/0e9369f1900877991f67/test_coverage)](https://codeclimate.com/github/cosi105/tweet_html/test_coverage)

## Message Queues

| Relation | Queue Name | Payload | Interaction |
| :------- | :--------- | :------ |:--
| Subscribes to | `new_tweet.tweet_data` | `{author_id, author_handle, tweet_id, tweet_body, tweet_created}` | Renders the given tweet as HTML and caches it.
| Subscribes to | `new_tweet.follower_ids` | `{tweet_id, [follower_ids]}` | Gets the HTML of the given tweet and publishes to `new_tweet.html_fanout`.
| Publishes to | `new_tweet.html_fanout` | `{tweet_html, [user_ids]}` | Publishes the HTML of a new tweet and a list of followers who need that tweet added to their cached timeline HTML.
| Subscribes to | `new_follow.sorted_tweets` | `{user_id, [sorted_tweet_ids]}` | Gets the HTML of all of the given tweets and publishes them to `new_follow.sorted_html`.
| Publishes to | `new_follow.sorted_html` | `{user_id, [sorted_tweets]}` | Publishes a user's entire timeline as a series of HTML tweets, after it has been modified by a new follow from the user.

## Caches

### tweet\_id: tweet\_html (tweets with even ids)
### tweet\_id: tweet\_html (tweets with odd ids)

## Seeding

This service subscribes to the `tweet.data.seed` queue, which the main NanoTwitter app uses to publish all all of the tweets in timeline format (i.e. a mapping of users to the tweets that belong in their timeline). The service not only builds its cache from the tweets within those timelines, but it then also arranges timelines as HTML strings to send to the Timeline HTML service via the `timeline.html.seed` queue.