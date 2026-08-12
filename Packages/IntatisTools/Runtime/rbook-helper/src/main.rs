use rbook::ebook::toc::TocEntryKind;
use rbook::epub::Epub;
use rbook::epub::manifest::DetachedEpubManifestEntry;
use rbook::epub::metadata::{DetachedEpubMetaEntry, EpubVersion};
use rbook::epub::spine::DetachedEpubSpineEntry;
use rbook::epub::toc::{DetachedEpubTocEntry, EpubTocEntry, EpubTocEntryMut};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use zip::ZipArchive;

const SCHEMA_VERSION: u32 = 1;
const RBOOK_VERSION: &str = "0.7.10";
const MAX_REQUEST_BYTES: usize = 256 * 1024;
const MAX_EPUB_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_ASSET_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ASSET_TOTAL_BYTES: u64 = 512 * 1024 * 1024;
const MAX_ZIP_ENTRIES: usize = 20_000;
const MAX_ZIP_ENTRY_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ZIP_TOTAL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_OPERATIONS: usize = 1_000;

#[derive(Debug, Clone, Copy)]
struct HelperError {
    code: &'static str,
    summary: &'static str,
}

type HelperResult<T> = Result<T, HelperError>;

impl HelperError {
    const fn validation() -> Self {
        Self {
            code: "validation_failed",
            summary: "rbook request validation failed",
        }
    }

    const fn unsupported_operation() -> Self {
        Self {
            code: "unsupported_operation",
            summary: "rbook operation is unsupported",
        }
    }

    const fn unsupported_feature() -> Self {
        Self {
            code: "unsupported_feature",
            summary: "EPUB feature is outside the supported subset",
        }
    }

    const fn version() -> Self {
        Self {
            code: "backend_version_mismatch",
            summary: "rbook version does not match the fixed manifest",
        }
    }

