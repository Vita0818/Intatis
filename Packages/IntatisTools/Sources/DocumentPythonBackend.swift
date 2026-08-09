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

/// Thin bridge into the pinned Python document libraries. Parsing, OOXML,
/// layout, and OCR semantics remain in the selected mature components; this
/// program only validates a versioned request, invokes one fixed route, bounds
/// projection size, and emits a versioned JSON envelope.
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
        internalWritableWorkspacePaths: [String] = []
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
            internalWritableWorkspacePaths: internalWritableWorkspacePaths)
    }

    static func run(
        operation: String,
        payload: JSONValue,
        readableWorkspacePaths: [String],
        writableWorkspacePaths: [String] = [],
        internalWritableWorkspacePaths: [String] = [],
        in context: ToolContext
    ) async throws -> DocumentBackendEnvelope {
        let invocation = try invocation(
            operation: operation,
            payload: payload,
            readableWorkspacePaths: readableWorkspacePaths,
            writableWorkspacePaths: writableWorkspacePaths,
            internalWritableWorkspacePaths: internalWritableWorkspacePaths)
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
            let safe = backendSummary?
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(160)
            return safe.map(String.init) ?? "the fixed document backend failed"
        }
    }

    // The program deliberately contains no backend search or fallback loop.
    // Every branch imports exactly one semantic library for one format.
    private static let program = #"""
import json
import math
import os
import pathlib
import re
import stat
import sys
from copy import copy
from importlib import metadata

SCHEMA_VERSION = 1
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
    if value['operation'] not in {'read', 'validate', 'ocr', 'write'}:
        raise ToolFailure('unsupported_operation', 'unsupported fixed Python route')
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
    if not isinstance(path, str) or not os.path.isabs(path) or '\x00' in path:
        raise ToolFailure('validation_failed', 'input_path must be an absolute host path')
    candidate = pathlib.Path(path)
    allowed_suffixes = {suffix} if isinstance(suffix, str) else set(suffix)
    if candidate.suffix.lower() not in allowed_suffixes or not candidate.is_file() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'input file is missing or has the wrong format')
    return candidate

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

def read_docx(payload):
    versions = require_versions(['python-docx'])
    from docx import Document
    path = safe_input(payload, '.docx')
    maximum_characters, maximum_items = bounds(payload)
    budget = Budget(maximum_characters, maximum_items)
    document = Document(str(path))
    paragraphs = []
    for index, paragraph in enumerate(document.paragraphs):
        text = budget.text(paragraph.text)
        if text is None:
            break
        runs = []
        for run_index, run in enumerate(paragraph.runs):
            run_text = budget.text(run.text)
            if run_text is None:
                break
            runs.append({'index': run_index, 'text': run_text, 'bold': run.bold,
                         'italic': run.italic, 'underline': run.underline})
        paragraphs.append({'index': index, 'text': text,
                           'style': paragraph.style.name if paragraph.style else None,
                           'runs': runs})
    tables = []
    for table_index, table in enumerate(document.tables):
        rows = []
        for row in table.rows:
            values = []
            for cell in row.cells:
                text = budget.text(cell.text)
                if text is None:
                    break
                values.append(text)
            rows.append(values)
            if budget.truncated:
                break
        tables.append({'index': table_index, 'rows': rows})
        if budget.truncated:
            break
    sections = []
    for index, section in enumerate(document.sections):
        sections.append({
            'index': index,
            'width_emu': int(section.page_width),
            'height_emu': int(section.page_height),
            'header': budget.text('\n'.join(p.text for p in section.header.paragraphs)),
            'footer': budget.text('\n'.join(p.text for p in section.footer.paragraphs)),
        })
    props = document.core_properties
    result = {'format': 'docx', 'paragraphs': paragraphs, 'tables': tables,
              'sections': sections,
              'core_properties': {'title': props.title, 'subject': props.subject,
                                  'author': props.author, 'keywords': props.keywords},
              'truncated': budget.truncated}
    return result, versions, []

