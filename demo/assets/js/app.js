// This code uses:
//
// * babel-polyfill (https://babeljs.io/docs/usage/polyfill/)
// * whatwg-fetch (https://github.github.io/fetch/)
// * tus-js-client (https://github.com/tus/tus-js-client)
// * uppy (https://uppy.io)

document.querySelectorAll('input[type=file]').forEach(function (fileInput) {
  fileInput.style.display = 'none' // uppy will add its own file input

  uppy = Uppy.Core({
      id: fileInput.id,
      autoProceed: true,
    })
    .use(Uppy.FileInput, {
      target: fileInput.parentNode,
    })
    .use(Uppy.Transloadit, {
      waitForEncoding: true,
      params: {
        auth: { key: fileInput.dataset.transloaditKey },
        steps: {
          resize: {
            robot: '/image/resize',
            use: ':original',
            width: 800,
            height: 800
          }
        }
      }
    })
    .use(Uppy.Informer, {
      target: fileInput.parentNode,
    })
    .use(Uppy.ProgressBar, {
      target: fileInput.parentNode,
    })

  uppy.on('transloadit:result', function (stepName, result) {
    var uploadedFileData = JSON.stringify({
      id: result['ssl_url'],
      storage: 'cache',
      metadata: {
        size: result['size'],
        filename: result['name'],
        mime_type: result['mime'],
        width: result['meta'] && result['meta']['width'],
        height: result['meta'] && result['meta']['height'],
        transloadit: result['meta'],
      }
    })

    params = new URLSearchParams()
    params.set('photo[image]', uploadedFileData)

    fetch('/album/photos', {
      method: 'POST',
      body: params,
      headers: { 'X-CSRF-Token': document.querySelector('meta[name=_csrf]').content },
      credentials: 'same-origin' // forward CSRF session
    }).then(function (response) {
      return response.text()
    }).then(function (html) {
      document.querySelector('ul').insertAdjacentHTML('beforeend', html)
    })
  })
})