    const fn backend() -> Self {
        Self {
            code: "backend_failed",
            summary: "rbook EPUB operation failed",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    schema_version: u32,
    engine: String,
    expected_version: String,
    operation: String,
    payload: Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct WritePayload {
    format: String,
    mode: String,
    #[serde(default)]
    input_path: Option<String>,
    output_path: String,
    operations: Vec<Operation>,
    allowed_asset_paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Operation {
    kind: String,
    parameters: Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct MetadataSet {
    field: String,
    value: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ResourceAdd {
    id: String,
    source_path: String,
    href: String,
    media_type: String,
    #[serde(default)]
    properties: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SpineAppend {
    resource_id: String,
    #[serde(default = "default_true")]
    linear: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TocAdd {
    label: String,
    href: String,
    #[serde(default)]
    parent_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct Envelope {
    schema_version: u32,
    ok: bool,
    code: Option<&'static str>,
    summary: &'static str,
    engine_versions: BTreeMap<&'static str, &'static str>,
    result: Value,
    warnings: Vec<&'static str>,
}

#[derive(Debug)]
enum Postcondition {
    Metadata {
        field: String,
        value: String,
    },
    Resource {
        id: String,
        href: String,
        media_type: String,
        properties: BTreeSet<String>,
        bytes: Vec<u8>,
    },
    Spine {
        index: usize,
        resource_id: String,
        linear: bool,
    },
    Toc {
        id: String,
        parent_id: Option<String>,
        label: String,
        href: String,
    },
}

fn default_true() -> bool {
    true
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(run).unwrap_or_else(|_| Err(HelperError::backend()));
    let envelope = match result {
        Ok(value) => success(value),
        Err(error) => failure(error),
    };
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    if serde_json::to_writer(&mut lock, &envelope).is_ok() {
        let _ = lock.write_all(b"\n");
    }
}

fn success(result: Value) -> Envelope {
    Envelope {
        schema_version: SCHEMA_VERSION,
        ok: true,
        code: None,
        summary: "rbook EPUB operation completed",
        engine_versions: BTreeMap::from([("rbook", RBOOK_VERSION)]),
        result,
        warnings: Vec::new(),
    }
}

fn failure(error: HelperError) -> Envelope {
    Envelope {
        schema_version: SCHEMA_VERSION,
        ok: false,
        code: Some(error.code),
        summary: error.summary,
        engine_versions: BTreeMap::from([("rbook", RBOOK_VERSION)]),
        result: Value::Null,
        warnings: Vec::new(),
    }
}

fn run() -> HelperResult<Value> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 2 || args[1] != "json-v1" {
        return Err(HelperError::validation());
    }
    let encoded = env::var("INTATIS_DOCUMENT_REQUEST").map_err(|_| HelperError::validation())?;
    if encoded.len() > MAX_REQUEST_BYTES {
        return Err(HelperError::validation());
    }
    let request: Request = serde_json::from_str(&encoded).map_err(|_| HelperError::validation())?;
    if request.schema_version != SCHEMA_VERSION || request.engine != "rbook" {
        return Err(HelperError::validation());
    }
    if request.expected_version != RBOOK_VERSION {
        return Err(HelperError::version());
    }
    let operation_env =
        env::var("INTATIS_DOCUMENT_OPERATION").map_err(|_| HelperError::validation())?;
    if operation_env != request.operation {
        return Err(HelperError::validation());
    }
    match request.operation.as_str() {
        "write" => write_epub(
            serde_json::from_value(request.payload).map_err(|_| HelperError::validation())?,
        ),
        _ => Err(HelperError::unsupported_operation()),
    }
}

fn write_epub(payload: WritePayload) -> HelperResult<Value> {
    if payload.format != "epub"
        || !matches!(payload.mode.as_str(), "create" | "edit")
        || payload.operations.is_empty()
        || payload.operations.len() > MAX_OPERATIONS
    {
        return Err(HelperError::validation());
    }
    let output = validate_output_file(&payload.output_path, "epub")?;
    match fs::symlink_metadata(&output) {
        Ok(_) => return Err(HelperError::validation()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(HelperError::validation()),
    }
    let input = match (payload.mode.as_str(), payload.input_path.as_deref()) {
        ("create", None) => None,
        ("edit", Some(path)) => {
            let input = canonical_input_file(path, "epub", MAX_EPUB_BYTES)?;
            preflight_epub_archive(&input)?;
            Some(input)
        }
        _ => return Err(HelperError::validation()),
    };
    let allowlist = canonical_allowlist(&payload.allowed_asset_paths)?;
    let mut epub = match input {
        Some(path) => Epub::open(path).map_err(|_| HelperError::validation())?,
        None => Epub::new(),
    };
    let mut postconditions = Vec::with_capacity(payload.operations.len());
    let mut metadata_fields = BTreeSet::new();
    let mut asset_total = 0_u64;
    let mut toc_ids = Vec::new();

    for (index, operation) in payload.operations.into_iter().enumerate() {
        match operation.kind.as_str() {
            "metadata.set" => {
                let parameters: MetadataSet = serde_json::from_value(operation.parameters)
                    .map_err(|_| HelperError::validation())?;
                validate_metadata(&parameters)?;
                if !metadata_fields.insert(parameters.field.clone()) {
                    return Err(HelperError::validation());
                }
                set_metadata(&mut epub, &parameters.field, &parameters.value)?;
                postconditions.push(Postcondition::Metadata {
                    field: parameters.field,
                    value: parameters.value,
                });
            }
            "resource.add" => {
                let parameters: ResourceAdd = serde_json::from_value(operation.parameters)
                    .map_err(|_| HelperError::validation())?;
                validate_resource_parameters(&parameters)?;
                if epub.manifest().by_id(&parameters.id).is_some()
                    || epub
                        .manifest()
                        .iter()
                        .any(|entry| entry.href_raw().as_str() == parameters.href)
                    || package_id_in_use(&epub, &parameters.id)
                {
                    return Err(HelperError::validation());
                }
                let source = canonical_input_file_with_extensions(
                    &parameters.source_path,
                    extensions_for_media_type(&parameters.media_type)?,
                    MAX_ASSET_BYTES,
                )?;
                if !allowlist.contains(&source) {
                    return Err(HelperError::validation());
                }
                let bytes = fs::read(&source).map_err(|_| HelperError::validation())?;
                asset_total = asset_total
                    .checked_add(bytes.len() as u64)
                    .ok_or_else(HelperError::validation)?;
                if asset_total > MAX_ASSET_TOTAL_BYTES {
                    return Err(HelperError::validation());
                }
                validate_resource_content(&parameters.media_type, &bytes)?;
                let properties = parameters.properties.unwrap_or_default();
                let mut entry = DetachedEpubManifestEntry::new(&parameters.id)
                    .href(&parameters.href)
                    .media_type(&parameters.media_type)
                    .content(bytes.clone());
                for property in &properties {
                    entry = entry.property(property);
                }
                epub.manifest_mut().push(entry);
                postconditions.push(Postcondition::Resource {
                    id: parameters.id,
                    href: parameters.href,
                    media_type: parameters.media_type,
                    properties: properties.into_iter().collect(),
                    bytes,
                });
            }
            "spine.append" => {
                let parameters: SpineAppend = serde_json::from_value(operation.parameters)
                    .map_err(|_| HelperError::validation())?;
                validate_identifier(&parameters.resource_id)?;
                let resource = epub
                    .manifest()
                    .by_id(&parameters.resource_id)
                    .ok_or_else(HelperError::validation)?;
                if resource.media_type() != "application/xhtml+xml" {
                    return Err(HelperError::unsupported_feature());
                }
                let spine_index = epub.spine().len();
                epub.spine_mut().push(
                    DetachedEpubSpineEntry::new(&parameters.resource_id).linear(parameters.linear),
                );
                postconditions.push(Postcondition::Spine {
                    index: spine_index,
                    resource_id: parameters.resource_id,
                    linear: parameters.linear,
                });
            }
            "toc.add" => {
                let parameters: TocAdd = serde_json::from_value(operation.parameters)
                    .map_err(|_| HelperError::validation())?;
                validate_toc(&parameters)?;
                ensure_toc_target_exists(&epub, &parameters.href)?;
                if let Some(parent) = &parameters.parent_id {
                    validate_identifier(parent)?;
                }
                let toc_id = unique_toc_id(&epub, index + 1);
                let entry = DetachedEpubTocEntry::new(&parameters.label)
                    .id(&toc_id)
                    .href(&parameters.href);
                append_toc(&mut epub, parameters.parent_id.as_deref(), entry)?;
                toc_ids.push(toc_id.clone());
                postconditions.push(Postcondition::Toc {
                    id: toc_id,
                    parent_id: parameters.parent_id,
                    label: parameters.label,
                    href: parameters.href,
                });
            }
            _ => return Err(HelperError::unsupported_operation()),
        }
    }

    if epub.metadata().identifier().is_none()
        || epub.metadata().title().is_none()
        || epub.metadata().language().is_none()
        || epub.spine().is_empty()
    {
        return Err(HelperError::validation());
    }

    let mut writer = epub.write();
    writer
        .target([EpubVersion::EPUB2, EpubVersion::EPUB3])
        .compression(6)
        .generate_toc(true);
    writer.save(&output).map_err(|_| HelperError::backend())?;
    preflight_epub_archive(&output)?;
    verify_postconditions(&output, &postconditions)?;
    let output_bytes = fs::metadata(&output)
        .map_err(|_| HelperError::backend())?
        .len();
    Ok(json!({
        "format": "epub",
        "mode": payload.mode,
        "operation_count": postconditions.len(),
        "toc_entry_ids": toc_ids,
        "byte_count": output_bytes,
        "verified": true,
    }))
}

fn canonical_input_file(value: &str, extension: &str, maximum_bytes: u64) -> HelperResult<PathBuf> {
    canonical_input_file_with_extensions(value, &[extension], maximum_bytes)
}

fn canonical_input_file_with_extensions(
    value: &str,
    extensions: &[&str],
    maximum_bytes: u64,
) -> HelperResult<PathBuf> {
    let path = strict_absolute_path(value)?;
    let metadata = fs::symlink_metadata(&path).map_err(|_| HelperError::validation())?;
    let actual_extension = path
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase);
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() == 0
        || metadata.len() > maximum_bytes
        || !actual_extension
            .as_deref()
            .is_some_and(|actual| extensions.contains(&actual))
    {
        return Err(HelperError::validation());
    }
    let canonical = fs::canonicalize(&path).map_err(|_| HelperError::validation())?;
    if canonical != path {
        return Err(HelperError::validation());
    }
    Ok(canonical)
}

fn validate_output_file(value: &str, extension: &str) -> HelperResult<PathBuf> {
    let path = strict_absolute_path(value)?;
    if !path
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case(extension))
    {
        return Err(HelperError::validation());
    }
    let parent = path.parent().ok_or_else(HelperError::validation)?;
    let parent_metadata = fs::symlink_metadata(parent).map_err(|_| HelperError::validation())?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err(HelperError::validation());
    }
    let canonical_parent = fs::canonicalize(parent).map_err(|_| HelperError::validation())?;
    let file_name = path.file_name().ok_or_else(HelperError::validation)?;
    let canonical_target = canonical_parent.join(file_name);
    if canonical_target != path {
        return Err(HelperError::validation());
    }
    Ok(path)
}

fn strict_absolute_path(value: &str) -> HelperResult<PathBuf> {
    if value.is_empty() || value.contains('\0') || value.len() > 8_192 {
        return Err(HelperError::validation());
    }
    let path = PathBuf::from(value);
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(HelperError::validation());
    }
    Ok(path)
}

fn canonical_allowlist(values: &[String]) -> HelperResult<BTreeSet<PathBuf>> {
    if values.len() > MAX_OPERATIONS {
        return Err(HelperError::validation());
    }
    let mut result = BTreeSet::new();
    for value in values {
        let path = strict_absolute_path(value)?;
        let metadata = fs::symlink_metadata(&path).map_err(|_| HelperError::validation())?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(HelperError::validation());
        }
        let canonical = fs::canonicalize(&path).map_err(|_| HelperError::validation())?;
        if canonical != path || !result.insert(canonical) {
            return Err(HelperError::validation());
        }
    }
    Ok(result)
}

fn preflight_epub_archive(path: &Path) -> HelperResult<()> {
    let metadata = fs::metadata(path).map_err(|_| HelperError::validation())?;
    if metadata.len() == 0 || metadata.len() > MAX_EPUB_BYTES {
        return Err(HelperError::validation());
    }
    let declared_entries = classic_zip_entry_count(path)?;
    let file = File::open(path).map_err(|_| HelperError::validation())?;
    let mut archive = ZipArchive::new(file).map_err(|_| HelperError::validation())?;
    if archive.is_empty() || archive.len() != declared_entries || archive.len() > MAX_ZIP_ENTRIES {
        return Err(HelperError::validation());
    }
    let mut total = 0_u64;
    let mut names = BTreeSet::new();
    let mut portable_names = BTreeSet::new();
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|_| HelperError::validation())?;
        let name = entry.name();
        let portable_name = name
            .chars()
            .flat_map(char::to_lowercase)
            .collect::<String>();
        if name.is_empty()
            || entry.encrypted()
            || !names.insert(entry.name_raw().to_vec())
            || !portable_names.insert(portable_name)
            || name.contains('\0')
            || name.contains('\\')
            || name.starts_with('/')
            || name
                .split('/')
                .any(|component| matches!(component, "." | ".."))
            || Path::new(name)
                .components()
                .any(|component| matches!(component, Component::ParentDir | Component::RootDir))
            || entry.unix_mode().is_some_and(|mode| {
                let kind = mode & 0o170000;
                !matches!(kind, 0 | 0o040000 | 0o100000)
            })
        {
            return Err(HelperError::validation());
        }
        let size = entry.size();
        let compressed = entry.compressed_size();
        if size > MAX_ZIP_ENTRY_BYTES {
            return Err(HelperError::validation());
        }
        total = total
            .checked_add(size)
            .ok_or_else(HelperError::validation)?;
        if total > MAX_ZIP_TOTAL_BYTES
            || (size > 1024 * 1024 && (compressed == 0 || size / compressed.max(1) > 200))
        {
            return Err(HelperError::validation());
        }
    }
    Ok(())
}

fn classic_zip_entry_count(path: &Path) -> HelperResult<usize> {
    const EOCD_MINIMUM_BYTES: usize = 22;
    const MAX_COMMENT_BYTES: usize = u16::MAX as usize;
    const EOCD_SIGNATURE: &[u8; 4] = b"PK\x05\x06";

    let mut file = File::open(path).map_err(|_| HelperError::validation())?;
    let length = file
        .metadata()
        .map_err(|_| HelperError::validation())?
        .len();
    let tail_length = usize::try_from(length.min((EOCD_MINIMUM_BYTES + MAX_COMMENT_BYTES) as u64))
        .map_err(|_| HelperError::validation())?;
    if tail_length < EOCD_MINIMUM_BYTES {
        return Err(HelperError::validation());
    }
    file.seek(SeekFrom::End(-(tail_length as i64)))
        .map_err(|_| HelperError::validation())?;
    let mut tail = vec![0_u8; tail_length];
    file.read_exact(&mut tail)
        .map_err(|_| HelperError::validation())?;

    let offset = (0..=tail.len() - EOCD_MINIMUM_BYTES)
        .rev()
        .find(|offset| {
            &tail[*offset..*offset + 4] == EOCD_SIGNATURE
                && u16::from_le_bytes([tail[*offset + 20], tail[*offset + 21]]) as usize
                    == tail.len() - *offset - EOCD_MINIMUM_BYTES
        })
        .ok_or_else(HelperError::validation)?;
    let disk = u16::from_le_bytes([tail[offset + 4], tail[offset + 5]]);
    let central_disk = u16::from_le_bytes([tail[offset + 6], tail[offset + 7]]);
    let entries_on_disk = u16::from_le_bytes([tail[offset + 8], tail[offset + 9]]);
    let entries = u16::from_le_bytes([tail[offset + 10], tail[offset + 11]]);
    if disk != 0
        || central_disk != 0
        || entries_on_disk != entries
        || entries == u16::MAX
        || entries == 0
    {
        return Err(HelperError::validation());
    }
    Ok(entries as usize)
}

fn validate_metadata(parameters: &MetadataSet) -> HelperResult<()> {
    const FIELDS: &[&str] = &[
        "title",
        "language",
        "identifier",
        "creator",
        "subject",
        "description",
        "publisher",
        "date",
        "rights",
    ];
    if !FIELDS.contains(&parameters.field.as_str())
        || parameters.value.is_empty()
        || parameters.value.chars().count() > 100_000
        || parameters.value.contains('\0')
    {
        return Err(HelperError::validation());
    }
    Ok(())
}

fn metadata_property(field: &str) -> HelperResult<&'static str> {
    match field {
        "title" => Ok("dc:title"),
        "language" => Ok("dc:language"),
        "identifier" => Ok("dc:identifier"),
        "creator" => Ok("dc:creator"),
        "subject" => Ok("dc:subject"),
        "description" => Ok("dc:description"),
        "publisher" => Ok("dc:publisher"),
        "date" => Ok("dc:date"),
        "rights" => Ok("dc:rights"),
        _ => Err(HelperError::validation()),
    }
}

fn set_metadata(epub: &mut Epub, field: &str, value: &str) -> HelperResult<()> {
    let property = metadata_property(field)?;
    let _ = epub.metadata_mut().remove_by_property(property).count();
    let mut entry = DetachedEpubMetaEntry::dublin_core(property).value(value);
    if field == "identifier" {
        let mut id = String::from("intatis_unique_identifier");
        let mut suffix = 1_usize;
        while package_id_in_use(epub, &id) {
            id = format!("intatis_unique_identifier_{suffix}");
            suffix += 1;
        }
        entry = entry.id(&id);
        epub.package_mut().set_unique_identifier(id);
    }
    epub.metadata_mut().push(entry);
    Ok(())
}

fn validate_resource_parameters(parameters: &ResourceAdd) -> HelperResult<()> {
    validate_identifier(&parameters.id)?;
    validate_href(&parameters.href, false)?;
    let expected_extensions = extensions_for_media_type(&parameters.media_type)?;
    let href_extension = Path::new(&parameters.href)
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase);
    let property_values = parameters.properties.as_deref().unwrap_or_default();
    if !href_extension
        .as_deref()
        .is_some_and(|actual| expected_extensions.contains(&actual))
        || parameters
            .properties
            .as_ref()
            .is_some_and(|properties| properties.is_empty())
        || property_values.len() > 32
    {
        return Err(HelperError::validation());
    }
    let allowed: BTreeSet<&str> = ["cover-image", "mathml", "nav", "svg"]
        .into_iter()
        .collect();
    let properties: BTreeSet<&str> = property_values.iter().map(String::as_str).collect();
    if properties.len() != property_values.len()
        || !properties.is_subset(&allowed)
        || properties.contains("svg") && parameters.media_type != "image/svg+xml"
        || properties.contains("nav") && parameters.media_type != "application/xhtml+xml"
        || properties.contains("cover-image")
            && !matches!(parameters.media_type.as_str(), "image/png" | "image/jpeg")
    {
        return Err(HelperError::unsupported_feature());
    }
    Ok(())
}

