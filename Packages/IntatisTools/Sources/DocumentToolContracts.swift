import Foundation
import IntatisProtocol

// MARK: - Model-facing document contracts

/// The document tools deliberately expose data, never backend selection or a
/// command line. Each argument type owns both its provider-facing schema and a
/// semantic validator for invariants that the generic schema checker cannot
/// express.
struct ReadPDFArguments: Codable, Equatable, Sendable {
    let path: String
    let pages: String?
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case path, pages
        case maxCharacters
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "path": DocumentContractSchema.path,
            "pages": DocumentContractSchema.pageSelection,
            "maxCharacters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["path"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path", "pages", "maxCharacters"],
            required: ["path"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(value.path, extension: .pdf, field: "path")
        try DocumentContractValidation.validatePageSelection(value.pages, field: "pages")
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "maxCharacters")
        return value
    }
}

struct DocumentTextReadArguments: Codable, Equatable, Sendable {
    let path: String
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case path, maxCharacters
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "path": DocumentContractSchema.path,
            "maxCharacters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["path"])

    static func decodeValidated(_ args: ToolArgs, format: DocumentFormat) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: ["path", "maxCharacters"],
            required: ["path"])

        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(
            value.path,
            extension: format,
            field: "path")
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "maxCharacters")
        return value
    }
}

struct DocumentOCRArguments: Codable, Equatable, Sendable {
    let inputPath: String
    let expectedSourceSHA256: String
    let pages: String?
    let languages: [String]
    let pageSegmentationMode: Int
    let maxCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case pages, languages
        case pageSegmentationMode = "psm"
        case maxCharacters = "max_characters"
    }

    static let allowedLanguages = [
        "eng", "chi_sim", "chi_tra", "jpn", "kor",
        "fra", "deu", "spa", "ita", "por",
    ]
    static let allowedPageSegmentationModes = [1, 3, 4, 6, 11, 12]

    static let schema = DocumentContractSchema.object(
        properties: [
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "pages": DocumentContractSchema.pageSelection,
            "languages": DocumentContractSchema.array(
                items: DocumentContractSchema.stringEnum(allowedLanguages),
                minimumItems: 1,
                maximumItems: 4,
                uniqueItems: true),
            "psm": DocumentContractSchema.integerEnum(allowedPageSegmentationModes),
            "max_characters": DocumentContractSchema.integer(minimum: 1, maximum: 500_000),
        ],
        required: ["input_path", "expected_source_sha256", "languages", "psm"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: [
                "input_path", "expected_source_sha256", "pages", "languages", "psm",
                "max_characters",
            ],
            required: ["input_path", "expected_source_sha256", "languages", "psm"])
        let value: Self = try DocumentContractValidation.decode(args)
        try DocumentContractValidation.validatePath(
            value.inputPath,
            extension: .pdf,
            field: "input_path")
        try DocumentContractValidation.validateSHA256(
            value.expectedSourceSHA256,
            field: "expected_source_sha256")
        try DocumentContractValidation.validatePageSelection(value.pages, field: "pages")
        guard (1...4).contains(value.languages.count),
              Set(value.languages).count == value.languages.count,
              value.languages.allSatisfy(Self.allowedLanguages.contains) else {
            throw DocumentToolError(
                .validationFailed,
                "languages must contain one to four distinct allowlisted Tesseract language codes")
        }
        guard Self.allowedPageSegmentationModes.contains(value.pageSegmentationMode) else {
            throw DocumentToolError(.validationFailed, "psm is not allowlisted")
        }
        try DocumentContractValidation.validateInteger(
            value.maxCharacters,
            minimum: 1,
            maximum: 500_000,
            field: "max_characters")
        return value
    }
}

enum DocumentRenderPageBox: String, Codable, CaseIterable, Sendable {
    case media
    case crop
}

enum DocumentRenderBackground: String, Codable, CaseIterable, Sendable {
    case white
    case transparent
}

enum DocumentRenderAnnotationPolicy: String, Codable, CaseIterable, Sendable {
    case show
    case hide
}

struct DocumentRenderArguments: Codable, Equatable, Sendable {
    static let defaultDPI = 144
    static let defaultMaximumPagePixels = 40_000_000
    static let defaultMaximumTotalPixels = 200_000_000
    static let defaultMaximumOutputBytes = 512 * 1_024 * 1_024

    let inputFormat: DocumentFormat
    let inputPath: String
    let expectedSourceSHA256: String
    let localAssetPaths: [String]?
    let outputDirectory: String
    let replaceExisting: Bool?
    let expectedOutputSHA256: String?
    let pages: String?
    let dpi: Int?
    let pageBox: DocumentRenderPageBox?
    let background: DocumentRenderBackground?
    let annotations: DocumentRenderAnnotationPolicy?
    let maximumPagePixels: Int?
    let maximumTotalPixels: Int?
    let maximumOutputBytes: Int?

    enum CodingKeys: String, CodingKey {
        case inputFormat = "input_format"
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case localAssetPaths = "local_asset_paths"
        case outputDirectory = "output_dir"
        case replaceExisting = "replace_existing"
        case expectedOutputSHA256 = "expected_output_sha256"
        case pages, dpi
        case pageBox = "page_box"
        case background, annotations
        case maximumPagePixels = "maximum_page_pixels"
        case maximumTotalPixels = "maximum_total_pixels"
        case maximumOutputBytes = "maximum_output_bytes"
    }

