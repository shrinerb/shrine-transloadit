require "./config/sequel"
require "./uploaders/image_uploader"

class Photo < Sequel::Model
  include ImageUploader::Attachment.new(:image)

  def filename
    image.original_filename
  end

  def dimensions
    image.metadata.fetch_values("width", "height")
  end
end
