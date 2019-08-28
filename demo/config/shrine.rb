require "./config/credentials"

require "shrine"
require "shrine/storage/s3"
require "shrine/storage/url"

require "dry-monitor"

s3_options = {
  bucket:            ENV.fetch("S3_BUCKET"),
  region:            ENV.fetch("S3_REGION"),
  access_key_id:     ENV.fetch("S3_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("S3_SECRET_ACCESS_KEY"),
}

Shrine.storages = {
  cache: Shrine::Storage::S3.new(prefix: "cache", **s3_options),
  store: Shrine::Storage::S3.new(**s3_options),
}

Shrine.plugin :instrumentation, notifications: Dry::Monitor::Notifications.new(:app)

Shrine.plugin :sequel
Shrine.plugin :backgrounding
Shrine.plugin :derivatives

Shrine.plugin :transloadit,
  auth: {
    key:    ENV.fetch("TRANSLOADIT_KEY"),
    secret: ENV.fetch("TRANSLOADIT_SECRET"),
  },
  credentials: {
    cache: :shrine_s3,
    store: :shrine_s3,
  }

require "./jobs/promote_job"
require "./jobs/destroy_job"

Shrine::Attacher.promote_block do
  PromoteJob.perform_async(record.class, record.id, name, file_data)
end

Shrine::Attacher.destroy_block do
  DestroyJob.perform_async(self.class, data)
end
