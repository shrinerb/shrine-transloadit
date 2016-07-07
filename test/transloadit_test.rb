require "test_helper"

describe Shrine::Plugins::Transloadit do
  around(:all) do |&block|
    shrine_class = Class.new(Shrine)
    shrine_class.storages[:cache] = $s3
    @cached_file = shrine_class.new(:cache).upload(image)
    super(&block)
    $s3.clear!
  end

  before do
    @attacher = attacher do
      plugin :versions
      plugin :transloadit,
        auth_key:    ENV.fetch("TRANSLOADIT_AUTH_KEY"),
        auth_secret: ENV.fetch("TRANSLOADIT_AUTH_SECRET")
    end

    @record = @attacher.record
  end

  it "works for single files" do
    @attacher.shrine_class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_file.to_json)

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    assert response.completed?
    @attacher.transloadit_save(response.body)

    assert_equal "store", @record.attachment.storage_key
    refute_empty @record.attachment.metadata["transloadit"]
  end

  it "works for versions" do
    @attacher.shrine_class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(original: transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_file.to_json)

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    assert response.completed?
    @attacher.transloadit_save(response.body)

    assert_instance_of Hash, @record.attachment
    refute_empty @record.attachment[:original].metadata["transloadit"]
  end

  it "works on class-level with webhooks & background jobs flow" do
    @attacher.shrine_class.class_eval do
      def transloadit_process(io, context)
        notify_url = "https://echo-webhook.herokuapp.com/#{SecureRandom.hex(5)}"
        transloadit_assembly(transloadit_file(io), notify_url: notify_url)
      end
    end
    @attacher.class.promote { |data| self.class.transloadit_process(data) }
    @record.update(attachment: @cached_file.to_json)
    @record.reload

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    assert response.completed?

    body = RestClient.get(response["notify_url"]).body
    params = CGI.parse(body)
    params.each { |key, value| params[key] = value.first }

    @attacher.class.transloadit_save(params)
    @record.reload
    assert_equal "store", @record.attachment.storage_key
    assert @record.attachment.exists?
    refute_empty @record.attachment.metadata["transloadit"]

    params["transloadit"] = JSON.parse(params["transloadit"])
    @attacher.class.transloadit_save(params) # handles parsed JSON
  end

  it "populates metadata" do
    @attacher.shrine_class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_file.to_json)

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    @attacher.transloadit_save(response.body)

    attachment = @attacher.get
    refute_empty attachment.id
    assert_equal @attacher.store.storage, attachment.storage
    refute_empty attachment.metadata["filename"]
    assert_equal image.size,   attachment.metadata["size"]
    assert_equal "image/jpeg", attachment.metadata["mime_type"]
    assert_equal 100,          attachment.metadata["width"]
    assert_equal 67,           attachment.metadata["height"]
    refute_empty attachment.metadata["transloadit"]
  end

  describe "import step" do
    it "accepts files from S3" do
      uploaded_file = @cached_file.dup
      import = @attacher.store.transloadit_import_step("import", uploaded_file)
      assert_equal "/s3/import",                      import.robot
      assert_equal "import",                          import.name
      assert_equal ENV.fetch("S3_ACCESS_KEY_ID"),     import.options[:key]
      assert_equal ENV.fetch("S3_SECRET_ACCESS_KEY"), import.options[:secret]
      assert_equal ENV.fetch("S3_BUCKET"),            import.options[:bucket]
      assert_equal ENV.fetch("S3_REGION"),            import.options[:bucket_region]
      assert_equal uploaded_file.id,                  import.options[:path]
    end

    it "accepts other files over HTTP/HTTPS" do
      uploaded_file = @cached_file.dup
      uploaded_file.instance_eval { def storage; nil; end }

      uploaded_file.instance_eval { def url; "http://example.com"; end }
      import = @attacher.store.transloadit_import_step("import", uploaded_file)
      assert_equal "/http/import",       import.robot
      assert_equal "import",             import.name
      assert_equal "http://example.com", import.options[:url]

      uploaded_file.instance_eval { def url; "https://example.com"; end }
      import = @attacher.store.transloadit_import_step("import", uploaded_file)
      assert_equal "/http/import",       import.robot
      assert_equal "import",             import.name
      assert_equal "https://example.com", import.options[:url]
    end

    it "accepts files over FTP" do
      uploaded_file = @cached_file.dup
      uploaded_file.instance_eval { def storage; nil; end }
      uploaded_file.instance_eval { def url; "ftp://janko:secret@example.com/image.jpg"; end }
      import = @attacher.store.transloadit_import_step("import", uploaded_file)
      assert_equal "/ftp/import", import.robot
      assert_equal "import",      import.name
      assert_equal "example.com", import.options[:host]
      assert_equal "janko",       import.options[:user]
      assert_equal "secret",      import.options[:password]
      assert_equal "image.jpg",   import.options[:path]
    end

    it "accepts additional step options" do
      uploaded_file = @cached_file.dup
      import = @attacher.store.transloadit_import_step("import", uploaded_file, path: "foo")
      assert_equal "foo", import.options[:path]
    end
  end

  describe "export step" do
    it "accepts files from S3" do
      uploaded_file = @cached_file.dup
      export = @attacher.store.transloadit_export_step("export")
      assert_equal "/s3/store",                       export.robot
      assert_equal "export",                          export.name
      assert_equal ENV.fetch("S3_ACCESS_KEY_ID"),     export.options[:key]
      assert_equal ENV.fetch("S3_SECRET_ACCESS_KEY"), export.options[:secret]
      assert_equal ENV.fetch("S3_BUCKET"),            export.options[:bucket]
      assert_equal ENV.fetch("S3_REGION"),            export.options[:bucket_region]
    end

    it "accepts additional step options" do
      uploaded_file = @cached_file.dup
      export = @attacher.store.transloadit_export_step("export", path: "foo")
      assert_equal "foo", export.options[:path]
    end
  end

  describe "creating assembly" do
    before do
      @uploader = @attacher.store
    end

    it "accepts additional assembly options" do
      assembly = @uploader.transloadit_assembly({}, notify_url: "http://example.com")
      assert_equal "http://example.com", assembly.options[:notify_url]
    end

    it "accepts a template as the first argument" do
      assembly = @uploader.transloadit_assembly("my_template")
      assert_equal "my_template", assembly.options[:template_id]
    end

    it "doesn't override passed in :steps and :fields" do
      step = @uploader.transloadit.step("step1", "/image/resize")
      file = @uploader.transloadit_file.add_step("step2", "/http/import")
      assembly = @uploader.transloadit_assembly(file, steps: [step], fields: {foo: "bar"})
      steps = assembly.options[:steps]
      assert_includes steps.map(&:name), "step1"
      assert_includes steps.map(&:name), "step2"
      assert_equal "bar", assembly.options[:fields][:foo]
    end

    it "adds an export step if it's not present" do
      file = @uploader.transloadit_file.add_step("import", "/http/import")

      assembly = @uploader.transloadit_assembly(file)
      assert_equal 2,             assembly.options[:steps].count
      assert_equal "export",      assembly.options[:steps].last.name
      assert_equal "/s3/store",   assembly.options[:steps].last.robot
      assert_match "${file.ext}", assembly.options[:steps].last.options[:path]

      assembly = @uploader.transloadit_assembly(file: file)
      assert_equal 2,             assembly.options[:steps].count
      assert_equal "export_file", assembly.options[:steps].last.name
      assert_equal "/s3/store",   assembly.options[:steps].last.robot
      assert_match "${file.ext}", assembly.options[:steps].last.options[:path]
    end

    it "doesn't add an export step if it's given" do
      file = @uploader.transloadit_file
        .add_step("import", "/http/import")
        .add_step("my_export", "/s3/store")

      assembly = @uploader.transloadit_assembly(file)
      assert_equal 2,           assembly.options[:steps].count
      assert_equal "my_export", assembly.options[:steps].last.name

      assembly = @uploader.transloadit_assembly(file: file)
      assert_equal 2,           assembly.options[:steps].count
      assert_equal "my_export", assembly.options[:steps].last.name
    end

    it "complains when there are duplicate step names" do
      file = @uploader.transloadit_file
        .add_step("import", "/s3/import", foo: "foo")
        .add_step("import", "/s3/import", bar: "bar")

      assert_raises(Shrine::Error) { @uploader.transloadit_assembly(file) }
    end

    it "complains when there are no steps defined on a TransloaditFile" do
      assert_raises(Shrine::Error) do
        @uploader.transloadit_assembly(@uploader.transloadit_file)
      end

      assert_raises(Shrine::Error) do
        @uploader.transloadit_assembly(file: @uploader.transloadit_file)
      end
    end

    it "complains when the import step is missing" do
      file = @uploader.transloadit_file
        .add_step("resize", "/image/resize")
        .add_step("export", "/s3/store")

      assert_raises(Shrine::Error) { @uploader.transloadit_assembly(file) }
    end
  end

  describe Shrine::Plugins::Transloadit::TransloaditFile do
    before do
      @transloadit_file = @attacher.store.transloadit_file
    end

    describe "#add_step" do
      it "creates a new instance" do
        new_file = @transloadit_file.add_step("import", "/http/import")
        assert_equal 1, new_file.steps.count
        assert_equal 0, @transloadit_file.steps.count
      end

      it "accepts both step arguments and steps itself" do
        file = @transloadit_file.add_step("import", "/http/import")
        assert_instance_of Transloadit::Step, file.steps[0]

        file = @transloadit_file.add_step(@transloadit_file.transloadit.step("import", "/http/import"))
        assert_instance_of Transloadit::Step, file.steps[0]
      end

      it "automatically adds :use for previous step" do
        file = @transloadit_file
          .add_step("import", "/http/import")
          .add_step("export", "/http/store")

        assert_equal nil,        file.steps[0].options[:use]
        assert_equal ["import"], file.steps[1].options[:use]
      end
    end
  end

  describe Shrine::Plugins::Transloadit::UrlStorage do
    before do
      @storage = Shrine::Plugins::Transloadit::UrlStorage.new
    end

    it "implements #url" do
      assert_equal "http://example.com", @storage.url("http://example.com")
    end

    it "implements #download" do
      assert_instance_of Tempfile, @storage.download("http://example.com")
    end

    it "implements #open" do
      assert_instance_of Down::ChunkedIO, @storage.open("http://example.com")
    end

    it "implements #exists?" do
      assert_equal true, @storage.exists?("http://example.com")
    end
  end

  it "propagates Transloadit errors" do
    @attacher.shrine_class.class_eval do
      def transloadit_process(io, context)
        transloadit.assembly({})
      end
    end
    assert_raises(Shrine::Error) { @attacher.transloadit_process(@cached_file) }
  end

  it "keeps the same transloadit client on the uploader instance" do
    assert_equal @attacher.store.transloadit, @attacher.store.transloadit
  end

  it "creates a new transloadit client for each uploader instance" do
    refute_equal @attacher.shrine_class.transloadit, @attacher.shrine_class.transloadit
  end

  def wait_for_response(response)
    loop do
      if response["notify_url"]
        break if response["notify_status"]
      else
        break if response.finished?
      end
      sleep 1
      response.reload!
    end
  end
end
