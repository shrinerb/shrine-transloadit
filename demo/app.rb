require "roda"
require "tilt/erb"

require "./models/photo"
require "./services/transloadit_service"

require "json"

class TransloaditDemo < Roda
  plugin :render

  plugin :sessions, secret: SecureRandom.hex(32)
  plugin :route_csrf
  plugin :forme_route_csrf

  route do |r|
    # This is used only in production.
    r.post "webhooks/transloadit" do
      TransloaditService.receive_webhook(r.params)

      "" # returns empty 200 status
    end

    check_csrf!

    r.root do
      photos = Photo.all

      view(:index, locals: { photos: photos })
    end

    r.post "photos" do
      TransloaditService.create_photos(r.params)

      r.redirect "/"
    end
  end
end
