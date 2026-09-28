# Changelog

All notable changes to SplatKit. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Breaking changes

- HTTP errors carry a `SplatError.APIError` with the HTTP status, the API's
  error `code`, `message`, `requestID` and `retryAfter`, and `.serverError` is
  renamed `.requestFailed`. It covers the same statuses as before (every
  failure except 401, 404 and 429, including 4xx such as `conflict`), but its
  old name suggested 5xx only. The old name is removed rather than narrowed,
  so code that relied on it fails to compile instead of silently missing
  errors.
  - `.notFound(let message)` → `.notFound(let error)`, then `error.message`
  - `.serverError(let code, let message)` → `.requestFailed(let error)`,
    then `error.statusCode` and `error.message`
  - Patterns without bindings, such as `catch SplatError.unauthorized`, still
    compile. Constructing these cases needs a payload:
    `.unauthorized(SplatError.APIError(statusCode: 401, message: "…"))`.
- `SplatScanner` failures throw the new `.captureFailed(String)`. They were
  `.serverError(0, …)`, which compiles no more, and a failed video file was
  `.uploadFailed`, which **still compiles but stops matching** around
  `scanner.stop()`.
- `createScene` returns `(sceneID:uploadURL:)`, matching `sceneID` elsewhere.
  `result.sceneId` no longer compiles; destructuring is unaffected.
- Requests that never produce an HTTP response now throw `URLError`
  (`.badURL`, `.badServerResponse`) instead of `SplatError.serverError(0, …)`.
  An unparseable upload URL from `createScene` throws
  `SplatError.decodingError`.
- `SceneStatus` is a `RawRepresentable` struct instead of an enum, so the API
  can add pipeline stages without breaking anyone: `switch`es need a
  `default`, and `SceneStatus(rawValue:)` no longer returns an optional. It
  names every status the API reports, including `previewReady`,
  `estimatingPoses` and the `preview*` stages, and a stage it doesn't name
  keeps its raw value.
- Once `createAndProcess` has created the scene, every failure is thrown as
  `SplatError.interrupted(sceneID:underlying:)`, including upload, launch and
  polling failures, timeouts and cancellation. **This compiles unchanged**:
  `catch SplatError.timeout` or `catch SplatError.processingFailed` around
  `createAndProcess` stops matching. Match the underlying error instead
  (`catch SplatError.interrupted(let sceneID, SplatError.timeout)`) or read
  `error.sceneID`. Exhaustive `switch`es over `SplatError` must handle the
  new case.
- The default polling timeout is 165 minutes instead of 20. The API fails a
  job still processing after 150 minutes and checks every 10, so 20 minutes
  gave up on jobs that were still running.

### Added

- Automatic retries for reads and `processScene`: network failures, 429 and
  5xx, up to 3 retries with exponential backoff and jitter, honouring a
  `Retry-After` of up to 60 seconds. Other writes are never retried.
- `processScene(…, idempotencyKey:)`. Every launch sends an `Idempotency-Key`,
  generated per call unless you pass one, and reuses it on retries.
- `SplatClient.Configuration` (`requestTimeout`, `pollingInterval`,
  `pollingTimeout`, `maxRetries`) and `init(apiKey:baseURL:session:configuration:)`.
- `waitForScene(id:onProgress:)` to resume polling a scene, and
  `SplatError.sceneID`.
- `updateScene(id:_:)` with `SceneUpdate`, `retrainScene(id:preset:)`,
  `cancelScene(id:)`, `downloadScene(id:format:)` with `ModelFormat`,
  `getSceneThumbnail(id:)`, and `getUsage()` with `Usage`. The SDK now covers
  all eleven operations of the public API.
- `listScenePage(cursor:limit:)` returns one page with `nextCursor` and
  `hasMore`; `allScenes(pageSize:)` walks every page as an async sequence.
- `SplatError.apiError` reads the failed response behind any HTTP error.
  Error descriptions include the request ID.
- `SceneStatus.isTerminal`.
- `lidarPoints` on `processScene` and `createAndProcess`, and
  `CaptureResult.lidarPoints` from `SplatScanner` on LiDAR devices.
- `SplatScanner.session` and `totalFrameCount` for live preview UIs.
- `Scene` decodes `processingError`, `viewerURL`, `downloadURL` and `format`
  from the API, and unknown statuses decode instead of failing.
- The SplatCapture example app, and macOS CI for the package and the example.

### Changed

- `SplatClient.init`'s `pollingInterval` and `pollingTimeout` are optional and
  default to the `Configuration` values. Existing calls compile unchanged.
- `SplatError.timeout` and `.cancelled` now document what throws them: the
  client giving up on polling, and a scene cancelled on the server.
- `SplatError.apiError` looks through `.interrupted`.
- Scene IDs are percent-encoded as a single path segment.
- List cursors are percent-encoded in full. The API decodes a bare `+` in a
  query string as a space, which would corrupt the timestamp cursor's
  `+00:00` offset.
- A failed scene reports the API's `processing_error` as its failure message.
- `processScene` and `createAndProcess` fit captures to the process route's
  limits: over 1,000 ARKit poses and over 50,000 LiDAR points are thinned
  evenly, and fewer than 5 poses are not sent (the pipeline then solves poses
  itself). Before, a scan longer than about 100 seconds failed with a 400
  after its upload.
- A 429's description is the server's message when it sent one, so a used-up
  quota says so and how to raise it, instead of "Rate limited".
- An error response that isn't from the API (an edge proxy's HTML page, or an
  empty or very long body) reads as its HTTP reason phrase, such as
  "Bad Gateway", instead of the raw page.

### Deprecated

- `listScenes()`. It returns only the first page (up to 50 scenes) although
  it was documented as returning every scene. Use `listScenePage(cursor:limit:)`
  or `allScenes(pageSize:)`.

### Fixed

- Viewer URLs pointed at the retired `splat-3d.com/s/{id}` route, which returns
  404; they now use `/tour/{id}`.
- `preview_ready` decodes as an in-progress status instead of failing.
- `Scene.isProcessing` is true for every non-terminal status. It was false for
  `estimating_poses` and the `preview_*` stages the pipeline writes.
- `Scene.downloadURL`'s documentation: the URL needs the API key, and serves
  SOG unless `?format=ply` is passed.

## 0.1.0

Initial release.