fn extensions_for_media_type(media_type: &str) -> HelperResult<&'static [&'static str]> {
    match media_type {
        "application/xhtml+xml" => Ok(&["xhtml", "html", "htm"]),
        "text/css" => Ok(&["css"]),
        "image/png" => Ok(&["png"]),
        "image/jpeg" => Ok(&["jpg", "jpeg"]),
        "image/svg+xml" => Ok(&["svg"]),
        "font/woff2" => Ok(&["woff2"]),
        "application/font-woff" => Ok(&["woff"]),
        _ => Err(HelperError::unsupported_feature()),
    }
}

fn validate_resource_content(media_type: &str, bytes: &[u8]) -> HelperResult<()> {
    if matches!(
        media_type,
        "application/xhtml+xml" | "text/css" | "image/svg+xml"
    ) {
        let text = std::str::from_utf8(bytes).map_err(|_| HelperError::validation())?;
        let lower = text
            .to_ascii_lowercase()
            .replace("http://www.w3.org/1999/xhtml", "")
            .replace("http://www.w3.org/2000/svg", "")
            .replace("http://www.w3.org/1999/xlink", "")
            .replace("http://www.idpf.org/2007/ops", "");
        let forbidden = [
            "<script",
            "javascript:",
            "vbscript:",
            "data:",
            "http://",
            "https://",
            "src=\"//",
            "src='//",
            "href=\"//",
            "href='//",
            "@import",
            "url(//",
            "srcdoc=",
            "http-equiv",
            "<!doctype",
            "<!entity",
        ];
        if forbidden.iter().any(|needle| lower.contains(needle))
            || contains_inline_event_handler(&lower)
        {
            return Err(HelperError::unsupported_feature());
        }
    }
    Ok(())
}