    var resolvedDPI: Int { dpi ?? Self.defaultDPI }
    var resolvedPageBox: DocumentRenderPageBox { pageBox ?? .crop }
    var resolvedBackground: DocumentRenderBackground { background ?? .white }
    var resolvedAnnotations: DocumentRenderAnnotationPolicy { annotations ?? .show }
    var resolvedMaximumPagePixels: Int {
        maximumPagePixels ?? Self.defaultMaximumPagePixels
    }
    var resolvedMaximumTotalPixels: Int {
        maximumTotalPixels ?? Self.defaultMaximumTotalPixels
    }
    var resolvedMaximumOutputBytes: Int {
        maximumOutputBytes ?? Self.defaultMaximumOutputBytes
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "input_format": DocumentContractSchema.format([
                .pdf, .docx, .pptx, .xlsx, .html,
            ]),
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "local_asset_paths": DocumentContractSchema.localAssetPaths,
            "output_dir": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
            "pages": DocumentContractSchema.pageSelection,
            "dpi": DocumentContractSchema.integer(minimum: 36, maximum: 600),
            "page_box": DocumentContractSchema.stringEnum(
                DocumentRenderPageBox.allCases.map(\.rawValue)),
            "background": DocumentContractSchema.stringEnum(
                DocumentRenderBackground.allCases.map(\.rawValue)),
            "annotations": DocumentContractSchema.stringEnum(
                DocumentRenderAnnotationPolicy.allCases.map(\.rawValue)),
            "maximum_page_pixels": DocumentContractSchema.integer(
                minimum: 1_000_000,
                maximum: 100_000_000),
            "maximum_total_pixels": DocumentContractSchema.integer(
                minimum: 1_000_000,
                maximum: 1_000_000_000),
            "maximum_output_bytes": DocumentContractSchema.integer(
                minimum: 1_024,
                maximum: 2_147_483_648),
        ],
        required: ["input_format", "input_path", "expected_source_sha256", "output_dir"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: [
                "input_format", "input_path", "expected_source_sha256", "output_dir",
                "local_asset_paths", "replace_existing", "expected_output_sha256", "pages", "dpi",
                "page_box", "background", "annotations", "maximum_page_pixels",
                "maximum_total_pixels", "maximum_output_bytes",
            ],
            required: ["input_format", "input_path", "expected_source_sha256", "output_dir"])
        let value: Self = try DocumentContractValidation.decode(args)
        guard value.inputFormat != .epub else {
            throw DocumentToolError(
                .unsupportedOperation,
                "EPUB rendering remains disabled until the full-spine corpus gate passes")
        }
        try DocumentContractValidation.validatePath(
            value.inputPath,
            extension: value.inputFormat,
            field: "input_path")
        try DocumentContractValidation.validateLocalAssetPaths(
            value.localAssetPaths,
            inputFormat: value.inputFormat)
        try DocumentContractValidation.validateOutputDirectory(
            value.outputDirectory,
            field: "output_dir")
        try DocumentContractValidation.validateSHA256(
            value.expectedSourceSHA256,
            field: "expected_source_sha256")
        try DocumentContractValidation.validateReplacement(
            replaceExisting: value.replaceExisting ?? false,
            expectedOutputSHA256: value.expectedOutputSHA256)
        try DocumentContractValidation.validatePageSelection(value.pages, field: "pages")
        try DocumentContractValidation.validateInteger(
            value.dpi,
            minimum: 36,
            maximum: 600,
            field: "dpi")
        try DocumentContractValidation.validateInteger(
            value.maximumPagePixels,
            minimum: 1_000_000,
            maximum: 100_000_000,
            field: "maximum_page_pixels")
        try DocumentContractValidation.validateInteger(
            value.maximumTotalPixels,
            minimum: 1_000_000,
            maximum: 1_000_000_000,
            field: "maximum_total_pixels")
        try DocumentContractValidation.validateInteger(
            value.maximumOutputBytes,
            minimum: 1_024,
            maximum: 2_147_483_648,
            field: "maximum_output_bytes")
        guard value.resolvedMaximumTotalPixels >= value.resolvedMaximumPagePixels else {
            throw DocumentToolError(
                .validationFailed,
                "maximum_total_pixels must be at least maximum_page_pixels")
        }
        return value
    }
}

struct DocumentExportPDFArguments: Codable, Equatable, Sendable {
    let inputFormat: DocumentFormat
    let inputPath: String
    let expectedSourceSHA256: String
    let localAssetPaths: [String]?
    let outputPath: String
    let replaceExisting: Bool?
    let expectedOutputSHA256: String?

    enum CodingKeys: String, CodingKey {
        case inputFormat = "input_format"
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case localAssetPaths = "local_asset_paths"
        case outputPath = "output_path"
        case replaceExisting = "replace_existing"
        case expectedOutputSHA256 = "expected_output_sha256"
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "input_format": DocumentContractSchema.format([
                .docx, .pptx, .xlsx, .html,
            ]),
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "local_asset_paths": DocumentContractSchema.localAssetPaths,
            "output_path": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
        ],
        required: ["input_format", "input_path", "expected_source_sha256", "output_path"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectPDFFormat(
            object,
            key: "input_format",
            operation: "document_export_pdf")
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: [
                "input_format", "input_path", "expected_source_sha256", "output_path",
                "local_asset_paths", "replace_existing", "expected_output_sha256",
            ],
            required: ["input_format", "input_path", "expected_source_sha256", "output_path"])
        let value: Self = try DocumentContractValidation.decode(args)
        guard [.docx, .pptx, .xlsx, .html].contains(value.inputFormat) else {
            throw DocumentToolError(
                .unsupportedOperation,
                "document_export_pdf supports DOCX, PPTX, XLSX, and HTML only")
        }
        try DocumentContractValidation.validatePath(
            value.inputPath,
            extension: value.inputFormat,
            field: "input_path")
        try DocumentContractValidation.validateLocalAssetPaths(
            value.localAssetPaths,
            inputFormat: value.inputFormat)
        try DocumentContractValidation.validatePath(
            value.outputPath,
            extension: .pdf,
            field: "output_path")
        try DocumentContractValidation.validateDistinctPaths(
            input: value.inputPath,
            output: value.outputPath)
        try DocumentContractValidation.validateSHA256(
            value.expectedSourceSHA256,
            field: "expected_source_sha256")
        try DocumentContractValidation.validateReplacement(
            replaceExisting: value.replaceExisting ?? false,
            expectedOutputSHA256: value.expectedOutputSHA256)
        return value
    }
}

enum DocumentWriteMode: String, Codable, CaseIterable, Sendable {
    case create
    case edit
}

struct DocumentWriteOperation: Codable, Equatable, Sendable {
    let kind: String
    let parameters: [String: JSONValue]
}

struct DocumentWriteArguments: Codable, Equatable, Sendable {
    let format: DocumentFormat
    let mode: DocumentWriteMode
    let inputPath: String?
    let expectedSourceSHA256: String?
    let localAssetPaths: [String]?
    let outputPath: String
    let replaceExisting: Bool?
    let expectedOutputSHA256: String?
    let operations: [DocumentWriteOperation]

    enum CodingKeys: String, CodingKey {
        case format, mode
        case inputPath = "input_path"
        case expectedSourceSHA256 = "expected_source_sha256"
        case localAssetPaths = "local_asset_paths"
        case outputPath = "output_path"
        case replaceExisting = "replace_existing"
        case expectedOutputSHA256 = "expected_output_sha256"
        case operations
    }