def read_pptx(payload):
    versions = require_versions(['python-pptx'])
    from pptx import Presentation
    path = safe_input(payload, '.pptx')
    maximum_characters, maximum_items = bounds(payload)
    budget = Budget(maximum_characters, maximum_items)
    presentation = Presentation(str(path))
    slides = []
    requested = payload.get('slides')
    requested = set(int(v) for v in requested) if isinstance(requested, list) else None
    for ordinal, slide in enumerate(presentation.slides, start=1):
        if requested is not None and ordinal not in requested:
            continue
        shapes = []
        for shape_index, shape in enumerate(slide.shapes):
            entry = {'index': shape_index, 'name': shape.name,
                     'shape_type': str(shape.shape_type)}
            if getattr(shape, 'has_text_frame', False):
                entry['text'] = budget.text(shape.text)
            if getattr(shape, 'has_table', False):
                entry['table'] = [[budget.text(cell.text) for cell in row.cells]
                                  for row in shape.table.rows]
            if getattr(shape, 'has_chart', False):
                entry['chart_type'] = str(shape.chart.chart_type)
                entry['chart_series_count'] = len(shape.chart.series)
            shapes.append(entry)
            if budget.truncated:
                break
        slides.append({'page': ordinal, 'shapes': shapes})
        if budget.truncated:
            break
    return {'format': 'pptx', 'slide_count': len(presentation.slides),
            'slides': slides, 'truncated': budget.truncated}, versions, []

def read_xlsx(payload):
    versions = require_versions(['openpyxl'])
    from openpyxl import load_workbook
    from openpyxl.utils.cell import range_boundaries
    path = safe_input(payload, '.xlsx')
    maximum_characters, maximum_items = bounds(payload)
    maximum_cells = min(int(payload.get('maximum_cells', 10000)), 50000)
    budget = Budget(maximum_characters, maximum_items)
    workbook = load_workbook(str(path), read_only=True,
                             data_only=bool(payload.get('data_only', False)),
                             keep_links=False)
    requested_sheet = payload.get('sheet')
    names = [requested_sheet] if requested_sheet else list(workbook.sheetnames)
    sheets = []
    for name in names:
        if name not in workbook.sheetnames:
            raise ToolFailure('validation_failed', 'requested worksheet does not exist')
        sheet = workbook[name]
        cell_range = payload.get('range')
        if cell_range:
            min_col, min_row, max_col, max_row = range_boundaries(cell_range)
        else:
            min_col, min_row = 1, 1
            max_col, max_row = sheet.max_column, sheet.max_row
            if max_col * max_row > maximum_cells:
                raise ToolFailure('unsupported_feature', 'large worksheet requires an explicit range')
        if (max_col - min_col + 1) * (max_row - min_row + 1) > maximum_cells:
            raise ToolFailure('validation_failed', 'requested range exceeds the cell limit')
        rows = []
        for row in sheet.iter_rows(min_row=min_row, max_row=max_row,
                                   min_col=min_col, max_col=max_col):
            values = []
            for cell in row:
                value = cell.value
                if isinstance(value, (str, int, float, bool)) or value is None:
                    rendered = value
                else:
                    rendered = str(value)
                if isinstance(rendered, str):
                    rendered = budget.text(rendered)
                values.append({'coordinate': cell.coordinate, 'value': rendered,
                               'data_type': cell.data_type})
            rows.append(values)
            if budget.truncated:
                break
        sheets.append({'name': name, 'range': cell_range, 'rows': rows})
        if budget.truncated:
            break
    workbook.close()
    return {'format': 'xlsx', 'sheet_names': list(workbook.sheetnames),
            'sheets': sheets, 'truncated': budget.truncated}, versions, []

