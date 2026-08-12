import Foundation
import IntatisCore
import IntatisProtocol

struct DocumentBackendEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let ok: Bool
    let code: String?
    let summary: String?
    let engineVersions: [String: String]
    let result: JSONValue?
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok, code, summary
        case engineVersions = "engine_versions"
        case result, warnings
    }
}

/// Pinned Python document boundary. Ordinary DOCX/PPTX/XLSX/HTML/EPUB reads
/// delegate conversion to Docling and only return bounded Markdown. The longer
/// allowlisted adapters below remain for explicit write verification and OCR;
/// they are not part of the ordinary read path.
enum DocumentPythonBackend {
    static let schemaVersion = 1
    static let pinnedVersions: [String: String] = [
        "python": "3.11.9",
        "python-docx": "1.2.0",
        "python-pptx": "1.0.2",
        "openpyxl": "3.1.5",
        "lxml": "6.1.1",
        "docling": "2.117.0",
        "docling-core": "2.89.0",
        "docling-parse": "7.8.1",
        "pypdfium2": "5.12.1",
    ]

    static func invocation(
        operation: String,
        payload: JSONValue,
        readableWorkspacePaths: [String],
        writableWorkspacePaths: [String] = [],
        internalWritableWorkspacePaths: [String] = [],
        internalReadOnlyWorkspacePaths: [String] = []
    ) throws -> DocumentBackendInvocation {
        let request: JSONValue = .object([
            "schema_version": .number(Double(schemaVersion)),
            "operation": .string(operation),
            "payload": payload,
        ])
        let data = try JSONEncoder.sortedDocumentEncoder.encode(request)
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.utf8.count <= 256 * 1_024 else {
            throw DocumentToolError(
                .validationFailed,
                "document backend request exceeds the fixed envelope limit")
        }
        return DocumentBackendInvocation(
            executable: .pythonRuntime,
            arguments: ["-I", "-B", "-c", program],
            environment: [
                "INTATIS_DOCUMENT_REQUEST": encoded,
                "INTATIS_DOCUMENT_OPERATION": operation,
                "PYTHONHASHSEED": "0",
            ],
            readableWorkspacePaths: readableWorkspacePaths,
            writableWorkspacePaths: writableWorkspacePaths,
            internalWritableWorkspacePaths: internalWritableWorkspacePaths,
            internalReadOnlyWorkspacePaths: internalReadOnlyWorkspacePaths)
    }

    static func run(
        operation: String,
        payload: JSONValue,
        readableWorkspacePaths: [String],
        writableWorkspacePaths: [String] = [],
        internalWritableWorkspacePaths: [String] = [],
        internalReadOnlyWorkspacePaths: [String] = [],
        in context: ToolContext
    ) async throws -> DocumentBackendEnvelope {
        let invocation = try invocation(
            operation: operation,
            payload: payload,
            readableWorkspacePaths: readableWorkspacePaths,
            writableWorkspacePaths: writableWorkspacePaths,
            internalWritableWorkspacePaths: internalWritableWorkspacePaths,
            internalReadOnlyWorkspacePaths: internalReadOnlyWorkspacePaths)
        let result: ShellResult
        do {
            result = try await context.documentBackend.run(
                invocation,
                cwd: context.workspaceRoot)
        } catch let error as DocumentToolError {
            throw error
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "fixed Python document runtime is unavailable")
            }
            throw DocumentToolError(.backendFailed, "document backend could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "document backend could not be started")
        }
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendFailed, "fixed document backend exited unsuccessfully")
        }
        guard result.stdout.utf8.count <= 8 * 1_024 * 1_024,
              let data = result.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  DocumentBackendEnvelope.self,
                  from: data),
              envelope.schemaVersion == schemaVersion else {
            throw DocumentToolError(.backendFailed, "document backend returned an invalid envelope")
        }
        guard envelope.ok else {
            let code = envelope.code.flatMap(DocumentToolErrorCode.init(rawValue:))
                ?? .backendFailed
            throw DocumentToolError(code, sanitizedSummary(for: code, envelope.summary))
        }
        return envelope
    }

    static func fixedOCRPayload(
        inputPath: String,
        pages: [Int],
        languages: [String],
        psm: Int,
        maximumCharacters: Int,
        maximumFileBytes: Int
    ) throws -> JSONValue {
        guard let runtime = intatisDocumentRuntimeRoot() else {
            throw DocumentToolError(.backendMissing, "fixed document runtime root is unavailable")
        }
        let artifacts = runtime.appendingPathComponent("models/docling", isDirectory: true)
        #if os(macOS)
        let tesseract = URL(fileURLWithPath: "/opt/homebrew/bin/tesseract")
        let tessdata = URL(fileURLWithPath: "/opt/homebrew/share/tessdata", isDirectory: true)
        #else
        let tesseract = runtime.appendingPathComponent("bin/tesseract")
        let tessdata = runtime.appendingPathComponent("share/tessdata", isDirectory: true)
        #endif
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifacts.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: tesseract.path),
              FileManager.default.fileExists(atPath: tessdata.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DocumentToolError(
                .backendMissing,
                "fixed Docling models, Tesseract, or tessdata are unavailable")
        }
        guard languages.allSatisfy({ language in
            FileManager.default.fileExists(
                atPath: tessdata.appendingPathComponent("\(language).traineddata").path)
        }) else {
            throw DocumentToolError(
                .backendMissing,
                "one or more requested fixed tessdata language files are unavailable")
        }
        return .object([
            "input_path": .string(inputPath),
            "pages": .array(pages.map { .number(Double($0)) }),
            "languages": .array(languages.map(JSONValue.string)),
            "psm": .number(Double(psm)),
            "maximum_characters": .number(Double(maximumCharacters)),
            "maximum_file_bytes": .number(Double(maximumFileBytes)),
            "artifacts_path": .string(artifacts.path),
            "tesseract_path": .string(tesseract.path),
            "tessdata_path": .string(tessdata.path),
        ])
    }

    private static func sanitizedSummary(
        for code: DocumentToolErrorCode,
        _ backendSummary: String?
    ) -> String {
        switch code {
        case .backendMissing:
            return "a fixed document backend component is unavailable"
        case .backendVersionMismatch:
            return "a fixed document backend has an unexpected version"
        case .unsupportedOperation:
            return "the requested format/operation is not supported"
        case .unsupportedFeature:
            return "the document uses a feature outside the supported subset"
        case .ocrRequired:
            return "the document requires explicit OCR"
        case .validationFailed:
            return "the document or requested projection failed validation"
        case .renderFailed:
            return "the document could not be rendered"
        case .outputConflict:
            return "the reviewed source or destination changed"
        case .commitUncertain:
            return "the document commit could not be reconciled"
        case .backendFailed:
            // Unexpected backend exceptions can contain absolute paths, cell
            // contents, relationship targets, or library-specific reprs. The
            // typed code is sufficient for callers; never surface that text.
            return "the fixed document backend failed"
        }
    }

    // The program deliberately contains no backend search or fallback loop.
    // Every branch imports exactly one semantic library for one format.
    private static let program = #"""
import base64
import hashlib
import html as html_stdlib
import json
import math
import os
import pathlib
import re
import stat
import sys
import unicodedata
import zipfile
from copy import copy, deepcopy
from importlib import metadata

SCHEMA_VERSION = 1
MAXIMUM_PDF_PAGES = 100000
MAXIMUM_OOXML_ENTRIES = 20000
MAXIMUM_OOXML_ENTRY_BYTES = 256 * 1024 * 1024
MAXIMUM_OOXML_TOTAL_BYTES = 1024 * 1024 * 1024
MAXIMUM_OOXML_COMPRESSION_RATIO = 200
EXPECTED = {
    'python': '3.11.9',
    'python-docx': '1.2.0',
    'python-pptx': '1.0.2',
    'openpyxl': '3.1.5',
    'lxml': '6.1.1',
    'docling': '2.117.0',
    'docling-core': '2.89.0',
    'docling-parse': '7.8.1',
    'pypdfium2': '5.12.1',
}

class ToolFailure(Exception):
    def __init__(self, code, summary):
        super().__init__(summary)
        self.code = code
        self.summary = summary

def emit(ok, result=None, versions=None, warnings=None, code=None, summary=None):
    value = {
        'schema_version': SCHEMA_VERSION,
        'ok': bool(ok),
        'engine_versions': versions or {},
        'warnings': warnings or [],
    }
    if result is not None:
        value['result'] = result
    if code is not None:
        value['code'] = code
    if summary is not None:
        value['summary'] = str(summary)[:240]
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')))

def require_request():
    raw = os.environ.get('INTATIS_DOCUMENT_REQUEST')
    if not raw or len(raw.encode('utf-8')) > 262144:
        raise ToolFailure('validation_failed', 'invalid request envelope')
    value = json.loads(raw)
    if set(value) != {'schema_version', 'operation', 'payload'}:
        raise ToolFailure('validation_failed', 'invalid request fields')
    if value['schema_version'] != SCHEMA_VERSION:
        raise ToolFailure('backend_version_mismatch', 'request schema mismatch')
    if value['operation'] not in {'read', 'ocr', 'write', 'verify_write', 'prepare_html_render'}:
        raise ToolFailure('unsupported_operation', 'unsupported fixed Python route')
    if os.environ.get('INTATIS_DOCUMENT_OPERATION') != value['operation']:
        raise ToolFailure('validation_failed', 'operation binding mismatch')
    if not isinstance(value['payload'], dict):
        raise ToolFailure('validation_failed', 'payload must be an object')
    return value['operation'], value['payload']

def require_versions(distributions):
    versions = {'python': '.'.join(str(v) for v in sys.version_info[:3])}
    if versions['python'] != EXPECTED['python']:
        raise ToolFailure('backend_version_mismatch', 'python version mismatch')
    for distribution in distributions:
        try:
            actual = metadata.version(distribution)
        except metadata.PackageNotFoundError:
            raise ToolFailure('backend_missing', distribution + ' is not installed')
        versions[distribution] = actual
        if actual != EXPECTED[distribution]:
            raise ToolFailure('backend_version_mismatch', distribution + ' version mismatch')
    return versions

def safe_input(payload, suffix):
    path = payload.get('input_path')
    if not isinstance(path, str) or not os.path.isabs(path) or '\x00' in path or len(path) > 4096:
        raise ToolFailure('validation_failed', 'input_path must be an absolute host path')
    candidate = pathlib.Path(path)
    allowed_suffixes = {suffix} if isinstance(suffix, str) else set(suffix)
    if candidate.suffix.lower() not in allowed_suffixes or not candidate.is_file() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'input file is missing or has the wrong format')
    return candidate

def safe_zip_member_name(raw_name):
    if (not isinstance(raw_name, str) or not raw_name or '\x00' in raw_name
            or len(raw_name.encode('utf-8')) > 1024 or '\\' in raw_name
            or raw_name.startswith('/') or re.match(r'^[A-Za-z]:', raw_name)):
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member name')
    parts = pathlib.PurePosixPath(raw_name).parts
    if not parts or any(part in {'', '.', '..'} for part in parts):
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member path')
    normalized = unicodedata.normalize('NFC', raw_name.rstrip('/')).casefold()
    if not normalized:
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member name')
    return normalized

def reject_xlsx_external_formulas(member_names, archive):
    formula_members = [
        name for name in member_names
        if name.casefold() == 'xl/workbook.xml'
        or (name.casefold().startswith('xl/worksheets/')
            and name.casefold().endswith('.xml'))
    ]
    formula_pattern = re.compile(
        rb'<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?(?:f|definedName)(?:\s[^>]*)?>(.*?)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?(?:f|definedName)>',
        re.IGNORECASE | re.DOTALL)
    for name in formula_members:
        try:
            data = archive.read(name)
        except (KeyError, RuntimeError, zipfile.BadZipFile, OSError):
            raise ToolFailure('validation_failed', 'XLSX formula parts could not be inspected') from None
        for raw_formula in formula_pattern.findall(data):
            try:
                formula = html_stdlib.unescape(raw_formula.decode('utf-8', errors='strict'))
            except UnicodeDecodeError:
                raise ToolFailure('validation_failed', 'XLSX formula text is not valid UTF-8') from None
            reject_external_spreadsheet_text(formula)

def reject_xlsx_preservation_hazards(member_names, archive):
    lower_names = {name.casefold() for name in member_names}
    forbidden_prefixes = (
        '_xmlsignatures/', 'customxml/', 'xl/activex/', 'xl/charts/',
        'xl/controls/', 'xl/ctrlprops/', 'xl/dialogsheets/', 'xl/drawings/',
        'xl/embeddings/', 'xl/externallinks/', 'xl/macrosheets/', 'xl/model/',
        'xl/pivotcache/', 'xl/pivottables/', 'xl/printersettings/',
        'xl/querytables/', 'xl/richdata/',
        'xl/slicercaches/', 'xl/slicers/', 'xl/threadedcomments/',
        'xl/timelinecaches/', 'xl/timelines/', 'xl/webextensions/',
    )
    forbidden_exact = {
        'docprops/custom.xml', 'xl/comments.xml', 'xl/connections.xml',
        'xl/metadata.xml', 'xl/persons/person.xml', 'xl/vbaproject.bin',
        'xl/xmlmaps.xml',
    }
    if (any(name.startswith(forbidden_prefixes) for name in lower_names)
            or any(name in forbidden_exact or name.endswith('.bin') for name in lower_names)):
        raise ToolFailure(
            'unsupported_feature',
            'XLSX contains parts that cannot be preserved by the fixed edit route')

    vendor_markers = (b'<extLst', b':extLst', b'<mc:AlternateContent')
    for name in member_names:
        lower = name.casefold()
        if not lower.startswith('xl/') or not lower.endswith('.xml'):
            continue
        try:
            with archive.open(name, mode='r') as stream:
                overlap = b''
                while True:
                    chunk = stream.read(131072)
                    if not chunk:
                        break
                    inspected = overlap + chunk
                    if any(marker in inspected for marker in vendor_markers):
                        raise ToolFailure(
                            'unsupported_feature',
                            'XLSX contains vendor extension markup that cannot be preserved exactly')
                    overlap = inspected[-64:]
        except ToolFailure:
            raise
        except (OSError, RuntimeError, zipfile.BadZipFile):
            raise ToolFailure('validation_failed', 'XLSX extension markup could not be inspected') from None

    reject_xlsx_external_formulas(member_names, archive)