fn contains_inline_event_handler(value: &str) -> bool {
    value
        .split_ascii_whitespace()
        .any(|token| token.starts_with("on") && token.contains('='))
}

fn validate_identifier(value: &str) -> HelperResult<()> {
    if value.is_empty() || value.len() > 255 || value.contains('\0') {
        return Err(HelperError::validation());
    }
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return Err(HelperError::validation());
    };
    if !(first.is_ascii_alphabetic() || first == '_')
        || !chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '-'))
    {
        return Err(HelperError::validation());
    }
    Ok(())
}

fn validate_href(value: &str, allow_fragment: bool) -> HelperResult<()> {
    if value.is_empty()
        || value.len() > 2_048
        || value.contains('\0')
        || value.contains('\\')
        || value.starts_with('/')
        || value.contains('?')
        || value.contains(':')
        || (!allow_fragment && value.contains('#'))
    {
        return Err(HelperError::validation());
    }
    let decoded = decode_percent_encoded(value)?;
    let decoded = std::str::from_utf8(&decoded).map_err(|_| HelperError::validation())?;
    let path = decoded.split('#').next().unwrap_or(decoded);
    if path.is_empty()
        || path
            .split('/')
            .any(|component| component.is_empty() || matches!(component, "." | ".."))
        || value
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
    {
        return Err(HelperError::validation());
    }
    Ok(())
}

