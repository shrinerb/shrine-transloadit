# Shrine::Plugins::Transloadit

Provides [Transloadit] integration for [Shrine], using its [Ruby SDK].

Transloadit is a service that helps you handle file uploads, resize, crop and
watermark your images, make GIFs, transcode your videos, extract thumbnails,
generate audio waveforms and more.

## Contents

* [Installation](#installation)
* [Setup](#setup)
* [Usage](#usage)
* [Notifications](#notifications)
* [Direct uploads](#direct-uploads)
* [Promotion](#promotion)
* [Skipping exports](#skipping-exports)
* [API](#api)
  - [Processor](#processor)
  - [Saver](#saver)
  - [Step](#step)
    - [Import step](#import-step)
    - [Export step](#export-step)
  - [File](#file)
* [Instrumentation](#instrumentation)

## Installation

Put the gem in your Gemfile:

```rb
# Gemfile
gem "shrine-transloadit", "~> 1.0"
```

## Setup

You'll first need to create [credentials] for the storage service you want to
import from and export to. Let's assume you're using S3 and have named the
credentials `s3_store`. Now you can load the `transloadit` plugin, providing
Transloadit key & secret, and mapping credentials to Shrine storages:

```rb
# example storage configuration
Shrine.storages = {
  cache: Shrine::Storage::S3.new(prefix: "cache", **options),
  store: Shrine::Storage::S3.new(**options),
}

# transloadit plugin configuration
Shrine.plugin :transloadit,
  auth: {
    key:    "YOUR_TRANSLOADIT_KEY",
    secret: "YOUR_TRANSLOADIT_SECRET",
  },
  credentials: {
    cache: :s3_store, # use "s3_store" credentials for :cache storage
    store: :s3_store, # use "s3_store" credentials for :store storage
  }

# for storing processed files
Shrine.plugin :derivatives
```

## Usage

The `transloadit` plugin provides helper methods for creating [import][import
robots] and [export][export robots] steps, as well as for parsing out exported
files from results.

Here is a basic example where we kick off transcoding and thumbnail extraction
from an attached video, wait for assembly to complete, then save processed
files as derivatives:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do
    import = file.transloadit_import_step
    encode = transloadit_step "encode", "/video/encode", use: import
    thumbs = transloadit_step "thumbs", "/video/thumbs", use: import
    export = store.transloadit_export_step use: [encode, thumbs]

    assembly = transloadit.assembly(steps: [import, encode, thumbs, export])
    assembly.create!
  end

  Attacher.transloadit_saver :video do |results|
    transcoded = store.transloadit_file(results["encode"])
    thumbnails = store.transloadit_files(results["thumbs"])

    merge_derivatives(transcoded: transcoded, thumbnails: thumbnails)
  end
end
```
```rb
response = attacher.transloadit_process(:video)
response.reload_until_finished!

if response.error?
  # handle error
end

attacher.transloadit_save(:video, response["results"])
attacher.derivatives #=>
# {
#   transcoded: #<Shrine::UploadedFile storage_key=:store ...>,
#   thumbnails: [
#     #<Shrine::UploadedFile storage_key=:store ...>,
#     #<Shrine::UploadedFile storage_key=:store ...>,
#     ...
#   ]
# }
```

### Backgrounding

When using [backgrounding], it's probably best to create the assembly after
promotion:

```rb
class PromoteJob
  def perform(record, name, file_data)
    attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)
    attacher.atomic_promote
    attacher.transloadit_process(:video)
    # ...
  rescue Shrine::AttachmentChanged, ActiveRecord::RecordNotFound
  end
end
```

## Notifications

When using [assembly notifications], the attacher data can be sent to the
webhook via `:fields`:

```rb
Attacher.transloadit_processor :video do
  # ...
  assembly = transloadit.assembly(
    steps:      [ ... ],
    notify_url: "https://example.com/webhooks/transloadit",
    fields:     {
      attacher: {
        record_class: record.class,
        record_id:    record.id,
        name:         name,
        data:         file_data,
      }
    }
  )
  assembly.create!
end
```

Then in the webhook handler we can load the attacher and [atomically
persist][atomic_helpers] assembly results. If during processing the attachment
has changed or record was deleted, we make sure we delete processed files.

```rb
post "/transloadit/video" do
  Shrine.transloadit_verify!(params) # verify transloadit signature

  response = JSON.parse(params["transloadit"])

  record_class, record_id, name, file_data = response["fields"]["attacher"].values
  record_class = Object.const_get(record_class)

  attacher    = record_class.send(:"#{name}_attacher")
  derivatives = attacher.transloadit_save(:video, response["results"])

  begin
    record   = record_class.find(record_id)
    attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)

    attacher.merge_derivatives(derivatives)
    attacher.atomic_persist
  rescue Shrine::AttachmentChanged, ActiveRecord::RecordNotFound
    attacher.destroy_attached # delete orphaned processed files
  end

  # return successful response for Transloadit
  status 200
end
```

Note that if you have CSRF protection, make sure that you skip verifying the
CSRF token for this route.

## Direct uploads

Transloadit supports client side uploads via [Robodog], an [Uppy]-based
JavaScript library.

If you have an HTML form, you can use Robodog's [Form API][Robodog Form] to add
Transloadit's encoding capabilities to it:

```js
window.Robodog.form('form#myform', {
  params: {
    auth: { key: 'YOUR_TRANSLOADIT_KEY' },
    template_id: 'YOUR_TEMPLATE_ID',
  },
  waitForEncoding: true,
  // ...
})
```

With the above setup, Robodog will send the assembly results to your controller
in the `transloadit` param, which we can parse out and save to our record. See
the [demo app] for an example of doing this.

## Promotion

If you want Transloadit to also upload your cached original file to permanent
storage, you can skip promotion on the Shrine side:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do
    import = file.transloadit_import_step
    encode = transloadit_step "encode", "/video/encode", use: import
    thumbs = transloadit_step "thumbs", "/video/thumbs", use: import
    export = store.transloadit_export_step use: [import, encode, thumbs] # include original

    assembly = transloadit.assembly(steps: [import, encode, thumbs, export])
    assembly.create!
  end

  Attacher.transloadit_saver :video do |results|
    stored     = store.transloadit_file(results["import"])
    transcoded = store.transloadit_file(results["encode"])
    thumbnails = store.transloadit_files(results["thumbs"])

    set(stored) # set promoted file
    merge_derivatives(transcoded: transcoded, thumbnails: thumbnails)
  end
end
```
```rb
class PromoteJob
  def perform(record, name, file_data)
    attacher = Shrine::Attacher.retrieve(model: record, name: name, file: file_data)

    response = attacher.transloadit_process(:video)
    response.reload_until_finished!

    if response.error?
      # handle error
    end

    attacher.transloadit_save(:video, response["results"])
    attacher.atomic_persist attacher.uploaded_file(file_data)
  rescue Shrine::AttachmentChanged, ActiveRecord::RecordNotFound
    attacher&.destroy_attached # delete orphaned processed files
  end
end
```

## Skipping exports

If you want to use Transloadit only for processing, and prefer to store results
to yourself, you can do so with help of the [shrine-url] gem.

```rb
# Gemfile
gem "shrine-url"
```
```rb
# ...
require "shrine/storage/url"

Shrine.storages = {
  # ...
  url: Shrine::Storage::Url.new,
}
```

If you don't specify an export step, Transloadit will return processed files
uploaded to Transloadit's temporary storage. You can load these results using
the `:url` storage, and then upload them to your permanent storage:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do
    import = file.transloadit_import_step
    encode = transloadit_step "encode", "/video/encode", use: import
    thumbs = transloadit_step "thumbs", "/video/thumbs", use: import
    # no export step

    assembly = transloadit.assembly(steps: [import, encode, thumbs])
    assembly.create!
  end

  Attacher.transloadit_saver :video do |results|
    url        = shrine_class.new(:url)
    transcoded = url.transloadit_file(results["encode"])
    thumbnails = url.transloadit_files(results["thumbs"])

    # results are uploaded to Transloadit's temporary storage
    transcoded #=> #<Shrine::UploadedFile @storage_key=:url @id="https://tmp.transloadit.com/..." ...>
    thumbnails #=> [#<Shrine::UploadedFile @storage_key=:url @id="https://tmp.transloadit.com/..." ...>, ...]

    # upload results to permanent storage
    add_derivatives(transcoded: transcoded, thumbnails: thumbnails)
  end
end
```
```rb
response = attacher.transloadit_process(:video)
response.reload_until_finished!

if response.error?
  # handle error
end

attacher.transloadit_save(:video, response["results"])
attacher.derivatives #=>
# {
#   transcoded: #<Shrine::UploadedFile storage_key=:store ...>,
#   thumbnails: [
#     #<Shrine::UploadedFile storage_key=:store ...>,
#     #<Shrine::UploadedFile storage_key=:store ...>,
#     ...
#   ]
# }
```

## API

### Processor

The processor is just a block registered under an identifier, which is expected
to create a Transloadit assembly:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do
    # ...
  end
end
```

It is executed when `Attacher#transloadit_process` is called:

```rb
attacher.transloadit_process(:video) # calls :video processor
```

Any arguments passed to the processor will be given to the block:

```rb
attacher.transloadit_process(:video, foo: "bar")
```
```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do |options|
    options #=> { :foo => "bar" }
  end
end
```

The processor block is executed in context of a `Shrine::Attacher` instance:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_processor :video do
    self #=> #<Shrine::Attacher>

    record #=> #<Video>
    name   #=> :file
    file   #=> #<Shrine::UploadedFile>
  end
end
```

### Saver

The saver is just a block registered under an identifier, which is expected to
save given Transloadit results into the attacher:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_saver :video do |results|
    # ...
  end
end
```

It is executed when `Attacher#transloadit_save` is called:

```rb
attacher.transloadit_save(:video, results) # calls :video saver
```

Any arguments passed to the saver will be given to the block:

```rb
attacher.transloadit_save(:video, results, foo: "bar")
```
```rb
class VideoUploader < Shrine
  Attacher.transloadit_saver :video do |results, options|
    options #=> { :foo => "bar" }
  end
end
```

The saver block is executed in context of a `Shrine::Attacher` instance:

```rb
class VideoUploader < Shrine
  Attacher.transloadit_saver :video do |results|
    self #=> #<Shrine::Attacher>

    record #=> #<Video>
    name   #=> :file
    file   #=> #<Shrine::UploadedFile>
  end
end
```

### Step

You can generate `Transloadit::Step` objects with `Shrine.transloadit_step`:

```rb
Shrine.transloadit_step "my_name", "/my/robot", **options
#=> #<Transloadit::Step name="my_name", robot="/my/robot", options={...}>
```

This method adds the ability to pass another `Transloadit::Step` object as the
`:use` parameter:

```rb
step_one = Shrine.transloadit_step "one", "/robot/one"
step_two = Shrine.transloadit_step "two", "/robot/two", use: step_one
step_two.options[:use] #=> ["one"]
```

### Import step

The `Shrine::UploadedFile#transloadit_import_step` method generates an import
step for the uploaded file:

```rb
file = Shrine.upload(io, :store)
file.storage #=> #<Shrine::Storage::S3>
file.id      #=> "foo"

step = file.transloadit_import_step

step       #=> #<Transloadit::Step ...>
step.name  #=> "import"
step.robot #=> "/s3/import"

step.options[:path]        #=> "foo"
step.options[:credentials] #=> :s3_store (inferred from the plugin setting)
```

You can change the default step name:

```rb
step = file.transloadit_import_step("my_import")
step.name #=> "my_import"
```

You can also pass step options:

```rb
step = file.transloadit_import_step(ignore_errors: ["meta"])
step.options[:ignore_errors] #=> ["meta"]
```

The following import robots are currently supported:

| Robot          | Description                                                |
| :-----------   | :----------                                                |
| `/s3/import`   | activated for `Shrine::Storage::S3`                        |
| `/http/import` | activated for any other storage which returns HTTP(S) URLs |
| `/ftp/import`  | activated for any other storage which returns FTP URLs     |

### Export step

The `Shrine#transloadit_export_step` method generates an export step for the underlying
storage:

```rb
uploader = Shrine.new(:store)
uploader.storage #=> #<Shrine::Storage::S3>

step = uploader.transloadit_export_step

step       #=> #<Transloadit::Step ...>
step.name  #=> "export"
step.robot #=> "/s3/store"

step.options[:credentials] #=> :s3_store (inferred from the plugin setting)
```

You can change the default step name:

```rb
step = uploader.transloadit_export_step("my_export")
step.name #=> "my_export"
```

You can also pass step options:

```rb
step = file.transloadit_export_step(acl: "public-read")
step.options[:acl] #=> "public-read"
```

The following export robots are currently supported:

| Robot            | Description                                                       |
| :----            | :----------                                                       |
| `/s3/store`      | activated for `Shrine::Storage::S3`                               |
| `/google/store`  | activated for [`Shrine::Storage::GoogleCloudStorage`][shrine-gcs] |
| `/youtube/store` | activated for [`Shrine::Storage::YouTube`][shrine-youtube]        |

### File

The `Shrine#transloadit_file` method will convert a Transloadit result hash
into a `Shrine::UploadedFile` object:

```rb
uploader = Shrine.new(:store)
uploader.storage #=> #<Shrine::Storage::S3>

file = uploader.transloadit_file(
  "url" => "https://my-bucket.s3.amazonaws.com/foo",
  # ...
)

file #=> #<Shrine::UploadedFile @id="foo" storage_key=:store ...>

file.storage #=> #<Shrine::Storage::S3>
file.id      #=> "foo"
```

You can use the plural `Shrine#transloadit_files` to convert an array of
results:

```rb
files = uploader.transloadit_files [
  { "url" => "https://my-bucket.s3.amazonaws.com/foo", ... },
  { "url" => "https://my-bucket.s3.amazonaws.com/bar", ... },
  { "url" => "https://my-bucket.s3.amazonaws.com/baz", ... },
]

files #=>
# [
#   #<Shrine::UploadedFile @id="foo" @storage_key=:store ...>,
#   #<Shrine::UploadedFile @id="bar" @storage_key=:store ...>,
#   #<Shrine::UploadedFile @id="baz" @storage_key=:store ...>,
# ]
```

It will include basic metadata:

```rb
file = uploader.transloadit_file(
  # ...
  "name" => "matrix.mp4",
  "size" => 44198,
  "mime" => "video/mp4",
)

file.original_filename #=> "matrix.mp4"
file.size              #=> 44198
file.mime_type         #=> "video/mp4"
```

It will also merge any custom metadata:

```rb
file = uploader.transloadit_file(
  # ...
  "meta" => { "duration" => 9000, ... },
)

file["duration"] #=> 9000
```

Currently only `Shrine::Stroage::S3` is supported. However, you can still
handle other remote files using [`Shrine::Storage::Url`][shrine-url]:

```rb
Shrine.storages => {
  # ...
  url: Shrine::Storage::Url.new,
}
```
```rb
uploader = Shrine.new(:url)
uploader #=> #<Shrine::Storage::Url>

file = uploader.transloadit_file(
  "url" => "https://example.com/foo",
  # ...
)

file.id #=> "https://example.com/foo"
```

## Instrumentation

If the `instrumentation` plugin has been loaded, the `transloadit` plugin adds
instrumentation around triggering processing.

```rb
# instrumentation plugin needs to be loaded *before* transloadit
plugin :instrumentation
plugin :transloadit
```

Calling the processor will trigger a `transloadit.shrine` event with the
following payload:

| Key          | Description                            |
| :----        | :----------                            |
| `:processor` | Name of the processor                  |
| `:uploader`  | The uploader class that sent the event |

A default log subscriber is added as well which logs these events:

```
Transloadit (1238ms) – {:processor=>:video, :uploader=>VideoUploader}
```

You can also use your own log subscriber:

```rb
plugin :transloadit, log_subscriber: -> (event) {
  Shrine.logger.info JSON.generate(name: event.name, duration: event.duration, **event.payload)
}
```
```
{"name":"transloadit","duration":1238,"processor":"video","uploader":"VideoUploader"}
```

Or disable logging altogether:

```rb
plugin :transloadit, log_subscriber: nil
```

## Contributing

Tests are run with:

```sh
$ bundle exec rake test
```

## License

[MIT](/LICENSE.txt)

[Shrine]: https://github.com/shrinerb/shrine
[Transloadit]: https://transloadit.com/
[Ruby SDK]: https://github.com/transloadit/ruby-sdk
[credentials]: https://transloadit.com/docs/#16-template-credentials
[import robots]: https://transloadit.com/docs/transcoding/#overview-service-file-importing
[export robots]: https://transloadit.com/docs/transcoding/#overview-service-file-exporting
[derivatives]: https://github.com/shrinerb/shrine/blob/master/doc/plugins/derivatives.md#readme
[assembly notifications]: https://transloadit.com/docs/#24-assembly-notifications
[backgrounding]: https://github.com/shrinerb/shrine/blob/master/doc/plugins/backgrounding.md#readme
[shrine-url]: https://github.com/shrinerb/shrine-url
[Robodog]: https://uppy.io/docs/robodog/
[Robodog Form]: https://uppy.io/docs/robodog/form/
[Uppy]: https://uppy.io/
[atomic_helpers]: https://github.com/shrinerb/shrine/blob/master/doc/plugins/atomic_helpers.md#readme
[shrine-gcs]: https://github.com/renchap/shrine-google_cloud_storage
[shrine-youtube]: https://github.com/thedyrt/shrine-storage-you_tube
[shrine-url]: https://github.com/shrinerb/shrine-url
