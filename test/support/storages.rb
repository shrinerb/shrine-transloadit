class Shrine::Storage::GoogleCloudStorage
  attr_reader :prefix

  def initialize(prefix: nil)
    @prefix = prefix
  end
end

class Shrine::Storage::YouTube
end