def preflight_ooxml(path, format_name, preserving_xlsx=False, inspect_xlsx_formulas=False):
    try:
        with zipfile.ZipFile(str(path), mode='r', allowZip64=True) as archive:
            entries = archive.infolist()
            if not 1 <= len(entries) <= MAXIMUM_OOXML_ENTRIES:
                raise ToolFailure('validation_failed', 'OOXML package entry count exceeds its fixed boundary')
            seen = set()
            member_names = []
            total_uncompressed = 0
            for entry in entries:
                normalized = safe_zip_member_name(entry.filename)
                if normalized in seen:
                    raise ToolFailure('validation_failed', 'OOXML package contains duplicate member names')
                seen.add(normalized)
                member_names.append(entry.filename)
                unix_mode = (entry.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(unix_mode):
                    raise ToolFailure('validation_failed', 'OOXML package contains a symbolic-link member')
                if entry.flag_bits & 0x1:
                    raise ToolFailure('unsupported_feature', 'encrypted OOXML packages are not supported')
                if entry.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                    raise ToolFailure('unsupported_feature', 'OOXML package compression is not supported')
                if (entry.file_size < 0 or entry.compress_size < 0
                        or entry.file_size > MAXIMUM_OOXML_ENTRY_BYTES):
                    raise ToolFailure('validation_failed', 'OOXML package member exceeds its fixed boundary')
                total_uncompressed += entry.file_size
                if total_uncompressed > MAXIMUM_OOXML_TOTAL_BYTES:
                    raise ToolFailure('validation_failed', 'OOXML package exceeds its aggregate expansion boundary')
                if entry.file_size > 1024 * 1024:
                    if entry.compress_size == 0 or entry.file_size / entry.compress_size > MAXIMUM_OOXML_COMPRESSION_RATIO:
                        raise ToolFailure('validation_failed', 'OOXML package compression ratio exceeds its fixed boundary')
            main_parts = {
                'docx': 'word/document.xml',
                'pptx': 'ppt/presentation.xml',
                'xlsx': 'xl/workbook.xml',
            }
            expected_main_part = main_parts.get(format_name)
            present_main_parts = {part for part in main_parts.values() if part in seen}
            if (expected_main_part is None or expected_main_part not in present_main_parts
                    or present_main_parts != {expected_main_part}):
                raise ToolFailure(
                    'validation_failed',
                    'OOXML package does not match the requested document format')
            if preserving_xlsx:
                reject_xlsx_preservation_hazards(member_names, archive)
            elif inspect_xlsx_formulas:
                reject_xlsx_external_formulas(member_names, archive)
    except ToolFailure:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile):
        raise ToolFailure('validation_failed', 'OOXML package central directory is invalid') from None

def bounds(payload):
    maximum_characters = int(payload.get('maximum_characters', 200000))
    maximum_items = int(payload.get('maximum_items', 5000))
    if not 1 <= maximum_characters <= 1000000 or not 1 <= maximum_items <= 20000:
        raise ToolFailure('validation_failed', 'projection bounds are invalid')
    return maximum_characters, maximum_items

class Budget:
    def __init__(self, characters, items):
        self.characters = characters
        self.items = items
        self.used_characters = 0
        self.used_items = 0
        self.truncated = False
    def text(self, value):
        value = '' if value is None else str(value)
        if self.used_items >= self.items:
            self.truncated = True
            return None
        remaining = self.characters - self.used_characters
        if remaining <= 0:
            self.truncated = True
            return None
        encoded = value[:remaining]
        if len(encoded) < len(value):
            self.truncated = True
        self.used_items += 1
        self.used_characters += len(encoded)
        return encoded

def read_markdown(payload):
    allowed_keys = {'format', 'input_path', 'maximum_characters', 'maximum_file_bytes'}
    if set(payload) - allowed_keys or not {'format', 'input_path'} <= set(payload):
        raise ToolFailure('validation_failed', 'document read payload fields are invalid')
    format_name = payload.get('format')
    suffixes = {
        'docx': '.docx',
        'pptx': '.pptx',
        'xlsx': '.xlsx',
        'html': {'.html', '.htm'},
        'epub': '.epub',
    }
    if not isinstance(format_name, str) or format_name not in suffixes:
        raise ToolFailure('unsupported_operation', 'format has no fixed Docling reader')
    path = safe_input(payload, suffixes[format_name])
    if format_name in {'docx', 'pptx', 'xlsx'}:
        preflight_ooxml(path, format_name)

    format_dependencies = {
        'docx': ['python-docx', 'lxml'],
        'pptx': ['python-pptx', 'lxml'],
        'xlsx': ['openpyxl'],
        'html': ['lxml'],
        'epub': ['lxml'],
    }
    versions = require_versions(
        ['docling', 'docling-core', 'docling-parse'] + format_dependencies[format_name])
    from docling.datamodel.backend_options import (
        EpubBackendOptions, HTMLBackendOptions, MsExcelBackendOptions,
        MsPowerpointBackendOptions, MsWordBackendOptions)
    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.datamodel.pipeline_options import ConvertPipelineOptions
    from docling.document_converter import (
        DocumentConverter, EpubFormatOption, ExcelFormatOption, HTMLFormatOption,
        PowerpointFormatOption, WordFormatOption)

    formats = {
        'docx': (InputFormat.DOCX, '.docx', WordFormatOption,
                 MsWordBackendOptions(enable_remote_fetch=False,
                                      enable_local_fetch=False,
                                      render_chart_images=False)),
        'pptx': (InputFormat.PPTX, '.pptx', PowerpointFormatOption,
                 MsPowerpointBackendOptions(enable_remote_fetch=False,
                                            enable_local_fetch=False,
                                            render_chart_images=False)),
        'xlsx': (InputFormat.XLSX, '.xlsx', ExcelFormatOption,
                 MsExcelBackendOptions(enable_remote_fetch=False,
                                       enable_local_fetch=False,
                                       render_chart_images=False)),
        'html': (InputFormat.HTML, {'.html', '.htm'}, HTMLFormatOption,
                 HTMLBackendOptions(enable_remote_fetch=False,
                                    enable_local_fetch=False,
                                    render_page=False,
                                    fetch_images=False)),
        'epub': (InputFormat.EPUB, '.epub', EpubFormatOption,
                 EpubBackendOptions(enable_remote_fetch=False,
                                    enable_local_fetch=False,
                                    fetch_images=False,
                                    max_total_bytes=512 * 1024 * 1024,
                                    max_file_bytes=256 * 1024 * 1024,
                                    max_member_count=20000)),
    }
    input_format, _, option_type, backend_options = formats[format_name]
    maximum_characters = int(payload.get('maximum_characters', 200000))
    maximum_file_bytes = int(payload.get('maximum_file_bytes', 512 * 1024 * 1024))
    if not 1 <= maximum_characters <= 500000 or not 1 <= maximum_file_bytes <= 512 * 1024 * 1024:
        raise ToolFailure('validation_failed', 'document read bounds are invalid')
    pipeline_options = ConvertPipelineOptions(
        document_timeout=240.0,
        enable_remote_services=False,
        allow_external_plugins=False,
        do_picture_classification=False,
        do_picture_description=False,
        do_chart_extraction=False)
    converter = DocumentConverter(
        allowed_formats=[input_format],
        format_options={input_format: option_type(
            pipeline_options=pipeline_options,
            backend_options=backend_options)})
    conversion = converter.convert(
        str(path),
        raises_on_error=True,
        max_num_pages=100000,
        max_file_size=maximum_file_bytes)
    if conversion.status != ConversionStatus.SUCCESS or conversion.errors:
        raise ToolFailure('backend_failed', 'fixed Docling conversion did not complete')
    markdown = conversion.document.export_to_markdown(
        image_placeholder='<!-- image omitted -->',
        traverse_pictures=False)
    truncated = len(markdown) > maximum_characters
    return {'format': format_name,
            'markdown': markdown[:maximum_characters],
            'truncated': truncated}, versions, []

def validate_self_contained_html(tree, input_path, allowed_asset_paths):
    from urllib.parse import urlsplit
    if not isinstance(allowed_asset_paths, list) or len(allowed_asset_paths) > 256:
        raise ToolFailure('validation_failed', 'HTML asset allowlist is invalid')
    allowed_assets = set()
    for raw_path in allowed_asset_paths:
        if not isinstance(raw_path, str) or not os.path.isabs(raw_path):
            raise ToolFailure('validation_failed', 'HTML asset path is invalid')
        candidate = pathlib.Path(raw_path)
        if not candidate.is_file() or candidate.is_symlink():
            raise ToolFailure('validation_failed', 'HTML asset is missing or unsafe')
        allowed_assets.add(str(candidate.resolve()))
    resource_attributes = {'src', 'poster', 'action', 'formaction'}
    for element in tree.iter():
        tag = element.tag.lower() if isinstance(element.tag, str) else ''
        if tag in {'script', 'iframe', 'object', 'embed', 'base', 'link'}:
            raise ToolFailure('unsupported_feature', 'active HTML content is not supported')
        if tag == 'meta' and any(name.lower() == 'http-equiv' for name in element.attrib):
            raise ToolFailure('unsupported_feature', 'HTML protocol directives are not supported')
        for name, raw_value in element.attrib.items():
            value = raw_value.strip()
            lower_name = name.lower()
            if lower_name.startswith('on'):
                raise ToolFailure('unsupported_feature', 'HTML event handlers are not supported')
            if lower_name in {'srcset', 'imagesrcset'}:
                raise ToolFailure('unsupported_feature', 'responsive HTML image sources are not supported')
            if lower_name == 'style' and any(token in value.lower() for token in ('url(', '@import', 'expression(')):
                raise ToolFailure('unsupported_feature', 'CSS resource references are not supported')
            if lower_name == 'href' and tag == 'a' and (value.startswith('#') or not value):
                continue
            if lower_name in {'href', 'xlink:href'} or lower_name in resource_attributes:
                scheme = urlsplit(value).scheme.lower()
                if scheme == 'data' and lower_name == 'src' and tag in {'img', 'source'}:
                    continue
                if lower_name == 'src' and tag in {'img', 'source'} and scheme == '' and not value.startswith('//'):
                    resolved = str((input_path.parent / value).resolve())
                    if resolved in allowed_assets:
                        continue
                raise ToolFailure('unsupported_feature', 'HTML resource is remote, active, or not allowlisted')
        if tag == 'style':
            css = ''.join(element.itertext()).lower()
            if any(token in css for token in ('url(', '@import', 'expression(')):
                raise ToolFailure('unsupported_feature', 'CSS resource references are not supported')

def require_exact_keys(value, allowed, required, label):
    if not isinstance(value, dict) or not set(value) <= set(allowed) or not set(required) <= set(value):
        raise ToolFailure('validation_failed', label + ' fields are invalid')

def require_string(value, label, minimum=0, maximum=1000000):
    if not isinstance(value, str) or not minimum <= len(value) <= maximum or '\x00' in value:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_integer(value, label, minimum=0, maximum=1000000):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_number(value, label, minimum=-1000000000000, maximum=1000000000000):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ToolFailure('validation_failed', label + ' is invalid')
    if not minimum <= value <= maximum:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_boolean(value, label):
    if not isinstance(value, bool):
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_scalar(value, label):
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return require_number(value, label)
    if isinstance(value, str):
        return require_string(value, label, maximum=65536)
    raise ToolFailure('validation_failed', label + ' is invalid')

def require_matrix(value, label, maximum_cells, scalar=False):
    if not isinstance(value, list) or not value or len(value) > maximum_cells:
        raise ToolFailure('validation_failed', label + ' is invalid')
    width = None
    cells = 0
    result = []
    for row in value:
        if not isinstance(row, list) or not row:
            raise ToolFailure('validation_failed', label + ' is invalid')
        if width is None:
            width = len(row)
        if len(row) != width:
            raise ToolFailure('validation_failed', label + ' must be rectangular')
        cells += len(row)
        if cells > maximum_cells:
            raise ToolFailure('validation_failed', label + ' exceeds its cell limit')
        if scalar:
            result.append([require_scalar(item, label) for item in row])
        else:
            result.append([require_string(item, label, maximum=65536) for item in row])
    return result

def safe_output(payload, suffixes):
    path = payload.get('output_path')
    if not isinstance(path, str) or not os.path.isabs(path) or '\x00' in path or len(path) > 4096:
        raise ToolFailure('validation_failed', 'output_path must be an absolute host path')
    candidate = pathlib.Path(path)
    allowed_suffixes = {suffixes} if isinstance(suffixes, str) else set(suffixes)
    if candidate.suffix.lower() not in allowed_suffixes:
        raise ToolFailure('validation_failed', 'output_path has the wrong format')
    if candidate.exists() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'staged output already exists')
    parent = candidate.parent
    if not parent.is_dir() or parent.is_symlink():
        raise ToolFailure('validation_failed', 'staged output parent is unsafe')
    return candidate

def safe_asset(path, allowed_assets=None, image_only=False):
    require_string(path, 'asset path', minimum=1, maximum=4096)
    if not os.path.isabs(path):
        raise ToolFailure('validation_failed', 'asset path must be an absolute host path')
    candidate = pathlib.Path(path)
    if not candidate.is_file() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'asset file is missing or unsafe')
    if image_only and candidate.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff'}:
        raise ToolFailure('unsupported_feature', 'image asset format is not supported')
    resolved = str(candidate.resolve())
    if allowed_assets is not None and resolved not in allowed_assets:
        raise ToolFailure('validation_failed', 'asset path is not in the host allowlist')
    return candidate

def save_package_exclusive(value, output):
    flags = os.O_CREAT | os.O_EXCL | os.O_RDWR
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(str(output), flags, 0o600)
    try:
        with os.fdopen(descriptor, 'w+b') as stream:
            descriptor = -1
            value.save(stream)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)

def write_bytes_exclusive(data, output):
    flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(str(output), flags, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError('short output write')
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def finalize_output(output):
    status = os.lstat(str(output))
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1 or not 0 < status.st_size <= 1073741824:
        raise ToolFailure('validation_failed', 'staged output is not a bounded single-link regular file')
    os.chmod(str(output), 0o600, follow_symlinks=False)

def read_bounded_regular_file(path, maximum_bytes, label):
    flags = os.O_RDONLY
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(path), flags)
    except OSError:
        raise ToolFailure('validation_failed', label + ' is not a safe readable file') from None
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or not 0 < before.st_size <= maximum_bytes):
            raise ToolFailure('validation_failed', label + ' exceeds its fixed safety boundary')
        chunks = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(131072, remaining))
            if not chunk:
                raise ToolFailure('validation_failed', label + ' changed while it was read')
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ToolFailure('validation_failed', label + ' changed while it was read')
        after = os.fstat(descriptor)
        identity = lambda value: (
            value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after):
            raise ToolFailure('validation_failed', label + ' changed while it was read')
        return b''.join(chunks)
    finally:
        os.close(descriptor)

