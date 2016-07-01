require "bundler/setup"

require "minitest/autorun"
require "minitest/pride"

require "minitest/hooks/default"

require "shrine"
require "shrine/storage/s3"
require "shrine/plugins/transloadit"

require "dotenv"

Dotenv.load!

$s3 = Shrine::Storage::S3.new(
  bucket:            ENV.fetch("S3_BUCKET"),
  region:            ENV.fetch("S3_REGION"),
  access_key_id:     ENV.fetch("S3_ACCESS_KEY_ID"),
  secret_access_key: ENV.fetch("S3_SECRET_ACCESS_KEY"),
)

Shrine.plugin :sequel

module TestHelpers
  def uploader(storage_key = :store, &block)
    uploader_class = Class.new(Shrine)
    uploader_class.storages[:cache] = $s3
    uploader_class.storages[:store] = $s3
    uploader_class.class_eval(&block) if block
    uploader_class.new(storage_key)
  end

  def attacher(&block)
    uploader = uploader(&block)

    db = Sequel.sqlite
    db.create_table :records do
      primary_key :id
      column :attachment_data, :text
    end

    Object.const_set("Record", Sequel::Model(db[:records]))
    Record.include uploader.class[:attachment]

    Record.create.attachment_attacher
  end

  def setup
    super
  end

  def teardown
    super
    Record.dataset.delete
    Object.send(:remove_const, "Record") if Object.const_defined?(:Record)
  end

  def image
    File.open("test/fixtures/image.jpg")
  end
end

Minitest::Test.include TestHelpers
