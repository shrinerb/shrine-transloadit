require "./config/credentials"

require "shrine"
require "shrine/storage/s3"

require "./jobs/transloadit_job"
require "./jobs/delete_job"

Shrine.storages[:store] = Shrine::Storage::S3.new(
  bucket:            ENV.fetch("S3_BUCKET"),
  region:            ENV.fetch("S3_REGION"),
  access_key_id:     ENV.fetch("S3_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("S3_SECRET_ACCESS_KEY"),
)

Shrine.plugin :transloadit,
  auth_key:    ENV.fetch("TRANSLOADIT_AUTH_KEY"),
  auth_secret: ENV.fetch("TRANSLOADIT_AUTH_SECRET")

Shrine.plugin :sequel
Shrine.plugin :backgrounding
Shrine.plugin :logging

Shrine::Attacher.promote { |data| TransloaditJob.perform_async(data) }
Shrine::Attacher.delete { |data| DeleteJob.perform_async(data) }