def html_image_media_type(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'image/png'
    if data.startswith(b'\xff\xd8\xff'):
        return 'image/jpeg'
    if data.startswith((b'GIF87a', b'GIF89a')):
        return 'image/gif'
    if len(data) >= 12 and data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        return 'image/webp'
    if data.startswith(b'BM'):
        return 'image/bmp'
    if data.startswith((b'II*\x00', b'MM\x00*')):
        return 'image/tiff'
    raise ToolFailure('unsupported_feature', 'HTML image asset format is not supported')

def prepare_html_render(payload):
    require_exact_keys(
        payload,
        {'input_path', 'output_path', 'allowed_asset_paths'},
        {'input_path', 'output_path', 'allowed_asset_paths'},
        'prepare_html_render payload')
    input_path = safe_input(payload, {'.html', '.htm'})
    output_path = safe_output(payload, {'.html', '.htm'})
    raw_assets = payload.get('allowed_asset_paths')
    if (not isinstance(raw_assets, list) or len(raw_assets) > 256
            or not all(isinstance(path, str) for path in raw_assets)
            or len(set(raw_assets)) != len(raw_assets)):
        raise ToolFailure('validation_failed', 'HTML asset allowlist is invalid')
    allowed_assets = {}
    for raw_path in raw_assets:
        asset = safe_asset(raw_path)
        allowed_assets[str(asset.resolve())] = asset

    versions = require_versions(['lxml'])
    from lxml import etree
    from urllib.parse import unquote, urlsplit
    source = read_bounded_regular_file(input_path, 16 * 1024 * 1024, 'HTML input')
    parser = etree.HTMLParser(no_network=True, recover=False, huge_tree=False)
    try:
        root = etree.fromstring(source, parser)
    except (etree.ParserError, ValueError):
        raise ToolFailure('validation_failed', 'HTML input could not be parsed') from None
    if root is None:
        raise ToolFailure('validation_failed', 'HTML input has no document root')
    tree = etree.ElementTree(root)
    validate_self_contained_html(tree, input_path, raw_assets)

    inlined_count = 0
    aggregate_asset_bytes = 0
    for element in tree.iter():
        tag = element.tag.lower() if isinstance(element.tag, str) else ''
        if tag not in {'img', 'source'} or 'src' not in element.attrib:
            continue
        value = element.attrib['src'].strip()
        parsed = urlsplit(value)
        if parsed.scheme.lower() == 'data':
            continue
        if (parsed.scheme or value.startswith('//') or parsed.query or parsed.fragment
                or not parsed.path):
            raise ToolFailure('unsupported_feature', 'HTML image source is not a fixed local asset')
        try:
            decoded_path = unquote(parsed.path, errors='strict')
        except (UnicodeDecodeError, ValueError):
            raise ToolFailure('validation_failed', 'HTML image source encoding is invalid') from None
        if '\x00' in decoded_path:
            raise ToolFailure('validation_failed', 'HTML image source path is invalid')
        resolved = str((input_path.parent / decoded_path).resolve())
        asset = allowed_assets.get(resolved)
        if asset is None:
            raise ToolFailure('unsupported_feature', 'HTML image source is not allowlisted')
        data = read_bounded_regular_file(asset, 16 * 1024 * 1024, 'HTML image asset')
        aggregate_asset_bytes += len(data)
        if aggregate_asset_bytes > 64 * 1024 * 1024:
            raise ToolFailure('validation_failed', 'HTML image assets exceed the aggregate byte limit')
        media_type = html_image_media_type(data)
        encoded = base64.b64encode(data).decode('ascii')
        element.set('src', 'data:' + media_type + ';base64,' + encoded)
        inlined_count += 1

    validate_self_contained_html(tree, output_path, [])
    serialized = etree.tostring(
        tree,
        encoding='utf-8',
        method='html',
        doctype='<!DOCTYPE html>')
    if not 0 < len(serialized) <= 96 * 1024 * 1024:
        raise ToolFailure('validation_failed', 'sanitized HTML exceeds the fixed byte limit')
    write_bytes_exclusive(serialized, output_path)
    finalize_output(output_path)
    return {
        'format': 'html',
        'sanitized': True,
        'inlined_asset_count': inlined_count,
    }, versions, []

def write_request(payload):
    allowed = {'format', 'mode', 'input_path', 'output_path', 'operations', 'allowed_asset_paths'}
    require_exact_keys(payload, allowed, {'format', 'mode', 'output_path', 'operations'}, 'write payload')
    format_name = payload.get('format')
    if format_name not in {'docx', 'pptx', 'xlsx', 'html'}:
        raise ToolFailure('unsupported_operation', 'format has no fixed Python writer')
    mode = payload.get('mode')
    if mode not in {'create', 'edit'}:
        raise ToolFailure('validation_failed', 'write mode is invalid')
    suffixes = {'.html', '.htm'} if format_name == 'html' else {'.' + format_name}
    if mode == 'create':
        if 'input_path' in payload:
            raise ToolFailure('validation_failed', 'create mode must not include input_path')
        input_path = None
    else:
        if 'input_path' not in payload:
            raise ToolFailure('validation_failed', 'edit mode requires input_path')
        input_path = safe_input(payload, suffixes)
    output_path = safe_output(payload, suffixes)
    operations = payload.get('operations')
    validate_operation_envelopes(operations)
    raw_assets = payload.get('allowed_asset_paths', [])
    if not isinstance(raw_assets, list) or len(raw_assets) > 256 or not all(isinstance(path, str) for path in raw_assets) or len(set(raw_assets)) != len(raw_assets):
        raise ToolFailure('validation_failed', 'host asset allowlist is invalid')
    allowed_assets = {str(safe_asset(path).resolve()) for path in raw_assets}
    return format_name, mode, input_path, output_path, operations, allowed_assets

def validate_operation_envelopes(operations):
    if not isinstance(operations, list) or not 1 <= len(operations) <= 1000:
        raise ToolFailure('validation_failed', 'operations are invalid')
    for operation in operations:
        require_exact_keys(operation, {'kind', 'parameters'}, {'kind', 'parameters'}, 'operation')
        require_string(operation.get('kind'), 'operation kind', minimum=1, maximum=80)
        if not isinstance(operation.get('parameters'), dict):
            raise ToolFailure('validation_failed', 'operation parameters must be an object')

def verify_write_request(payload):
    require_exact_keys(payload, {'format', 'input_path', 'operations', 'allowed_asset_paths'}, {'format', 'input_path', 'operations'}, 'verify_write payload')
    format_name = payload.get('format')
    if format_name not in {'docx', 'pptx', 'xlsx', 'html'}:
        raise ToolFailure('unsupported_operation', 'format has no fixed Python write verifier')
    suffixes = {'.html', '.htm'} if format_name == 'html' else {'.' + format_name}
    input_path = safe_input(payload, suffixes)
    operations = payload.get('operations')
    validate_operation_envelopes(operations)
    raw_assets = payload.get('allowed_asset_paths', [])
    if not isinstance(raw_assets, list) or len(raw_assets) > 256 or not all(isinstance(path, str) for path in raw_assets) or len(set(raw_assets)) != len(raw_assets):
        raise ToolFailure('validation_failed', 'host asset allowlist is invalid')
    allowed_assets = {str(safe_asset(path).resolve()) for path in raw_assets}
    return format_name, input_path, operations, allowed_assets

def indexed(values, index, label, maximum=1000000):
    require_integer(index, label + ' index', 0, maximum)
    if index >= len(values):
        raise ToolFailure('validation_failed', label + ' index is out of range')
    return values[index]

def write_docx(mode, input_path, output_path, operations, allowed_assets):
    versions = require_versions(['python-docx'])
    from docx import Document
    from docx.enum.section import WD_ORIENT
    from docx.shared import Pt
    if mode == 'edit':
        preflight_ooxml(input_path, 'docx')
    document = Document(str(input_path)) if mode == 'edit' else Document()
    try:
        for operation in operations:
            kind = operation['kind']
            parameters = operation['parameters']
            if kind == 'paragraph.add':
                require_exact_keys(parameters, {'text', 'style'}, {'text'}, kind)
                text = require_string(parameters['text'], 'text')
                style = parameters.get('style')
                if style is not None:
                    require_string(style, 'style', minimum=1, maximum=255)
                document.add_paragraph(text, style=style)
            elif kind == 'paragraph.set_text':
                require_exact_keys(parameters, {'paragraph_index', 'text'}, {'paragraph_index', 'text'}, kind)
                paragraph = indexed(document.paragraphs, parameters['paragraph_index'], 'paragraph')
                paragraph.text = require_string(parameters['text'], 'text')
            elif kind == 'run.add':
                require_exact_keys(parameters, {'paragraph_index', 'text', 'bold', 'italic', 'underline', 'style'}, {'paragraph_index', 'text'}, kind)
                paragraph = indexed(document.paragraphs, parameters['paragraph_index'], 'paragraph')
                run = paragraph.add_run(require_string(parameters['text'], 'text'))
                for attribute in ('bold', 'italic', 'underline'):
                    if attribute in parameters:
                        setattr(run, attribute, require_boolean(parameters[attribute], attribute))
                if 'style' in parameters:
                    run.style = require_string(parameters['style'], 'style', minimum=1, maximum=255)
            elif kind == 'table.add':
                require_exact_keys(parameters, {'values', 'style'}, {'values'}, kind)
                values = require_matrix(parameters['values'], 'values', 100000)
                table = document.add_table(rows=len(values), cols=len(values[0]))
                for row_index, row in enumerate(values):
                    for column_index, value in enumerate(row):
                        table.cell(row_index, column_index).text = value
                if 'style' in parameters:
                    table.style = require_string(parameters['style'], 'style', minimum=1, maximum=255)
            elif kind == 'table.set_cell':
                require_exact_keys(parameters, {'table_index', 'row_index', 'column_index', 'text'}, {'table_index', 'row_index', 'column_index', 'text'}, kind)
                table = indexed(document.tables, parameters['table_index'], 'table', 100000)
                row = indexed(table.rows, parameters['row_index'], 'table row')
                cell = indexed(row.cells, parameters['column_index'], 'table column', 16384)
                cell.text = require_string(parameters['text'], 'text')
            elif kind == 'image.add':
                require_exact_keys(parameters, {'path', 'paragraph_index', 'width_points', 'height_points'}, {'path'}, kind)
                asset = safe_asset(parameters['path'], allowed_assets, image_only=True)
                if 'paragraph_index' in parameters:
                    paragraph = indexed(document.paragraphs, parameters['paragraph_index'], 'paragraph')
                else:
                    paragraph = document.add_paragraph()
                width = Pt(require_number(parameters['width_points'], 'width_points', 0.1, 100000)) if 'width_points' in parameters else None
                height = Pt(require_number(parameters['height_points'], 'height_points', 0.1, 100000)) if 'height_points' in parameters else None
                paragraph.add_run().add_picture(str(asset), width=width, height=height)
            elif kind in {'header.set_text', 'footer.set_text'}:
                require_exact_keys(parameters, {'section_index', 'text'}, {'section_index', 'text'}, kind)
                section = indexed(document.sections, parameters['section_index'], 'section', 100000)
                container = section.header if kind == 'header.set_text' else section.footer
                text = require_string(parameters['text'], 'text')
                for paragraph in container.paragraphs:
                    paragraph.text = ''
                container.paragraphs[0].text = text
            elif kind == 'section.set':
                allowed = {'section_index', 'orientation', 'margin_top_points', 'margin_right_points', 'margin_bottom_points', 'margin_left_points'}
                require_exact_keys(parameters, allowed, {'section_index'}, kind)
                if len(parameters) == 1:
                    raise ToolFailure('validation_failed', 'section.set requires a property')
                section = indexed(document.sections, parameters['section_index'], 'section', 100000)
                if 'orientation' in parameters:
                    orientation = parameters['orientation']
                    if orientation not in {'portrait', 'landscape'}:
                        raise ToolFailure('validation_failed', 'orientation is invalid')
                    width, height = section.page_width, section.page_height
                    section.orientation = WD_ORIENT.LANDSCAPE if orientation == 'landscape' else WD_ORIENT.PORTRAIT
                    if width is not None and height is not None:
                        section.page_width = max(width, height) if orientation == 'landscape' else min(width, height)
                        section.page_height = min(width, height) if orientation == 'landscape' else max(width, height)
                margin_map = {
                    'margin_top_points': 'top_margin', 'margin_right_points': 'right_margin',
                    'margin_bottom_points': 'bottom_margin', 'margin_left_points': 'left_margin',
                }
                for field, attribute in margin_map.items():
                    if field in parameters:
                        setattr(section, attribute, Pt(require_number(parameters[field], field, 0, 2000)))
            else:
                raise ToolFailure('unsupported_operation', 'DOCX operation is not allowlisted')
    except ToolFailure:
        raise
    except (IndexError, KeyError, TypeError, ValueError):
        raise ToolFailure('validation_failed', 'DOCX operation could not be applied') from None
    save_package_exclusive(document, output_path)
    finalize_output(output_path)
    return {'format': 'docx', 'mode': mode, 'applied_operations': len(operations)}, versions, []

def slide_at(presentation, index):
    require_integer(index, 'slide index', 0, 100000)
    if index >= len(presentation.slides):
        raise ToolFailure('validation_failed', 'slide index is out of range')
    return presentation.slides[index]

def point_value(parameters, name):
    from pptx.util import Pt
    return Pt(require_number(parameters[name], name, 0.1 if name in {'width_points', 'height_points'} else 0, 100000))

def write_pptx(mode, input_path, output_path, operations, allowed_assets):
    versions = require_versions(['python-pptx'])
    from pptx import Presentation
    from pptx.chart.data import ChartData
    from pptx.enum.chart import XL_CHART_TYPE
    from pptx.enum.shapes import MSO_SHAPE
    from pptx.util import Inches
    if mode == 'edit':
        preflight_ooxml(input_path, 'pptx')
    presentation = Presentation(str(input_path)) if mode == 'edit' else Presentation()
    coordinate_fields = {'x_points', 'y_points', 'width_points', 'height_points'}
    try:
        for operation in operations:
            kind = operation['kind']
            parameters = operation['parameters']
            if kind == 'slide.add':
                require_exact_keys(parameters, {'layout_index', 'title'}, set(), kind)
                default_layout = min(6, len(presentation.slide_layouts) - 1)
                layout_index = require_integer(parameters.get('layout_index', default_layout), 'layout_index', 0, 1000)
                layout = indexed(presentation.slide_layouts, layout_index, 'slide layout', 1000)
                slide = presentation.slides.add_slide(layout)
                if 'title' in parameters:
                    title = require_string(parameters['title'], 'title', maximum=100000)
                    if slide.shapes.title is not None:
                        slide.shapes.title.text = title
                    else:
                        slide.shapes.add_textbox(Inches(0.5), Inches(0.3), Inches(9), Inches(0.6)).text_frame.text = title
            elif kind == 'text.set':
                require_exact_keys(parameters, {'slide_index', 'shape_index', 'text'}, {'slide_index', 'shape_index', 'text'}, kind)
                slide = slide_at(presentation, parameters['slide_index'])
                shape = indexed(slide.shapes, parameters['shape_index'], 'shape', 100000)
                if not getattr(shape, 'has_text_frame', False):
                    raise ToolFailure('unsupported_feature', 'selected shape has no text frame')
                shape.text_frame.text = require_string(parameters['text'], 'text')
            elif kind == 'shape.add':
                allowed = coordinate_fields | {'slide_index', 'shape_type', 'text'}
                required = coordinate_fields | {'slide_index', 'shape_type'}
                require_exact_keys(parameters, allowed, required, kind)
                slide = slide_at(presentation, parameters['slide_index'])
                shape_type = parameters['shape_type']
                if shape_type not in {'rectangle', 'rounded_rectangle', 'ellipse', 'line'}:
                    raise ToolFailure('validation_failed', 'shape_type is invalid')
                x, y = point_value(parameters, 'x_points'), point_value(parameters, 'y_points')
                width, height = point_value(parameters, 'width_points'), point_value(parameters, 'height_points')
                shape_types = {
                    'rectangle': MSO_SHAPE.RECTANGLE,
                    'rounded_rectangle': MSO_SHAPE.ROUNDED_RECTANGLE,
                    'ellipse': MSO_SHAPE.OVAL,
                    'line': MSO_SHAPE.LINE_INVERSE,
                }
                shape = slide.shapes.add_shape(shape_types[shape_type], x, y, width, height)
                if 'text' in parameters:
                    shape.text_frame.text = require_string(parameters['text'], 'text', maximum=100000)
            elif kind == 'image.add':
                allowed = coordinate_fields | {'slide_index', 'path'}
                required = allowed
                require_exact_keys(parameters, allowed, required, kind)
                slide = slide_at(presentation, parameters['slide_index'])
                asset = safe_asset(parameters['path'], allowed_assets, image_only=True)
                slide.shapes.add_picture(str(asset), point_value(parameters, 'x_points'), point_value(parameters, 'y_points'), point_value(parameters, 'width_points'), point_value(parameters, 'height_points'))
            elif kind == 'table.add':
                allowed = coordinate_fields | {'slide_index', 'values'}
                required = allowed
                require_exact_keys(parameters, allowed, required, kind)
                slide = slide_at(presentation, parameters['slide_index'])
                values = require_matrix(parameters['values'], 'values', 10000)
                table = slide.shapes.add_table(len(values), len(values[0]), point_value(parameters, 'x_points'), point_value(parameters, 'y_points'), point_value(parameters, 'width_points'), point_value(parameters, 'height_points')).table
                for row_index, row in enumerate(values):
                    for column_index, value in enumerate(row):
                        table.cell(row_index, column_index).text = value
            elif kind == 'chart.add':
                allowed = coordinate_fields | {'slide_index', 'chart_type', 'categories', 'series_name', 'values', 'title'}
                required = coordinate_fields | {'slide_index', 'chart_type', 'categories', 'series_name', 'values'}
                require_exact_keys(parameters, allowed, required, kind)
                slide = slide_at(presentation, parameters['slide_index'])
                chart_type = parameters['chart_type']
                chart_types = {
                    'column': XL_CHART_TYPE.COLUMN_CLUSTERED, 'bar': XL_CHART_TYPE.BAR_CLUSTERED,
                    'line': XL_CHART_TYPE.LINE, 'pie': XL_CHART_TYPE.PIE,
                }
                if chart_type not in chart_types:
                    raise ToolFailure('validation_failed', 'chart_type is invalid')
                categories = parameters['categories']
                values = parameters['values']
                if not isinstance(categories, list) or not isinstance(values, list) or not categories or len(categories) != len(values) or len(categories) > 10000:
                    raise ToolFailure('validation_failed', 'chart data is invalid')
                categories = [require_string(value, 'category', maximum=65536) for value in categories]
                values = [require_number(value, 'chart value') for value in values]
                data = ChartData()
                data.categories = categories
                data.add_series(require_string(parameters['series_name'], 'series_name', minimum=1, maximum=255), values)
                chart = slide.shapes.add_chart(chart_types[chart_type], point_value(parameters, 'x_points'), point_value(parameters, 'y_points'), point_value(parameters, 'width_points'), point_value(parameters, 'height_points'), data).chart
                if 'title' in parameters:
                    chart.has_title = True
                    chart.chart_title.text_frame.text = require_string(parameters['title'], 'title', maximum=10000)
            else:
                raise ToolFailure('unsupported_operation', 'PPTX operation is not allowlisted')
    except ToolFailure:
        raise
    except (IndexError, KeyError, TypeError, ValueError):
        raise ToolFailure('validation_failed', 'PPTX operation could not be applied') from None
    save_package_exclusive(presentation, output_path)
    finalize_output(output_path)
    return {'format': 'pptx', 'mode': mode, 'applied_operations': len(operations)}, versions, []

def require_sheet_name(value, label='sheet'):
    value = require_string(value, label, minimum=1, maximum=31)
    if any(character in value for character in '[]:*?/\\') or value == "'":
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_identifier(value, label):
    value = require_string(value, label, minimum=1, maximum=255)
    if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]*', value) is None:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def reject_external_spreadsheet_text(value):
    upper = value.upper()
    forbidden = (
        'HTTP://', 'HTTPS://', 'FILE://', 'FTP://', 'SFTP://', '\\\\',
        'WEBSERVICE(', 'RTD(', 'DDE(', 'CALL(', 'REGISTER.ID(',
    )
    if (any(token in upper for token in forbidden)
            or re.search(r'\[[^\]]+\][^!]{0,255}!', upper)
            or re.search(r'\|[^!]{0,512}!', upper)):
        raise ToolFailure('unsupported_feature', 'external workbook references are not supported')

