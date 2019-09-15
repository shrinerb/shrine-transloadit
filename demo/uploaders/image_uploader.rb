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

  Attacher.transloadit_saver :thumbnails do |results|
    size_300 = store.transloadit_file(results["resize_300"])
    size_500 = store.transloadit_file(results["resize_500"])
    size_800 = store.transloadit_file(results["resize_800"])

    merge_derivatives(small: size_300, medium: size_500, large: size_800)
  end
end