def read_html(payload):
    versions = require_versions(['lxml'])
    from lxml import etree, html
    path = safe_input(payload, {'.html', '.htm'})
    maximum_characters, maximum_items = bounds(payload)
    budget = Budget(maximum_characters, maximum_items)
    parser = etree.HTMLParser(no_network=True, recover=False, huge_tree=False)
    tree = etree.parse(str(path), parser)
    if bool(payload.get('require_self_contained', False)):
        validate_self_contained_html(
            tree,
            path,
            payload.get('allowed_asset_paths', []))
    expression = payload.get('xpath') or '/*'
    if not isinstance(expression, str) or not expression:
        raise ToolFailure('validation_failed', 'xpath must be a non-empty string')
    selected = tree.xpath(expression)
    if len(selected) > maximum_items:
        raise ToolFailure('validation_failed', 'xpath result exceeds the item limit')
    items = []
    for index, value in enumerate(selected):
        if isinstance(value, etree._Element):
            text = budget.text(''.join(value.itertext()))
            items.append({'index': index, 'tag': value.tag,
                          'attributes': dict(value.attrib), 'text': text})
        else:
            items.append({'index': index, 'value': budget.text(value)})
        if budget.truncated:
            break
    return {'format': 'html', 'xpath': expression, 'items': items,
            'truncated': budget.truncated}, versions, []

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
    if allowed_assets and resolved not in allowed_assets:
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
    if not isinstance(operations, list) or not 1 <= len(operations) <= 1000:
        raise ToolFailure('validation_failed', 'operations are invalid')
    for operation in operations:
        require_exact_keys(operation, {'kind', 'parameters'}, {'kind', 'parameters'}, 'operation')
        require_string(operation.get('kind'), 'operation kind', minimum=1, maximum=64)
        if not isinstance(operation.get('parameters'), dict):
            raise ToolFailure('validation_failed', 'operation parameters must be an object')
    raw_assets = payload.get('allowed_asset_paths', [])
    if not isinstance(raw_assets, list) or len(raw_assets) > 256 or not all(isinstance(path, str) for path in raw_assets) or len(set(raw_assets)) != len(raw_assets):
        raise ToolFailure('validation_failed', 'host asset allowlist is invalid')
    allowed_assets = {str(safe_asset(path).resolve()) for path in raw_assets}
    return format_name, mode, input_path, output_path, operations, allowed_assets

def indexed(values, index, label):
    require_integer(index, label + ' index')
    if index >= len(values):
        raise ToolFailure('validation_failed', label + ' index is out of range')
    return values[index]

