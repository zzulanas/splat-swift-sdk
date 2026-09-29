# Changelog

All notable changes to SplatKit. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Breaking changes

- `Scene` is renamed `SplatScene`. SwiftUI and RealityKit declare `Scene`
  too, so a file that imported either beside SplatKit couldn't use the name
  unqualified: an app's `var body: some Scene` failed to compile there.
  Write `SplatScene` wherever you name the type. There is no `Scene` alias,
  because an alias would keep the ambiguity.
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
- `SplatScanner` failures throw the new `.captureFailed(Error)`, carrying the
  recorder's own error (e.g. an `AVError` when storage runs out) when there is
  one. They were `.serverError(0, …)`, which compiles no more, and a failed
  video file was `.uploadFailed`, which **still compiles but stops matching**
  around `scanner.stop()`.
- `createScene` returns `(sceneID:uploadURL:)`, matching `sceneID` elsewhere.
  `result.sceneId` no longer compiles; destructuring is unaffected.
- Requests that never produce an HTTP response now throw `URLError`
  (`.badURL`, `.badServerResponse`) instead of `SplatError.serverError(0, …)`.
  An unparseable upload URL from `createScene` throws
  `SplatError.decodingError`.
- `SceneStatus` is a `RawRepresentable` struct instead of an enum, so the API
  can add pipeline stages without another source break. It names every
  status the API reports, including `previewReady`, `estimatingPoses` and the
  `preview*` stages, and a stage it doesn't name keeps its raw value. What
  changes for existing code:
  - `switch`es need a plain `default`; one with `@unknown default` no longer
    compiles.
  - `SceneStatus(rawValue:)` no longer returns an optional.
  - Interpolating a status (`"\(status)"`) prints its API value,
    `extracting_frames`, instead of the case name `extractingFrames`. Logs,
    analytics keys or saved state built that way **still compile but change**.
  - `allCases` has 15 members in pipeline order instead of 10, and grows when
    a stage is named, so don't index into it.
- SplatKit needs Swift 5.10 (Xcode 15.3): `SplatScanner` uses
  `nonisolated(unsafe)`. The manifest's tools version says so.
- Once `createAndProcess` has created the scene, a failure that leaves the
  outcome open (network errors, API errors while launching, a timeout,
  cancellation) is thrown as `SplatError.interrupted(Interruption)`. Continue
  it with `resume(_:)`. Settled outcomes are thrown as themselves:
  `.processingFailed`, `.cancelled`, and the error of a launch the API failed
  and refunded. **Around `createAndProcess`, these catches still compile but
  stop matching errors that happen after the scene exists:**
  - `catch is CancellationError`: a cancelled task arrives as `.interrupted`
    with `underlying` `CancellationError`. SwiftUI `.task` code that ignores
    cancellation should match
    `SplatError.interrupted(let i) where i.underlying is CancellationError`.
    Cancelled while the scene is still being created, it is a plain
    `CancellationError` (there is no scene yet).
  - `catch let error as URLError`, including `URLError.cancelled`.
  - `catch SplatError.uploadFailed`, `.unauthorized`, `.notFound`,
    `.rateLimited`, `.requestFailed`, `.decodingError` and `.timeout`.
  Match `.interrupted` and inspect `interruption.underlying` instead.
  Exhaustive `switch`es over `SplatError` must also handle `.interrupted` and
  `.notStarted`.
- Progress callbacks (`onProgress` on `createAndProcess`, `waitForScene` and
  `resume`) are `@MainActor @Sendable` and **run on the main actor**; before,
  they ran on the concurrency pool. A closure literal compiles as before, now
  also from main-actor code in Swift 6, where it didn't. A stored closure that
  isn't `@Sendable` no longer converts, and slow work in the callback now
  blocks the main thread.
- A cancelled task throws `CancellationError` from every call. It used to
  surface as `URLError.cancelled` from a request, or as
  `.uploadFailed(URLError.cancelled)` from an upload, so
  `catch let error as URLError where error.code == .cancelled` **still
  compiles but stops matching**.
- `processScene` returns a `SceneLaunch`, the API's acknowledgement (scene ID,
  status, message, idempotency key), instead of a `Scene` read after the
  launch. That read could fail after the launch was already charged, and
  report a paid launch as an error. `launch.status` still compiles; read the
  scene with `getScene` or `waitForScene`.
- `processScene` sends `Idempotency-Key: process-<scene ID>` unless you pass
  one, so repeating it for a scene replays the launch. A scene launched with
  another key, or with none, answers a repeat with `conflict` (409).
- `waitForScene` throws the new `.notStarted` for a scene still `uploading` on
  two polls in a row, where no job exists. It used to poll it until the
  timeout.