def require_spreadsheet_scalar(value, label):
    value = require_scalar(value, label)
    if isinstance(value, str) and value.startswith('='):
        reject_external_spreadsheet_text(value)
    return value

def cell_coordinate(value, label):
    from openpyxl.utils.cell import coordinate_to_tuple
    value = require_string(value, label, minimum=2, maximum=16)
    if re.fullmatch(r'\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}', value) is None:
        raise ToolFailure('validation_failed', label + ' is invalid')
    row, column = coordinate_to_tuple(value.replace('$', ''))
    if row > 1048576 or column > 16384:
        raise ToolFailure('validation_failed', label + ' exceeds XLSX bounds')
    return value.replace('$', '').upper()

def range_coordinates(value, label, maximum_cells=100000):
    from openpyxl.utils.cell import range_boundaries
    value = require_string(value, label, minimum=5, maximum=40)
    parts = value.split(':')
    if len(parts) != 2:
        raise ToolFailure('validation_failed', label + ' is invalid')
    start, end = cell_coordinate(parts[0], label), cell_coordinate(parts[1], label)
    min_col, min_row, max_col, max_row = range_boundaries(start + ':' + end)
    if min_col > max_col or min_row > max_row or (max_col - min_col + 1) * (max_row - min_row + 1) > maximum_cells:
        raise ToolFailure('validation_failed', label + ' is invalid or too large')
    return start + ':' + end, (min_col, min_row, max_col, max_row)

def workbook_sheet(workbook, name):
    name = require_sheet_name(name)
    if name not in workbook.sheetnames:
        raise ToolFailure('validation_failed', 'worksheet does not exist')
    return workbook[name]

def write_xlsx(mode, input_path, output_path, operations, allowed_assets):
    versions = require_versions(['openpyxl'])
    from openpyxl import Workbook, load_workbook
    from openpyxl.chart import AreaChart, BarChart, LineChart, PieChart, Reference, ScatterChart, Series
    from openpyxl.styles import PatternFill
    from openpyxl.worksheet.table import Table, TableStyleInfo
    from openpyxl.workbook.defined_name import DefinedName
    if mode == 'edit':
        preflight_ooxml(input_path, 'xlsx', preserving_xlsx=True)
    workbook = load_workbook(str(input_path), read_only=False, data_only=False, keep_links=False) if mode == 'edit' else Workbook()
    try:
        for operation in operations:
            kind = operation['kind']
            parameters = operation['parameters']
            if kind == 'sheet.add':
                require_exact_keys(parameters, {'name'}, {'name'}, kind)
                name = require_sheet_name(parameters['name'], 'name')
                if name in workbook.sheetnames:
                    raise ToolFailure('validation_failed', 'worksheet already exists')
                workbook.create_sheet(title=name)
            elif kind == 'sheet.rename':
                require_exact_keys(parameters, {'current_name', 'new_name'}, {'current_name', 'new_name'}, kind)
                current_name = require_sheet_name(parameters['current_name'], 'current_name')
                new_name = require_sheet_name(parameters['new_name'], 'new_name')
                if current_name not in workbook.sheetnames or new_name in workbook.sheetnames:
                    raise ToolFailure('validation_failed', 'worksheet rename is invalid')
                workbook[current_name].title = new_name
            elif kind == 'cell.set':
                require_exact_keys(parameters, {'sheet', 'cell', 'value'}, {'sheet', 'cell', 'value'}, kind)
                sheet = workbook_sheet(workbook, parameters['sheet'])
                sheet[cell_coordinate(parameters['cell'], 'cell')] = require_spreadsheet_scalar(parameters['value'], 'value')
            elif kind == 'range.set':
                require_exact_keys(parameters, {'sheet', 'start_cell', 'values'}, {'sheet', 'start_cell', 'values'}, kind)
                sheet = workbook_sheet(workbook, parameters['sheet'])
                start = cell_coordinate(parameters['start_cell'], 'start_cell')
                from openpyxl.utils.cell import coordinate_to_tuple
                start_row, start_column = coordinate_to_tuple(start)
                values = require_matrix(parameters['values'], 'values', 100000, scalar=True)
                if start_row + len(values) - 1 > 1048576 or start_column + len(values[0]) - 1 > 16384:
                    raise ToolFailure('validation_failed', 'range.set exceeds XLSX bounds')
                for row_offset, row in enumerate(values):
                    for column_offset, value in enumerate(row):
                        sheet.cell(start_row + row_offset, start_column + column_offset).value = require_spreadsheet_scalar(value, 'value')
            elif kind == 'style.set':
                allowed = {'sheet', 'range', 'bold', 'italic', 'font_color', 'fill_color', 'number_format', 'horizontal_alignment', 'vertical_alignment'}
                require_exact_keys(parameters, allowed, {'sheet', 'range'}, kind)
                if len(parameters) == 2:
                    raise ToolFailure('validation_failed', 'style.set requires a style property')
                sheet = workbook_sheet(workbook, parameters['sheet'])
                _, boundaries = range_coordinates(parameters['range'], 'range')
                min_col, min_row, max_col, max_row = boundaries
                for row in sheet.iter_rows(min_row=min_row, max_row=max_row, min_col=min_col, max_col=max_col):
                    for cell in row:
                        if 'bold' in parameters or 'italic' in parameters or 'font_color' in parameters:
                            font = copy(cell.font)
                            if 'bold' in parameters:
                                font.bold = require_boolean(parameters['bold'], 'bold')
                            if 'italic' in parameters:
                                font.italic = require_boolean(parameters['italic'], 'italic')
                            if 'font_color' in parameters:
                                color = require_string(parameters['font_color'], 'font_color', minimum=6, maximum=7).lstrip('#')
                                if re.fullmatch(r'[A-Fa-f0-9]{6}', color) is None:
                                    raise ToolFailure('validation_failed', 'font_color is invalid')
                                font.color = 'FF' + color.upper()
                            cell.font = font
                        if 'fill_color' in parameters:
                            color = require_string(parameters['fill_color'], 'fill_color', minimum=6, maximum=7).lstrip('#')
                            if re.fullmatch(r'[A-Fa-f0-9]{6}', color) is None:
                                raise ToolFailure('validation_failed', 'fill_color is invalid')
                            cell.fill = PatternFill(fill_type='solid', fgColor='FF' + color.upper())
                        if 'number_format' in parameters:
                            cell.number_format = require_string(parameters['number_format'], 'number_format', minimum=1, maximum=255)
                        if 'horizontal_alignment' in parameters or 'vertical_alignment' in parameters:
                            alignment = copy(cell.alignment)
                            if 'horizontal_alignment' in parameters:
                                horizontal = parameters['horizontal_alignment']
                                if horizontal not in {'general', 'left', 'center', 'right', 'fill', 'justify'}:
                                    raise ToolFailure('validation_failed', 'horizontal_alignment is invalid')
                                alignment.horizontal = horizontal
                            if 'vertical_alignment' in parameters:
                                vertical = parameters['vertical_alignment']
                                if vertical not in {'top', 'center', 'bottom', 'justify'}:
                                    raise ToolFailure('validation_failed', 'vertical_alignment is invalid')
                                alignment.vertical = vertical
                            cell.alignment = alignment
            elif kind == 'table.add':
                require_exact_keys(parameters, {'sheet', 'range', 'name', 'style'}, {'sheet', 'range', 'name'}, kind)
                sheet = workbook_sheet(workbook, parameters['sheet'])
                reference, _ = range_coordinates(parameters['range'], 'range')
                name = require_identifier(parameters['name'], 'name')
                table = Table(displayName=name, ref=reference)
                if 'style' in parameters:
                    table.tableStyleInfo = TableStyleInfo(name=require_string(parameters['style'], 'style', minimum=1, maximum=255), showFirstColumn=False, showLastColumn=False, showRowStripes=True, showColumnStripes=False)
                sheet.add_table(table)
            elif kind == 'name.set':
                require_exact_keys(parameters, {'name', 'reference'}, {'name', 'reference'}, kind)
                name = require_identifier(parameters['name'], 'name')
                reference = require_string(parameters['reference'], 'reference', minimum=3, maximum=512)
                reject_external_spreadsheet_text(reference)
                workbook.defined_names[name] = DefinedName(name, attr_text=reference)
            elif kind == 'chart.add':
                require_exact_keys(parameters, {'sheet', 'chart_type', 'data_range', 'category_range', 'anchor', 'title'}, {'sheet', 'chart_type', 'data_range', 'anchor'}, kind)
                sheet = workbook_sheet(workbook, parameters['sheet'])
                chart_type = parameters['chart_type']
                chart_classes = {
                    'column': BarChart, 'bar': BarChart, 'line': LineChart,
                    'pie': PieChart, 'area': AreaChart, 'scatter': ScatterChart,
                }
                if chart_type not in chart_classes:
                    raise ToolFailure('validation_failed', 'chart_type is invalid')
                _, data_bounds = range_coordinates(parameters['data_range'], 'data_range')
                min_col, min_row, max_col, max_row = data_bounds
                data = Reference(sheet, min_col=min_col, min_row=min_row, max_col=max_col, max_row=max_row)
                chart = chart_classes[chart_type]()
                categories = None
                if 'category_range' in parameters:
                    _, category_bounds = range_coordinates(parameters['category_range'], 'category_range')
                    cat_min_col, cat_min_row, cat_max_col, cat_max_row = category_bounds
                    categories = Reference(sheet, min_col=cat_min_col, min_row=cat_min_row, max_col=cat_max_col, max_row=cat_max_row)
                if chart_type == 'scatter' and categories is not None:
                    chart.series.append(Series(data, categories))
                else:
                    chart.add_data(data, titles_from_data=False)
                    if categories is not None:
                        chart.set_categories(categories)
                if chart_type == 'column':
                    chart.type = 'col'
                elif chart_type == 'bar':
                    chart.type = 'bar'
                if 'title' in parameters:
                    chart.title = require_string(parameters['title'], 'title', maximum=10000)
                sheet.add_chart(chart, cell_coordinate(parameters['anchor'], 'anchor'))
            else:
                raise ToolFailure('unsupported_operation', 'XLSX operation is not allowlisted')
    except ToolFailure:
        raise
    except (IndexError, KeyError, TypeError, ValueError):
        raise ToolFailure('validation_failed', 'XLSX operation could not be applied') from None
    save_package_exclusive(workbook, output_path)
    workbook.close()
    finalize_output(output_path)
    return {'format': 'xlsx', 'mode': mode, 'applied_operations': len(operations), 'requires_calc_recalculation': True}, versions, []

