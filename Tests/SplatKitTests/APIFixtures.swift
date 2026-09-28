import Foundation

// MARK: - API Fixtures
//
// Response bodies the contract tests replay. Each cites where its keys come
// from: a schema or example in the pinned spec (Fixtures/openapi.json, a copy
// of https://api.splat-3d.com/openapi.json) or the API source in the
// gaussian-splatting repo (api/src/..., supabase/migrations/...). Values are
// examples. ContractTests checks every fixture against its spec schema; where
// the source and the spec disagree, the fixture follows the source and
// ContractTests lists the difference.

enum Fixture {

    /// A scene ID in the API's format (6 random bytes, hex; createScene in
    /// api/src/lib/scenes.ts). Spec example for Scene.id.
    static let sceneID = "a1b2c3d4e5f6"

    /// `/v1/scenes/{id}` for ``sceneID``.
    static let scenePath = "/v1/scenes/\(sceneID)"

    /// Spec example for ErrorResponse.meta.request_id.
    static let requestID = "550e8400-e29b-41d4-a716-446655440000"

    /// Timestamps as PostgREST serializes `timestamptz`: microseconds and a
    /// numeric offset. Every `created_at`/`updated_at` comes straight from the
    /// database (getSceneStatus, listScenes, updateScene in api/src/lib/scenes.ts).
    static let createdAt = "2026-09-28T12:00:00.123456+00:00"
    static let updatedAt = "2026-09-28T12:14:03.5+00:00"

    /// The list cursor is the last row's `created_at` (listScenes in
    /// api/src/lib/scenes.ts), so it carries a `+`.
    static let pageOneCursor = "2026-09-27T09:30:00.654321+00:00"

    // MARK: - Scenes

