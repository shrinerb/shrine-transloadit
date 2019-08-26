require "bundler/setup"

ENV["MT_NO_EXPECTATIONS"] = "1" # disable Minitest's expectations monkey-patches

require "minitest/autorun"
require "minitest/pride"

require "shrine"
require "shrine/storage/s3"
require "shrine/storage/url"
require "shrine/storage/memory"

require "./test/support/logging_helper"
require "./test/support/storages"