    static let schema = DocumentContractSchema.object(
        properties: [
            "format": DocumentContractSchema.format(editableOnly: true),
            "mode": DocumentContractSchema.stringEnum(DocumentWriteMode.allCases.map(\.rawValue)),
            "input_path": DocumentContractSchema.path,
            "expected_source_sha256": DocumentContractSchema.sha256,
            "local_asset_paths": DocumentContractSchema.localAssetPaths,
            "output_path": DocumentContractSchema.path,
            "replace_existing": DocumentContractSchema.boolean,
            "expected_output_sha256": DocumentContractSchema.sha256,
            "operations": DocumentContractSchema.array(
                items: DocumentWriteOperationMatrix.schema,
                minimumItems: 1,
                maximumItems: 1_000),
        ],
        required: ["format", "mode", "output_path", "operations"])

    static func decodeValidated(_ args: ToolArgs) throws -> Self {
        let object = try DocumentContractValidation.rootObject(args)
        try DocumentContractValidation.rejectPDFFormat(
            object,
            key: "format",
            operation: "document_write")
        try DocumentContractValidation.rejectForbiddenExecutionControls(in: .object(object))
        try DocumentContractValidation.requireKeys(
            object,
            allowed: [
                "format", "mode", "input_path", "expected_source_sha256", "output_path",
                "local_asset_paths", "replace_existing", "expected_output_sha256", "operations",
            ],
            required: ["format", "mode", "output_path", "operations"])
        try DocumentContractValidation.validateOperationEnvelopes(object["operations"])
        let value: Self = try DocumentContractValidation.decode(args)
        guard DocumentFormat.editableFormats.contains(value.format) else {
            throw DocumentToolError(.unsupportedOperation, "document_write does not support PDF mutation")
        }
        try DocumentContractValidation.validatePath(
            value.outputPath,
            extension: value.format,
            field: "output_path")
        try DocumentContractValidation.validateLocalAssetPaths(
            value.localAssetPaths,
            inputFormat: value.format)
        try DocumentContractValidation.validateReplacement(
            replaceExisting: value.replaceExisting ?? false,
            expectedOutputSHA256: value.expectedOutputSHA256)

        switch value.mode {
        case .create:
            guard value.inputPath == nil, value.expectedSourceSHA256 == nil else {
                throw DocumentToolError(
                    .validationFailed,
                    "create mode must not include input_path or expected_source_sha256")
            }
        case .edit:
            guard let inputPath = value.inputPath,
                  let expectedSourceSHA256 = value.expectedSourceSHA256 else {
                throw DocumentToolError(
                    .validationFailed,
                    "edit mode requires input_path and expected_source_sha256")
            }
            try DocumentContractValidation.validatePath(
                inputPath,
                extension: value.format,
                field: "input_path")
            try DocumentContractValidation.validateSHA256(
                expectedSourceSHA256,
                field: "expected_source_sha256")
            if inputPath == value.outputPath {
                guard value.replaceExisting == true,
                      value.expectedOutputSHA256 == expectedSourceSHA256 else {
                    throw DocumentToolError(
                        .validationFailed,
                        "in-place edit requires replace_existing and matching source/output digests")
                }
            }
        }

        guard (1...1_000).contains(value.operations.count) else {
            throw DocumentToolError(
                .validationFailed,
                "operations must contain between one and 1000 entries")
        }
        for operation in value.operations {
            try DocumentWriteOperationMatrix.validate(operation, format: value.format)
        }
        return value
    }
}

// MARK: - JSON Schema builders

private enum DocumentContractSchema {
    static let boolean = JSONValue.object(["type": .string("boolean")])
    static let path = string(minimumLength: 1, maximumLength: 4_096)
    static let pageSelection = string(minimumLength: 1, maximumLength: 1_024)
    static let sha256 = JSONValue.object([
        "type": .string("string"),
        "minLength": .number(64),
        "maxLength": .number(64),
        "pattern": .string("^[A-Fa-f0-9]{64}$"),
    ])
    static let localAssetPaths = array(
        items: path,
        minimumItems: 1,
        maximumItems: 256,
        uniqueItems: true)

    static func object(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static func string(
        minimumLength: Int? = nil,
        maximumLength: Int? = nil,
        pattern: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string")]
        if let minimumLength { value["minLength"] = .number(Double(minimumLength)) }
        if let maximumLength { value["maxLength"] = .number(Double(maximumLength)) }
        if let pattern { value["pattern"] = .string(pattern) }
        return .object(value)
    }

    static func stringEnum(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    static func integer(minimum: Int, maximum: Int) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(Double(minimum)),
            "maximum": .number(Double(maximum)),
        ])
    }

    static func integerEnum(_ values: [Int]) -> JSONValue {
        .object([
            "type": .string("integer"),
            "enum": .array(values.map { .number(Double($0)) }),
        ])
    }

    static func number(minimum: Double, maximum: Double) -> JSONValue {
        .object([
            "type": .string("number"),
            "minimum": .number(minimum),
            "maximum": .number(maximum),
        ])
    }

    static func array(
        items: JSONValue,
        minimumItems: Int,
        maximumItems: Int,
        uniqueItems: Bool = false
    ) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "minItems": .number(Double(minimumItems)),
            "maxItems": .number(Double(maximumItems)),
            "uniqueItems": .bool(uniqueItems),
        ])
    }

    static func format(editableOnly: Bool) -> JSONValue {
        let formats = editableOnly
            ? DocumentFormat.editableFormats.map(\.rawValue).sorted()
            : DocumentFormat.allCases.map(\.rawValue)
        return stringEnum(formats)
    }

    static func format(_ formats: [DocumentFormat]) -> JSONValue {
        stringEnum(formats.map(\.rawValue))
    }

}

// MARK: - Semantic validation

private enum DocumentContractValidation {
    private static let forbiddenExecutionControlKeys: Set<String> = [
        "args", "argv", "backend", "binary", "command", "cwd", "env", "environment",
        "executable", "network", "allow_network", "temp", "temp_dir",
        "temporary_directory", "working_directory",
    ]

