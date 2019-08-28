require "./config/shrine"

class ImageUploader < Shrine
  plugin :derivatives

  Attacher.transloadit_processor :thumbnails do
    import = file.transloadit_import_step

    resizes = [300, 500, 800].map do |size|
      transloadit_step "resize_#{size}", "/image/resize",
        width: size, height: size, use: import
    end

    export = store.transloadit_export_step use: resizes

    assembly = transloadit.assembly(
      steps:      [import, *resizes, export],
      notify_url: ENV["TRANSLOADIT_NOTIFY_URL"],
      fields: {
        attacher: { # needed if you're using notifications
          record_class: record.class,
          record_id:    record.id,
          name:         name,
          data:         file_data,
        }
      }
    )

    assembly.create!
  end

  Attacher.transloadit_saver :thumbnails do |response|
    results = response["results"]

    merge_derivatives(
      small:  store.transloadit_file(results["resize_300"]),
      medium: store.transloadit_file(results["resize_500"]),
      large:  store.transloadit_file(results["resize_800"]),
    )
  end
end