def html_selection(tree, expression, expected_count):
    from lxml import etree
    expression = require_string(expression, 'xpath', minimum=1, maximum=2048)
    if not expression.startswith(('/', '.')):
        raise ToolFailure('validation_failed', 'xpath must start at a document or relative context')
    expected_count = require_integer(expected_count, 'expected_match_count', 1, 10000)
    try:
        values = tree.xpath(expression)
    except etree.XPathError:
        raise ToolFailure('validation_failed', 'xpath is invalid') from None
    if not isinstance(values, list) or len(values) != expected_count or not all(isinstance(value, etree._Element) for value in values):
        raise ToolFailure('validation_failed', 'xpath did not match the exact expected element count')
    return values

def append_html_fragment(target, fragment):
    from lxml import etree, html
    try:
        values = html.fragments_fromstring(fragment)
    except (etree.ParserError, ValueError):
        raise ToolFailure('validation_failed', 'HTML fragment is invalid') from None
    for value in values:
        if isinstance(value, str):
            if len(target):
                target[-1].tail = (target[-1].tail or '') + value
            else:
                target.text = (target.text or '') + value
        else:
            target.append(value)

def reject_write_html_fragment(fragment):
    lower = fragment.lower()
    forbidden = (
        '<script', 'javascript:', 'vbscript:', 'data:', 'http://', 'https://',
        'srcdoc=', 'src="//', "src='//", 'href="//', "href='//", 'url(//', '@import',
    )
    if any(token in lower for token in forbidden) or re.search(r'\son[a-z0-9_-]+\s*=', lower):
        raise ToolFailure('unsupported_feature', 'active or remote HTML fragments are not supported')

def validate_write_html_attribute(name, value):
    if (re.fullmatch(r'[A-Za-z_:][A-Za-z0-9_.:-]*', name) is None
            or name.lower().startswith('on')
            or name.lower() in {'srcdoc', 'srcset', 'imagesrcset'}):
        raise ToolFailure('unsupported_feature', 'HTML attribute is not supported')
    if name.lower() in {'href', 'src', 'action', 'formaction', 'poster', 'xlink:href'}:
        lower = value.strip().lower()
        if lower.startswith(('http://', 'https://', '//', 'javascript:', 'vbscript:', 'data:')):
            raise ToolFailure('unsupported_feature', 'remote or executable HTML references are not supported')

def write_html(mode, input_path, output_path, operations, allowed_assets):
    versions = require_versions(['lxml'])
    from lxml import etree, html
    parser = etree.HTMLParser(no_network=True, recover=False, huge_tree=False)
    if mode == 'edit':
        try:
            tree = etree.parse(str(input_path), parser)
        except (etree.ParserError, OSError):
            raise ToolFailure('validation_failed', 'HTML input could not be parsed') from None
        resource_base = input_path
        validate_self_contained_html(tree, resource_base, list(allowed_assets))
    else:
        root = html.document_fromstring('<!DOCTYPE html><html><head><meta charset="utf-8"></head><body></body></html>', parser=parser)
        tree = etree.ElementTree(root)
        resource_base = output_path
    for operation in operations:
        kind = operation['kind']
        parameters = operation['parameters']
        base = {'xpath', 'expected_match_count'}
        if kind == 'xpath.set_text':
            require_exact_keys(parameters, base | {'text'}, base | {'text'}, kind)
            selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
            text = require_string(parameters['text'], 'text')
            for element in selected:
                for child in list(element):
                    element.remove(child)
                element.text = text
        elif kind == 'xpath.set_attribute':
            require_exact_keys(parameters, base | {'name', 'value'}, base | {'name', 'value'}, kind)
            selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
            name = require_string(parameters['name'], 'name', minimum=1, maximum=255)
            value = require_string(parameters['value'], 'value')
            validate_write_html_attribute(name, value)
            for element in selected:
                element.set(name, value)
        elif kind == 'xpath.append':
            require_exact_keys(parameters, base | {'html'}, base | {'html'}, kind)
            selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
            fragment = require_string(parameters['html'], 'html', minimum=1)
            reject_write_html_fragment(fragment)
            for element in selected:
                append_html_fragment(element, fragment)
        elif kind == 'xpath.remove':
            require_exact_keys(parameters, base, base, kind)
            selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
            for element in selected:
                parent = element.getparent()
                if parent is None:
                    raise ToolFailure('unsupported_feature', 'HTML document root cannot be removed')
                parent.remove(element)
        else:
            raise ToolFailure('unsupported_operation', 'HTML operation is not allowlisted')
        validate_self_contained_html(tree, resource_base, list(allowed_assets))
    data = etree.tostring(tree, method='html', encoding='utf-8', doctype='<!DOCTYPE html>')
    write_bytes_exclusive(data, output_path)
    finalize_output(output_path)
    return {'format': 'html', 'mode': mode, 'applied_operations': len(operations)}, versions, []

def write_native(payload):
    format_name, mode, input_path, output_path, operations, allowed_assets = write_request(payload)
    if format_name == 'docx':
        return write_docx(mode, input_path, output_path, operations, allowed_assets)
    if format_name == 'pptx':
        return write_pptx(mode, input_path, output_path, operations, allowed_assets)
    if format_name == 'xlsx':
        return write_xlsx(mode, input_path, output_path, operations, allowed_assets)
    if format_name == 'html':
        return write_html(mode, input_path, output_path, operations, allowed_assets)
    raise ToolFailure('unsupported_operation', 'format has no fixed Python writer')

def validate_xlsx_verify_operations(operations):
    for operation in operations:
        kind = operation['kind']
        parameters = operation['parameters']
        if kind == 'sheet.add':
            require_exact_keys(parameters, {'name'}, {'name'}, kind)
            require_sheet_name(parameters['name'], 'name')
        elif kind == 'sheet.rename':
            require_exact_keys(parameters, {'current_name', 'new_name'}, {'current_name', 'new_name'}, kind)
            require_sheet_name(parameters['current_name'], 'current_name')
            require_sheet_name(parameters['new_name'], 'new_name')
        elif kind == 'cell.set':
            require_exact_keys(parameters, {'sheet', 'cell', 'value'}, {'sheet', 'cell', 'value'}, kind)
            require_sheet_name(parameters['sheet'])
            cell_coordinate(parameters['cell'], 'cell')
            require_spreadsheet_scalar(parameters['value'], 'value')
        elif kind == 'range.set':
            require_exact_keys(parameters, {'sheet', 'start_cell', 'values'}, {'sheet', 'start_cell', 'values'}, kind)
            require_sheet_name(parameters['sheet'])
            start = cell_coordinate(parameters['start_cell'], 'start_cell')
            from openpyxl.utils.cell import coordinate_to_tuple
            start_row, start_column = coordinate_to_tuple(start)
            values = require_matrix(parameters['values'], 'values', 100000, scalar=True)
            if start_row + len(values) - 1 > 1048576 or start_column + len(values[0]) - 1 > 16384:
                raise ToolFailure('validation_failed', 'range.set exceeds XLSX bounds')
            for row in values:
                for value in row:
                    require_spreadsheet_scalar(value, 'value')
        elif kind == 'style.set':
            allowed = {'sheet', 'range', 'bold', 'italic', 'font_color', 'fill_color', 'number_format', 'horizontal_alignment', 'vertical_alignment'}
            require_exact_keys(parameters, allowed, {'sheet', 'range'}, kind)
            if len(parameters) == 2:
                raise ToolFailure('validation_failed', 'style.set requires a style property')
            require_sheet_name(parameters['sheet'])
            range_coordinates(parameters['range'], 'range')
            for field in ('bold', 'italic'):
                if field in parameters:
                    require_boolean(parameters[field], field)
            for field in ('font_color', 'fill_color'):
                if field in parameters:
                    color = require_string(parameters[field], field, minimum=6, maximum=7).lstrip('#')
                    if re.fullmatch(r'[A-Fa-f0-9]{6}', color) is None:
                        raise ToolFailure('validation_failed', field + ' is invalid')
            if 'number_format' in parameters:
                require_string(parameters['number_format'], 'number_format', minimum=1, maximum=255)
            if 'horizontal_alignment' in parameters and parameters['horizontal_alignment'] not in {'general', 'left', 'center', 'right', 'fill', 'justify'}:
                raise ToolFailure('validation_failed', 'horizontal_alignment is invalid')
            if 'vertical_alignment' in parameters and parameters['vertical_alignment'] not in {'top', 'center', 'bottom', 'justify'}:
                raise ToolFailure('validation_failed', 'vertical_alignment is invalid')
        elif kind == 'table.add':
            require_exact_keys(parameters, {'sheet', 'range', 'name', 'style'}, {'sheet', 'range', 'name'}, kind)
            require_sheet_name(parameters['sheet'])
            range_coordinates(parameters['range'], 'range')
            require_identifier(parameters['name'], 'name')
            if 'style' in parameters:
                require_string(parameters['style'], 'style', minimum=1, maximum=255)
        elif kind == 'name.set':
            require_exact_keys(parameters, {'name', 'reference'}, {'name', 'reference'}, kind)
            require_identifier(parameters['name'], 'name')
            reference = require_string(parameters['reference'], 'reference', minimum=3, maximum=512)
            reject_external_spreadsheet_text(reference)
        elif kind == 'chart.add':
            require_exact_keys(parameters, {'sheet', 'chart_type', 'data_range', 'category_range', 'anchor', 'title'}, {'sheet', 'chart_type', 'data_range', 'anchor'}, kind)
            require_sheet_name(parameters['sheet'])
            if parameters['chart_type'] not in {'column', 'bar', 'line', 'pie', 'area', 'scatter'}:
                raise ToolFailure('validation_failed', 'chart_type is invalid')
            range_coordinates(parameters['data_range'], 'data_range')
            if 'category_range' in parameters:
                range_coordinates(parameters['category_range'], 'category_range')
            cell_coordinate(parameters['anchor'], 'anchor')
            if 'title' in parameters:
                require_string(parameters['title'], 'title', maximum=10000)
        else:
            raise ToolFailure('unsupported_operation', 'XLSX verification operation is not allowlisted')

def final_sheet_name(name, operation_index, operations):
    resolved = name
    for future in operations[operation_index + 1:]:
        if future['kind'] == 'sheet.rename' and future['parameters']['current_name'] == resolved:
            resolved = future['parameters']['new_name']
    return resolved

def spreadsheet_scalar_matches(actual, expected):
    if expected is None:
        return actual is None
    if isinstance(expected, bool):
        return isinstance(actual, bool) and actual == expected
    if isinstance(expected, (int, float)) and not isinstance(expected, bool):
        return isinstance(actual, (int, float)) and not isinstance(actual, bool) and float(actual) == float(expected)
    return isinstance(actual, str) and actual == expected

def normalized_rgb(color):
    if color is None:
        return None
    color_type = getattr(color, 'type', None)
    value = getattr(color, 'rgb', None)
    if color_type == 'rgb' and isinstance(value, str) and len(value) in {6, 8}:
        return value[-6:].upper()
    if color_type == 'indexed':
        from openpyxl.styles.colors import COLOR_INDEX
        indexed = getattr(color, 'indexed', None)
        if isinstance(indexed, int) and 0 <= indexed < len(COLOR_INDEX):
            return COLOR_INDEX[indexed][-6:].upper()
    return None

def bounded_file_sha256(path, label):
    return hashlib.sha256(
        read_bounded_regular_file(path, 64 * 1024 * 1024, label)).hexdigest()

def normalized_a1_reference(value):
    return ''.join(value.upper().replace('$', '').replace("'", '').split())

def defined_name_semantics(value):
    try:
        destinations = list(value.destinations)
    except (AttributeError, TypeError, ValueError):
        destinations = []
    if destinations:
        return ('destinations', tuple(sorted(
            (sheet.upper(), normalized_a1_reference(reference))
            for sheet, reference in destinations)))
    return ('expression', normalized_a1_reference(value.attr_text or ''))

def chart_type_name(chart):
    class_name = type(chart).__name__
    if class_name == 'BarChart':
        return 'bar' if getattr(chart, 'type', None) == 'bar' else 'column'
    return {
        'LineChart': 'line', 'PieChart': 'pie', 'AreaChart': 'area',
        'ScatterChart': 'scatter',
    }.get(class_name)

def data_source_formula(source):
    if source is None:
        return None
    for attribute in ('numRef', 'strRef'):
        reference = getattr(source, attribute, None)
        formula = getattr(reference, 'f', None) if reference is not None else None
        if isinstance(formula, str):
            return normalized_a1_reference(formula)
    return None

def chart_formula_sets(chart):
    data = set()
    categories = set()
    for series in chart.series:
        for attribute in ('val', 'yVal'):
            formula = data_source_formula(getattr(series, attribute, None))
            if formula:
                data.add(formula)
        for attribute in ('cat', 'xVal'):
            formula = data_source_formula(getattr(series, attribute, None))
            if formula:
                categories.add(formula)
    return data, categories

def expected_chart_data_references(sheet_name, range_value, chart_type):
    from openpyxl.utils.cell import get_column_letter
    _, boundaries = range_coordinates(range_value, 'data_range')
    min_col, min_row, max_col, max_row = boundaries
    if chart_type == 'scatter':
        ranges = [range_value]
    else:
        ranges = [
            get_column_letter(column) + str(min_row) + ':' + get_column_letter(column) + str(max_row)
            for column in range(min_col, max_col + 1)
        ]
    return {normalized_a1_reference(sheet_name + '!' + value) for value in ranges}

def chart_anchor_cell(chart):
    from openpyxl.utils.cell import get_column_letter
    anchor = getattr(chart, 'anchor', None)
    marker = getattr(anchor, '_from', None)
    row = getattr(marker, 'row', None)
    column = getattr(marker, 'col', None)
    if not isinstance(row, int) or not isinstance(column, int):
        return None
    return get_column_letter(column + 1) + str(row + 1)

