import XCTest
@testable import SplatKit

// MARK: - Contract tests
//
// Pins the API contract the SDK was written against. Fixtures/openapi.json is
// https://api.splat-3d.com/openapi.json as fetched on 2026-09-28; refresh it
// when the API changes and these tests point at what the SDK must follow.
//
//   openapi.json ──> every operationId ──> covered by a SplatClient method
//        │
//        └──> response schemas ──> every fixture in APIFixtures.swift
//                                   (differences listed per fixture below)

final class ContractTests: XCTestCase {

    /// Every operation in the pinned spec and the SplatClient method covering it.
    static let coverage: [String: String] = [
        "createScene": "createScene(title:preset:)",
        "listScenes": "listScenePage(cursor:limit:), allScenes(pageSize:)",
        "getScene": "getScene(id:)",
        "updateScene": "updateScene(id:_:)",
        "deleteScene": "deleteScene(id:)",
        "processScene": "processScene(id:arkitPoses:lidarPoints:enableLOD:idempotencyKey:)",
        "retrainScene": "retrainScene(id:preset:)",
        "cancelScene": "cancelScene(id:)",
        "downloadScene": "downloadScene(id:format:)",
        "getSceneThumbnail": "getSceneThumbnail(id:)",
        "getUsage": "getUsage()",
    ]

    /// A fixture, the response it stands for, and where the API source (which
    /// the fixture follows) differs from the spec's schema.
    struct FixtureCase {
        let name: String
        let body: String
        let operation: String
        let status: Int
        let deviations: Set<String>

        init(_ name: String, _ body: String, _ operation: String, _ status: Int, deviations: Set<String> = []) {
            self.name = name
            self.body = body
            self.operation = operation
            self.status = status
            self.deviations = deviations
        }
    }

