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

### Added

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