def write_docx(mode, input_path, output_path, operations, allowed_assets):
    versions = require_versions(['python-docx'])
    from docx import Document
    from docx.enum.section import WD_ORIENT
    from docx.shared import Pt
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
                table = indexed(document.tables, parameters['table_index'], 'table')
                row = indexed(table.rows, parameters['row_index'], 'table row')
                cell = indexed(row.cells, parameters['column_index'], 'table column')
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
                section = indexed(document.sections, parameters['section_index'], 'section')
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
                section = indexed(document.sections, parameters['section_index'], 'section')
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
    require_integer(index, 'slide index')
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
    from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
    from pptx.util import Inches
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
                layout = indexed(presentation.slide_layouts, layout_index, 'slide layout')
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
                shape = indexed(slide.shapes, parameters['shape_index'], 'shape')
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
                if shape_type == 'line':
                    if 'text' in parameters:
                        raise ToolFailure('unsupported_feature', 'line shapes do not support text')
                    shape = slide.shapes.add_connector(MSO_CONNECTOR.STRAIGHT, x, y, x + width, y + height)
                else:
                    shape_types = {
                        'rectangle': MSO_SHAPE.RECTANGLE,
                        'rounded_rectangle': MSO_SHAPE.ROUNDED_RECTANGLE,
                        'ellipse': MSO_SHAPE.OVAL,
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
    forbidden = ('HTTP://', 'HTTPS://', 'WEBSERVICE(', 'RTD(', 'DDE(')
    if any(token in upper for token in forbidden) or re.search(r'\[[^\]]+\][^!]{0,255}!', upper):
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
            if re.fullmatch(r'[A-Za-z_:][A-Za-z0-9_.:-]*', name) is None or name.lower().startswith('on') or name.lower() == 'srcdoc':
                raise ToolFailure('unsupported_feature', 'HTML attribute is not supported')
            for element in selected:
                element.set(name, value)
        elif kind == 'xpath.append':
            require_exact_keys(parameters, base | {'html'}, base | {'html'}, kind)
            selected = html_selection(tree, parameters['xpath'], parameters['expected_match_count'])
            fragment = require_string(parameters['html'], 'html', minimum=1)
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

def validate_native(payload):
    format_name = payload.get('format')
    if format_name == 'docx':
        result, versions, warnings = read_docx({**payload, 'maximum_characters': 1,
                                               'maximum_items': 1})
    elif format_name == 'pptx':
        result, versions, warnings = read_pptx({**payload, 'maximum_characters': 1,
                                               'maximum_items': 1})
    elif format_name == 'xlsx':
        result, versions, warnings = read_xlsx({**payload, 'maximum_characters': 1,
                                               'maximum_items': 1,
                                               'maximum_cells': 1,
                                               'sheet': None, 'range': 'A1'})
    elif format_name == 'html':
        result, versions, warnings = read_html({**payload, 'maximum_characters': 1,
                                               'maximum_items': 1, 'xpath': '/*',
                                               'require_self_contained': bool(payload.get('require_self_contained', False)),
                                               'allowed_asset_paths': payload.get('allowed_asset_paths', [])})
    else:
        raise ToolFailure('unsupported_operation', 'format has no fixed Python validator')
    return {'format': format_name, 'valid': True}, versions, warnings

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
    pages = sorted(set(int(v) for v in payload.get('pages', [])))
    if not pages or pages[0] < 1 or len(pages) > 50:
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
    conversion = converter.convert(
        str(path), raises_on_error=True, max_num_pages=50,
        max_file_size=int(payload.get('maximum_file_bytes', 104857600)),
        page_range=(pages[0], pages[-1]))
    requested = set(pages)
    maximum_characters = int(payload.get('maximum_characters', 200000))
    budget = Budget(maximum_characters, 50000)
    output_pages = []
    for page in conversion.pages:
        page_no = int(page.page_no)
        if page_no not in requested or page.parsed_page is None:
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
        if budget.truncated:
            break
    return {'format': 'pdf', 'pages': output_pages, 'truncated': budget.truncated,
            'searchable_pdf_generated': False}, versions, []

def main():
    operation, payload = require_request()
    if operation == 'read':
        format_name = payload.get('format')
        if format_name == 'docx':
            result, versions, warnings = read_docx(payload)
        elif format_name == 'pptx':
            result, versions, warnings = read_pptx(payload)
        elif format_name == 'xlsx':
            result, versions, warnings = read_xlsx(payload)
        elif format_name == 'html':
            result, versions, warnings = read_html(payload)
        else:
            raise ToolFailure('unsupported_operation', 'format has no fixed Python reader')
    elif operation == 'validate':
        result, versions, warnings = validate_native(payload)
    elif operation == 'ocr':
        result, versions, warnings = run_ocr(payload)
    elif operation == 'write':
        result, versions, warnings = write_native(payload)
    else:
        raise ToolFailure('unsupported_operation', 'unsupported fixed Python route')
    emit(True, result=result, versions=versions, warnings=warnings)

try:
    main()
except ToolFailure as error:
    emit(False, code=error.code, summary=error.summary)
except ModuleNotFoundError:
    emit(False, code='backend_missing', summary='fixed Python dependency is unavailable')
except Exception as error:
    emit(False, code='backend_failed', summary=type(error).__name__ + ': ' + str(error))
"""#
}

private extension JSONEncoder {
    static var sortedDocumentEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
