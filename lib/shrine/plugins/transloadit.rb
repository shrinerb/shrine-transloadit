require "transloadit"

require "uri"
require "json"
require "openssl"

class Shrine
  module Plugins
    module Transloadit
      class Error < Shrine::Error; end

      class ResponseError < Error
        attr_reader :response

        def initialize(response)
          @response = response
          super("#{response["error"]}: #{response["reason"] || response["message"]}")
        end
      end

      # Accepts Transloadit credentials via `:auth_key` and `:auth_secret`.
      #
      # If :cache storage wasn't assigned, it will be assigned to a URL storage
      # for direct uploads.
      #
      # If promoting was not yet overriden, it is set to automatically trigger
      # Transloadit processing defined in `Shrine#transloadit_process`.
      def self.configure(uploader, opts = {})
        uploader.opts[:transloadit_auth_key] = opts.fetch(:auth_key, uploader.opts[:transloadit_auth_key])
        uploader.opts[:transloadit_auth_secret] = opts.fetch(:auth_secret, uploader.opts[:transloadit_auth_secret])

        raise Error, "The :auth_key is required for transloadit plugin" if uploader.opts[:transloadit_auth_key].nil?
        raise Error, "The :auth_secret is required for transloadit plugin" if uploader.opts[:transloadit_auth_secret].nil?

        uploader.opts[:backgrounding_promote] ||= proc { transloadit_process }
      end

      # It loads the backgrounding plugin, so that it can override promoting.
      def self.load_dependencies(uploader, opts = {})
        uploader.plugin :backgrounding
      end

      module AttacherClassMethods
        # Loads the attacher from the data, and triggers Transloadit
        # processing. Intended to be used in a background job.
        def transloadit_process(data)
          attacher = self.load(data)
          cached_file = attacher.uploaded_file(data["attachment"])
          attacher.transloadit_process(cached_file)
          attacher
        end

        # This should be called when receiving a webhook, where arguments are
        # params that Transloadit POSTed to the endpoint. It checks the
        # signature, loads the attacher, saves processing results to the record.
        def transloadit_save(params)
          shrine_class.verify_transloadit_signature!(params)
          response = JSON.parse(params["transloadit"])
          data = response["fields"]["attacher"]
          attacher = self.load(data)
          cached_file = attacher.uploaded_file(data["attachment"])
          attacher.transloadit_save(response, valid: attacher.get == cached_file)
          attacher
        end
      end

      module AttacherMethods
        # Triggers Transloadit processing defined by the user in
        # `Shrine#transloadit_process`. It dumps the attacher in the payload of
        # the request, so that it's included in the webhook and that we know
        # which webhook belongs to which record/attachment.
        #
        # After the Transloadit assembly was submitted, the response is saved
        # into cached file's metadata, which can then be reloaded at will for
        # checking progress of the assembly.
        #
        # Raises a `Shrine::Plugins::Transloadit::ResponseError` if Transloadit returned an error.
        def transloadit_process(cached_file = get)
          assembly = store.transloadit_process(cached_file, context)
          assembly.options[:fields] ||= {}
          assembly.options[:fields]["attacher"] = self.dump.merge("attachment" => cached_file.to_json)
          response = assembly.create!
          raise ResponseError.new(response.body) if response["error"]
          cached_file.metadata["transloadit_response"] = response.body.to_json
          swap(cached_file) or _set(cached_file)
        end

        # It receives the result of Transloadit processing, and converts it into
        # Shrine's representation(s) of an uploaded file (either as a single
        # file or a hash of versions).
        #
        # If attachment has changed in the meanwhile, meaning the result of
        # this processing is no longer valid, it deletes the processed files
        # from the main storage.
        #
        # Raises a `Shrine::Plugins::Transloadit::ResponseError` if Transloadit returned an error.
        def transloadit_save(response, valid: true)
          raise ResponseError.new(response) if response["error"]

          if versions = response["fields"]["versions"]
            stored_file = versions.inject({}) do |hash, (name, step_name)|
              results        = response["results"].fetch(step_name) { [] }
              uploaded_files = results.map { |result| store.transloadit_uploaded_file(result) }
              multiple       = response["fields"]["multiple"].to_h[name]

              if multiple == "list"
                hash.merge!(name => uploaded_files)
              elsif uploaded_files.one?
                hash.merge!(name => uploaded_files[0])
              elsif uploaded_files.empty?
                hash
              else
                raise Error, "Step produced multiple files but wasn't marked as multiple"
              end
            end
          else
            results        = response["results"].values.last
            uploaded_files = results.map { |result| store.transloadit_uploaded_file(result) }
            multiple       = response["fields"]["multiple"]

            if multiple == "list"
              stored_file = uploaded_files
            elsif uploaded_files.one?
              stored_file = uploaded_files[0]
            else
              raise Error, "Step produced multiple files but wasn't marked as multiple"
            end
          end

          if valid
            swap(stored_file)
          else
            _delete(stored_file, action: :abort)
          end
        end
      end

      module ClassMethods
        # Creates a new Transloadit client, so that the expiration timestamp is
        # refreshed on new processing requests.
        def transloadit
          ::Transloadit.new(
            key:    opts[:transloadit_auth_key],
            secret: opts[:transloadit_auth_secret],
          )
        end

        # Checks if the webhook has indeed been triggered by Transloadit, by
        # checking if sent signature matches the calculated signature, and
        # raising a `Shrine::Plugins::Transloadit::Error` if signatures don't
        # match.
        def verify_transloadit_signature!(params)
          sent_signature = params["signature"]
          payload = params["transloadit"]
          algorithm = OpenSSL::Digest.new('sha1')
          secret = opts[:transloadit_auth_secret]
          calculated_signature = OpenSSL::HMAC.hexdigest(algorithm, secret, payload)
          raise Error, "Received signature doesn't match the calculated signature" if calculated_signature != sent_signature
        end
      end

      module InstanceMethods
        # Converts Transloadit's representation of an uploaded file into
        # Shrine's representation. It currently only accepts files exported to
        # S3. All Transloadit's metadata is saved into a "transloadit"
        # attribute.
        #
        # When doing direct uploads to Transloadit you will only get a
        # temporary URL, which will be saved in the "id" attribute and it's
        # expected that the URL storage is used.
        def transloadit_uploaded_file(result)
          case url = result.fetch("url")
          when /amazonaws\.com/
            raise Error, "Cannot save a processed file which wasn't exported: #{url.inspect}" if url.include?("tmp.transloadit.com")
            path = URI(url).path
            id = path.match(%r{^(/#{storage.prefix})?/}).post_match
          else
            raise Error, "The transloadit Shrine plugin doesn't support storage identified by #{url.inspect}"
          end

          self.class::UploadedFile.new(
            "id"       => id,
            "storage"  => storage_key.to_s,
            "metadata" => {
              "filename"    => result.fetch("name"),
              "size"        => result.fetch("size"),
              "mime_type"   => result.fetch("mime"),
              "width"       => (result["meta"] && result["meta"]["width"]),
              "height"      => (result["meta"] && result["meta"]["height"]),
              "transloadit" => result["meta"],
            }
          )
        end

        # Generates a Transloadit import step from the Shrine::UploadedFile.
        # If it's from the S3 storage, an S3 import step will be generated.
        # Otherwise either a generic HTTP(S) or an FTP import will be generated.
        def transloadit_import_step(name, io, **step_options)
          uri = URI.parse(io.url)

          if defined?(Storage::S3) && io.storage.is_a?(Storage::S3)
            step = transloadit.step(name, "/s3/import",
              key:           io.storage.client.config.access_key_id,
              secret:        io.storage.client.config.secret_access_key,
              bucket:        io.storage.bucket.name,
              bucket_region: io.storage.client.config.region,
              path:          [*io.storage.prefix, io.id].join("/"),
            )
          elsif uri.scheme == "http" || uri.scheme == "https"
            step = transloadit.step(name, "/http/import",
              url: uri.to_s,
            )
          elsif uri.scheme == "ftp"
            step = transloadit.step(name, "/ftp/import",
              host:     uri.host,
              user:     uri.user,
              password: uri.password,
              path:     uri.path,
            )
          else
            raise Error, "Cannot construct a transloadit import step from #{io.inspect}"
          end

          step.options.update(step_options)

          step
        end

        # Generates an export step from the current (permanent) storage.
        # At the moment only Amazon S3 is supported.
        def transloadit_export_step(name, path: nil, **step_options)
          if defined?(Storage::S3) && storage.is_a?(Storage::S3)
            path ||= "${unique_prefix}/${file.url_name}" # Transloadit's default path

            step = transloadit.step(name, "/s3/store",
              key:           storage.client.config.access_key_id,
              secret:        storage.client.config.secret_access_key,
              bucket:        storage.bucket.name,
              bucket_region: storage.client.config.region,
              path:          [*storage.prefix, path].join("/"),
            )
          else
            raise Error, "Cannot construct a transloadit export step from #{storage.inspect}"
          end

          step.options.update(step_options)

          step
        end

        # Creates a new TransloaditFile for building steps, with an optional
        # import step applied.
        def transloadit_file(io = nil)
          file = TransloaditFile.new(transloadit: transloadit)
          file = file.add_step(transloadit_import_step("import", io)) if io
          file
        end

        # Accepts a TransloaditFile, a hash of TransloaditFiles or a template,
        # and converts it into a Transloadit::Assembly.
        #
        # If a hash of versions are given, the version information is saved in
        # assembly's payload, so that later in the webhook it can be used to
        # construct a hash of versions.
        def transloadit_assembly(value, context: {}, **options)
          options = { steps: [], fields: {} }.merge(options)

          case value
          when TransloaditFile then transloadit_assembly_update_single!(value, context, options)
          when Hash            then transloadit_assembly_update_versions!(value, context, options)
          when String          then transloadit_assembly_update_template!(value, context, options)
          else
            raise Error, "Assembly value has to be either a TransloaditFile, a hash of TransloaditFile objects, or a template"
          end

          if options[:steps].uniq(&:name) != options[:steps]
            raise Error, "There are different transloadit steps using the same name"
          end

          transloadit.assembly(options)
        end

        # An cached instance of a Tranloadit client.
        def transloadit
          @transloadit ||= self.class.transloadit
        end

        private

        # Updates assembly options for single files.
        def transloadit_assembly_update_single!(transloadit_file, context, options)
          raise Error, "The given TransloaditFile is missing an import step" if !transloadit_file.imported?
          unless transloadit_file.exported?
            path = generate_location(transloadit_file, context) + ".${file.ext}"
            export_step = transloadit_export_step("export", path: path)
            transloadit_file = transloadit_file.add_step(export_step)
          end
          options[:steps] += transloadit_file.steps
          options[:fields]["multiple"] = transloadit_file.multiple
        end

        # Updates assembly options for a hash of versions.
        def transloadit_assembly_update_versions!(versions, context, options)
          raise Error, "The versions Shrine plugin isn't loaded" if !defined?(Shrine::Plugins::Versions)
          options[:fields]["versions"] = {}
          options[:fields]["multiple"] = {}
          versions.each do |name, transloadit_file|
            raise Error, "The :#{name} version value is not a TransloaditFile" if !transloadit_file.is_a?(TransloaditFile)
            raise Error, "The given TransloaditFile is missing an import step" if !transloadit_file.imported?
            unless transloadit_file.exported?
              path = generate_location(transloadit_file, context.merge(version: name)) + ".${file.ext}"
              export_step = transloadit_export_step("export_#{name}", path: path)
              transloadit_file = transloadit_file.add_step(export_step)
            end
            options[:steps] |= transloadit_file.steps
            options[:fields]["versions"][name] = transloadit_file.name
            options[:fields]["multiple"][name] = transloadit_file.multiple
          end
        end

        # Updates assembly options for a template.
        def transloadit_assembly_update_template!(template, context, options)
          options[:template_id] = template
        end
      end

      module FileMethods
        # Converts the "transloadit_response" that was saved in cached file's
        # metadata into a reloadable object which is normally returned by the
        # Transloadit gem.
        def transloadit_response
          @transloadit_response ||= (
            body = metadata["transloadit_response"] or return
            body.instance_eval { def body; self; end }
            response = ::Transloadit::Response.new(body)
            response.extend ::Transloadit::Response::Assembly
            response
          )
        end
      end

      class TransloaditFile
        attr_reader :transloadit, :steps

        def initialize(transloadit:, steps: [], multiple: nil)
          @transloadit = transloadit
          @steps       = steps
          @multiple    = multiple
        end

        # Adds a step to the pipeline, automatically setting :use to the
        # previous step, so that later multiple pipelines can be seamlessly
        # joined into a single assembly.
        #
        # It returns a new TransloaditFile with the step added.
        def add_step(*args)
          if args[0].is_a?(::Transloadit::Step)
            step = args[0]
          else
            step = transloadit.step(*args)
          end

          unless step.options[:use]
            step.use steps.last if steps.any?
          end

          transloadit_file(steps: steps + [step])
        end

        # Specify the result format.
        def multiple(format = nil)
          if format
            transloadit_file(multiple: format)
          else
            @multiple
          end
        end

        # The key that Transloadit will use in its processing results for the
        # corresponding processed file. This equals to the name of the last
        # step, unless the last step is an export step.
        def name
          if exported?
            @steps[-2].name
          else
            @steps.last.name
          end
        end

        # Returns true if this TransloaditFile includes an import step.
        def imported?
          @steps.any? && @steps.first.robot.end_with?("/import")
        end

        # Returns true if this TransloaditFile includes an export step.
        def exported?
          @steps.any? && @steps.last.robot.end_with?("/store")
        end

        private

        def transloadit_file(**options)
          TransloaditFile.new(
            transloadit: @transloadit,
            steps:       @steps,
            multiple:    @multiple,
            **options
          )
        end
      end
    end

    register_plugin(:transloadit, Transloadit)
  end
end
