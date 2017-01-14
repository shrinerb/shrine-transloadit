require "sucker_punch"

class TransloaditJob
  include SuckerPunch::Job

  def perform(data)
    attacher = Shrine::Attacher.transloadit_process(data)

    # Webhooks won't work in development environment, so we can just use polling.
    unless ENV["RACK_ENV"] == "production"
      response = attacher.get.transloadit_response
      response.reload_until_finished!
      attacher.transloadit_save(response.body)
    end
  end
end