- The default polling timeout is 165 minutes instead of 20. The API fails a
  job still processing after 150 minutes and checks every 10, so 20 minutes
  gave up on jobs that were still running.

### Added

- Automatic retries for reads and `processScene`: network failures, 5xx and
  rate limits, up to 3 retries with exponential backoff and jitter, honouring
  a `Retry-After` of up to 60 seconds. A used-up quota and other writes are
  never retried.
- `processScene(…, idempotencyKey:)` and `SceneLaunch`. Every launch sends an
  `Idempotency-Key`, `process-<scene ID>` by default, and reuses it on retries.
- `SplatClient.Configuration` (`requestTimeout`, `pollingInterval`,
  `pollingTimeout`, `maxRetries`) and `init(apiKey:baseURL:session:configuration:)`.
- `resume(_:onProgress:)` continues an interrupted `createAndProcess` without
  paying again. It reads the scene, uploads again only if the upload failed,
  and launches only if nothing was launched, with the identical request (the
  API hashes `enable_lod` and `lidar_points`, so a hand-rebuilt launch could
  409 or drop them).
- `resume(sceneID:preset:arkitPoses:lidarPoints:onProgress:)` continues a
  scene after an app restart, from its saved ID and the same preset and
  capture, rebuilding the same request.
- `onSceneCreated` on `createAndProcess`: the scene ID as soon as the scene
  exists, before anything is charged, so an app killed mid-wait can resume it.
- `waitForScene(id:onProgress:)` to pick up a launched scene. It keeps polling
  through network failures, 5xx and rate limits until its deadline; once it
  has read the scene, it also rides out up to 3 polls of 401 or 404, which the
  API returns when its database blips. After the deadline it looks once more.
- `SplatError.Interruption` (with `Phase`), `SplatError.notStarted`, and
  public initializers for `SceneLaunch` and `Interruption`.
- `updateScene(id:_:)` with `SceneUpdate`, `retrainScene(id:preset:)`,
  `cancelScene(id:)`, `downloadScene(id:format:)` with `ModelFormat`,
  `getSceneThumbnail(id:)`, and `getUsage()` with `Usage`. The SDK now covers
  all eleven operations of the public API.
- `listScenePage(cursor:limit:)` returns one page with `nextCursor` and
  `hasMore`; `allScenes(pageSize:)` walks every page as a `SceneSequence`. A
  cancelled task ends the walk with `CancellationError`, so a finished loop
  always saw every scene.
- `ModelFormat`, an open set like `SceneStatus`, for downloads and
  `SplatScene.format`. A format the API adds later keeps its name, and a
  download of it gets that file extension.
- Public initializers on `ScenePage`, `Usage` and `Usage.Limits` for test
  doubles.
- `SplatError.apiError` reads the failed response behind any HTTP error.
  Error descriptions include the request ID.
- `SceneStatus.isTerminal`.
- `lidarPoints` on `processScene` and `createAndProcess`, and
  `CaptureResult.lidarPoints` from `SplatScanner` on LiDAR devices.
- `SplatScanner.session` and `totalFrameCount` for live preview UIs.
- `SplatScene` decodes `processingError`, `viewerURL`, `downloadURL` and
  `format` from the API, and unknown statuses decode instead of failing.
- The SplatCapture example app, and macOS CI for the package and the example.

### Changed

- `SplatClient.init`'s `pollingInterval` and `pollingTimeout` are optional and
  default to the `Configuration` values. Existing calls compile unchanged.
- `SplatError.timeout` and `.cancelled` now document what throws them: the
  client giving up on polling, and a scene cancelled on the server.
- `SplatError.apiError` looks through `.interrupted`.
- A launch the API failed for good (`upstream_error`) is not retried: every
  repeat replays the same stored failure.
- Polls make one request each and wait out failures at the polling interval,
  so per-request retries no longer run past the deadline.
- Request bodies are encoded with sorted keys, so a repeated launch is
  byte-identical.
- `.processingFailed` is no longer documented as final: the pipeline can
  complete a scene the stale-job sweep had failed.
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
- Interpolating a `SplatError.APIError` prints its message, as 0.1.0's
  `String` payload did; `debugDescription` has every field.
- Thumbnails link to the API the client talks to, not always production.
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
- `SplatScene.isProcessing` is true for every non-terminal status. It was
  false for `estimating_poses` and the `preview_*` stages the pipeline writes.
- `SplatScene.downloadURL`'s documentation: the URL needs the API key, and
  serves SOG unless `?format=ply` is passed.

## 0.1.0

Initial release.
