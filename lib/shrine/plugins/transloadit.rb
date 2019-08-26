# frozen_string_literal: true

require "transloadit"

require "uri"
require "json"
require "openssl"

class Shrine
  module Plugins
    module Transloadit
      # Transloadit's default destination path for export robots.
      DEFAULT_PATH = "${unique_prefix}/${file.url_name}"

      class Error < Shrine::Error
      end

      class InvalidSignature < Error
      end

      LOG_SUBSCRIBER = -> (event) do
        Shrine.logger.info "Transloadit (#{event.duration}ms) – #{{
          processor: event[:processor],
          uploader:  event[:uploader],
        }.inspect}"
      end

      # Accepts Transloadit credentials via `:auth_key` and `:auth_secret`.
      def self.configure(uploader, log_subscriber: LOG_SUBSCRIBER, **opts)
        uploader.opts[:transloadit] ||= { processors: {}, savers: {}, credentials: {} }
        uploader.opts[:transloadit].merge!(opts)

        fail Error, "The :auth option is required" unless uploader.opts[:transloadit][:auth]

        # instrumentation plugin integration
        uploader.subscribe(:transloadit, &log_subscriber) if uploader.respond_to?(:subscribe)
      end

      module AttacherClassMethods
        def transloadit_processor(name, &block)
          if block
            shrine_class.opts[:transloadit][:processors][name.to_sym] = block
          else
            shrine_class.opts[:transloadit][:processors][name.to_sym] or
              fail Error, "transloadit processor #{name.inspect} not registered"
          end
        end

        def transloadit_saver(name, &block)
          if block
            shrine_class.opts[:transloadit][:savers][name.to_sym] = block
          else
            shrine_class.opts[:transloadit][:savers][name.to_sym] or
              fail Error, "transloadit saver #{name.inspect} not registered"
          end
        end
      end

      module AttacherMethods
        def transloadit_process(name, *args)
          processor = self.class.transloadit_processor(name)
          instrument_transloadit(name) do
            instance_exec(*args, &processor)
          end
        end

        def transloadit_save(name, *args)
          saver = self.class.transloadit_saver(name)
          instance_exec(*args, &saver)
        end

        def transloadit_step(*args)
          shrine_class.transloadit_step(*args)
        end

        def transloadit
          shrine_class.transloadit
        end

        private

        def instrument_transloadit(processor, &block)
          return yield unless shrine_class.respond_to?(:instrument)

          shrine_class.instrument(:transloadit, processor: processor, &block)
        end
      end

      module ClassMethods
        def transloadit_step(name, robot, use: nil, **options)
          if Array(use).first.is_a?(::Transloadit::Step)
            step = transloadit.step(name, robot, **options)
            step.use(use) if use
            step
          else
            transloadit.step(name, robot, use: use, **options)
          end
        end

        # Verifies the Transloadit signature of a webhook request. Raises
        # `Shrine::Plugins::Transloadit::InvalidSignature` if signatures
        # don't match.
        def transloadit_verify!(params)
          if transloadit_sign(params["transloadit"]) != params["signature"]
            raise InvalidSignature, "received signature doesn't match calculated"
          end
        end

        # Creates a new Transloadit client each time. This way the expiration
        # timestamp is refreshed on new processing requests.
        def transloadit
          ::Transloadit.new(**opts[:transloadit][:auth])
        end

        def transloadit_credentials(storage_key)
          opts[:transloadit][:credentials][storage_key] or
            fail Error, "credentials not registered for storage #{storage_key.inspect}"
        end

        private

        # Signs given string with Transloadit secret key.
        def transloadit_sign(string)
          algorithm  = OpenSSL::Digest::SHA1.new
          secret_key = opts[:transloadit][:auth][:secret]

          OpenSSL::HMAC.hexdigest(algorithm, secret_key, string)
        end
      end

      module InstanceMethods
        def transloadit_files(results)
          results.map { |result| transloadit_file(result) }
        end

        def transloadit_file(result)
          result = result.first if result.is_a?(Array)
          uri    = URI.parse(result.fetch("url"))

          if defined?(Storage::S3) && storage.is_a?(Storage::S3)
            prefix = "#{storage.prefix}/" if storage.prefix
            id = uri.path.match(%r{^/#{prefix}})&.post_match or
              fail Error, "URL path doesn't start with storage prefix: #{uri}"
          elsif defined?(Storage::Url) && storage.is_a?(Storage::Url)
            id = uri.to_s
          else
            fail Error, "storage not supported: #{storage.inspect}"
          end

          metadata = {
            "filename"  => result.fetch("name"),
            "size"      => result.fetch("size"),
            "mime_type" => result.fetch("mime"),
          }

          # merge transloadit's meatadata, but don't let it override ours
          metadata.merge!(result.fetch("meta")) { |k, v1, v2| v1 }

          self.class::UploadedFile.new(
            id:       id,
            storage:  storage_key,
            metadata: metadata,
          )
        end

        def transloadit_export_step(name = "export", **options)
          unless options.key?(:credentials)
            options[:credentials] = self.class.transloadit_credentials(storage_key).to_s
          end

          if defined?(Storage::S3) && storage.is_a?(Storage::S3)
            transloadit_s3_store_step(name, **options)
          elsif defined?(Storage::GoogleCloudStorage) && storage.is_a?(Storage::GoogleCloudStorage)
            transloadit_google_store_step(name, **options)
          elsif defined?(Storage::YouTube) && storage.is_a?(Storage::YouTube)
            transloadit_youtube_store_step(name, **options)
          else
            fail Error, "cannot construct export step for #{storage.inspect}"
          end
        end

        private

        def transloadit_s3_store_step(name, path: DEFAULT_PATH, **options)
          transloadit_step name, "/s3/store",
            path: [*storage.prefix, path].join("/"),
            **options
        end

        def transloadit_google_store_step(name, path: DEFAULT_PATH, **options)
          transloadit_step name, "/google/store",
            path: [*storage.prefix, path].join("/"),
            **options
        end

        def transloadit_youtube_store_step(name, **options)
          transloadit_step name, "/youtube/store",
            **options
        end

        def transloadit_step(*args)
          self.class.transloadit_step(*args)
        end
      end

      module FileMethods
        def transloadit_import_step(name = "import", **options)
          if defined?(Storage::S3) && storage.is_a?(Storage::S3)
            transloadit_s3_import_step(name, **options)
          elsif url && URI(url).is_a?(URI::HTTP)
            transloadit_http_import_step(name, **options)
          elsif url && URI(url).is_a?(URI::FTP)
            transloadit_ftp_import_step(name, **options)
          else
            fail Error, "cannot construct import step from #{self.inspect}"
          end
        end

        private

        def transloadit_s3_import_step(name, **options)
          unless options.key?(:credentials)
            options[:credentials] = shrine_class.transloadit_credentials(storage_key).to_s
          end

          transloadit_step name, "/s3/import",
            path: [*storage.prefix, id].join("/"),
            **options
        end

        def transloadit_http_import_step(name, **options)
          transloadit_step name, "/http/import",
            url: url,
            **options
        end

        def transloadit_ftp_import_step(name, **options)
          uri = URI.parse(url)

          transloadit_step name, "/ftp/import",
            host:     uri.host,
            user:     uri.user,
            password: uri.password,
            path:     uri.path,
            **options
        end

        def transloadit_step(*args)
          shrine_class.transloadit_step(*args)
        end
      end
    end

    register_plugin(:transloadit, Transloadit)
  end
end