def openpyxl_chart_title_text(chart):
    title = getattr(chart, 'title', None)
    rich = getattr(getattr(title, 'tx', None), 'rich', None)
    paragraphs = getattr(rich, 'p', None)
    if not isinstance(paragraphs, list):
        return None
    result = []
    for paragraph in paragraphs:
        for run in getattr(paragraph, 'r', []) or []:
            text = getattr(run, 't', None)
            if isinstance(text, str):
                result.append(text)
        for field in getattr(paragraph, 'fld', []) or []:
            text = getattr(field, 't', None)
            if isinstance(text, str):
                result.append(text)
    return ''.join(result)

def verify_xlsx_write(input_path, operations):
    preflight_ooxml(input_path, 'xlsx', inspect_xlsx_formulas=True)
    versions = require_versions(['openpyxl'])
    from openpyxl import load_workbook
    from openpyxl.utils.cell import coordinate_to_tuple, get_column_letter
    from openpyxl.workbook.defined_name import DefinedName
    validate_xlsx_verify_operations(operations)
    workbook = load_workbook(str(input_path), read_only=False, data_only=False, keep_links=False)
    cached_workbook = load_workbook(
        str(input_path), read_only=True, data_only=True, keep_links=False)
    try:
        for index, operation in enumerate(operations):
            parameters = operation['parameters']
            if operation['kind'] == 'sheet.add':
                expected = final_sheet_name(parameters['name'], index, operations)
                if expected not in workbook.sheetnames:
                    raise ToolFailure('validation_failed', 'declared worksheet addition is missing')
            elif operation['kind'] == 'sheet.rename':
                expected = final_sheet_name(parameters['new_name'], index, operations)
                if expected not in workbook.sheetnames:
                    raise ToolFailure('validation_failed', 'declared worksheet rename is missing')

        expected_values = {}
        expected_styles = {}
        for index, operation in enumerate(operations):
            kind = operation['kind']
            parameters = operation['parameters']
            if kind not in {'cell.set', 'range.set', 'style.set'}:
                continue
            sheet_name = final_sheet_name(parameters['sheet'], index, operations)
            if sheet_name not in workbook.sheetnames:
                raise ToolFailure('validation_failed', 'declared worksheet target is missing')
            if kind == 'cell.set':
                expected_values[(sheet_name, cell_coordinate(parameters['cell'], 'cell'))] = parameters['value']
            elif kind == 'range.set':
                start_row, start_column = coordinate_to_tuple(cell_coordinate(parameters['start_cell'], 'start_cell'))
                for row_offset, row in enumerate(parameters['values']):
                    for column_offset, value in enumerate(row):
                        coordinate = get_column_letter(start_column + column_offset) + str(start_row + row_offset)
                        expected_values[(sheet_name, coordinate)] = value
            else:
                _, boundaries = range_coordinates(parameters['range'], 'range')
                min_col, min_row, max_col, max_row = boundaries
                properties = {key: value for key, value in parameters.items() if key not in {'sheet', 'range'}}
                for row in range(min_row, max_row + 1):
                    for column in range(min_col, max_col + 1):
                        coordinate = get_column_letter(column) + str(row)
                        expected_styles.setdefault((sheet_name, coordinate), {}).update(properties)

        for (sheet_name, coordinate), expected in expected_values.items():
            if not spreadsheet_scalar_matches(workbook[sheet_name][coordinate].value, expected):
                raise ToolFailure('validation_failed', 'declared XLSX cell value or formula was not preserved')
            if isinstance(expected, str) and expected.startswith('='):
                try:
                    cached_cell = cached_workbook[sheet_name][coordinate]
                    cached_value = cached_cell.value
                except (KeyError, IndexError, TypeError, ValueError):
                    raise ToolFailure(
                        'unsupported_feature',
                        'XLSX formula cache cannot be read reliably') from None
                if cached_value is None or cached_cell.data_type == 'f':
                    raise ToolFailure(
                        'unsupported_feature',
                        'XLSX formula has no readable cached calculation result')

        for (sheet_name, coordinate), expected in expected_styles.items():
            cell = workbook[sheet_name][coordinate]
            if 'bold' in expected and bool(cell.font.bold) != expected['bold']:
                raise ToolFailure('validation_failed', 'declared XLSX bold style was not preserved')
            if 'italic' in expected and bool(cell.font.italic) != expected['italic']:
                raise ToolFailure('validation_failed', 'declared XLSX italic style was not preserved')
            if 'font_color' in expected and normalized_rgb(cell.font.color) != expected['font_color'].lstrip('#').upper():
                raise ToolFailure('validation_failed', 'declared XLSX font color was not preserved')
            if 'fill_color' in expected and normalized_rgb(cell.fill.fgColor) != expected['fill_color'].lstrip('#').upper():
                raise ToolFailure('validation_failed', 'declared XLSX fill color was not preserved')
            if 'number_format' in expected and cell.number_format != expected['number_format']:
                raise ToolFailure('validation_failed', 'declared XLSX number format was not preserved')
            if 'horizontal_alignment' in expected and cell.alignment.horizontal != expected['horizontal_alignment']:
                raise ToolFailure('validation_failed', 'declared XLSX horizontal alignment was not preserved')
            if 'vertical_alignment' in expected and cell.alignment.vertical != expected['vertical_alignment']:
                raise ToolFailure('validation_failed', 'declared XLSX vertical alignment was not preserved')

        expected_names = {}
        for operation in operations:
            if operation['kind'] == 'name.set':
                expected_names[operation['parameters']['name']] = operation['parameters']['reference']
        for name, reference in expected_names.items():
            actual = workbook.defined_names.get(name)
            expected = DefinedName(name, attr_text=reference)
            if actual is None or defined_name_semantics(actual) != defined_name_semantics(expected):
                raise ToolFailure('validation_failed', 'declared XLSX defined name was not preserved')

        used_charts = set()
        for index, operation in enumerate(operations):
            kind = operation['kind']
            parameters = operation['parameters']
            if kind == 'table.add':
                sheet_name = final_sheet_name(parameters['sheet'], index, operations)
                sheet = workbook_sheet(workbook, sheet_name)
                table = sheet.tables.get(parameters['name'])
                if table is None or normalized_a1_reference(table.ref) != normalized_a1_reference(parameters['range']):
                    raise ToolFailure('validation_failed', 'declared XLSX table is missing or has the wrong range')
                if 'style' in parameters and (
                        table.tableStyleInfo is None
                        or table.tableStyleInfo.name != parameters['style']):
                    raise ToolFailure(
                        'unsupported_feature',
                        'XLSX table style could not be preserved exactly')
            elif kind == 'name.set':
                continue
            elif kind == 'chart.add':
                sheet_name = final_sheet_name(parameters['sheet'], index, operations)
                sheet = workbook_sheet(workbook, sheet_name)
                expected_data = expected_chart_data_references(sheet_name, parameters['data_range'], parameters['chart_type'])
                expected_categories = None
                if 'category_range' in parameters:
                    expected_categories = {normalized_a1_reference(sheet_name + '!' + parameters['category_range'])}
                match = None
                for chart_index, chart in enumerate(getattr(sheet, '_charts', [])):
                    if (sheet_name, chart_index) in used_charts:
                        continue
                    data, categories = chart_formula_sets(chart)
                    if chart_type_name(chart) != parameters['chart_type'] or chart_anchor_cell(chart) != cell_coordinate(parameters['anchor'], 'anchor'):
                        continue
                    if data != expected_data or categories != (expected_categories or set()):
                        continue
                    actual_title = openpyxl_chart_title_text(chart)
                    if ('title' in parameters and actual_title != parameters['title']) or (
                            'title' not in parameters and actual_title not in {None, ''}):
                        continue
                    match = chart_index
                    break
                if match is None:
                    raise ToolFailure('validation_failed', 'declared XLSX chart type, anchor, or data references were not preserved')
                used_charts.add((sheet_name, match))
    finally:
        cached_workbook.close()
        workbook.close()
    return {'format': 'xlsx', 'verified_count': len(operations)}, versions, []

def verify_docx_write(input_path, operations, allowed_assets):
    preflight_ooxml(input_path, 'docx')
    versions = require_versions(['python-docx'])
    from docx import Document
    document = Document(str(input_path))
    appended_paragraphs = sum(
        1 for operation in operations
        if operation['kind'] == 'paragraph.add'
        or (operation['kind'] == 'image.add' and 'paragraph_index' not in operation['parameters']))
    added_tables = sum(1 for operation in operations if operation['kind'] == 'table.add')
    initial_paragraph_count = len(document.paragraphs) - appended_paragraphs
    initial_table_count = len(document.tables) - added_tables
    if min(initial_paragraph_count, initial_table_count) < 0:
        raise ToolFailure('validation_failed', 'DOCX structural additions are missing')
    next_paragraph = initial_paragraph_count
    next_table = initial_table_count
    paragraph_state = {}
    table_state = {}
    image_expectations = []
    header_state = {}
    footer_state = {}
    section_state = {}
    for operation in operations:
        kind = operation['kind']
        parameters = operation['parameters']
        if kind == 'paragraph.add':
            require_exact_keys(parameters, {'text', 'style'}, {'text'}, kind)
            text = require_string(parameters['text'], 'text')
            style = parameters.get('style')
            if style is not None:
                require_string(style, 'style', minimum=1, maximum=255)
            paragraph_state[next_paragraph] = {'text': text, 'style': style, 'runs': []}
            next_paragraph += 1
        elif kind == 'paragraph.set_text':
            require_exact_keys(parameters, {'paragraph_index', 'text'}, {'paragraph_index', 'text'}, kind)
            index = require_integer(parameters['paragraph_index'], 'paragraph_index')
            if index >= len(document.paragraphs):
                raise ToolFailure('validation_failed', 'declared DOCX paragraph is missing')
            state = paragraph_state.setdefault(index, {'text': None, 'style': None, 'runs': []})
            state['text'] = require_string(parameters['text'], 'text')
            state['runs'] = []
            image_expectations = [
                expectation for expectation in image_expectations
                if expectation['paragraph_index'] != index]
        elif kind == 'run.add':
            require_exact_keys(parameters, {'paragraph_index', 'text', 'bold', 'italic', 'underline', 'style'}, {'paragraph_index', 'text'}, kind)
            index = require_integer(parameters['paragraph_index'], 'paragraph_index')
            if index >= len(document.paragraphs):
                raise ToolFailure('validation_failed', 'declared DOCX paragraph is missing')
            run = {'text': require_string(parameters['text'], 'text')}
            for field in ('bold', 'italic', 'underline'):
                if field in parameters:
                    run[field] = require_boolean(parameters[field], field)
            if 'style' in parameters:
                run['style'] = require_string(parameters['style'], 'style', minimum=1, maximum=255)
            state = paragraph_state.setdefault(index, {'text': None, 'style': None, 'runs': []})
            if state['text'] is not None:
                state['text'] += run['text']
            state['runs'].append(run)
        elif kind == 'table.add':
            require_exact_keys(parameters, {'values', 'style'}, {'values'}, kind)
            values = require_matrix(parameters['values'], 'values', 100000)
            style = parameters.get('style')
            if style is not None:
                require_string(style, 'style', minimum=1, maximum=255)
            table_state[next_table] = {'values': [list(row) for row in values], 'style': style}
            next_table += 1
        elif kind == 'table.set_cell':
            require_exact_keys(parameters, {'table_index', 'row_index', 'column_index', 'text'}, {'table_index', 'row_index', 'column_index', 'text'}, kind)
            table_index = require_integer(parameters['table_index'], 'table_index', 0, 100000)
            row_index = require_integer(parameters['row_index'], 'row_index')
            column_index = require_integer(parameters['column_index'], 'column_index', 0, 16384)
            text = require_string(parameters['text'], 'text')
            if table_index >= len(document.tables) or row_index >= len(document.tables[table_index].rows) or column_index >= len(document.tables[table_index].columns):
                raise ToolFailure('validation_failed', 'declared DOCX table cell is missing')
            state = table_state.get(table_index)
            if state is not None and row_index < len(state['values']) and column_index < len(state['values'][row_index]):
                state['values'][row_index][column_index] = text
            else:
                table_state.setdefault(table_index, {'values': None, 'style': None})
                table_state[table_index].setdefault('cells', {})[(row_index, column_index)] = text
        elif kind == 'image.add':
            require_exact_keys(parameters, {'path', 'paragraph_index', 'width_points', 'height_points'}, {'path'}, kind)
            asset = safe_asset(parameters['path'], allowed_assets, image_only=True)
            if 'paragraph_index' in parameters:
                paragraph_index = require_integer(parameters['paragraph_index'], 'paragraph_index')
                if paragraph_index >= len(document.paragraphs):
                    raise ToolFailure('validation_failed', 'declared DOCX image paragraph is missing')
            else:
                paragraph_index = next_paragraph
                paragraph_state.setdefault(next_paragraph, {'text': '', 'style': None, 'runs': []})
                next_paragraph += 1
            expectation = {
                'paragraph_index': paragraph_index,
                'digest': bounded_file_sha256(asset, 'DOCX image asset'),
            }
            if 'width_points' in parameters:
                expectation['width_points'] = require_number(parameters['width_points'], 'width_points', 0.1, 100000)
            if 'height_points' in parameters:
                expectation['height_points'] = require_number(parameters['height_points'], 'height_points', 0.1, 100000)
            image_expectations.append(expectation)
        elif kind in {'header.set_text', 'footer.set_text'}:
            require_exact_keys(parameters, {'section_index', 'text'}, {'section_index', 'text'}, kind)
            section_index = require_integer(parameters['section_index'], 'section_index', 0, 100000)
            if section_index >= len(document.sections):
                raise ToolFailure('validation_failed', 'declared DOCX section is missing')
            target = header_state if kind == 'header.set_text' else footer_state
            target[section_index] = require_string(parameters['text'], 'text')
        elif kind == 'section.set':
            allowed = {'section_index', 'orientation', 'margin_top_points', 'margin_right_points', 'margin_bottom_points', 'margin_left_points'}
            require_exact_keys(parameters, allowed, {'section_index'}, kind)
            if len(parameters) == 1:
                raise ToolFailure('validation_failed', 'section.set requires a property')
            section_index = require_integer(parameters['section_index'], 'section_index', 0, 100000)
            if section_index >= len(document.sections):
                raise ToolFailure('validation_failed', 'declared DOCX section is missing')
            state = section_state.setdefault(section_index, {})
            if 'orientation' in parameters:
                if parameters['orientation'] not in {'portrait', 'landscape'}:
                    raise ToolFailure('validation_failed', 'orientation is invalid')
                state['orientation'] = parameters['orientation']
            for field in ('margin_top_points', 'margin_right_points', 'margin_bottom_points', 'margin_left_points'):
                if field in parameters:
                    state[field] = require_number(parameters[field], field, 0, 2000)
        else:
            raise ToolFailure('unsupported_operation', 'DOCX verification operation is not allowlisted')

    for index, expected in paragraph_state.items():
        paragraph = document.paragraphs[index]
        if expected['text'] is not None and paragraph.text != expected['text']:
            raise ToolFailure('validation_failed', 'declared DOCX paragraph text was not preserved')
        if expected['style'] is not None and (paragraph.style is None or paragraph.style.name != expected['style']):
            raise ToolFailure('validation_failed', 'declared DOCX paragraph style was not preserved')
        used_runs = set()
        for expected_run in expected['runs']:
            match = None
            for run_index, run in enumerate(paragraph.runs):
                if run_index in used_runs or run.text != expected_run['text']:
                    continue
                if any(getattr(run, field) != expected_run[field] for field in ('bold', 'italic', 'underline') if field in expected_run):
                    continue
                if 'style' in expected_run and (run.style is None or run.style.name != expected_run['style']):
                    continue
                match = run_index
                break
            if match is None:
                raise ToolFailure('validation_failed', 'declared DOCX run was not preserved')
            used_runs.add(match)

    for index, expected in table_state.items():
        table = document.tables[index]
        if expected.get('values') is not None:
            for row_index, row in enumerate(expected['values']):
                for column_index, value in enumerate(row):
                    if table.cell(row_index, column_index).text != value:
                        raise ToolFailure('validation_failed', 'declared DOCX table value was not preserved')
        for (row_index, column_index), value in expected.get('cells', {}).items():
            if table.cell(row_index, column_index).text != value:
                raise ToolFailure('validation_failed', 'declared DOCX table cell was not preserved')
        if expected.get('style') is not None and (table.style is None or table.style.name != expected['style']):
            raise ToolFailure('validation_failed', 'declared DOCX table style was not preserved')

    paragraph_indexes = {id(paragraph._p): index for index, paragraph in enumerate(document.paragraphs)}
    actual_images = []
    for shape in document.inline_shapes:
        node = shape._inline
        while node is not None and not str(node.tag).endswith('}p'):
            node = node.getparent()
        paragraph_index = paragraph_indexes.get(id(node)) if node is not None else None
        try:
            relationship_id = shape._inline.graphic.graphicData.pic.blipFill.blip.embed
            blob = document.part.related_parts[relationship_id].blob
        except (AttributeError, KeyError):
            raise ToolFailure('unsupported_feature', 'DOCX image relationship cannot be verified') from None
        actual_images.append({
            'paragraph_index': paragraph_index,
            'digest': hashlib.sha256(blob).hexdigest(),
            'width_points': float(shape.width) / 12700.0,
            'height_points': float(shape.height) / 12700.0,
        })
    used_images = set()
    for expected in image_expectations:
        match = None
        for image_index, actual in enumerate(actual_images):
            if image_index in used_images:
                continue
            if (actual['paragraph_index'] != expected['paragraph_index']
                    or actual['digest'] != expected['digest']):
                continue
            if ('width_points' in expected
                    and abs(actual['width_points'] - expected['width_points']) > 0.02):
                continue
            if ('height_points' in expected
                    and abs(actual['height_points'] - expected['height_points']) > 0.02):
                continue
            match = image_index
            break
        if match is None:
            raise ToolFailure('validation_failed', 'declared DOCX image content, placement, or geometry was not preserved')
        used_images.add(match)

    for index, text in header_state.items():
        actual = '\n'.join(paragraph.text for paragraph in document.sections[index].header.paragraphs if paragraph.text)
        if actual != text:
            raise ToolFailure('validation_failed', 'declared DOCX header was not preserved')
    for index, text in footer_state.items():
        actual = '\n'.join(paragraph.text for paragraph in document.sections[index].footer.paragraphs if paragraph.text)
        if actual != text:
            raise ToolFailure('validation_failed', 'declared DOCX footer was not preserved')
    margin_attributes = {
        'margin_top_points': 'top_margin', 'margin_right_points': 'right_margin',
        'margin_bottom_points': 'bottom_margin', 'margin_left_points': 'left_margin',
    }
    for index, expected in section_state.items():
        section = document.sections[index]
        if expected.get('orientation') == 'landscape' and not section.page_width > section.page_height:
            raise ToolFailure('validation_failed', 'declared DOCX landscape orientation was not preserved')
        if expected.get('orientation') == 'portrait' and not section.page_height >= section.page_width:
            raise ToolFailure('validation_failed', 'declared DOCX portrait orientation was not preserved')
        for field, attribute in margin_attributes.items():
            if field in expected and abs(float(getattr(section, attribute)) / 12700.0 - expected[field]) > 0.02:
                raise ToolFailure('validation_failed', 'declared DOCX section margin was not preserved')
    return {'format': 'docx', 'verified_count': len(operations)}, versions, []