    /// POST /v1/scenes → 201. Spec: CreateSceneResponse, with its examples.
    static let createScene = """
    {
        "data": { "sceneId": "a1b2c3d4e5f6", "uploadUrl": "https://r2.dev/upload?..." },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// GET /v1/scenes/{id} → 200 for a complete scene. Keys: SceneStatusResult
    /// and getSceneStatus's `complete` branch in api/src/lib/scenes.ts
    /// (viewer_url, download_url, format). Spec: SceneDetailResponse.
    static let completeScene = """
    {
        "data": {
            "id": "a1b2c3d4e5f6",
            "title": "My living room",
            "address": "123 Main St",
            "status": "complete",
            "is_public": false,
            "thumbnail_r2_key": "tours/a1b2c3d4e5f6/thumbnail.png",
            "num_gaussians": 1940000,
            "ssim": 0.82,
            "psnr_holdout": 24.28,
            "ssim_holdout": 0.79,
            "processing_stage": null,
            "processing_pct": 100,
            "processing_error": null,
            "viewer_url": "https://splat-3d.com/tour/a1b2c3d4e5f6",
            "download_url": "https://api.splat-3d.com/v1/scenes/a1b2c3d4e5f6/download",
            "format": "sog",
            "lod_meta_url": null,
            "created_at": "\(createdAt)",
            "updated_at": "\(updatedAt)"
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// GET /v1/scenes/{id} → 200 while processing: the processing branch of
    /// getSceneStatus in api/src/lib/scenes.ts (live stage and percent).
    static let trainingScene = """
    {
        "data": {
            "id": "a1b2c3d4e5f6",
            "title": "My living room",
            "address": null,
            "status": "processing",
            "is_public": false,
            "thumbnail_r2_key": null,
            "num_gaussians": null,
            "ssim": null,
            "psnr_holdout": null,
            "ssim_holdout": null,
            "processing_stage": "training",
            "processing_pct": 45,
            "processing_error": null,
            "viewer_url": null,
            "download_url": null,
            "format": null,
            "lod_meta_url": null,
            "created_at": "\(createdAt)",
            "updated_at": "\(updatedAt)"
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// GET /v1/scenes/{id} → 200 after the stale-job sweep failed the scene:
    /// processing_error is FAILED_TIMEOUT_MSG from the sweep in
    /// web/src/app/api/internal/scenes/sweep-stale/route.ts.
    static let sweptScene = """
    {
        "data": {
            "id": "a1b2c3d4e5f6",
            "title": "My living room",
            "address": null,
            "status": "failed",
            "is_public": false,
            "thumbnail_r2_key": null,
            "num_gaussians": null,
            "ssim": null,
            "psnr_holdout": null,
            "ssim_holdout": null,
            "processing_stage": "training",
            "processing_pct": 45,
            "processing_error": "Processing timed out — the GPU job did not complete.",
            "viewer_url": null,
            "download_url": null,
            "format": null,
            "lod_meta_url": null,
            "created_at": "\(createdAt)",
            "updated_at": "\(updatedAt)"
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// GET /v1/scenes?limit=2 → 200, first of two pages. Item keys: the column
    /// list listScenes selects; meta: the list route in api/src/routes/scenes.ts
    /// (next_cursor is the last item's created_at). Spec: SceneListResponse.
    static let scenePageOne = """
    {
        "data": [
            {
                "id": "a1b2c3d4e5f6",
                "title": "My living room",
                "address": null,
                "status": "complete",
                "training_model": "gsplat",
                "is_public": false,
                "thumbnail_r2_key": "tours/a1b2c3d4e5f6/thumbnail.png",
                "num_gaussians": 1940000,
                "processing_stage": null,
                "processing_pct": 100,
                "created_at": "\(createdAt)",
                "updated_at": "\(updatedAt)"
            },
            {
                "id": "0f1e2d3c4b5a",
                "title": "Kitchen",
                "address": null,
                "status": "training",
                "training_model": "gsplat",
                "is_public": false,
                "thumbnail_r2_key": null,
                "num_gaussians": null,
                "processing_stage": "training",
                "processing_pct": 45,
                "created_at": "\(pageOneCursor)",
                "updated_at": "2026-09-27T09:41:10.2+00:00"
            }
        ],
        "meta": {
            "request_id": "550e8400-e29b-41d4-a716-446655440000",
            "next_cursor": "\(pageOneCursor)",
            "has_more": true,
            "count": 2
        }
    }
    """

    /// GET /v1/scenes?cursor=…&limit=2 → 200, the last page. Same sources as
    /// ``scenePageOne``.
    static let scenePageTwo = """
    {
        "data": [
            {
                "id": "9a8b7c6d5e4f",
                "title": null,
                "address": null,
                "status": "failed",
                "training_model": "gsplat",
                "is_public": false,
                "thumbnail_r2_key": null,
                "num_gaussians": null,
                "processing_stage": null,
                "processing_pct": null,
                "created_at": "2026-09-20T08:00:00+00:00",
                "updated_at": "2026-09-20T08:31:00+00:00"
            }
        ],
        "meta": {
            "request_id": "550e8400-e29b-41d4-a716-446655440000",
            "next_cursor": null,
            "has_more": false,
            "count": 1
        }
    }
    """

    /// PATCH /v1/scenes/{id} → 200. updateScene returns the whole updated row
    /// (`.select()` in api/src/lib/scenes.ts); keys are the scenes Row type in
    /// api/src/lib/types.ts. Spec: UpdateSceneResponse (an untyped record).
    static let updatedScene = """
    {
        "data": {
            "id": "a1b2c3d4e5f6",
            "user_id": "6f1c2b9e-3d4a-4e5f-8a7b-9c0d1e2f3a4b",
            "title": "Kitchen",
            "description": null,
            "address": null,
            "status": "complete",
            "training_model": "gsplat",
            "is_public": true,
            "is_featured": false,
            "video_r2_key": "tours/a1b2c3d4e5f6/source.mp4",
            "ply_r2_key": "tours/a1b2c3d4e5f6/model.ply",
            "sog_r2_key": "tours/a1b2c3d4e5f6/model.sog",
            "thumbnail_r2_key": "tours/a1b2c3d4e5f6/thumbnail.png",
            "preview_frames_r2_prefix": null,
            "preview_ply_r2_key": null,
            "video_size_bytes": 52428800,
            "video_duration_seconds": null,
            "video_width": null,
            "video_height": null,
            "ply_size_bytes": null,
            "sog_size_bytes": null,
            "num_frames_extracted": null,
            "num_frames_after_filter": null,
            "num_gaussians": 1940000,
            "processing_stage": null,
            "processing_pct": 100,
            "processing_error": null,
            "processing_started_at": "2026-09-28T12:00:30.1+00:00",
            "processing_completed_at": "\(updatedAt)",
            "training_time_seconds": null,
            "training_iterations": 7000,
            "psnr": null,
            "ssim": null,
            "psnr_holdout": null,
            "ssim_holdout": null,
            "camera_hint": null,
            "coordinate_system": null,
            "lod_meta_r2_key": null,
            "lod_chunk_count": null,
            "lod_total_size_bytes": null,
            "params": null,
            "modal_job_id": null,
            "modal_call_id": null,
            "webhook_url": null,
            "webhook_secret": null,
            "created_at": "\(createdAt)",
            "updated_at": "2026-09-28T12:20:00.5+00:00"
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// POST /v1/scenes/{id}/process → 200. The saved launch response built by
    /// claim_scene_launch (supabase/migrations/20260928120000_atomic_scene_launches.sql).
    /// Spec: ProcessSceneResponse.
    static let processAccepted = """
    {
        "data": {
            "status": "processing",
            "sceneId": "a1b2c3d4e5f6",
            "message": "Processing started. This typically takes 7-15 minutes."
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// POST /v1/scenes/{id}/retrain → 200. `id` is the NEW scene (retrainScene
    /// in api/src/lib/scenes.ts). Spec: RetrainSceneResponse.
    static let retrainAccepted = """
    {
        "data": { "id": "0f1e2d3c4b5a", "retraining": true, "quality_tier": "pro" },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// POST /v1/scenes/{id}/cancel → 200 (cancel route in
    /// api/src/routes/scenes.ts). Spec: CancelSceneResponse.
    static let cancelAccepted = """
    {
        "data": { "id": "a1b2c3d4e5f6", "cancelled": true },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    // MARK: - Usage

    /// GET /v1/usage → 200. Spec: UsageResponse, with UsageData's examples.
    static let usage = """
    {
        "data": {
            "period": "2026-04",
            "scenes_created": 3,
            "scenes_processed": 2,
            "gpu_seconds_used": 450,
            "storage_bytes": 1073741824,
            "limits": {
                "scenes_created": 100,
                "scenes_processed": 100,
                "gpu_seconds": 36000,
                "storage_bytes": 53687091200
            }
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// GET /v1/usage → 200 on the Build plan: `null` scene limits mean
    /// unlimited (PLAN_LIMITS.build in api/src/middleware/quota.ts).
    static let unlimitedUsage = """
    {
        "data": {
            "period": "2026-09",
            "scenes_created": 250,
            "scenes_processed": 240,
            "gpu_seconds_used": 0,
            "storage_bytes": 0,
            "limits": {
                "scenes_created": null,
                "scenes_processed": null,
                "gpu_seconds": 720000,
                "storage_bytes": 1099511627776
            }
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    // MARK: - Errors

    /// The v1 error envelope (errorHandler in api/src/middleware/error-handler.ts;
    /// spec: ErrorResponse).
    static func error(_ code: String, _ message: String) -> String {
        """
        {
            "error": { "code": "\(code)", "message": "\(message)" },
            "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
        }
        """
    }

    /// 401 from requireApiKeyAuth (api/src/middleware/auth.ts); matches a live
    /// response from api.splat-3d.com on 2026-09-28.
    static let unauthorized = error("unauthorized", "Authentication required. Provide a Bearer s3d_... API key.")

    /// 404 from getSceneStatus (api/src/lib/scenes.ts); also the spec's
    /// ErrorResponse example.
    static let sceneNotFound = error("not_found", "Scene not found.")

    /// 403 from deleteScene for another user's scene (api/src/lib/scenes.ts).
    static let forbidden = error("forbidden", "You do not own this scene.")

    /// 400 from updateScene when nothing is set (api/src/lib/scenes.ts).
    static let nothingToUpdate = error("invalid_input", "No valid fields to update.")

    /// 409 from processScene when a launch exists with another key or body
    /// (api/src/lib/scenes.ts).
    static let launchConflict = error(
        "conflict",
        "This scene already has a launch with different request parameters or idempotency key."
    )

    /// 409 from retrainScene (api/src/lib/scenes.ts).
    static let retrainConflict = error("conflict", "Cannot retrain a scene that is still uploading.")

    /// 409 from cancelScene (api/src/lib/scenes.ts).
    static let cancelConflict = error("conflict", "Cannot cancel scene in 'complete' state.")

    /// 503 from processScene when the launch reservation can't be confirmed
    /// (api/src/lib/scenes.ts); the API asks for the same request again.
    static let launchUnconfirmed = error(
        "internal_error",
        "Unable to confirm the launch reservation. Retry the same request."
    )

    /// 402 from processScene's credit reservation (api/src/lib/scenes.ts).
    static let insufficientCredits = error(
        "insufficient_credits",
        "Insufficient credits. Need 20 credits to process this scene."
    )

    /// 404 from downloadScene (api/src/lib/scenes.ts).
    static let noModel = error("not_found", "No model file available for this scene.")

    /// 404 from getSceneThumbnail (api/src/lib/scenes.ts); matches a live
    /// response from api.splat-3d.com on 2026-09-28.
    static let noThumbnail = error("not_found", "Thumbnail not found.")

    /// Unhandled-error 500 from errorHandler (api/src/middleware/error-handler.ts).
    static let internalError = error("internal_error", "An unexpected error occurred.")

    /// 429 from enforceSceneCreateQuota (api/src/middleware/quota.ts): the
    /// envelope's meta also carries period, limit and field.
    static let quotaExceeded = """
    {
        "error": {
            "code": "quota_exceeded",
            "message": "Monthly scene creation limit reached (10 scenes per month). Upgrade your plan for higher limits."
        },
        "meta": {
            "request_id": "550e8400-e29b-41d4-a716-446655440000",
            "period": "2026-09",
            "limit": 10,
            "field": "scenes_created"
        }
    }
    """

    /// 422 from createScene's per-tier envelope check (api/src/lib/scenes.ts);
    /// `details` is the spec's ErrorResponse.error.details example.
    static let tierViolation = """
    {
        "error": {
            "code": "invalid_input",
            "message": "Parameter(s) out of range for the standard tier: iterations=15000 requires the quality tier or higher.",
            "details": [
                {
                    "field": "iterations",
                    "value": 15000,
                    "allowed": { "min": 3000, "max": 10000 },
                    "tier": "standard",
                    "hint": "iterations=15000 requires the quality tier or higher."
                }
            ]
        },
        "meta": { "request_id": "550e8400-e29b-41d4-a716-446655440000" }
    }
    """

    /// 400 for a request that fails route schema validation. Not the error
    /// envelope: @hono/zod-validator 0.7.6 (no defaultHook in api/src) returns
    /// `c.json({ success: false, error: ZodError }, 400)`. Generated with the
    /// API's zod 3.25.76 against listScenesQuerySchema for `limit=0`.
    static let validationFailure = """
    {"success":false,"error":{"issues":[{"code":"too_small","minimum":1,"type":"number","inclusive":true,"exact":false,"message":"Number must be greater than or equal to 1","path":["limit"]}],"name":"ZodError"}}
    """
}
