# Changelog

All notable changes to SplatKit. Versions follow [Semantic Versioning](https://semver.org).

## Unreleased

### Breaking changes

- `SplatError.unauthorized`, `.notFound`, `.rateLimited` and `.serverError` now
  carry a `SplatError.APIError` with the HTTP status, the API's error `code`,
  `message`, `requestID` and `retryAfter`. Patterns that don't bind a payload
  (`catch SplatError.unauthorized`) still compile. Code that bound the old
  values reads them from the error instead:
  - `.notFound(let message)` → `.notFound(let error)`, then `error.message`
  - `.serverError(let code, let message)` → `.serverError(let error)`, then
    `error.statusCode` and `error.message`
  - Constructing these cases needs a payload:
    `.unauthorized(SplatError.APIError(statusCode: 401, message: "…"))`.
- Requests that never produce an HTTP response now throw `URLError`
  (`.badURL`, `.badServerResponse`) instead of `SplatError.serverError(0, …)`.
  An unparseable upload URL from `createScene` throws
  `SplatError.decodingError`.
- `SceneStatus` is no longer `RawRepresentable`: `SceneStatus(rawValue:)` is
  gone (`rawValue` remains), and exhaustive `switch`es must handle the new
  `.previewReady` and `.unknown(String)` cases.

### Added

- `updateScene(id:_:)` with `SceneUpdate`, `retrainScene(id:preset:)`,
  `cancelScene(id:)`, `downloadScene(id:format:)` with `ModelFormat`,
  `getSceneThumbnail(id:)`, and `getUsage()` with `Usage`. The SDK now covers
  all eleven operations of the public API.
- `listScenePage(cursor:limit:)` returns one page with `nextCursor` and
  `hasMore`; `allScenes(pageSize:)` walks every page as an async sequence.
- `SplatError.apiError` reads the failed response behind any HTTP error.
  Error descriptions include the request ID.
- `lidarPoints` on `processScene` and `createAndProcess`, and
  `CaptureResult.lidarPoints` from `SplatScanner` on LiDAR devices.
- `SplatScanner.session` and `totalFrameCount` for live preview UIs.
- `Scene` decodes `processingError`, `viewerURL`, `downloadURL` and `format`
  from the API, and unknown statuses decode as `.unknown` instead of failing.
- The SplatCapture example app, and macOS CI for the package and the example.

### Changed

- Scene IDs are percent-encoded as a single path segment.
- List cursors are percent-encoded in full. The API decodes a bare `+` in a
  query string as a space, which broke the timestamp cursor's `+00:00` offset.
- A failed scene reports the API's `processing_error` as its failure message.

### Deprecated

- `listScenes()`. It returns only the first page (up to 50 scenes) although
  it was documented as returning every scene. Use `listScenePage(cursor:limit:)`
  or `allScenes(pageSize:)`.

### Fixed

- Viewer URLs pointed at the retired `splat-3d.com/s/{id}` route, which returns
  404; they now use `/tour/{id}`.
- `preview_ready` decodes as an in-progress status instead of failing.

## 0.1.0

Initial release.
