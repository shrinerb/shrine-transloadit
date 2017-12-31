require "roda"
require "tilt/erb"

require "./models/album"
require "./models/photo"

class TransloaditDemo < Roda
  plugin :public

  plugin :render
  plugin :partials

  plugin :assets, js: "app.js", css: "app.css"

  use Rack::MethodOverride
  plugin :all_verbs

  use Rack::Session::Cookie, secret: "secret"
  plugin :csrf, raise: true, skip: ["POST:/webhooks/transloadit"]

  plugin :indifferent_params

  route do |r|
    r.public # serve static assets
    r.assets # serve dynamic assets

    @album = Album.first || Album.create(name: "My Album")

    r.root do
      view(:index)
    end

    r.put "album" do
      @album.update(params[:album])
      r.redirect r.referer
    end

    r.post "album/photos" do
      photo = @album.add_photo(params[:photo])
      partial("photo", locals: { photo: photo, idx: @album.photos.count })
    end

    # This is used only in production.
    r.post "webhooks/transloadit" do
      Shrine::Attacher.transloadit_save(params)
      response.write("") # returns empty 200 status
    end
  end
end