    static func rootObject(_ args: ToolArgs) throws -> [String: JSONValue] {
        guard let data = args.raw.data(using: .utf8) else {
            throw DocumentToolError(.validationFailed, "arguments are not valid UTF-8")
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let object) = value else {
                throw DocumentToolError(.validationFailed, "arguments must be a JSON object")
            }
            return object
        } catch let error as DocumentToolError {
            throw error
        } catch {
            throw DocumentToolError(.validationFailed, "arguments are not valid JSON")
        }
    }

    static func decode<T: Decodable>(_ args: ToolArgs) throws -> T {
        guard let data = args.raw.data(using: .utf8) else {
            throw DocumentToolError(.validationFailed, "arguments are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DocumentToolError(.validationFailed, "arguments do not match the document contract")
        }
    }

    static func requireKeys(
        _ object: [String: JSONValue],
        allowed: Set<String>,
        required: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw DocumentToolError(.validationFailed, "arguments contain an unknown field")
        }
        guard required.isSubset(of: Set(object.keys)) else {
            throw DocumentToolError(.validationFailed, "arguments are missing a required field")
        }
    }

    static func rejectForbiddenExecutionControls(in value: JSONValue) throws {
        switch value {
        case .object(let object):
            if object.keys.contains(where: forbiddenExecutionControlKeys.contains) {
                throw DocumentToolError(
                    .unsupportedOperation,
                    "document tools do not accept backend, command, environment, network, or temporary-path controls")
            }
            for nested in object.values {
                try rejectForbiddenExecutionControls(in: nested)
            }
        case .array(let values):
            for nested in values {
                try rejectForbiddenExecutionControls(in: nested)
            }
        case .null, .bool, .number, .string:
            break
        }
    }

    static func rejectPDFFormat(
        _ object: [String: JSONValue],
        key: String,
        operation: String
    ) throws {
        if case .string("pdf")? = object[key] {
            throw DocumentToolError(
                .unsupportedOperation,
                "\(operation) does not support PDF mutation or PDF input")
        }
    }

    static func validatePath(
        _ path: String,
        extension format: DocumentFormat,
        field: String
    ) throws {
        try validatePlainPath(path, field: field)
        let actual = URL(fileURLWithPath: path).pathExtension.lowercased()
        let allowed: Set<String> = format == .html ? ["html", "htm"] : [format.rawValue]
        guard allowed.contains(actual) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) extension does not match the declared format")
        }
    }

    static func validateOutputDirectory(_ path: String, field: String) throws {
        try validatePlainPath(path, field: field)
        let standardized = (path as NSString).standardizingPath
        guard standardized != ".", standardized != "/" else {
            throw DocumentToolError(.validationFailed, "\(field) must name a child directory")
        }
    }

    static func validateDistinctPaths(input: String, output: String) throws {
        guard (input as NSString).standardizingPath != (output as NSString).standardizingPath else {
            throw DocumentToolError(.validationFailed, "input_path and output_path must differ")
        }
    }

    static func validateLocalAssetPaths(
        _ paths: [String]?,
        inputFormat: DocumentFormat
    ) throws {
        guard let paths else { return }
        guard inputFormat == .html else {
            throw DocumentToolError(
                .validationFailed,
                "local_asset_paths is only valid for HTML input")
        }
        guard (1...256).contains(paths.count), Set(paths).count == paths.count else {
            throw DocumentToolError(
                .validationFailed,
                "local_asset_paths must contain one to 256 distinct paths")
        }
        for path in paths {
            try validatePlainPath(path, field: "local_asset_paths")
        }
    }

    static func validatePlainPath(_ path: String, field: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096, !trimmed.contains("\0") else {
            throw DocumentToolError(.validationFailed, "\(field) is not a valid bounded path")
        }
        let lower = trimmed.lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("file://") else {
            throw DocumentToolError(.validationFailed, "\(field) must be a workspace file path")
        }
    }

    static func validateSHA256(_ digest: String, field: String) throws {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else {
            throw DocumentToolError(.validationFailed, "\(field) must be a SHA-256 hex digest")
        }
    }

    static func validateReplacement(
        replaceExisting: Bool,
        expectedOutputSHA256: String?
    ) throws {
        if replaceExisting {
            guard let expectedOutputSHA256 else {
                throw DocumentToolError(
                    .validationFailed,
                    "replace_existing requires expected_output_sha256")
            }
            try validateSHA256(expectedOutputSHA256, field: "expected_output_sha256")
        } else if expectedOutputSHA256 != nil {
            throw DocumentToolError(
                .validationFailed,
                "expected_output_sha256 is only valid with replace_existing")
        }
    }

    static func validateInteger(
        _ value: Int?,
        minimum: Int,
        maximum: Int,
        field: String
    ) throws {
        guard let value else { return }
        guard (minimum...maximum).contains(value) else {
            throw DocumentToolError(
                .validationFailed,
                "\(field) is outside the supported bounds")
        }
    }

    static func validatePageSelection(_ raw: String?, field: String) throws {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024 else {
            throw DocumentToolError(.validationFailed, "\(field) is empty or too long")
        }
        if trimmed.lowercased() == "all" { return }

        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 1_000 else {
            throw DocumentToolError(.validationFailed, "\(field) has too many page selectors")
        }
        for part in parts {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw DocumentToolError(.validationFailed, "\(field) contains an empty selector")
            }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2,
                  let start = Int(bounds[0]),
                  (1...100_000).contains(start) else {
                throw DocumentToolError(.validationFailed, "\(field) contains an invalid page selector")
            }
            if bounds.count == 2 {
                guard let end = Int(bounds[1]), start <= end, end <= 100_000 else {
                    throw DocumentToolError(.validationFailed, "\(field) contains an invalid page range")
                }
            }
        }
    }

    static func validateOperationEnvelopes(_ raw: JSONValue?) throws {
        guard case .array(let operations)? = raw,
              (1...1_000).contains(operations.count) else {
            throw DocumentToolError(
                .validationFailed,
                "operations must be an array containing between one and 1000 entries")
        }
        for operation in operations {
            guard case .object(let envelope) = operation else {
                throw DocumentToolError(.validationFailed, "each operation must be an object")
            }
            try requireKeys(
                envelope,
                allowed: ["kind", "parameters"],
                required: ["kind", "parameters"])
            guard case .string(let kind)? = envelope["kind"],
                  !kind.isEmpty,
                  kind.count <= 80,
                  case .object = envelope["parameters"] else {
                throw DocumentToolError(
                    .validationFailed,
                    "each operation requires a bounded kind and object parameters")
            }
        }
    }

    static func validateA1Cell(_ value: String, field: String) throws {
        try validatePattern(
            value,
            pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#,
            field: field)
    }

    static func validateA1Range(_ value: String, field: String) throws {
        try validatePattern(
            value,
            pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}:\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#,
            field: field)
    }

    static func validateXPath(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 2_048,
              trimmed.hasPrefix("/") || trimmed.hasPrefix(".") else {
            throw DocumentToolError(.validationFailed, "\(field) must be a bounded XPath")
        }
    }

    static func validatePattern(_ value: String, pattern: String, field: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(in: value, range: range)?.range == range else {
            throw DocumentToolError(.validationFailed, "\(field) has an invalid value")
        }
    }
}

// MARK: - document_write operation matrix

private struct DocumentWriteOperationRule {
    let kind: String
    let parameters: [String: DocumentOperationParameterRule]
    let required: Set<String>