def pptx_geometry_matches(shape, parameters):
    fields = {
        'x_points': 'left', 'y_points': 'top',
        'width_points': 'width', 'height_points': 'height',
    }
    return all(
        abs(float(getattr(shape, attribute)) / 12700.0 - float(parameters[field])) <= 0.02
        for field, attribute in fields.items())

def verify_pptx_write(input_path, operations, allowed_assets):
    preflight_ooxml(input_path, 'pptx')
    versions = require_versions(['python-pptx'])
    from pptx import Presentation
    from pptx.enum.chart import XL_CHART_TYPE
    from pptx.enum.shapes import MSO_SHAPE
    presentation = Presentation(str(input_path))
    added_slides = sum(1 for operation in operations if operation['kind'] == 'slide.add')
    initial_slide_count = len(presentation.slides) - added_slides
    if initial_slide_count < 0:
        raise ToolFailure('validation_failed', 'PPTX slide additions are missing')
    next_slide = initial_slide_count
    added_slide_indexes = {}
    text_expectations = {}
    shape_expectations = []
    used_shapes = set()
    coordinate_fields = {'x_points', 'y_points', 'width_points', 'height_points'}
    chart_types = {
        'column': XL_CHART_TYPE.COLUMN_CLUSTERED, 'bar': XL_CHART_TYPE.BAR_CLUSTERED,
        'line': XL_CHART_TYPE.LINE, 'pie': XL_CHART_TYPE.PIE,
    }
    shape_types = {
        'rectangle': MSO_SHAPE.RECTANGLE,
        'rounded_rectangle': MSO_SHAPE.ROUNDED_RECTANGLE,
        'ellipse': MSO_SHAPE.OVAL,
        'line': MSO_SHAPE.LINE_INVERSE,
    }
    for operation_index, operation in enumerate(operations):
        kind = operation['kind']
        parameters = operation['parameters']
        if kind == 'slide.add':
            require_exact_keys(parameters, {'layout_index', 'title'}, set(), kind)
            expected_layout = require_integer(
                parameters.get('layout_index', min(6, len(presentation.slide_layouts) - 1)),
                'layout_index', 0, 1000)
            if expected_layout >= len(presentation.slide_layouts):
                raise ToolFailure('validation_failed', 'declared PPTX slide layout is missing')
            if 'title' in parameters:
                require_string(parameters['title'], 'title', maximum=100000)
            if next_slide >= len(presentation.slides):
                raise ToolFailure('validation_failed', 'declared PPTX slide is missing')
            slide = presentation.slides[next_slide]
            actual_layout = next((layout_index for layout_index, layout in enumerate(presentation.slide_layouts)
                                  if layout.part.partname == slide.slide_layout.part.partname), None)
            if actual_layout != expected_layout:
                raise ToolFailure('validation_failed', 'declared PPTX slide layout was not preserved')
            added_slide_indexes[operation_index] = next_slide
            if 'title' in parameters:
                title_shape = slide.shapes.title
                if title_shape is not None:
                    title_index = list(slide.shapes).index(title_shape)
                else:
                    fallback_geometry = {
                        'x_points': 36.0, 'y_points': 21.6,
                        'width_points': 648.0, 'height_points': 43.2,
                    }
                    matching_textboxes = [
                        (shape_index, shape) for shape_index, shape in enumerate(slide.shapes)
                        if type(shape).__name__ == 'Shape'
                        and getattr(shape, 'has_text_frame', False)
                        and pptx_geometry_matches(shape, fallback_geometry)]
                    if len(matching_textboxes) != 1:
                        raise ToolFailure(
                            'unsupported_feature',
                            'PPTX fallback title textbox cannot be identified exactly')
                    title_index, title_shape = matching_textboxes[0]
                later_override = any(
                    future['kind'] == 'text.set'
                    and future['parameters'].get('slide_index') == next_slide
                    and future['parameters'].get('shape_index') == title_index
                    for future in operations[operation_index + 1:])
                if not later_override and title_shape.text != parameters['title']:
                    raise ToolFailure('validation_failed', 'declared PPTX slide title was not preserved')
            next_slide += 1
        elif kind == 'text.set':
            require_exact_keys(parameters, {'slide_index', 'shape_index', 'text'}, {'slide_index', 'shape_index', 'text'}, kind)
            slide_index = require_integer(parameters['slide_index'], 'slide_index', 0, 100000)
            shape_index = require_integer(parameters['shape_index'], 'shape_index', 0, 100000)
            require_string(parameters['text'], 'text')
            if slide_index >= len(presentation.slides) or shape_index >= len(presentation.slides[slide_index].shapes):
                raise ToolFailure('validation_failed', 'declared PPTX text shape is missing')
            text_expectations[(slide_index, shape_index)] = parameters['text']
        elif kind == 'shape.add':
            allowed = coordinate_fields | {'slide_index', 'shape_type', 'text'}
            required = coordinate_fields | {'slide_index', 'shape_type'}
            require_exact_keys(parameters, allowed, required, kind)
            slide_index = require_integer(parameters['slide_index'], 'slide_index', 0, 100000)
            if parameters['shape_type'] not in shape_types:
                raise ToolFailure('validation_failed', 'shape_type is invalid')
            for field in coordinate_fields:
                require_number(parameters[field], field, 0.1 if field in {'width_points', 'height_points'} else 0, 100000)
            if 'text' in parameters:
                require_string(parameters['text'], 'text', maximum=100000)
            shape_expectations.append(('shape', slide_index, operation_index, dict(parameters)))
        elif kind == 'image.add':
            allowed = coordinate_fields | {'slide_index', 'path'}
            require_exact_keys(parameters, allowed, allowed, kind)
            slide_index = require_integer(parameters['slide_index'], 'slide_index', 0, 100000)
            asset = safe_asset(parameters['path'], allowed_assets, image_only=True)
            for field in coordinate_fields:
                require_number(parameters[field], field, 0.1 if field in {'width_points', 'height_points'} else 0, 100000)
            expected = dict(parameters)
            expected['_asset_digest'] = bounded_file_sha256(asset, 'PPTX image asset')
            shape_expectations.append(('image', slide_index, operation_index, expected))
        elif kind == 'table.add':
            allowed = coordinate_fields | {'slide_index', 'values'}
            require_exact_keys(parameters, allowed, allowed, kind)
            slide_index = require_integer(parameters['slide_index'], 'slide_index', 0, 100000)
            require_matrix(parameters['values'], 'values', 10000)
            for field in coordinate_fields:
                require_number(parameters[field], field, 0.1 if field in {'width_points', 'height_points'} else 0, 100000)
            shape_expectations.append(('table', slide_index, operation_index, dict(parameters)))
        elif kind == 'chart.add':
            allowed = coordinate_fields | {'slide_index', 'chart_type', 'categories', 'series_name', 'values', 'title'}
            required = coordinate_fields | {'slide_index', 'chart_type', 'categories', 'series_name', 'values'}
            require_exact_keys(parameters, allowed, required, kind)
            slide_index = require_integer(parameters['slide_index'], 'slide_index', 0, 100000)
            if parameters['chart_type'] not in chart_types:
                raise ToolFailure('validation_failed', 'chart_type is invalid')
            categories, values = parameters['categories'], parameters['values']
            if not isinstance(categories, list) or not isinstance(values, list) or not categories or len(categories) != len(values) or len(categories) > 10000:
                raise ToolFailure('validation_failed', 'chart data is invalid')
            for value in categories:
                require_string(value, 'category', maximum=65536)
            for value in values:
                require_number(value, 'chart value')
            require_string(parameters['series_name'], 'series_name', minimum=1, maximum=255)
            if 'title' in parameters:
                require_string(parameters['title'], 'title', maximum=10000)
            for field in coordinate_fields:
                require_number(parameters[field], field, 0.1 if field in {'width_points', 'height_points'} else 0, 100000)
            shape_expectations.append(('chart', slide_index, operation_index, dict(parameters)))
        else:
            raise ToolFailure('unsupported_operation', 'PPTX verification operation is not allowlisted')

    for (slide_index, shape_index), text in text_expectations.items():
        shape = presentation.slides[slide_index].shapes[shape_index]
        if not getattr(shape, 'has_text_frame', False) or shape.text != text:
            raise ToolFailure('validation_failed', 'declared PPTX text was not preserved')

    for expected_kind, slide_index, operation_index, parameters in shape_expectations:
        if slide_index >= len(presentation.slides):
            raise ToolFailure('validation_failed', 'declared PPTX slide target is missing')
        match = None
        for shape_index, shape in enumerate(presentation.slides[slide_index].shapes):
            if (slide_index, shape_index) in used_shapes or not pptx_geometry_matches(shape, parameters):
                continue
            if expected_kind == 'shape':
                if getattr(shape, 'auto_shape_type', None) != shape_types[parameters['shape_type']]:
                    continue
                expected_text = parameters.get('text')
                for future in operations[operation_index + 1:]:
                    if (future['kind'] == 'text.set'
                            and future['parameters'].get('slide_index') == slide_index
                            and future['parameters'].get('shape_index') == shape_index):
                        expected_text = future['parameters']['text']
                if expected_text is not None and (not getattr(shape, 'has_text_frame', False) or shape.text != expected_text):
                    continue
            elif expected_kind == 'image':
                if (type(shape).__name__ != 'Picture'
                        or hashlib.sha256(shape.image.blob).hexdigest() != parameters['_asset_digest']):
                    continue
            elif expected_kind == 'table':
                if not getattr(shape, 'has_table', False):
                    continue
                actual = [[cell.text for cell in row.cells] for row in shape.table.rows]
                if actual != parameters['values']:
                    continue
            elif expected_kind == 'chart':
                if not getattr(shape, 'has_chart', False) or shape.chart.chart_type != chart_types[parameters['chart_type']]:
                    continue
                if len(shape.chart.series) != 1:
                    continue
                series = shape.chart.series[0]
                if series.name != parameters['series_name']:
                    continue
                actual_values = list(series.values)
                if (len(actual_values) != len(parameters['values'])
                        or any(actual is None or float(actual) != float(expected)
                               for actual, expected in zip(actual_values, parameters['values']))):
                    continue
                try:
                    actual_categories = [str(value) for value in shape.chart.plots[0].categories]
                except (AttributeError, IndexError, TypeError):
                    continue
                if actual_categories != parameters['categories']:
                    continue
                if 'title' in parameters and (
                        not shape.chart.has_title
                        or shape.chart.chart_title.text_frame.text != parameters['title']):
                    continue
                if 'title' not in parameters and shape.chart.has_title:
                    continue
            match = shape_index
            break
        if match is None:
            raise ToolFailure('validation_failed', 'declared PPTX shape, image, table, or chart was not preserved')
        used_shapes.add((slide_index, match))
    return {'format': 'pptx', 'verified_count': len(operations)}, versions, []

