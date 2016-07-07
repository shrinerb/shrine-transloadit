require "transloadit"
require "down"

require "uri"
require "json"
require "openssl"
require "net/http"

class Shrine
  module Plugins
    module Transloadit
      def self.configure(uploader, opts = {})
        uploader.opts[:transloadit_auth_key] = opts.fetch(:auth_key, uploader.opts[:transloadit_auth_key])
        uploader.opts[:transloadit_auth_secret] = opts.fetch(:auth_secret, uploader.opts[:transloadit_auth_secret])

        raise Error, "The :auth_key is required for transloadit plugin" if uploader.opts[:transloadit_auth_key].nil?
        raise Error, "The :auth_secret is required for transloadit plugin" if uploader.opts[:transloadit_auth_secret].nil?

        uploader.storages[:cache] ||= UrlStorage.new
        uploader.opts[:backgrounding_promote] ||= proc { transloadit_process }
      end

      def self.load_dependencies(uploader, opts = {})
        uploader.plugin :backgrounding
      end

      module AttacherClassMethods
        def transloadit_process(data)
          attacher = self.load(data)
          cached_file = attacher.uploaded_file(data["attachment"])
          attacher.transloadit_process(cached_file)
          attacher
        end

        def transloadit_save(params)
          params["transloadit"] = params["transloadit"].to_json if params["transloadit"].is_a?(Hash)
          check_transloadit_signature!(params)
          response = JSON.parse(params["transloadit"])
          data = response["fields"]["attacher"]
          attacher = self.load(data)
          cached_file = attacher.uploaded_file(data["attachment"])
          attacher.transloadit_save(response, valid: attacher.get == cached_file)
          attacher
        end

        def check_transloadit_signature!(params)
          sent_signature = params["signature"]
          payload = params["transloadit"]
          algorithm = OpenSSL::Digest.new('sha1')
          secret = shrine_class.opts[:transloadit_auth_secret]
          calculated_signature = OpenSSL::HMAC.hexdigest(algorithm, secret, payload)
          raise Error, "Transloadit signature that was sent doesn't match the calculated signature" if calculated_signature != sent_signature
        end
      end

      module AttacherMethods
        def transloadit_process(cached_file = get)
          assembly = store.transloadit_process(cached_file, context)
          assembly.options[:fields] ||= {}
          assembly.options[:fields]["attacher"] = self.dump.merge("attachment" => cached_file.to_json)
          response = assembly.submit!
          raise Error, "#{response["error"]}: #{response["message"]}" if response["error"]
          cached_file.metadata["transloadit_response"] = response.body.to_json
          swap(cached_file) or _set(cached_file)
        end

        def transloadit_save(response, valid: true)
          if versions = response["fields"]["versions"]
            stored_file = versions.inject({}) do |hash, (name, key)|
              result = response["results"].fetch(key)[0]
              uploaded_file = store.transloadit_uploaded_file(result)
              hash.update(name => uploaded_file)
            end
          else
            result = response["results"].values.last[0]
            stored_file = store.transloadit_uploaded_file(result)
          end

          if valid
            swap(stored_file)
          else
            _delete(stored_file, phase: :abort)
          end
        end

        def uploaded_file(value)
          if value.is_a?(String) || value.is_a?(Hash)
            value = JSON.parse(value) if value.is_a?(String)
            if value["url"].is_a?(String) # from direct upload
              cache.transloadit_uploaded_file(value)
            else
              super
            end
          else
            super
          end
        end
      end

      module ClassMethods
        def transloadit
          ::Transloadit.new(
            key:    opts[:transloadit_auth_key],
            secret: opts[:transloadit_auth_secret],
          )
        end
      end

      module InstanceMethods
        def transloadit_uploaded_file(result)
          case url = result.fetch("url")
          when /tmp\.transloadit\.com/
            id = url
          when /amazonaws\.com/
            path = URI(url).path
            id = path.match(/^\/#{storage.prefix}/).post_match
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

        def transloadit_import_step(name, io, **step_options)
          uri = URI.parse(io.url)

          if defined?(Storage::S3) && io.storage.is_a?(Storage::S3)
            step = transloadit.step(name, "/s3/import",
              key:           io.storage.s3.client.config.access_key_id,
              secret:        io.storage.s3.client.config.secret_access_key,
              bucket:        io.storage.bucket.name,
              bucket_region: io.storage.s3.client.config.region,
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

        def transloadit_export_step(name, **step_options)
          if defined?(Storage::S3) && storage.is_a?(Storage::S3)
            step = transloadit.step(name, "/s3/store",
              key:           storage.s3.client.config.access_key_id,
              secret:        storage.s3.client.config.secret_access_key,
              bucket:        storage.bucket.name,
              bucket_region: storage.s3.client.config.region
            )
          else
            raise Error, "Cannot construct a transloadit export step from #{storage.inspect}"
          end

          step.options.update(step_options)

          step
        end

        def transloadit_file(io = nil)
          file = TransloaditFile.new(transloadit: transloadit)
          file = file.add_step(transloadit_import_step("import", io)) if io
          file
        end

        def transloadit_assembly(value, context: {}, **options)
          options[:steps] ||= []
          options[:fields] ||= {}

          if (versions = value).is_a?(Hash)
            options[:fields]["versions"] = {}
            raise Error, "The versions Shrine plugin isn't loaded" if !defined?(Shrine::Plugins::Versions)
            versions.each do |name, transloadit_file|
              raise Error, "The given TransloaditFile is missing an import step" if !transloadit_file.imported?
              unless transloadit_file.exported?
                path = generate_location(transloadit_file, context.merge(version: name)) + ".${file.ext}"
                export_step = transloadit_export_step("export_#{name}", path: path)
                transloadit_file = transloadit_file.add_step(export_step)
              end
              options[:steps] |= transloadit_file.steps
              options[:fields]["versions"][name] = transloadit_file.name
            end
          elsif (transloadit_file = value).is_a?(TransloaditFile)
            raise Error, "The given TransloaditFile is missing an import step" if !transloadit_file.imported?
            unless transloadit_file.exported?
              path = generate_location(transloadit_file, context) + ".${file.ext}"
              export_step = transloadit_export_step("export", path: path)
              transloadit_file = transloadit_file.add_step(export_step)
            end
            options[:steps] += transloadit_file.steps
          elsif (template = value).is_a?(String)
            options[:template_id] = template
          else
            raise Error, "First argument has to be a TransloaditFile, a hash of TransloaditFiles, or a template"
          end

          if options[:steps].uniq(&:name) != options[:steps]
            raise Error, "There are different transloadit steps using the same name"
          end

          transloadit.assembly(options)
        end

        def transloadit
          @transloadit ||= self.class.transloadit
        end
      end

      module FileMethods
        def transloadit_response
          @transloadit_response ||= (
            body = metadata.fetch("transloadit_response")
            body.instance_eval { def body; self; end }
            response = ::Transloadit::Response.new(body)
            response.extend ::Transloadit::Response::Assembly
            response
          )
        end
      end

      class TransloaditFile
        attr_reader :transloadit, :steps

        def initialize(transloadit:, steps: [])
          @transloadit = transloadit
          @steps = steps
        end

        def add_step(*args)
          if args[0].is_a?(::Transloadit::Step)
            step = args[0]
          else
            step = transloadit.step(*args)
          end

          unless step.options[:use]
            step.use @steps.last if @steps.any?
          end

          TransloaditFile.new(transloadit: transloadit, steps: @steps + [step])
        end

        # Transloadit in its result uses the name of the last step before the
        # export step.
        def name
          if exported?
            @steps[-2].name
          else
            @steps.last.name
          end
        end

        def imported?
          @steps.any? && @steps.first.robot.end_with?("/import")
        end

        def exported?
          @steps.any? && @steps.last.robot.end_with?("/store")
        end
      end

      class UrlStorage
        def download(id)
          Down.download(id)
        end

        def open(id)
          Down.open(id)
        end

        def exists?(id)
          response = nil
          uri = URI(id)
          Net::HTTP.start(uri.host, uri.port) { |http| response = http.head(id) }
          response.code.to_i == 200
        end

        def url(id, **options)
          id
        end
      end
    end

    register_plugin(:transloadit, Transloadit)
  end
end