fn decode_percent_encoded(value: &str) -> HelperResult<Vec<u8>> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = bytes
                .get(index + 1)
                .and_then(|value| hex_value(*value))
                .ok_or_else(HelperError::validation)?;
            let low = bytes
                .get(index + 2)
                .and_then(|value| hex_value(*value))
                .ok_or_else(HelperError::validation)?;
            let decoded_byte = (high << 4) | low;
            if matches!(decoded_byte, 0 | b'/' | b'\\' | b':') {
                return Err(HelperError::validation());
            }
            decoded.push(decoded_byte);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    Ok(decoded)
}

fn hex_value(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn validate_toc(parameters: &TocAdd) -> HelperResult<()> {
    if parameters.label.is_empty()
        || parameters.label.chars().count() > 10_000
        || parameters.label.contains('\0')
    {
        return Err(HelperError::validation());
    }
    validate_href(&parameters.href, true)
}

fn ensure_toc_target_exists(epub: &Epub, href: &str) -> HelperResult<()> {
    let path = href.split('#').next().unwrap_or(href);
    if !epub
        .manifest()
        .iter()
        .any(|entry| entry.href_raw().as_str() == path)
    {
        return Err(HelperError::validation());
    }
    Ok(())
}

fn package_id_in_use(epub: &Epub, id: &str) -> bool {
    epub.manifest().by_id(id).is_some()
        || epub.metadata().iter().any(|entry| entry.id() == Some(id))
        || epub.spine().iter().any(|entry| entry.id() == Some(id))
}

fn unique_toc_id(epub: &Epub, operation_index: usize) -> String {
    let base = format!("intatis_toc_{operation_index}");
    let mut candidate = base.clone();
    let mut suffix = 1_usize;
    while toc_id_exists(epub.toc().contents(), &candidate) {
        candidate = format!("{base}_{suffix}");
        suffix += 1;
    }
    candidate
}

fn toc_id_exists(root: Option<EpubTocEntry<'_>>, id: &str) -> bool {
    root.is_some_and(|root| {
        root.id() == Some(id) || root.flatten().any(|entry| entry.id() == Some(id))
    })
}

fn append_toc(
    epub: &mut Epub,
    parent_id: Option<&str>,
    entry: DetachedEpubTocEntry,
) -> HelperResult<()> {
    let mut toc = epub.toc_mut();
    if let Some(parent_id) = parent_id {
        let mut root = toc.contents_mut().ok_or_else(HelperError::validation)?;
        let mut pending = Some(entry);
        if !push_under_parent(&mut root, parent_id, &mut pending) {
            return Err(HelperError::validation());
        }
        return Ok(());
    }
    if let Some(mut root) = toc.contents_mut() {
        root.push(entry);
    } else {
        toc.insert_root(
            TocEntryKind::Toc,
            EpubVersion::EPUB3,
            DetachedEpubTocEntry::new("Table of Contents").children(entry),
        );
    }
    Ok(())
}

fn push_under_parent(
    current: &mut EpubTocEntryMut<'_>,
    parent_id: &str,
    pending: &mut Option<DetachedEpubTocEntry>,
) -> bool {
    if current.as_view().id() == Some(parent_id) {
        if let Some(entry) = pending.take() {
            current.push(entry);
            return true;
        }
        return false;
    }
    let count = current.as_view().len();
    for index in 0..count {
        if let Some(mut child) = current.get_mut(index)
            && push_under_parent(&mut child, parent_id, pending)
        {
            return true;
        }
    }
    false
}

fn verify_postconditions(path: &Path, postconditions: &[Postcondition]) -> HelperResult<()> {
    let epub = Epub::open(path).map_err(|_| HelperError::validation())?;
    for postcondition in postconditions {
        let valid = match postcondition {
            Postcondition::Metadata { field, value } => {
                let property = metadata_property(field)?;
                let values: Vec<&str> = epub
                    .metadata()
                    .iter()
                    .filter(|entry| entry.property().as_str() == property)
                    .map(|entry| entry.value())
                    .collect();
                values == [value.as_str()]
                    && (field != "identifier"
                        || epub.metadata().identifier().map(|entry| entry.value())
                            == Some(value.as_str()))
            }
            Postcondition::Resource {
                id,
                href,
                media_type,
                properties,
                bytes,
            } => epub.manifest().by_id(id).is_some_and(|entry| {
                let actual_properties: BTreeSet<String> = entry
                    .properties()
                    .as_str()
                    .split_ascii_whitespace()
                    .map(str::to_owned)
                    .collect();
                entry.href_raw().as_str() == href
                    && entry.media_type() == media_type
                    && &actual_properties == properties
                    && entry.read_bytes().ok().as_deref() == Some(bytes.as_slice())
            }),
            Postcondition::Spine {
                index,
                resource_id,
                linear,
            } => epub
                .spine()
                .get(*index)
                .is_some_and(|entry| entry.idref() == resource_id && entry.is_linear() == *linear),
            Postcondition::Toc {
                id,
                parent_id,
                label,
                href,
            } => verify_toc(&epub, id, parent_id.as_deref(), label, href),
        };
        if !valid {
            return Err(HelperError::validation());
        }
    }
    Ok(())
}

fn verify_toc(epub: &Epub, id: &str, parent_id: Option<&str>, label: &str, href: &str) -> bool {
    let Some(root) = epub.toc().contents() else {
        return false;
    };
    if let Some(parent_id) = parent_id {
        return find_toc_entry(root, parent_id).is_some_and(|parent| {
            parent
                .iter()
                .any(|entry| toc_entry_matches(entry, id, label, href))
        });
    }
    root.iter()
        .any(|entry| toc_entry_matches(entry, id, label, href))
}

fn find_toc_entry<'a>(root: EpubTocEntry<'a>, id: &str) -> Option<EpubTocEntry<'a>> {
    if root.id() == Some(id) {
        return Some(root);
    }
    root.flatten().find(|entry| entry.id() == Some(id))
}

