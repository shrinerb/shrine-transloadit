require "sucker_punch"

class PromoteJob
  include SuckerPunch::Job

  ATOMIC_ERRORS = [
    Shrine::AttachmentChanged,
    Sequel::NoMatchingRow,
    Sequel::NoExistingObject,
  ]

  def perform(record_class, record_id, name, file_data)
    record   = Object.const_get(record_class.to_s).with_pk!(record_id)
    attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)

    attacher.atomic_promote

    transloadit_process(attacher)
  rescue *ATOMIC_ERRORS
  end

  private

  def transloadit_process(attacher)
    response = attacher.transloadit_process(:thumbnails)

    # if we're not using notifications, poll the assembly and save results.
    unless response["notify_url"]
      response.reload_until_finished!
      fail "assembly failed: #{response.body.to_json}" if response.error?

      attacher.transloadit_save(:thumbnails, response)
      attacher.atomic_persist
    end
  rescue *ATOMIC_ERRORS
    attacher.destroy(background: true)
  end
end