    static let fixtures: [FixtureCase] = [
        FixtureCase("createScene", Fixture.createScene, "createScene", 201),
        // getSceneStatus returns holdout metrics the spec omits, and no
        // training_model although SceneDetail inherits it as required.
        FixtureCase("completeScene", Fixture.completeScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        FixtureCase("trainingScene", Fixture.trainingScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        FixtureCase("uploadingScene", Fixture.uploadingScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        FixtureCase("estimatingPosesScene", Fixture.estimatingPosesScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        FixtureCase("failedLaunchScene", Fixture.failedLaunchScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        FixtureCase("sweptScene", Fixture.sweptScene, "getScene", 200, deviations: [
            "missing data.training_model",
            "undeclared data.psnr_holdout",
            "undeclared data.ssim_holdout",
        ]),
        // listScenes never selects ssim, which the spec's Scene requires.
        FixtureCase("scenePageOne", Fixture.scenePageOne, "listScenes", 200, deviations: ["missing data[].ssim"]),
        FixtureCase("scenePageTwo", Fixture.scenePageTwo, "listScenes", 200, deviations: ["missing data[].ssim"]),
        FixtureCase("updatedScene", Fixture.updatedScene, "updateScene", 200),
        FixtureCase("processAccepted", Fixture.processAccepted, "processScene", 200),
        FixtureCase("retrainAccepted", Fixture.retrainAccepted, "retrainScene", 200),
        FixtureCase("cancelAccepted", Fixture.cancelAccepted, "cancelScene", 200),
        FixtureCase("usage", Fixture.usage, "getUsage", 200),
        FixtureCase("unlimitedUsage", Fixture.unlimitedUsage, "getUsage", 200),
        FixtureCase("unauthorized", Fixture.unauthorized, "getUsage", 401),
        FixtureCase("sceneNotFound", Fixture.sceneNotFound, "getScene", 404),
        FixtureCase("forbidden", Fixture.forbidden, "deleteScene", 403),
        FixtureCase("nothingToUpdate", Fixture.nothingToUpdate, "updateScene", 400),
        FixtureCase("launchConflict", Fixture.launchConflict, "processScene", 409),
        FixtureCase("insufficientCredits", Fixture.insufficientCredits, "processScene", 402),
        FixtureCase("launchUnconfirmed", Fixture.launchUnconfirmed, "processScene", 503),
        FixtureCase("processQuotaExceeded", Fixture.processQuotaExceeded, "processScene", 429),
        FixtureCase("launchRejected", Fixture.launchRejected, "processScene", 502),
        FixtureCase("keyLookupFailed", Fixture.keyLookupFailed, "getScene", 401),
        FixtureCase("retrainConflict", Fixture.retrainConflict, "retrainScene", 409),
        FixtureCase("cancelConflict", Fixture.cancelConflict, "cancelScene", 409),
        FixtureCase("noModel", Fixture.noModel, "downloadScene", 404),
        FixtureCase("noThumbnail", Fixture.noThumbnail, "getSceneThumbnail", 404),
        FixtureCase("internalError", Fixture.internalError, "getScene", 500),
        FixtureCase("tierViolation", Fixture.tierViolation, "createScene", 422),
        // The quota middleware adds period, limit and field to meta.
        FixtureCase("quotaExceeded", Fixture.quotaExceeded, "createScene", 429, deviations: [
            "undeclared meta.period",
            "undeclared meta.limit",
            "undeclared meta.field",
        ]),
        // Route-validation 400s bypass the error envelope entirely.
        FixtureCase("validationFailure", Fixture.validationFailure, "listScenes", 400, deviations: [
            "missing error.code",
            "missing error.message",
            "missing meta",
            "undeclared success",
            "undeclared error.issues",
            "undeclared error.name",
        ]),
    ]

    /// Statuses the fixtures use that the spec does not document for that
    /// operation. Their bodies are checked against ErrorResponse.
    static let undocumentedStatuses: Set<String> = [
        "deleteScene 403",   // another user's scene (deleteScene in api/src/lib/scenes.ts)
        "processScene 402",  // insufficient credits (processScene)
        "processScene 503",  // launch not confirmed; "Retry the same request" (processScene)
        "processScene 429",  // monthly processing quota used up (processScene)
        "processScene 502",  // a launch the API failed and refunded (failLaunch)
        "getScene 500",      // any unhandled error (errorHandler)
        "listScenes 400",    // `limit` outside 1–100 (route validation)
    ]

    func testSDKCoversEveryOperation() throws {
        XCTAssertEqual(try PinnedSpec.load().operationIDs, Set(Self.coverage.keys))
    }

    func testFixturesMatchSpecSchemas() throws {
        let spec = try PinnedSpec.load()
        var undocumented: Set<String> = []

        for fixture in Self.fixtures {
            let body = try JSONSerialization.jsonObject(with: Data(fixture.body.utf8))

            let documented = spec.responseSchema(fixture.operation, status: fixture.status)
            if documented == nil {
                undocumented.insert("\(fixture.operation) \(fixture.status)")
            }

            let schema = documented ?? spec.component("ErrorResponse")
            XCTAssertEqual(spec.differences(body, from: schema), fixture.deviations, fixture.name)
        }

        XCTAssertEqual(undocumented, Self.undocumentedStatuses)
    }
}

// MARK: - PinnedSpec

/// The OpenAPI document in Fixtures/openapi.json.
struct PinnedSpec {

    let root: [String: Any]

    static func load() throws -> PinnedSpec {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return PinnedSpec(root: try XCTUnwrap(json as? [String: Any]))
    }

    var operationIDs: Set<String> {
        Set(operations.keys)
    }

    /// Operations keyed by `operationId`.
    private var operations: [String: [String: Any]] {
        let paths = root["paths"] as? [String: [String: Any]] ?? [:]
        var result: [String: [String: Any]] = [:]
        for methods in paths.values {
            for case let operation as [String: Any] in methods.values {
                guard let id = operation["operationId"] as? String else {
                    continue
                }
                result[id] = operation
            }
        }
        return result
    }

    /// The JSON schema of an operation's response, or `nil` when the spec
    /// documents no JSON body for that status.
    func responseSchema(_ operationID: String, status: Int) -> [String: Any]? {
        let responses = operations[operationID]?["responses"] as? [String: Any]
        let response = responses?[String(status)] as? [String: Any]
        let content = response?["content"] as? [String: Any]
        let json = content?["application/json"] as? [String: Any]
        return json?["schema"] as? [String: Any]
    }

    /// A reference to a named component schema.
    func component(_ name: String) -> [String: Any] {
        ["$ref": "#/components/schemas/\(name)"]
    }

    /// Where `value`'s keys differ from `schema`.
    ///
    /// `"missing data.ssim"` is a required key `value` lacks; `"undeclared
    /// data.psnr_holdout"` is a key the schema doesn't list. Records
    /// (`additionalProperties`, or no `properties`) accept any key.
    func differences(_ value: Any, from schema: [String: Any], at path: String = "") -> Set<String> {
        let schema = resolve(schema)

        if let array = value as? [Any] {
            guard let items = schema["items"] as? [String: Any] else {
                return []
            }
            return array.reduce(into: Set<String>()) { result, item in
                result.formUnion(differences(item, from: items, at: path + "[]"))
            }
        }

        guard let object = value as? [String: Any] else {
            return []
        }

        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let isRecord = schema["additionalProperties"] is [String: Any] || properties.isEmpty

        var result = Set(required.filter { object[$0] == nil }.map { "missing \(join(path, $0))" })
        for (key, child) in object {
            guard let childSchema = properties[key] as? [String: Any] else {
                if !isRecord {
                    result.insert("undeclared \(join(path, key))")
                }
                continue
            }
            result.formUnion(differences(child, from: childSchema, at: join(path, key)))
        }
        return result
    }

    /// Follow `$ref`s and merge `allOf` parts into one object schema.
    private func resolve(_ schema: [String: Any]) -> [String: Any] {
        if let ref = schema["$ref"] as? String {
            let name = ref.replacingOccurrences(of: "#/components/schemas/", with: "")
            let schemas = (root["components"] as? [String: Any])?["schemas"] as? [String: Any]
            return resolve(schemas?[name] as? [String: Any] ?? [:])
        }

        guard let parts = schema["allOf"] as? [[String: Any]] else {
            return schema
        }

        var properties: [String: Any] = [:]
        var required: [String] = []
        for part in parts.map(resolve) {
            properties.merge(part["properties"] as? [String: Any] ?? [:]) { _, new in new }
            required += part["required"] as? [String] ?? []
        }
        return ["type": "object", "properties": properties, "required": required]
    }

    private func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
