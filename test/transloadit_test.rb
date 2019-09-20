require "test_helper"
require "shrine/plugins/transloadit"
require "dry-monitor"

describe Shrine::Plugins::Transloadit do
  before do
    @shrine = Class.new(Shrine)

    @shrine.storages[:store] = s3

    @shrine.plugin :transloadit, auth: { key: "test key", secret: "test secret" }

    @attacher = @shrine::Attacher.new
    @uploader = @attacher.store
  end

  describe "Attacher" do
    describe "#transloadit_process" do
      it "executes the registered processor" do
        @attacher.class.transloadit_processor(:thumbs) { { some: "result" } }

        assert_equal Hash[some: "result"], @attacher.transloadit_process(:thumbs)
      end

      it "executes default processor" do
        @attacher.class.transloadit_processor { { some: "result" } }

        assert_equal Hash[some: "result"], @attacher.transloadit_process
      end

      it "evaluates processor in context of attacher instance" do
        @attacher.class.transloadit_processor(:thumbs) { self }

        assert_equal @attacher, @attacher.transloadit_process(:thumbs)
      end

      it "accepts additional options" do
        @attacher.class.transloadit_processor(:thumbs) { |foo:| foo }

        assert_equal "bar", @attacher.transloadit_process(:thumbs, foo: "bar")
      end

      it "adds instrumentation" do
        @shrine.plugin :instrumentation, notifications: Dry::Monitor::Notifications.new(:test)
        @shrine.plugin :transloadit

        @attacher.class.transloadit_processor(:thumbs) {}

        assert_logged /^Transloadit \(\d+ms\)/ do
          @attacher.transloadit_process(:thumbs)
        end
      end

      it "raises exception if processor is missing" do
        assert_raises Shrine::Plugins::Transloadit::Error do
          @attacher.transloadit_process(:thumbs)
        end
      end
    end

    describe "#transloadit_save" do
      it "executes the registered saver" do
        @attacher.class.transloadit_saver(:thumbs) { { some: "result" } }

        assert_equal Hash[some: "result"], @attacher.transloadit_save(:thumbs)
      end

      it "executes default saver" do
        @attacher.class.transloadit_saver { { some: "result" } }

        assert_equal Hash[some: "result"], @attacher.transloadit_save
      end

      it "evaluates saver in context of attacher instance" do
        @attacher.class.transloadit_saver(:thumbs) { self }

        assert_equal @attacher, @attacher.transloadit_save(:thumbs)
      end

      it "accepts additional options" do
        @attacher.class.transloadit_saver(:thumbs) { |foo:| foo }

        assert_equal "bar", @attacher.transloadit_save(:thumbs, foo: "bar")
      end

      it "raises exception if saver is missing" do
        assert_raises Shrine::Plugins::Transloadit::Error do
          @attacher.transloadit_save(:thumbs)
        end
      end
    end

    describe "#transloadit_step" do
      it "returns a Transloadit::Step" do
        step = @attacher.transloadit_step "name", "/my/robot", { foo: "bar" }

        assert_instance_of Transloadit::Step, step
        assert_equal "name",                  step.name
        assert_equal "/my/robot",             step.robot
        assert_equal "bar",                   step.options[:foo]
      end

      it "allows passing Transloadit::Step to :use" do
        step_one = @attacher.transloadit_step "one", "/robot/one"
        step_two = @attacher.transloadit_step "two", "/robot/two", use: step_one

        assert_equal ["one"], step_two.options[:use]
      end
    end

    describe "#transloadit" do
      it "returns a Transloadit" do
        transloadit = @attacher.transloadit

        assert_instance_of Transloadit, transloadit
        assert_equal "test key",        transloadit.key
        assert_equal "test secret",     transloadit.secret
      end
    end
  end

  describe "Shrine" do
    describe ".transloadit_step" do
      it "accepts step object for :use" do
        step_1 = @shrine.transloadit.step("one", "/robot/one")
        step_2 = @shrine.transloadit_step("two", "/robot/two", use: step_1)

        assert_equal ["one"], step_2.options[:use]
      end

      it "accepts step array for :use" do
        step_1 = @shrine.transloadit.step("one", "/robot/one")
        step_2 = @shrine.transloadit_step("two", "/robot/two", use: [step_1])

        assert_equal ["one"], step_2.options[:use]
      end

      it "allows default :use" do
        step = @shrine.transloadit_step("two", "/robot/two", use: ["one"])

        assert_equal ["one"], step.options[:use]
      end
    end

    describe ".transloadit_verify!" do
      it "returns if signature matches" do
        params = {
          "transloadit" => '{"some":"response"}',
          "signature"   => "e157d17c559f0cdaa7005d7f856d8bdb41b210be",
        }

        @shrine.transloadit_verify!(params)
      end

      it "raises exception if signature doesn't match" do
        params = {
          "transloadit" => '{"some":"response"}',
          "signature"   => "invalid",
        }

        assert_raises Shrine::Plugins::Transloadit::InvalidSignature do
          @shrine.transloadit_verify!(params)
        end
      end
    end

    describe ".transloadit" do
      it "returns the Transloadit instance" do
        assert_instance_of Transloadit, @shrine.transloadit
        assert_equal "test key",        @shrine.transloadit.key
        assert_equal "test secret",     @shrine.transloadit.secret
      end

      it "returns a new instance every time" do
        refute_equal @shrine.transloadit, @shrine.transloadit
      end
    end

    describe ".transloadit_credentials" do
      it "returns credentials" do
        @shrine.plugin :transloadit, credentials: { store: :s3_store }

        assert_equal :s3_store, @shrine.transloadit_credentials(:store)
      end

      it "raises exception when credentials are not registered" do
        assert_raises Shrine::Plugins::Transloadit::Error do
          @shrine.transloadit_credentials(:store)
        end
      end
    end

    describe "#transloadit_file" do
      it "loads S3 file" do
        file = @uploader.transloadit_file transloadit_result(
          "url" => "https://s3.amazonaws.com/foo",
        )

        assert_instance_of @shrine::UploadedFile, file
        assert_equal "foo", file.id
      end

      it "loads S3 file with prefix" do
        @shrine.storages[:store] = s3(prefix: "prefix")

        file = @uploader.transloadit_file transloadit_result(
          "url" => "https://s3.amazonaws.com/prefix/foo",
        )

        assert_equal "foo", file.id
      end

      it "raises exception when storage prefix doesn't match URL path" do
        @shrine.storages[:store] = s3(prefix: "prefix")

        assert_raises Shrine::Plugins::Transloadit::Error do
          @uploader.transloadit_file transloadit_result(
            "url" => "https://s3.amazonaws.com/foo",
          )
        end
      end

      it "loads Url file" do
        @shrine.storages[:store] = Shrine::Storage::Url.new

        file = @uploader.transloadit_file transloadit_result(
          "url" => "https://s3.amazonaws.com/foo",
        )

        assert_equal "https://s3.amazonaws.com/foo", file.id
      end

      it "raises exception on unsupported storage" do
        @shrine.storages[:store] = Shrine::Storage::Memory.new

        assert_raises Shrine::Plugins::Transloadit::Error do
          @uploader.transloadit_file transloadit_result(
            "url" => "https://s3.amazonaws.com/foo",
          )
        end
      end

      it "copies basic metadata" do
        file = @uploader.transloadit_file transloadit_result(
          "name" => "foo.txt",
          "size" => 123,
          "mime" => "text/plain",
        )

        assert_equal "foo.txt",    file.original_filename
        assert_equal 123,          file.size
        assert_equal "text/plain", file.mime_type
      end

      it "copies type-specific metadata" do
        file = @uploader.transloadit_file transloadit_result(
          "meta" => { "foo" => "bar" },
        )

        assert_equal "bar", file.metadata["foo"]
      end

      it "doesn't let type-specific metadata override basic metadata" do
        file = @uploader.transloadit_file transloadit_result(
          "size" => 123,
          "meta" => { "size" => "overridden" },
        )

        assert_equal 123, file.metadata["size"]
      end

      it "accepts array of results" do
        file = @uploader.transloadit_file [
          transloadit_result("url" => "https://s3.amazonaws.com/foo"),
          transloadit_result("url" => "https://s3.amazonaws.com/bar"),
        ]

        assert_equal "foo", file.id
      end
    end

    describe "#transloadit_files" do
      it "returns array of files" do
        files = @uploader.transloadit_files [
          transloadit_result("url" => "https://s3.amazonaws.com/foo"),
          transloadit_result("url" => "https://s3.amazonaws.com/bar"),
        ]

        assert_equal "foo", files[0].id
        assert_equal "bar", files[1].id
      end
    end

    describe "#transloadit_export_step" do
      before do
        @shrine.plugin :transloadit, credentials: { store: :store_credentials }
      end

      it "generates export step for S3 storage" do
        step = @uploader.transloadit_export_step

        assert_instance_of Transloadit::Step, step

        assert_equal "export",                            step.name
        assert_equal "/s3/store",                         step.robot
        assert_equal "${unique_prefix}/${file.url_name}", step.options[:path]
        assert_equal "store_credentials",                 step.options[:credentials]
      end

      it "handles S3 prefix" do
        @shrine.storages[:store] = s3(prefix: "prefix")

        step = @uploader.transloadit_export_step

        assert_equal "prefix/${unique_prefix}/${file.url_name}", step.options[:path]

        step = @uploader.transloadit_export_step(path: "foo")

        assert_equal "prefix/foo", step.options[:path]
      end

      it "generates export step for GCS storage" do
        @shrine.storages[:store] = Shrine::Storage::GoogleCloudStorage.new

        step = @uploader.transloadit_export_step

        assert_instance_of Transloadit::Step, step

        assert_equal "export",                            step.name
        assert_equal "/google/store",                     step.robot
        assert_equal "${unique_prefix}/${file.url_name}", step.options[:path]
        assert_equal "store_credentials",                 step.options[:credentials]
      end

      it "handles GCS prefix" do
        @shrine.storages[:store] = Shrine::Storage::GoogleCloudStorage.new(prefix: "prefix")

        step = @uploader.transloadit_export_step

        assert_equal "prefix/${unique_prefix}/${file.url_name}", step.options[:path]

        step = @uploader.transloadit_export_step(path: "foo")

        assert_equal "prefix/foo", step.options[:path]
      end

      it "generates export step for YouTube storage" do
        @shrine.storages[:store] = Shrine::Storage::YouTube.new

        step = @uploader.transloadit_export_step

        assert_instance_of Transloadit::Step, step

        assert_equal "export",            step.name
        assert_equal "/youtube/store",    step.robot
        assert_equal "store_credentials", step.options[:credentials]
      end

      it "raises exception when credentials are missing" do
        @shrine.plugin :transloadit, credentials: {}

        assert_raises Shrine::Plugins::Transloadit::Error do
          @uploader.transloadit_export_step
        end
      end

      it "allows specifying step name" do
        step = @uploader.transloadit_export_step("custom")

        assert_equal "custom", step.name
      end

      it "allows passing step options" do
        step = @uploader.transloadit_export_step(foo: "bar")

        assert_equal "bar", step.options[:foo]
      end

      it "allows removing :credentials" do
        @shrine.plugin :transloadit, credentials: {}

        step = @uploader.transloadit_export_step(credentials: nil)

        assert_nil step.options[:credentials]
      end

      it "allows using another step" do
        previous_step = @shrine.transloadit_step("foo", "/bar/baz")
        step          = @uploader.transloadit_export_step(use: previous_step)

        assert_equal ["foo"], step.options[:use]
      end
    end
  end

  describe "UploadedFile" do
    before do
      @file = @uploader.upload(StringIO.new)

      @shrine.plugin :transloadit, credentials: { store: :store_credentials }
    end

    describe "#transloadit_import_step" do
      it "generates import step for S3 storage" do
        step = @file.transloadit_import_step

        assert_instance_of Transloadit::Step, step

        assert_equal "import",            step.name
        assert_equal "/s3/import",        step.robot
        assert_equal @file.id,            step.options[:path]
        assert_equal "store_credentials", step.options[:credentials]
      end

      it "handles S3 prefix" do
        @shrine.storages[:store] = s3(prefix: "prefix")

        step = @file.transloadit_import_step

        assert_equal "prefix/#{@file.id}", step.options[:path]
      end

      it "generates import step for HTTP links" do
        @shrine.plugin :transloadit, credentials: {}

        @shrine.storages[:store] = Shrine::Storage::Url.new
        @file = @shrine.uploaded_file(id: "http://example.com/foo", storage: :store)

        step = @file.transloadit_import_step

        assert_instance_of Transloadit::Step, step

        assert_equal "import",       step.name
        assert_equal "/http/import", step.robot
        assert_equal @file.id,       step.options[:url]
      end

      it "generates import step for HTTPS links" do
        @shrine.plugin :transloadit, credentials: {}

        @shrine.storages[:store] = Shrine::Storage::Url.new
        @file = @shrine.uploaded_file(id: "https://example.com/foo", storage: :store)

        step = @file.transloadit_import_step

        assert_instance_of Transloadit::Step, step

        assert_equal "import",       step.name
        assert_equal "/http/import", step.robot
        assert_equal @file.id,       step.options[:url]
      end

      it "generates import step for FTP links" do
        @shrine.plugin :transloadit, credentials: {}

        @shrine.storages[:store] = Shrine::Storage::Url.new
        @file = @shrine.uploaded_file(id: "ftp://janko:secret@example.com/foo", storage: :store)

        step = @file.transloadit_import_step

        assert_instance_of Transloadit::Step, step

        assert_equal "import",      step.name
        assert_equal "/ftp/import", step.robot
        assert_equal "example.com", step.options[:host]
        assert_equal "janko",       step.options[:user]
        assert_equal "secret",      step.options[:password]
        assert_equal "foo",         step.options[:path]
      end

      it "raises exception without credentials" do
        @shrine.plugin :transloadit, credentials: {}

        assert_raises Shrine::Plugins::Transloadit::Error do
          @file.transloadit_import_step
        end
      end

      it "raises exception for unknown storage" do
        @shrine.storages[:store] = Shrine::Storage::Memory.new

        assert_raises Shrine::Plugins::Transloadit::Error do
          @file.transloadit_import_step
        end
      end

      it "allows specifying step name" do
        step = @file.transloadit_import_step("custom")

        assert_equal "custom", step.name
      end

      it "allows passing step options" do
        step = @file.transloadit_import_step(foo: "bar")

        assert_equal "bar", step.options[:foo]
      end

      it "allows removing :credentials" do
        @shrine.plugin :transloadit, credentials: {}

        step = @file.transloadit_import_step(credentials: nil)

        assert_nil step.options[:credentials]
      end

      it "allows using another step" do
        previous_step = @shrine.transloadit_step("foo", "/bar/baz")
        step          = @file.transloadit_import_step(use: previous_step)

        assert_equal ["foo"], step.options[:use]
      end
    end
  end

  def transloadit_result(hash)
    result = {
      "url"  => "https://s3.amazonaws.com/foo",
      "name" => "foo.txt",
      "size" => 123,
      "mime" => "text/plain",
      "meta" => {},
    }

    result.merge(hash)
  end

  def s3(**options)
    Shrine::Storage::S3.new(bucket: "dummy", stub_responses: true, **options)
  end
end
