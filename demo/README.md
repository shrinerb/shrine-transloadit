# Shrine & Transloadit Demo

This is a demo app which integrates Transloadit file uploads with Shrine using
shrine-transloadit.

## Requirements

You need to have the following:

* Transloadit account
* Amazon S3 account
* SQLite

## Setup

* Create a Transloadit template with the following body:

```rb
{
  "steps": {
    "optimize": {
      "robot": "/image/optimize",
      "use": ":original"
    }
  }
}
```

* Add .env with Transloadit and Amazon S3 credentials:

  ```sh
  # .env
  TRANSLOADIT_KEY="..."
  TRANSLOADIT_SECRET="..."
  TRANSLOADIT_TEMPLATE="..."
  S3_BUCKET="..."
  S3_REGION="..."
  S3_ACCESS_KEY_ID="..."
  S3_SECRET_ACCESS_KEY="..."
  ```

* Run `bundle install`

* Run `rake db:migrate`

* Run `bundle exec rackup`
