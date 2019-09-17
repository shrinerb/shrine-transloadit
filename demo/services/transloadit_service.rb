require "./config/shrine"
require "./models/photo"
require "json"

class TransloaditService
  def self.receive_webhook(params)
    Shrine.transloadit_verify!(params)

    response = JSON.parse(params["transloadit"])

    record_class, record_id, name, file_data = response["fields"]["attacher"].values
    record_class = Object.const_get(record_class)

    attacher    = record_class.send(:"#{name}_attacher")
    derivatives = attacher.transloadit_save(:thumbnails, response["results"])

    begin
      record   = record_class.with_pk!(record_id)
      attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)

      attacher.set_derivatives(derivatives)
      attacher.atomic_persist
    rescue Shrine::AttachmentChanged, Sequel::NoMatchingRow
      attacher.destroy(background: true) # delete orphaned files
    end
  end

  def self.create_photos(params)
    response = JSON.parse(params.fetch("transloadit")).first
    results  = response.fetch("results")

    results.fetch(":original").zip(results.fetch("sepia")) do |original_data, sepia_data|
      photo    = Photo.new
      attacher = photo.image_attacher

      original = attacher.cache.transloadit_file(original_data)
      sepia    = attacher.cache.transloadit_file(sepia_data)

      attacher.change(original)
      attacher.set_derivatives(sepia: sepia)

      photo.save
    end
  end
end
