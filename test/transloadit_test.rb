require "test_helper"

print "Waking up http://echo-webhook.herokuapp.com... "
RestClient.get("http://echo-webhook.herokuapp.com") rescue nil
puts "Done"

describe Shrine::Plugins::Transloadit do
  around(:all) do |&block|
    @cached_image    = Shrine.new(:cache).upload(image)
    @cached_document = Shrine.new(:cache).upload(document)
    super(&block)
    Shrine.storages[:store].clear!
  end

  before do
    @attacher = @record.attachment_attacher
    @store = @attacher.store
  end

  it "works for single files" do
    @store.class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_image.to_json)

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    @attacher.transloadit_save(response.body)

    assert_equal "store", @record.attachment.storage_key
    refute_empty @record.attachment.metadata["transloadit"]
  end

  it "works for versions" do
    @store.class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(original: transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_image.to_json)

    response = @record.attachment.transloadit_response
    wait_for_response(response)
    @attacher.transloadit_save(response.body)

    assert_instance_of Hash, @record.attachment
    refute_empty @record.attachment[:original].metadata["transloadit"]
  end

  it "works on class-level with webhooks & background jobs flow" do
    @store.class.class_eval do
      def transloadit_process(io, context)
        notify_url = "https://echo-webhook.herokuapp.com/#{SecureRandom.hex(5)}"
        transloadit_assembly(transloadit_file(io), notify_url: notify_url)
      end
    end
    @attacher.class.promote { |data| self.class.transloadit_process(data) }
    @record.update(attachment: @cached_image.to_json)
    @record.reload

    response = @record.attachment.transloadit_response
    wait_for_response(response)

    body = RestClient.get(response["notify_url"]).body
    params = CGI.parse(body)
    params.each { |key, value| params[key] = value.first }

    @attacher.class.transloadit_save(params)
    @record.reload
    assert_equal "store", @record.attachment.storage_key
    assert @record.attachment.exists?
    refute_empty @record.attachment.metadata["transloadit"]

    @attacher.class.transloadit_save(params)
  end

  it "populates metadata" do
    @store.class.class_eval do
      def transloadit_process(io, context)
        transloadit_assembly(transloadit_file(io))
      end
    end
    @record.update(attachment: @cached_image.to_json)

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

  describe "with list multiple format" do
    it "works for single files" do
      @store.class.class_eval do
        def transloadit_process(io, context)
          thumbs = transloadit_file(io)
            .add_step("thumbs", "/document/thumbs")
            .multiple(:list)

          transloadit_assembly(thumbs)
        end
      end
      @record.update(attachment: @cached_document.to_json)

      response = @record.attachment.transloadit_response
      wait_for_response(response)
      @attacher.transloadit_save(response.body)

      assert_instance_of Array,            @attacher.get
      assert_equal 3,                      @attacher.get.size
      assert_kind_of Shrine::UploadedFile, @attacher.get[0]
      assert_kind_of Shrine::UploadedFile, @attacher.get[1]
      assert_kind_of Shrine::UploadedFile, @attacher.get[2]
    end

    it "works for versions" do
      @store.class.class_eval do
        def transloadit_process(io, context)
          thumbs = transloadit_file(io)
            .add_step("thumbs", "/document/thumbs")
            .multiple(:list)

          transloadit_assembly(thumbs: thumbs)
        end
      end
      @record.update(attachment: @cached_document.to_json)

      response = @record.attachment.transloadit_response
      wait_for_response(response)
      @attacher.transloadit_save(response.body)

      assert_instance_of Array,            @attacher.get[:thumbs]
      assert_equal 3,                      @attacher.get[:thumbs].size
      assert_kind_of Shrine::UploadedFile, @attacher.get[:thumbs][0]
      assert_kind_of Shrine::UploadedFile, @attacher.get[:thumbs][1]
      assert_kind_of Shrine::UploadedFile, @attacher.get[:thumbs][2]
    end

    it "fails when not marked as list for single files" do
      @store.class.class_eval do
        def transloadit_process(io, context)
          thumbs = transloadit_file(io).add_step("thumbs", "/document/thumbs")
          transloadit_assembly(thumbs)
        end
      end
      @record.update(attachment: @cached_document.to_json)
      response = @record.attachment.transloadit_response
      wait_for_response(response)

      assert_raises(Shrine::Plugins::Transloadit::Error) do
        @attacher.transloadit_save(response.body)
      end
    end

    it "fails when not marked as list for versions" do
      @store.class.class_eval do
        def transloadit_process(io, context)
          thumbs = transloadit_file(io).add_step("thumbs", "/document/thumbs")
          transloadit_assembly(thumbs: thumbs)
        end
      end
      @record.update(attachment: @cached_document.to_json)
      response = @record.attachment.transloadit_response
      wait_for_response(response)

      assert_raises(Shrine::Plugins::Transloadit::Error) do
        @attacher.transloadit_save(response.body)
      end
    end
  end

  describe "#transloadit_import_step" do
    it "accepts files from S3" do
      uploaded_file = @cached_image.dup
      import = @store.transloadit_import_step("import", uploaded_file)
      assert_equal "/s3/import",                      import.robot
      assert_equal "import",                          import.name
      assert_equal ENV.fetch("S3_ACCESS_KEY_ID"),     import.options[:key]
      assert_equal ENV.fetch("S3_SECRET_ACCESS_KEY"), import.options[:secret]
      assert_equal ENV.fetch("S3_BUCKET"),            import.options[:bucket]
      assert_equal ENV.fetch("S3_REGION"),            import.options[:bucket_region]
      assert_equal "store/#{uploaded_file.id}",       import.options[:path]
    end

    it "accepts other files over HTTP/HTTPS" do
      uploaded_file = @cached_image.dup
      uploaded_file.instance_eval { def storage; nil; end }

      uploaded_file.instance_eval { def url; "http://example.com"; end }
      import = @store.transloadit_import_step("import", uploaded_file)
      assert_equal "/http/import",       import.robot
      assert_equal "import",             import.name
      assert_equal "http://example.com", import.options[:url]

      uploaded_file.instance_eval { def url; "https://example.com"; end }
      import = @store.transloadit_import_step("import", uploaded_file)
      assert_equal "/http/import",       import.robot
      assert_equal "import",             import.name
      assert_equal "https://example.com", import.options[:url]
    end

    it "accepts files over FTP" do
      uploaded_file = @cached_image.dup
      uploaded_file.instance_eval { def storage; nil; end }
      uploaded_file.instance_eval { def url; "ftp://janko:secret@example.com/image.jpg"; end }
      import = @store.transloadit_import_step("import", uploaded_file)
      assert_equal "/ftp/import", import.robot
      assert_equal "import",      import.name
      assert_equal "example.com", import.options[:host]
      assert_equal "janko",       import.options[:user]
      assert_equal "secret",      import.options[:password]
      assert_equal "image.jpg",   import.options[:path]
    end

    it "accepts additional step options" do
      uploaded_file = @cached_image.dup
      import = @store.transloadit_import_step("import", uploaded_file, path: "foo")
      assert_equal "foo", import.options[:path]
    end
  end

  describe "#transloadit_export_step" do
    it "accepts files from S3" do
      uploaded_file = @cached_image.dup
      export = @store.transloadit_export_step("export")
      assert_equal "/s3/store",                       export.robot
      assert_equal "export",                          export.name
      assert_equal ENV.fetch("S3_ACCESS_KEY_ID"),     export.options[:key]
      assert_equal ENV.fetch("S3_SECRET_ACCESS_KEY"), export.options[:secret]
      assert_equal ENV.fetch("S3_BUCKET"),            export.options[:bucket]
      assert_equal ENV.fetch("S3_REGION"),            export.options[:bucket_region]
    end

    it "accepts additional step options" do
      uploaded_file = @cached_image.dup
      export = @store.transloadit_export_step("export", path: "foo")
      assert_equal "store/foo", export.options[:path]
    end
  end

  describe "#transloadit_assembly" do
    it "accepts additional assembly options" do
      assembly = @store.transloadit_assembly({}, notify_url: "http://example.com")
      assert_equal "http://example.com", assembly.options[:notify_url]
    end

    it "accepts a template as the first argument" do
      assembly = @store.transloadit_assembly("my_template")
      assert_equal "my_template", assembly.options[:template_id]
    end

    it "doesn't override passed in :steps and :fields" do
      step = @store.transloadit.step("step1", "/image/resize")
      file = @store.transloadit_file.add_step("step2", "/http/import")
      assembly = @store.transloadit_assembly(file, steps: [step], fields: {foo: "bar"})
      steps = assembly.options[:steps]
      assert_includes steps.map(&:name), "step1"
      assert_includes steps.map(&:name), "step2"
      assert_equal "bar", assembly.options[:fields][:foo]
    end

    it "adds an export step if it's not present" do
      file = @store.transloadit_file.add_step("import", "/http/import")

      assembly = @store.transloadit_assembly(file)
      assert_equal 2,             assembly.options[:steps].count
      assert_equal "export",      assembly.options[:steps].last.name
      assert_equal "/s3/store",   assembly.options[:steps].last.robot
      assert_match "${file.ext}", assembly.options[:steps].last.options[:path]

      assembly = @store.transloadit_assembly(file: file)
      assert_equal 2,             assembly.options[:steps].count
      assert_equal "export_file", assembly.options[:steps].last.name
      assert_equal "/s3/store",   assembly.options[:steps].last.robot
      assert_match "${file.ext}", assembly.options[:steps].last.options[:path]
    end

    it "doesn't add an export step if it's given" do
      file = @store.transloadit_file
        .add_step("import", "/http/import")
        .add_step("my_export", "/s3/store")

      assembly = @store.transloadit_assembly(file)
      assert_equal 2,           assembly.options[:steps].count
      assert_equal "my_export", assembly.options[:steps].last.name

      assembly = @store.transloadit_assembly(file: file)
      assert_equal 2,           assembly.options[:steps].count
      assert_equal "my_export", assembly.options[:steps].last.name
    end

    it "fails when the value is not a TransloaditFile" do
      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(123) }
      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file: 123) }
    end

    it "fails when there are no steps defined on a TransloaditFile" do
      file = @store.transloadit_file

      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file) }
      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file: file) }
    end

    it "fails when the import step is missing" do
      file = @store.transloadit_file
        .add_step("resize", "/image/resize")
        .add_step("export", "/s3/store")

      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file) }
      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file: file) }
    end

    it "fails when there are duplicate step names" do
      file = @store.transloadit_file
        .add_step("import", "/s3/import", foo: "foo")
        .add_step("import", "/s3/import", bar: "bar")

      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file) }
      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file: file) }
    end

    it "fails when single transloadit file is marked as multiple" do
      file = @store.transloadit_file
        .multiple

      assert_raises(Shrine::Plugins::Transloadit::Error) { @store.transloadit_assembly(file) }
    end
  end

  describe "#transloadit_file" do
    describe "#add_step" do
      it "creates a new instance" do
        transloadit_file = @store.transloadit_file
        new_file = transloadit_file.add_step("import", "/http/import")
        assert_equal 1, new_file.steps.count
        assert_equal 0, transloadit_file.steps.count
      end

      it "accepts both step arguments and steps itself" do
        file = @store.transloadit_file.add_step("import", "/http/import")
        assert_instance_of Transloadit::Step, file.steps[0]

        file = @store.transloadit_file.add_step(@store.transloadit.step("import", "/http/import"))
        assert_instance_of Transloadit::Step, file.steps[0]
      end

      it "automatically adds :use for previous step" do
        file = @store.transloadit_file
          .add_step("import", "/http/import")
          .add_step("export", "/http/store")

        assert_equal nil,        file.steps[0].options[:use]
        assert_equal ["import"], file.steps[1].options[:use]
      end

      it "generates import step for passed UploadedFile" do
        file = @store.transloadit_file(@cached_image)

        assert_equal 1, file.steps.count
        assert_equal "/s3/import", file.steps[0].robot
      end
    end
  end

  describe "#transloadit_response" do
    it "returns nil if there is no metadata" do
      assert_equal nil, @cached_image.transloadit_response
    end
  end

  it "propagates Transloadit errors" do
    @store.class.class_eval do
      def transloadit_process(io, context)
        transloadit.assembly({})
      end
    end
    exception = assert_raises(Shrine::Plugins::Transloadit::ResponseError) do
      @attacher.transloadit_process(@cached_image)
    end
    refute_nil exception.response.fetch("assembly_url")

    @store.class.class_eval do
      def transloadit_process(io, context)
        file = transloadit_file(io).add_step("resize", "/image/resize", width: -1)

        transloadit_assembly(file)
      end
    end
    @attacher.transloadit_process(@cached_image)
    response = @attacher.get.transloadit_response
    wait_for_response(response)
    exception = assert_raises(Shrine::Plugins::Transloadit::ResponseError) do
      @attacher.transloadit_save(response.body)
    end
    refute_nil exception.response.fetch("assembly_url")
  end

  it "keeps the same transloadit client on the uploader instance" do
    assert_equal @store.transloadit, @store.transloadit
  end

  it "creates a new transloadit client for each uploader instance" do
    refute_equal @store.class.transloadit, @store.class.transloadit
  end

  def wait_for_response(response)
    response.reload_until_finished!

    if response["notify_url"]
      loop do
        notifications = JSON.parse(transloadit.assembly.get_notifications.to_s)["items"]
        break if notifications.any? && notifications.first["assembly_id"] == response["assembly_id"]
        sleep 1
      end
    end
  end

  def transloadit
    @store.transloadit
  end
end