    var schema: JSONValue {
        DocumentContractSchema.object(
            properties: [
                "kind": DocumentContractSchema.stringEnum([kind]),
                "parameters": DocumentContractSchema.object(
                    properties: parameters.mapValues(\.schema),
                    required: required.sorted()),
            ],
            required: ["kind", "parameters"])
    }
}

private enum DocumentOperationParameterRule {
    case string(minimum: Int = 0, maximum: Int)
    case stringEnum([String])
    case integer(minimum: Int, maximum: Int)
    case number(minimum: Double, maximum: Double)
    case boolean
    case path
    case identifier
    case color
    case a1Cell
    case a1Range
    case stringArray(minimum: Int, maximum: Int)
    case numberArray(minimum: Int, maximum: Int)
    case stringMatrix(maximumCells: Int)
    case scalar
    case scalarMatrix(maximumCells: Int)

    var schema: JSONValue {
        switch self {
        case .string(let minimum, let maximum):
            return DocumentContractSchema.string(
                minimumLength: minimum,
                maximumLength: maximum)
        case .stringEnum(let values):
            return DocumentContractSchema.stringEnum(values)
        case .integer(let minimum, let maximum):
            return DocumentContractSchema.integer(minimum: minimum, maximum: maximum)
        case .number(let minimum, let maximum):
            return DocumentContractSchema.number(minimum: minimum, maximum: maximum)
        case .boolean:
            return DocumentContractSchema.boolean
        case .path:
            return DocumentContractSchema.path
        case .identifier:
            return DocumentContractSchema.string(
                minimumLength: 1,
                maximumLength: 255,
                pattern: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#)
        case .color:
            return DocumentContractSchema.string(
                minimumLength: 6,
                maximumLength: 7,
                pattern: #"^#?[A-Fa-f0-9]{6}$"#)
        case .a1Cell:
            return DocumentContractSchema.string(
                minimumLength: 2,
                maximumLength: 16,
                pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#)
        case .a1Range:
            return DocumentContractSchema.string(
                minimumLength: 5,
                maximumLength: 40,
                pattern: #"^\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}:\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}$"#)
        case .stringArray(let minimum, let maximum):
            return DocumentContractSchema.array(
                items: DocumentContractSchema.string(minimumLength: 0, maximumLength: 65_536),
                minimumItems: minimum,
                maximumItems: maximum)
        case .numberArray(let minimum, let maximum):
            return DocumentContractSchema.array(
                items: DocumentContractSchema.number(
                    minimum: -1_000_000_000_000,
                    maximum: 1_000_000_000_000),
                minimumItems: minimum,
                maximumItems: maximum)
        case .stringMatrix(let maximumCells):
            return DocumentContractSchema.array(
                items: DocumentContractSchema.array(
                    items: DocumentContractSchema.string(
                        minimumLength: 0,
                        maximumLength: 65_536),
                    minimumItems: 1,
                    maximumItems: maximumCells),
                minimumItems: 1,
                maximumItems: maximumCells)
        case .scalar:
            return .object([
                "oneOf": .array([
                    DocumentContractSchema.string(maximumLength: 65_536),
                    DocumentContractSchema.number(
                        minimum: -1_000_000_000_000,
                        maximum: 1_000_000_000_000),
                    DocumentContractSchema.boolean,
                    .object(["type": .string("null")]),
                ]),
            ])
        case .scalarMatrix(let maximumCells):
            return DocumentContractSchema.array(
                items: DocumentContractSchema.array(
                    items: Self.scalar.schema,
                    minimumItems: 1,
                    maximumItems: maximumCells),
                minimumItems: 1,
                maximumItems: maximumCells)
        }
    }

    func validate(_ value: JSONValue, field: String) throws {
        switch (self, value) {
        case (.string(let minimum, let maximum), .string(let string)):
            guard (minimum...maximum).contains(string.count) else {
                throw invalid(field)
            }
        case (.stringEnum(let allowed), .string(let string)):
            guard allowed.contains(string) else { throw invalid(field) }
        case (.integer(let minimum, let maximum), .number(let number)):
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(minimum),
                  number <= Double(maximum) else { throw invalid(field) }
        case (.number(let minimum, let maximum), .number(let number)):
            guard number.isFinite, number >= minimum, number <= maximum else {
                throw invalid(field)
            }
        case (.boolean, .bool):
            break
        case (.path, .string(let path)):
            try DocumentContractValidation.validatePlainPath(path, field: field)
        case (.identifier, .string(let identifier)):
            try DocumentContractValidation.validatePattern(
                identifier,
                pattern: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#,
                field: field)
        case (.color, .string(let color)):
            try DocumentContractValidation.validatePattern(
                color,
                pattern: #"^#?[A-Fa-f0-9]{6}$"#,
                field: field)
        case (.a1Cell, .string(let cell)):
            try DocumentContractValidation.validateA1Cell(cell, field: field)
        case (.a1Range, .string(let range)):
            try DocumentContractValidation.validateA1Range(range, field: field)
        case (.stringArray(let minimum, let maximum), .array(let values)):
            guard (minimum...maximum).contains(values.count),
                  values.allSatisfy({ value in
                      guard case .string(let string) = value else { return false }
                      return string.count <= 65_536
                  }) else { throw invalid(field) }
        case (.numberArray(let minimum, let maximum), .array(let values)):
            guard (minimum...maximum).contains(values.count),
                  values.allSatisfy({ value in
                      guard case .number(let number) = value else { return false }
                      return number.isFinite && abs(number) <= 1_000_000_000_000
                  }) else { throw invalid(field) }
        case (.stringMatrix(let maximumCells), .array(let rows)):
            try validateMatrix(
                rows,
                maximumCells: maximumCells,
                field: field,
                accepts: { value in
                    guard case .string(let string) = value else { return false }
                    return string.count <= 65_536
                })
        case (.scalar, let scalar):
            guard Self.isScalar(scalar) else { throw invalid(field) }
        case (.scalarMatrix(let maximumCells), .array(let rows)):
            try validateMatrix(
                rows,
                maximumCells: maximumCells,
                field: field,
                accepts: Self.isScalar)
        default:
            throw invalid(field)
        }
    }

    private func invalid(_ field: String) -> DocumentToolError {
        DocumentToolError(.validationFailed, "operation parameter \(field) is invalid")
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool:
            return true
        case .number(let number):
            return number.isFinite && abs(number) <= 1_000_000_000_000
        case .string(let string):
            return string.count <= 65_536
        case .array, .object:
            return false
        }
    }

    private func validateMatrix(
        _ rows: [JSONValue],
        maximumCells: Int,
        field: String,
        accepts: (JSONValue) -> Bool
    ) throws {
        guard !rows.isEmpty, rows.count <= maximumCells else { throw invalid(field) }
        var width: Int?
        var cells = 0
        for rowValue in rows {
            guard case .array(let row) = rowValue, !row.isEmpty else { throw invalid(field) }
            if let width {
                guard row.count == width else { throw invalid(field) }
            } else {
                width = row.count
            }
            cells += row.count
            guard cells <= maximumCells, row.allSatisfy(accepts) else { throw invalid(field) }
        }
    }
}

private enum DocumentWriteOperationMatrix {
    private static let coordinateRules: [String: DocumentOperationParameterRule] = [
        "x_points": .number(minimum: 0, maximum: 100_000),
        "y_points": .number(minimum: 0, maximum: 100_000),
        "width_points": .number(minimum: 0.1, maximum: 100_000),
        "height_points": .number(minimum: 0.1, maximum: 100_000),
    ]

    static let schema: JSONValue = .object([
        "oneOf": .array(
            DocumentFormat.editableFormats
                .flatMap(rules(for:))
                .sorted { lhs, rhs in lhs.kind < rhs.kind }
                .map(\.schema)),
    ])

    static func validate(_ operation: DocumentWriteOperation, format: DocumentFormat) throws {
        guard let rule = rules(for: format).first(where: { $0.kind == operation.kind }) else {
            throw DocumentToolError(
                .unsupportedOperation,
                "the requested document_write operation is not supported for \(format.rawValue)")
        }
        try DocumentContractValidation.requireKeys(
            operation.parameters,
            allowed: Set(rule.parameters.keys),
            required: rule.required)
        for (field, value) in operation.parameters {
            guard let parameterRule = rule.parameters[field] else {
                throw DocumentToolError(.validationFailed, "operation contains an unknown parameter")
            }
            try parameterRule.validate(value, field: field)
        }
        try validateCrossFields(operation, format: format)
    }

    private static func rules(for format: DocumentFormat) -> [DocumentWriteOperationRule] {
        switch format {
        case .docx:
            return docxRules
        case .pptx:
            return pptxRules
        case .xlsx:
            return xlsxRules
        case .html:
            return htmlRules
        case .epub:
            return epubRules
        case .pdf:
            return []
        }
    }

    private static let docxRules: [DocumentWriteOperationRule] = [
        .init(
            kind: "paragraph.add",
            parameters: [
                "text": .string(maximum: 1_000_000),
                "style": .string(minimum: 1, maximum: 255),
            ],
            required: ["text"]),
        .init(
            kind: "paragraph.set_text",
            parameters: [
                "paragraph_index": .integer(minimum: 0, maximum: 1_000_000),
                "text": .string(maximum: 1_000_000),
            ],
            required: ["paragraph_index", "text"]),
        .init(
            kind: "run.add",
            parameters: [
                "paragraph_index": .integer(minimum: 0, maximum: 1_000_000),
                "text": .string(maximum: 1_000_000),
                "bold": .boolean,
                "italic": .boolean,
                "underline": .boolean,
                "style": .string(minimum: 1, maximum: 255),
            ],
            required: ["paragraph_index", "text"]),
        .init(
            kind: "table.add",
            parameters: [
                "values": .stringMatrix(maximumCells: 100_000),
                "style": .string(minimum: 1, maximum: 255),
            ],
            required: ["values"]),
        .init(
            kind: "table.set_cell",
            parameters: [
                "table_index": .integer(minimum: 0, maximum: 100_000),
                "row_index": .integer(minimum: 0, maximum: 1_000_000),
                "column_index": .integer(minimum: 0, maximum: 16_384),
                "text": .string(maximum: 1_000_000),
            ],
            required: ["table_index", "row_index", "column_index", "text"]),
        .init(
            kind: "image.add",
            parameters: [
                "path": .path,
                "paragraph_index": .integer(minimum: 0, maximum: 1_000_000),
                "width_points": .number(minimum: 0.1, maximum: 100_000),
                "height_points": .number(minimum: 0.1, maximum: 100_000),
            ],
            required: ["path"]),
        .init(
            kind: "header.set_text",
            parameters: [
                "section_index": .integer(minimum: 0, maximum: 100_000),
                "text": .string(maximum: 1_000_000),
            ],
            required: ["section_index", "text"]),
        .init(
            kind: "footer.set_text",
            parameters: [
                "section_index": .integer(minimum: 0, maximum: 100_000),
                "text": .string(maximum: 1_000_000),
            ],
            required: ["section_index", "text"]),
        .init(
            kind: "section.set",
            parameters: [
                "section_index": .integer(minimum: 0, maximum: 100_000),
                "orientation": .stringEnum(["portrait", "landscape"]),
                "margin_top_points": .number(minimum: 0, maximum: 2_000),
                "margin_right_points": .number(minimum: 0, maximum: 2_000),
                "margin_bottom_points": .number(minimum: 0, maximum: 2_000),
                "margin_left_points": .number(minimum: 0, maximum: 2_000),
            ],
            required: ["section_index"]),
    ]

    private static let pptxRules: [DocumentWriteOperationRule] = [
        .init(
            kind: "slide.add",
            parameters: [
                "layout_index": .integer(minimum: 0, maximum: 1_000),
                "title": .string(maximum: 100_000),
            ],
            required: []),
        .init(
            kind: "text.set",
            parameters: [
                "slide_index": .integer(minimum: 0, maximum: 100_000),
                "shape_index": .integer(minimum: 0, maximum: 100_000),
                "text": .string(maximum: 1_000_000),
            ],
            required: ["slide_index", "shape_index", "text"]),
        .init(
            kind: "shape.add",
            parameters: coordinateRules.merging([
                "slide_index": .integer(minimum: 0, maximum: 100_000),
                "shape_type": .stringEnum(["rectangle", "rounded_rectangle", "ellipse", "line"]),
                "text": .string(maximum: 100_000),
            ]) { current, _ in current },
            required: [
                "slide_index", "shape_type", "x_points", "y_points", "width_points",
                "height_points",
            ]),
        .init(
            kind: "image.add",
            parameters: coordinateRules.merging([
                "slide_index": .integer(minimum: 0, maximum: 100_000),
                "path": .path,
            ]) { current, _ in current },
            required: [
                "slide_index", "path", "x_points", "y_points", "width_points", "height_points",
            ]),
        .init(
            kind: "table.add",
            parameters: coordinateRules.merging([
                "slide_index": .integer(minimum: 0, maximum: 100_000),
                "values": .stringMatrix(maximumCells: 10_000),
            ]) { current, _ in current },
            required: [
                "slide_index", "values", "x_points", "y_points", "width_points", "height_points",
            ]),
        .init(
            kind: "chart.add",
            parameters: coordinateRules.merging([
                "slide_index": .integer(minimum: 0, maximum: 100_000),
                "chart_type": .stringEnum(["column", "bar", "line", "pie"]),
                "categories": .stringArray(minimum: 1, maximum: 10_000),
                "series_name": .string(minimum: 1, maximum: 255),
                "values": .numberArray(minimum: 1, maximum: 10_000),
                "title": .string(maximum: 10_000),
            ]) { current, _ in current },
            required: [
                "slide_index", "chart_type", "categories", "series_name", "values",
                "x_points", "y_points", "width_points", "height_points",
            ]),
    ]

    private static let xlsxRules: [DocumentWriteOperationRule] = [
        .init(
            kind: "sheet.add",
            parameters: ["name": .string(minimum: 1, maximum: 31)],
            required: ["name"]),
        .init(
            kind: "sheet.rename",
            parameters: [
                "current_name": .string(minimum: 1, maximum: 31),
                "new_name": .string(minimum: 1, maximum: 31),
            ],
            required: ["current_name", "new_name"]),
        .init(
            kind: "cell.set",
            parameters: [
                "sheet": .string(minimum: 1, maximum: 31),
                "cell": .a1Cell,
                "value": .scalar,
            ],
            required: ["sheet", "cell", "value"]),
        .init(
            kind: "range.set",
            parameters: [
                "sheet": .string(minimum: 1, maximum: 31),
                "start_cell": .a1Cell,
                "values": .scalarMatrix(maximumCells: 100_000),
            ],
            required: ["sheet", "start_cell", "values"]),
        .init(
            kind: "style.set",
            parameters: [
                "sheet": .string(minimum: 1, maximum: 31),
                "range": .a1Range,
                "bold": .boolean,
                "italic": .boolean,
                "font_color": .color,
                "fill_color": .color,
                "number_format": .string(minimum: 1, maximum: 255),
                "horizontal_alignment": .stringEnum(["general", "left", "center", "right", "fill", "justify"]),
                "vertical_alignment": .stringEnum(["top", "center", "bottom", "justify"]),
            ],
            required: ["sheet", "range"]),
        .init(
            kind: "table.add",
            parameters: [
                "sheet": .string(minimum: 1, maximum: 31),
                "range": .a1Range,
                "name": .identifier,
                "style": .string(minimum: 1, maximum: 255),
            ],
            required: ["sheet", "range", "name"]),
        .init(
            kind: "name.set",
            parameters: [
                "name": .identifier,
                "reference": .string(minimum: 3, maximum: 512),
            ],
            required: ["name", "reference"]),
        .init(
            kind: "chart.add",
            parameters: [
                "sheet": .string(minimum: 1, maximum: 31),
                "chart_type": .stringEnum(["column", "bar", "line", "pie", "area", "scatter"]),
                "data_range": .a1Range,
                "category_range": .a1Range,
                "anchor": .a1Cell,
                "title": .string(maximum: 10_000),
            ],
            required: ["sheet", "chart_type", "data_range", "anchor"]),
    ]

    private static let xpathBaseRules: [String: DocumentOperationParameterRule] = [
        "xpath": .string(minimum: 1, maximum: 2_048),
        "expected_match_count": .integer(minimum: 1, maximum: 10_000),
    ]

    private static let htmlRules: [DocumentWriteOperationRule] = [
        .init(
            kind: "xpath.set_text",
            parameters: xpathBaseRules.merging([
                "text": .string(maximum: 1_000_000),
            ]) { current, _ in current },
            required: ["xpath", "expected_match_count", "text"]),
        .init(
            kind: "xpath.set_attribute",
            parameters: xpathBaseRules.merging([
                "name": .string(minimum: 1, maximum: 255),
                "value": .string(maximum: 1_000_000),
            ]) { current, _ in current },
            required: ["xpath", "expected_match_count", "name", "value"]),
        .init(
            kind: "xpath.append",
            parameters: xpathBaseRules.merging([
                "html": .string(minimum: 1, maximum: 1_000_000),
            ]) { current, _ in current },
            required: ["xpath", "expected_match_count", "html"]),
        .init(
            kind: "xpath.remove",
            parameters: xpathBaseRules,
            required: ["xpath", "expected_match_count"]),
    ]

    private static let epubRules: [DocumentWriteOperationRule] = [
        .init(
            kind: "metadata.set",
            parameters: [
                "field": .stringEnum([
                    "title", "language", "identifier", "creator", "subject", "description",
                    "publisher", "date", "rights",
                ]),
                "value": .string(minimum: 1, maximum: 100_000),
            ],
            required: ["field", "value"]),
        .init(
            kind: "resource.add",
            parameters: [
                "id": .identifier,
                "source_path": .path,
                "href": .string(minimum: 1, maximum: 2_048),
                "media_type": .stringEnum([
                    "application/xhtml+xml", "text/css", "image/png", "image/jpeg",
                    "image/svg+xml", "font/woff2", "application/font-woff",
                ]),
                "properties": .stringArray(minimum: 1, maximum: 32),
            ],
            required: ["id", "source_path", "href", "media_type"]),
        .init(
            kind: "spine.append",
            parameters: [
                "resource_id": .identifier,
                "linear": .boolean,
            ],
            required: ["resource_id"]),
        .init(
            kind: "toc.add",
            parameters: [
                "label": .string(minimum: 1, maximum: 10_000),
                "href": .string(minimum: 1, maximum: 2_048),
                "parent_id": .identifier,
            ],
            required: ["label", "href"]),
    ]

    private static func validateCrossFields(
        _ operation: DocumentWriteOperation,
        format: DocumentFormat
    ) throws {
        let parameters = operation.parameters
        switch (format, operation.kind) {
        case (.docx, "section.set"):
            let mutationFields: Set<String> = [
                "orientation", "margin_top_points", "margin_right_points",
                "margin_bottom_points", "margin_left_points",
            ]
            guard !Set(parameters.keys).isDisjoint(with: mutationFields) else {
                throw DocumentToolError(
                    .validationFailed,
                    "section.set requires at least one section property")
            }
        case (.pptx, "chart.add"):
            guard case .array(let categories)? = parameters["categories"],
                  case .array(let values)? = parameters["values"],
                  categories.count == values.count else {
                throw DocumentToolError(
                    .validationFailed,
                    "PPTX chart categories and values must have equal counts")
            }
        case (.xlsx, "style.set"):
            let styleFields: Set<String> = [
                "bold", "italic", "font_color", "fill_color", "number_format",
                "horizontal_alignment", "vertical_alignment",
            ]
            guard !Set(parameters.keys).isDisjoint(with: styleFields) else {
                throw DocumentToolError(
                    .validationFailed,
                    "style.set requires at least one supported style property")
            }
        case (.xlsx, "cell.set"), (.xlsx, "range.set"):
            try validateSpreadsheetSheetNames(in: parameters)
            try rejectExternalSpreadsheetReferences(in: parameters)
        case (.xlsx, "name.set"):
            guard case .string(let reference)? = parameters["reference"] else { return }
            try rejectExternalSpreadsheetText(reference)
        case (.xlsx, _):
            try validateSpreadsheetSheetNames(in: parameters)
        case (.html, _):
            guard case .string(let xpath)? = parameters["xpath"] else { return }
            try DocumentContractValidation.validateXPath(xpath, field: "xpath")
            if operation.kind == "xpath.set_attribute",
               case .string(let name)? = parameters["name"],
               case .string(let value)? = parameters["value"] {
                try validateHTMLAttribute(name: name, value: value)
            }
            if operation.kind == "xpath.append", case .string(let html)? = parameters["html"] {
                try rejectActiveOrRemoteHTML(html)
            }
        case (.epub, "resource.add"):
            guard case .string(let href)? = parameters["href"],
                  case .string(let sourcePath)? = parameters["source_path"],
                  case .string(let mediaType)? = parameters["media_type"] else { return }
            try validateEPUBHref(href)
            try validateEPUBResource(
                sourcePath: sourcePath,
                href: href,
                mediaType: mediaType,
                properties: parameters["properties"])
        case (.epub, "toc.add"):
            guard case .string(let href)? = parameters["href"] else { return }
            try validateEPUBHref(href)
        default:
            break
        }
    }

    private static func rejectExternalSpreadsheetReferences(
        in parameters: [String: JSONValue]
    ) throws {
        for value in parameters.values {
            try walkScalars(value) { string in
                if string.hasPrefix("=") {
                    try rejectExternalSpreadsheetText(string)
                }
            }
        }
    }

    private static func rejectExternalSpreadsheetText(_ value: String) throws {
        let upper = value.uppercased()
        let forbidden = ["HTTP://", "HTTPS://", "WEBSERVICE(", "RTD(", "DDE("]
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        let hasExternalWorkbookReference = (try? NSRegularExpression(
            pattern: #"\[[^\]]+\][^!]{0,255}!"#))?
            .firstMatch(in: upper, range: range) != nil
        guard !forbidden.contains(where: upper.contains), !hasExternalWorkbookReference else {
            throw DocumentToolError(
                .unsupportedFeature,
                "external workbook connections and network formulas are not supported")
        }
    }

    private static func validateSpreadsheetSheetNames(
        in parameters: [String: JSONValue]
    ) throws {
        for key in ["sheet", "current_name", "new_name"] {
            guard case .string(let name)? = parameters[key] else { continue }
            let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
            guard !name.isEmpty,
                  name.count <= 31,
                  name.rangeOfCharacter(from: forbidden) == nil,
                  name != "'" else {
                throw DocumentToolError(.validationFailed, "spreadsheet sheet name is invalid")
            }
        }
    }

    private static func walkScalars(
        _ value: JSONValue,
        visit: (String) throws -> Void
    ) throws {
        switch value {
        case .string(let string):
            try visit(string)
        case .array(let values):
            for value in values { try walkScalars(value, visit: visit) }
        case .object(let object):
            for value in object.values { try walkScalars(value, visit: visit) }
        case .null, .bool, .number:
            break
        }
    }

    private static func validateHTMLAttribute(name: String, value: String) throws {
        try DocumentContractValidation.validatePattern(
            name,
            pattern: #"^[A-Za-z_:][A-Za-z0-9_.:-]*$"#,
            field: "name")
        let lowerName = name.lowercased()
        guard !lowerName.hasPrefix("on"), lowerName != "srcdoc" else {
            throw DocumentToolError(.unsupportedFeature, "HTML event and srcdoc attributes are not supported")
        }
        if ["href", "src", "action", "formaction", "poster"].contains(lowerName) {
            try rejectRemoteReference(value)
        }
    }

    private static func rejectActiveOrRemoteHTML(_ html: String) throws {
        let lower = html.lowercased()
        let forbidden = [
            "<script", "javascript:", "vbscript:", "data:", "http://", "https://", "srcdoc=",
            "src=\"//", "src='//", "href=\"//", "href='//", "url(//", "@import",
        ]
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        let hasInlineEvent = (try? NSRegularExpression(
            pattern: #"\son[a-z0-9_-]+\s*="#))?
            .firstMatch(in: lower, range: range) != nil
        guard !forbidden.contains(where: lower.contains), !hasInlineEvent else {
            throw DocumentToolError(
                .unsupportedFeature,
                "active content and remote HTML resources are not supported")
        }
    }

    private static func rejectRemoteReference(_ value: String) throws {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("//"),
              !lower.hasPrefix("javascript:"),
              !lower.hasPrefix("data:") else {
            throw DocumentToolError(.unsupportedFeature, "remote or executable HTML references are not supported")
        }
    }

    private static func validateEPUBHref(_ href: String) throws {
        try rejectRemoteReference(href)
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        guard !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw DocumentToolError(.validationFailed, "EPUB href must be package-relative")
        }
    }

    private static func validateEPUBResource(
        sourcePath: String,
        href: String,
        mediaType: String,
        properties: JSONValue?
    ) throws {
        let expectedExtensions: [String: Set<String>] = [
            "application/xhtml+xml": ["xhtml", "html", "htm"],
            "text/css": ["css"],
            "image/png": ["png"],
            "image/jpeg": ["jpg", "jpeg"],
            "image/svg+xml": ["svg"],
            "font/woff2": ["woff2"],
            "application/font-woff": ["woff"],
        ]
        guard let allowed = expectedExtensions[mediaType] else {
            throw DocumentToolError(.unsupportedFeature, "EPUB resource media type is not supported")
        }
        let sourceExtension = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
        let hrefPath = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let hrefExtension = URL(fileURLWithPath: hrefPath).pathExtension.lowercased()
        guard allowed.contains(sourceExtension), allowed.contains(hrefExtension) else {
            throw DocumentToolError(
                .validationFailed,
                "EPUB resource extensions do not match media_type")
        }
        if case .array(let values)? = properties {
            let allowedProperties: Set<String> = ["cover-image", "mathml", "nav", "svg"]
            guard values.allSatisfy({ value in
                guard case .string(let property) = value else { return false }
                return allowedProperties.contains(property)
            }) else {
                throw DocumentToolError(
                    .unsupportedFeature,
                    "EPUB scripted and remote-resource properties are not supported")
            }
        }
    }
}
