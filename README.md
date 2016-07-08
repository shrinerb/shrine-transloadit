# Shrine::Plugins::Transloadit

Provides [Transloadit] integration for [Shrine].

Transloadit offers advanced file processing for all sorts of media, including
images, videos, audio, and documents, along with importing from and exporting
to various file storage services.

## Setup

While Transloadit is able to export processed files to [many storage
services], this plugin currently supports only Amazon S3 (just because there
are no Shrine integrations written for other services on that list yet).

```rb
gem "shrine-transloadit"
gem "aws-sdk"
```

```rb
require "shrine"
require "shrine/storage/s3"

Shrine.plugin :transloadit,
  auth_key:    "your transloadit key",
  auth_secret: "your transloadit secret"

Shrine.storages[:store] = Shrine::Storage::S3.new(
  access_key_id: "xyz",
  secret_access_key: "abc",
  region: "my-region",
  bucket: "my-app",
)
```

```rb
post "/webhooks/transloadit" do
  Shrine::Attacher.transloadit_save(params)
end
```

This setup assumes you want to do [direct uploads](#direct-uploads) to
Transloadit. This is completely optional, the plugin will work equally well
with whatever your `:cache` storage is.

## How it works

Transloadit works in a way that you create an "assembly", which contains all
information about how the file(s) should be processed, from import to export.
Processing itself happens asynchronously, and you can give Transloadit a URL
which it will POST results to when processing finishes.

This plugin allows you to easily implement this webhook flow. You can intercept
promoting, and submit a Transloadit assembly using the cached file, along with
a URL to the route in your app where you'd like Transloadit to POST the results
of processing. Then you can call the plugin again in the route to save the
results to your attachment column.

The **[demo app]** shows a complete implementation of this flow, and can serve
as a good baseline for your own implementation.

## Usage

Transloadit assemblies are built inside `#transloadit_process` method in your
uploader, and you can use some convenient helper methods which the plugin
provides.

```rb
class MyUploader < Shrine
  def transloadit_process(io, context)
    resized = transloadit_file(io)
      .add_step("resize", "/image/resize", width: 800)

    transloadit_assembly(resized, context: context)
  end
end
```

These helper methods just provide a higher-level interface over the
[transloadit gem], which you might want look at to get a better understanding
of how building assemblies works.

In short, in Transloadit every action, be it import, processing, or export, is
a "step". Each step is defined by its [robot and arguments], and needs to have
a *unique name*. Transloadit allows you to define the entire processing flow
(which can result in multiple files) as a collection of steps, which is called
an "assembly". Once the assembly is built it can be submitted to Transloadit.

### Versions

With Transloadit you can create multiple files in a single assembly, and this
plugin allows you to leverage that in form of a hash of versions.

```rb
class MyUploader < Shrine
  plugin :versions

  def transloadit_process(io, context)
    original = transloadit_file(io)
    medium = original.add_step("resize_500", "/image/resize", width: 500)
    small = original.add_step("resize_300", "/image/resize", width: 300)

    files = {original: original, medium: medium, small: small}

    transloadit_assembly(files, context: context)
  end
end
```

### Webhooks

Transloadit performs its processing asynchronously, and you can provide a URL
where you want Transloadit to POST results of processing once it's finished.

```rb
class MyUploader < Shrine
  def transloadit_process(io, context)
    # ...

    transloadit_assembly(files, notify_url: "http://myapp.com/webhooks/transloadit")
  end
end
```

Then in your `POST /webhooks/transloadit` route you can call the plugin to
automatically save the results to the attachment column in Shrine's format.

```rb
post "/webhooks/transloadit" do
  Shrine::Attacher.transloadit_save(params)
end
```

### Templates

Transloadit recommends using [templates], since they allow you to replay failed
assemblies, and also allow you not to expose credentials in your HTML.

Here is an example where the whole processing is defined inside a template,
and we just set the location of the imported file.

```rb
# Your saved template
{
  steps: {
    import: {
      robot: "/http/import",
      url: "..."
    },
    resize: {
      robot: "/image/resize",
      use: "import",
      width: 800
    }
  }
}
```
```rb
class MyUploader < Shrine
  def transloadit_process(io, context)
    transloadit_assembly("my_template", steps: {import: {url: io.url}})
  end
end
```

### Backgrounding

Even though submitting a Transloadit assembly doesn't require any uploading, it
still does two HTTP requests, so you might want to put it into a backgrond job.
This plugin naturally hooks onto Shrine's backgrounding plugin:

```rb
Shrine::Attacher.promote { |data| TransloaditJob.perform_async(data) }
```
```rb
class TransloaditJob
  include Sidekiq::Worker

  def perform(data)
    Shrine::Attacher.transloadit_process(data)
  end
end
```

### Tracking progress

When an assembly is submitted, Transloadit returns a lot of useful information
about the status of that assembly, which the plugin saves to the cached
attachment's metadata.

```rb
response = photo.image.transloadit_response
response.body #=>
# {
#   "ok"                 => "ASSEMBLY_EXECUTING",
#   "message"            => "The assembly is currently being executed.",
#   "assembly_id"        => "83d07d10414011e68cc8c5df79919836",
#   "assembly_url"       => "http://api2.janani.transloadit.com/assemblies/83d07d10414011e68cc8c5df79919836",
#   "execution_start"    => "2016/07/03 17:06:42 GMT",
#   "execution_duration" => 2.113,
#   "params"             => "{\"steps\":{...}}",
#   ...
# }
```

At an point during the execution of the assembly you can refresh this
information:

```rb
response.finished? #=> false
response.reload!
response.finished? #=> true
```

### Direct uploads

Transloadit supports direct uploads, allowing you to do additional processing
on upload, along with a [jQuery plugin] for easy integration. Generally you
only want to do some light processing on direct uploads, and without any
exporting, so that you have better control over your Transloadit bandwidth.

When direct upload finishes, Transloadit returns information about the uploaded
file(s). You can just convert that data to a JSON string and pass it as attachment
value (e.g. by assigning it to the hidden attachment field), and the plugin
will automatically recognize it and convert it to Shrine's attachment
representation.

See the **[demo app]** for a complete implementation of direct uploads.

### Import & Export

Every `TransloaditFile` needs to have an import and an export step. This plugin
automatically generates those steps for you:

```rb
transloadit_file(io)

# is equivalent to

file = transloadit_file
file.add_step(transloadit_import_step("import", io))
```

```rb
transloadit_assembly({original: original, thumb: thumb})

# is equivalent to

transloadit_assembly({
  original: original.add_step(transloadit_export_step("export_original")),
  thumb: thumb.add_step(transloadit_export_step("export_thumb")),
})
```

If you want/need to generate these steps yourself, you can just use the
expanded forms.

### Transloadit gem

If you want to have complete control over how steps are generated, you can just
use the [transloadit gem] directly. This plugin doesn't care how you generate
your steps, it only requires you to return an instance of
`Transloadit::Assembly`.

```rb
class MyUploader < Shrine
  def transloadit_process(io, context)
    # build options
    transloadit #=> #<Transloadit>
    transloadit.assembly(options)
  end
end
```

The import/export helper methods simply generate a `Transloadit::Step` object,
and you can pass additional options:

```rb
class MyUploader < Shrinee
  def transloadit_process(io, context)
    transloadit_import_step("import", io)             #=> #<Transloadit::Step>
    transloadit_export_step("export", path: "mypath") #=> #<Transloadit::Step>
  end
end
```

The `#add_step` method for `TransloaditFile` is just a convenient way to add
steps where `:use` is automatically set to previous step.

### Testing

In development or test environment you cannot use webhooks, because Transloadit
as an external service cannot access your localhost. In this case you can just
do polling:

```rb
class MyUploader < Shrine
  def transloadit_process(io, context)
    # ...

    if ENV["RACK_ENV"] == "production"
      notify_url = "https://myapp.com/webhooks/transloadit"
    else
      # In development we cannot receive webhooks, because Transloadit as an
      # external service cannot reach our localhost.
    end

    transloadit_assembly(files, context: context, notify_url: notify_url)
  end
end
```

```rb
class TransloaditJob
  include Sidekiq::Worker

  def perform(data)
    attacher = Shrine::Attacher.transloadit_process(data)

    # Webhooks won't work in development, so we can just use polling.
    unless ENV["RACK_ENV"] == "production"
      response = attacher.get.transloadit_response
      until response.finished?
        sleep 1
        response.reload!
      end
      attacher.transloadit_save(response.body)
    end
  end
end
```

## Contributing

Before you can run tests, you need to first create an `.env` file in the
project root containing your Transloadit and Amazon S3 credentials:

```sh
# .env
TRANSLOADIT_AUTH_KEY="..."
TRANSLOADIT_AUTH_SECRET="..."
S3_BUCKET="..."
S3_REGION="..."
S3_ACCESS_KEY_ID="..."
S3_SECRET_ACCESS_KEY="..."
```

Afterwards you can run the tests:

```sh
$ bundle exec rake test
```

## License

[MIT](/LICENSE.txt)

[Shrine]: https://github.com/janko-m/shrine
[Transloadit]: https://transloadit.com/
[many storage services]: https://transloadit.com/docs/conversion-robots/#file-export-robots
[transloadit gem]: https://github.com/transloadit/ruby-sdk
[robot and arguments]: https://transloadit.com/docs/conversion-robots/
[templates]: https://transloadit.com/docs/#templates
[jQuery plugin]: https://github.com/transloadit/jquery-sdk
[demo app]: /demo
