require "sucker_punch"

class PromoteJob
  include SuckerPunch::Job

  def perform(record_class, record_id, name, file_data)
    record   = Object.const_get(record_class.to_s).with_pk!(record_id)
    attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)

    attacher.atomic_promote

    transloadit_process(attacher)
  rescue Shrine::AttachmentChanged, Sequel::NoMatchingRow, Sequel::NoExistingObject
  end

  private

  def transloadit_process(attacher)
    response = attacher.transloadit_process(:thumbnails)

    # if we're using notifications, the webhook will take care of the rest
    return unless response["notify_url"]

    response.reload_until_finished!
    fail "assembly failed: #{response.body.to_json}" if response.error?

    attacher.transloadit_save(:thumbnails, response["results"])
    attacher.atomic_persist
  rescue Shrine::AttachmentChanged, Sequel::NoExistingObject
    attacher.destroy_attached
  end
end