def html_element_signature(element):
    return (
        element.tag,
        tuple(sorted(element.attrib.items())),
        element.text or '',
        element.tail or '',
        tuple(html_element_signature(child) for child in element),
    )

def final_html_xpath(tree, expression):
    from lxml import etree
    expression = require_string(expression, 'xpath', minimum=1, maximum=2048)
    if not expression.startswith(('/', '.')):
        raise ToolFailure('validation_failed', 'xpath must start at a document or relative context')
    try:
        values = tree.xpath(expression)
    except etree.XPathError:
        raise ToolFailure('validation_failed', 'xpath is invalid') from None
    if not isinstance(values, list) or not all(isinstance(value, etree._Element) for value in values):
        raise ToolFailure('unsupported_feature', 'HTML XPath does not have element postconditions')
    return values

def html_descends_from(element, ancestor):
    node = element
    while node is not None:
        if node is ancestor:
            return True
        node = node.getparent()
    return False

def apply_future_html_root_edits(tree, root, expected, operations):
    for future in operations:
        kind = future['kind']
        parameters = future['parameters']
        if kind not in {'xpath.set_text', 'xpath.set_attribute', 'xpath.append'}:
            continue
        selected = final_html_xpath(tree, parameters.get('xpath'))
        if root not in selected:
            if any(html_descends_from(value, root) for value in selected):
                raise ToolFailure(
                    'unsupported_feature',
                    'HTML appended descendant edits cannot be verified exactly')
            continue
        if kind == 'xpath.set_text':
            for child in list(expected):
                expected.remove(child)
            expected.text = parameters['text']
        elif kind == 'xpath.set_attribute':
            expected.set(parameters['name'], parameters['value'])
        else:
            append_html_fragment(expected, parameters['html'])
    return expected

def validate_html_verify_operations(operations):
    for operation in operations:
        kind = operation['kind']
        parameters = operation['parameters']
        base = {'xpath', 'expected_match_count'}
        if kind == 'xpath.set_text':
            require_exact_keys(parameters, base | {'text'}, base | {'text'}, kind)
            require_string(parameters['text'], 'text')
        elif kind == 'xpath.set_attribute':
            require_exact_keys(parameters, base | {'name', 'value'}, base | {'name', 'value'}, kind)
            name = require_string(parameters['name'], 'name', minimum=1, maximum=255)
            value = require_string(parameters['value'], 'value')
            validate_write_html_attribute(name, value)
        elif kind == 'xpath.append':
            require_exact_keys(parameters, base | {'html'}, base | {'html'}, kind)
            reject_write_html_fragment(require_string(parameters['html'], 'html', minimum=1))
        elif kind == 'xpath.remove':
            require_exact_keys(parameters, base, base, kind)
        else:
            raise ToolFailure('unsupported_operation', 'HTML verification operation is not allowlisted')
        require_string(parameters['xpath'], 'xpath', minimum=1, maximum=2048)
        require_integer(parameters['expected_match_count'], 'expected_match_count', 1, 10000)

def verify_html_write(input_path, operations, allowed_assets):
    versions = require_versions(['lxml'])
    from lxml import etree, html
    parser = etree.HTMLParser(no_network=True, recover=False, huge_tree=False)
    try:
        tree = etree.parse(str(input_path), parser)
    except (etree.ParserError, OSError):
        raise ToolFailure('validation_failed', 'HTML output could not be reopened') from None
    validate_self_contained_html(tree, input_path, list(allowed_assets))
    validate_html_verify_operations(operations)
    for operation_index, operation in enumerate(operations):
        kind = operation['kind']
        parameters = operation['parameters']
        base = {'xpath', 'expected_match_count'}
        if kind == 'xpath.set_text':
            require_exact_keys(parameters, base | {'text'}, base | {'text'}, kind)
            text = require_string(parameters['text'], 'text')
            later_replacement = any(
                future['kind'] in {'xpath.set_text', 'xpath.remove'}
                and future['parameters'].get('xpath') == parameters['xpath']
                for future in operations[operation_index + 1:])
            if not later_replacement:
                selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
                later_append = any(
                    future['kind'] == 'xpath.append'
                    and future['parameters'].get('xpath') == parameters['xpath']
                    for future in operations[operation_index + 1:])
                if any(element.text != text or (not later_append and len(element) != 0) for element in selected):
                    raise ToolFailure('validation_failed', 'declared HTML text replacement was not preserved')
        elif kind == 'xpath.set_attribute':
            require_exact_keys(parameters, base | {'name', 'value'}, base | {'name', 'value'}, kind)
            name = require_string(parameters['name'], 'name', minimum=1, maximum=255)
            value = require_string(parameters['value'], 'value')
            validate_write_html_attribute(name, value)
            later_replacement = any(
                (future['kind'] == 'xpath.remove'
                 and future['parameters'].get('xpath') == parameters['xpath'])
                or (future['kind'] == 'xpath.set_attribute'
                    and future['parameters'].get('xpath') == parameters['xpath']
                    and future['parameters'].get('name') == name)
                for future in operations[operation_index + 1:])
            if not later_replacement:
                selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
                if any(element.get(name) != value for element in selected):
                    raise ToolFailure('validation_failed', 'declared HTML attribute was not preserved')
        elif kind == 'xpath.append':
            require_exact_keys(parameters, base | {'html'}, base | {'html'}, kind)
            fragment = require_string(parameters['html'], 'html', minimum=1)
            reject_write_html_fragment(fragment)
            later_target_replacement = any(
                future['kind'] in {'xpath.set_text', 'xpath.remove'}
                and future['parameters'].get('xpath') == parameters['xpath']
                for future in operations[operation_index + 1:])
            if not later_target_replacement:
                selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
                try:
                    fragments = html.fragments_fromstring(fragment)
                except (etree.ParserError, ValueError):
                    raise ToolFailure('validation_failed', 'HTML fragment is invalid') from None
                for target in selected:
                    used_children = set()
                    for value in fragments:
                        if isinstance(value, str):
                            if any(
                                    future['kind'] == 'xpath.append'
                                    and future['parameters'].get('xpath') == parameters['xpath']
                                    for future in operations[operation_index + 1:]):
                                raise ToolFailure(
                                    'unsupported_feature',
                                    'consecutive plain-text HTML appends cannot be verified exactly')
                            final_text_slot = target[-1].tail if len(target) else target.text
                            if not (final_text_slot or '').endswith(value):
                                raise ToolFailure('validation_failed', 'declared HTML appended text was not preserved')
                        else:
                            match = None
                            for child_index, child in enumerate(target):
                                if child_index in used_children or child.tag != value.tag:
                                    continue
                                expected = apply_future_html_root_edits(
                                    tree,
                                    child,
                                    deepcopy(value),
                                    operations[operation_index + 1:])
                                if html_element_signature(child) == html_element_signature(expected):
                                    match = child_index
                                    break
                            if match is None:
                                raise ToolFailure('validation_failed', 'declared HTML appended element or its final edits were not preserved')
                            used_children.add(match)
        elif kind == 'xpath.remove':
            require_exact_keys(parameters, base, base, kind)
            expression = require_string(parameters['xpath'], 'xpath', minimum=1, maximum=2048)
            require_integer(parameters['expected_match_count'], 'expected_match_count', 1, 10000)
            if not expression.startswith(('/', '.')):
                raise ToolFailure('validation_failed', 'xpath must start at a document or relative context')
            try:
                remaining = tree.xpath(expression)
            except etree.XPathError:
                raise ToolFailure('validation_failed', 'xpath is invalid') from None
            if remaining:
                if any(future['kind'] == 'xpath.append' for future in operations[operation_index + 1:]):
                    raise ToolFailure(
                        'unsupported_feature',
                        'HTML removal followed by recreation cannot be verified exactly')
                raise ToolFailure('validation_failed', 'declared HTML removal was not preserved')
        else:
            raise ToolFailure('unsupported_operation', 'HTML verification operation is not allowlisted')
    return {'format': 'html', 'verified_count': len(operations)}, versions, []

def verify_native_write(payload):
    format_name, input_path, operations, allowed_assets = verify_write_request(payload)
    if format_name == 'docx':
        return verify_docx_write(input_path, operations, allowed_assets)
    if format_name == 'pptx':
        return verify_pptx_write(input_path, operations, allowed_assets)
    if format_name == 'xlsx':
        return verify_xlsx_write(input_path, operations)
    if format_name == 'html':
        return verify_html_write(input_path, operations, allowed_assets)
    raise ToolFailure('unsupported_operation', 'format has no fixed Python write verifier')

def contiguous_page_runs(pages):
    runs = []
    for page in pages:
        if not runs or page != runs[-1][1] + 1:
            runs.append([page, page])
        else:
            runs[-1][1] = page
    return [tuple(value) for value in runs]

def run_ocr(payload):
    distributions = ['docling', 'docling-core', 'docling-parse', 'pypdfium2']
    versions = require_versions(distributions)
    import subprocess
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions, TesseractCliOcrOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption
    path = safe_input(payload, '.pdf')
    artifacts = pathlib.Path(payload.get('artifacts_path', ''))
    tesseract = pathlib.Path(payload.get('tesseract_path', ''))
    tessdata = pathlib.Path(payload.get('tessdata_path', ''))
    if not artifacts.is_dir() or not tesseract.is_file() or not os.access(tesseract, os.X_OK) or not tessdata.is_dir():
        raise ToolFailure('backend_missing', 'fixed OCR runtime artifacts are missing')
    version_line = subprocess.run([str(tesseract), '--version'], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  check=False, text=True, timeout=5).stdout.splitlines()[0]
    if version_line.strip() != 'tesseract 5.5.3':
        raise ToolFailure('backend_version_mismatch', 'tesseract version mismatch')
    versions['tesseract'] = '5.5.3'
    raw_pages = payload.get('pages', [])
    if not isinstance(raw_pages, list) or any(isinstance(value, bool) or not isinstance(value, int) for value in raw_pages):
        raise ToolFailure('validation_failed', 'OCR pages are invalid')
    pages = sorted(set(raw_pages))
    if not pages or pages[0] < 1 or pages[-1] > MAXIMUM_PDF_PAGES or len(pages) > 50:
        raise ToolFailure('validation_failed', 'OCR pages are invalid')
    languages = payload.get('languages')
    allowed_languages = {'eng', 'chi_sim', 'chi_tra', 'deu', 'fra', 'spa', 'ita', 'por', 'jpn', 'kor'}
    if not isinstance(languages, list) or not languages or not set(languages) <= allowed_languages:
        raise ToolFailure('validation_failed', 'OCR languages are invalid')
    psm = int(payload.get('psm'))
    if psm not in {1, 3, 4, 6, 11, 12}:
        raise ToolFailure('validation_failed', 'OCR PSM is invalid')
    options = PdfPipelineOptions()
    options.enable_remote_services = False
    options.allow_external_plugins = False
    options.artifacts_path = artifacts
    options.do_ocr = True
    options.do_table_structure = False
    options.do_code_enrichment = False
    options.do_formula_enrichment = False
    options.do_picture_classification = False
    options.do_picture_description = False
    options.do_chart_extraction = False
    options.generate_page_images = False
    options.generate_picture_images = False
    options.generate_table_images = False
    options.generate_parsed_pages = True
    options.ocr_options = TesseractCliOcrOptions(
        lang=languages, tesseract_cmd=str(tesseract), path=str(tessdata),
        psm=psm, force_full_page_ocr=True)
    converter = DocumentConverter(format_options={
        InputFormat.PDF: PdfFormatOption(pipeline_options=options)
    })
    requested = set(pages)
    maximum_characters = int(payload.get('maximum_characters', 200000))
    budget = Budget(maximum_characters, 50000)
    output_pages = []
    seen = set()
    for start_page, end_page in contiguous_page_runs(pages):
        conversion = converter.convert(
            str(path), raises_on_error=True,
            max_num_pages=MAXIMUM_PDF_PAGES,
            max_file_size=int(payload.get('maximum_file_bytes', 104857600)),
            page_range=(start_page, end_page))
        for page in conversion.pages:
            page_no = int(page.page_no)
            if page_no not in requested or page_no in seen or page.parsed_page is None:
                continue
            blocks = []
            for cell in page.parsed_page.textline_cells:
                if not cell.from_ocr:
                    continue
                text = budget.text(cell.text)
                if text is None:
                    break
                rectangle = cell.rect
                xs = [rectangle.r_x0, rectangle.r_x1, rectangle.r_x2, rectangle.r_x3]
                ys = [rectangle.r_y0, rectangle.r_y1, rectangle.r_y2, rectangle.r_y3]
                blocks.append({'text': text,
                               'bbox': {'left': min(xs), 'top': max(ys),
                                        'right': max(xs), 'bottom': min(ys),
                                        'origin': str(rectangle.coord_origin)},
                               'confidence': float(cell.confidence)})
            output_pages.append({'page': page_no, 'text': '\n'.join(v['text'] for v in blocks),
                                 'blocks': blocks})
            seen.add(page_no)
            if budget.truncated:
                break
        if budget.truncated:
            break
    output_pages.sort(key=lambda value: value['page'])
    if not budget.truncated and seen != requested:
        raise ToolFailure('validation_failed', 'one or more requested OCR pages were not returned')
    return {'format': 'pdf', 'pages': output_pages, 'truncated': budget.truncated,
            'searchable_pdf_generated': False}, versions, []

def main():
    operation, payload = require_request()
    if operation == 'read':
        result, versions, warnings = read_markdown(payload)
    elif operation == 'ocr':
        result, versions, warnings = run_ocr(payload)
    elif operation == 'write':
        result, versions, warnings = write_native(payload)
    elif operation == 'verify_write':
        result, versions, warnings = verify_native_write(payload)
    elif operation == 'prepare_html_render':
        result, versions, warnings = prepare_html_render(payload)
    else:
        raise ToolFailure('unsupported_operation', 'unsupported fixed Python route')
    emit(True, result=result, versions=versions, warnings=warnings)

try:
    main()
except ToolFailure as error:
    emit(False, code=error.code, summary=error.summary)
except ModuleNotFoundError:
    emit(False, code='backend_missing', summary='fixed Python dependency is unavailable')
except Exception:
    # Exception reprs routinely contain absolute paths, relationship targets,
    # XML snippets, cell values, and other user data. Preserve only the typed
    # failure class at this trust boundary.
    emit(False, code='backend_failed', summary='fixed document backend failed unexpectedly')
"""#
}

private extension JSONEncoder {
    static var sortedDocumentEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