fn toc_entry_matches(entry: EpubTocEntry<'_>, id: &str, label: &str, href: &str) -> bool {
    entry.id() == Some(id)
        && entry.label() == label
        && entry.href_raw().map(|value| value.as_str()) == Some(href)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEMP: AtomicU64 = AtomicU64::new(1);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = env::temp_dir().join(format!(
                "intatis-rbook-helper-test-{}-{id}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create test directory");
            Self(fs::canonicalize(path).expect("canonical test directory"))
        }

        fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn metadata(field: &str, value: &str) -> Operation {
        Operation {
            kind: "metadata.set".into(),
            parameters: json!({"field": field, "value": value}),
        }
    }

    fn resource(path: &Path) -> Operation {
        Operation {
            kind: "resource.add".into(),
            parameters: json!({
                "id": "chapter_one",
                "source_path": path,
                "href": "text/chapter.xhtml",
                "media_type": "application/xhtml+xml"
            }),
        }
    }

    fn spine() -> Operation {
        Operation {
            kind: "spine.append".into(),
            parameters: json!({"resource_id": "chapter_one", "linear": true}),
        }
    }

    fn toc() -> Operation {
        Operation {
            kind: "toc.add".into(),
            parameters: json!({"label": "Chapter One", "href": "text/chapter.xhtml"}),
        }
    }

    fn create_payload(directory: &TestDirectory, output: &Path) -> WritePayload {
        let chapter = directory.path("chapter.xhtml");
        fs::write(
            &chapter,
            br#"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hello</p></body></html>"#,
        )
        .expect("write chapter");
        WritePayload {
            format: "epub".into(),
            mode: "create".into(),
            input_path: None,
            output_path: output.to_string_lossy().into_owned(),
            operations: vec![
                metadata("identifier", "urn:intatis:test"),
                metadata("title", "Test Book"),
                metadata("language", "en"),
                resource(&chapter),
                spine(),
                toc(),
            ],
            allowed_asset_paths: vec![chapter.to_string_lossy().into_owned()],
        }
    }

    #[test]
    fn create_and_edit_round_trip() {
        let directory = TestDirectory::new();
        let created = directory.path("created.epub");
        let result = write_epub(create_payload(&directory, &created)).expect("create EPUB");
        assert_eq!(result["verified"], true);
        let edited = directory.path("edited.epub");
        let edit = WritePayload {
            format: "epub".into(),
            mode: "edit".into(),
            input_path: Some(created.to_string_lossy().into_owned()),
            output_path: edited.to_string_lossy().into_owned(),
            operations: vec![metadata("title", "Edited Book")],
            allowed_asset_paths: Vec::new(),
        };
        write_epub(edit).expect("edit EPUB");
        let reopened = Epub::open(edited).expect("reopen edited EPUB");
        assert_eq!(reopened.metadata().title().unwrap().value(), "Edited Book");
    }

    #[test]
    fn rejects_invalid_schema_path_and_operation() {
        assert!(strict_absolute_path("relative.epub").is_err());
        assert!(validate_href("../chapter.xhtml", false).is_err());
        assert!(validate_href("safe/%2e%2e/chapter.xhtml", false).is_err());
        assert!(validate_href("safe%2fchapter.xhtml", false).is_err());
        assert!(validate_href("https://example.test/chapter.xhtml", false).is_err());
        let invalid: Result<Request, _> = serde_json::from_value(json!({
            "schema_version": 2,
            "engine": "rbook",
            "expected_version": RBOOK_VERSION,
            "operation": "read",
            "payload": {},
            "unexpected": true
        }));
        assert!(invalid.is_err());

        let directory = TestDirectory::new();
        let payload = WritePayload {
            format: "epub".into(),
            mode: "create".into(),
            input_path: None,
            output_path: directory.path("bad.epub").to_string_lossy().into_owned(),
            operations: vec![Operation {
                kind: "shell".into(),
                parameters: json!({}),
            }],
            allowed_asset_paths: Vec::new(),
        };
        assert_eq!(
            write_epub(payload).unwrap_err().code,
            "unsupported_operation"
        );
    }

    #[test]
    fn enforces_asset_allowlist_and_active_content_policy() {
        let directory = TestDirectory::new();
        let output = directory.path("denied.epub");
        let mut payload = create_payload(&directory, &output);
        payload.allowed_asset_paths.clear();
        assert_eq!(write_epub(payload).unwrap_err().code, "validation_failed");

        let active = br#"<html xmlns="http://www.w3.org/1999/xhtml"><script>bad()</script></html>"#;
        assert_eq!(
            validate_resource_content("application/xhtml+xml", active)
                .unwrap_err()
                .code,
            "unsupported_feature"
        );
    }

    #[test]
    fn postcondition_detects_mismatch() {
        let directory = TestDirectory::new();
        let output = directory.path("book.epub");
        write_epub(create_payload(&directory, &output)).expect("create EPUB");
        let mismatch = Postcondition::Metadata {
            field: "title".into(),
            value: "Wrong".into(),
        };
        assert_eq!(
            verify_postconditions(&output, &[mismatch])
                .unwrap_err()
                .code,
            "validation_failed"
        );
    }

    #[test]
    fn zip_budget_rejects_high_expansion_ratio() {
        let directory = TestDirectory::new();
        let path = directory.path("bomb.epub");
        let file = File::create(&path).expect("create zip");
        let mut writer = zip::ZipWriter::new(file);
        writer
            .start_file(
                "large.bin",
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated),
            )
            .expect("start zip entry");
        writer
            .write_all(&vec![0_u8; 2 * 1024 * 1024])
            .expect("write zip entry");
        writer.finish().expect("finish zip");
        assert_eq!(
            preflight_epub_archive(&path).unwrap_err().code,
            "validation_failed"
        );
    }

    #[test]
    fn zip_preflight_rejects_duplicate_entry_names() {
        let directory = TestDirectory::new();
        let path = directory.path("duplicate.epub");
        let file = File::create(&path).expect("create zip");
        let mut writer = zip::ZipWriter::new(file);
        for (name, content) in [
            ("chapter1.xhtml", b"first".as_slice()),
            ("chapter2.xhtml", b"second".as_slice()),
        ] {
            writer
                .start_file(name, zip::write::SimpleFileOptions::default())
                .expect("start zip entry");
            writer.write_all(content).expect("write zip entry");
        }
        writer.finish().expect("finish zip");

        let old_name = b"chapter2.xhtml";
        let new_name = b"chapter1.xhtml";
        let mut bytes = fs::read(&path).expect("read zip");
        let mut replacements = 0;
        for index in 0..=bytes.len() - old_name.len() {
            if &bytes[index..index + old_name.len()] == old_name {
                bytes[index..index + old_name.len()].copy_from_slice(new_name);
                replacements += 1;
            }
        }
        assert_eq!(replacements, 2, "replace local and central filenames");
        fs::write(&path, bytes).expect("write duplicate-name zip");
        assert_eq!(
            preflight_epub_archive(&path).unwrap_err().code,
            "validation_failed"
        );
    }

    #[test]
    fn zip_preflight_rejects_case_colliding_entry_names() {
        let directory = TestDirectory::new();
        let path = directory.path("case-collision.epub");
        let file = File::create(&path).expect("create case-collision zip");
        let mut archive = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        archive
            .start_file("OPS/chapter.xhtml", options)
            .expect("first member");
        archive.write_all(b"one").expect("first content");
        archive
            .start_file("ops/chapter.xhtml", options)
            .expect("second member");
        archive.write_all(b"two").expect("second content");
        archive.finish().expect("finish case-collision zip");

        assert!(preflight_epub_archive(&path).is_err());
    }
}
