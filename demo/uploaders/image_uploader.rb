require "./config/shrine"

class ImageUploader < Shrine
  plugin :remove_attachment
  plugin :pretty_location
  plugin :versions

  def transloadit_process(io, context)
    original = transloadit_file(io)
    thumb = original.add_step("resize_300", "/image/resize", width: 300, height: 300)

    files = { original: original, thumb: thumb }

    if ENV["RACK_ENV"] == "production"
      notify_url = "https://myapp.com/webhooks/transloadit"
    else
      # In development we cannot receive webhooks, because Transloadit as an
      # external service cannot reach our localhost.
    end

    transloadit_assembly(files, context: context, notify_url: notify_url)
  end
end
