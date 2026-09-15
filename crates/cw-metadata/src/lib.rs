//! EXIF metadata reading and RAW embedded-preview extraction.
//!
//! JPEG uses `kamadak-exif`. RAW formats (NEF, CR2/CR3, ARW, …) use
//! `rawler` — verified against real Nikon Z6III NEF files. For metadata,
//! `rawler`'s `raw_metadata()` gives the same `DateTimeOriginal` +
//! `SubSecTimeOriginal` shape as plain JPEG EXIF, so both paths share one
//! date parser. For display, `rawler`'s `full_image()` extracts the RAW
//! file's embedded JPEG preview (despite the name, this is not a real
//! demosaic — confirmed by testing: ~36ms, full sensor resolution) rather
//! than actually rendering the sensor data, which is what makes instant
//! burst review possible without a slow RAW decode.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use exif::{In, Tag, Value};
use image::DynamicImage;
use rawler::decoders::RawDecodeParams;
use rawler::rawsource::RawSource;
use time::{Date, Month, PrimitiveDateTime, Time};

/// Extensions recognized as RAW formats. `rawler` supports more than this
/// list covers, but only NEF has been verified against real camera files;
/// the rest are included because they go through the same generic path and
/// cost nothing extra to attempt.
pub const RAW_EXTENSIONS: &[&str] = &[
    "nef", "nrw", "cr2", "cr3", "crw", "arw", "srf", "sr2", "orf", "rw2", "raf", "pef", "dng",
    "srw", "x3f", "3fr", "iiq", "erf", "mrw",
];

pub fn is_raw_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| RAW_EXTENSIONS.iter().any(|raw| ext.eq_ignore_ascii_case(raw)))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotoMetadata {
    pub capture_time: PrimitiveDateTime,
    pub camera_model: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// Standard EXIF orientation (1-8). `None`/1 means no rotation needed;
    /// the stored image buffer (especially for RAW embedded previews, and
    /// commonly for JPEG too) is not pre-rotated for portrait shots — the
    /// display layer needs to apply this itself.
    pub orientation: Option<u16>,
}

#[derive(Debug)]
pub enum MetadataError {
    Io(std::io::Error),
    Exif(exif::Error),
    Raw(rawler::RawlerError),
    MissingCaptureTime,
    InvalidCaptureTime(String),
    NoPreviewAvailable,
}

impl From<std::io::Error> for MetadataError {
    fn from(e: std::io::Error) -> Self {
        MetadataError::Io(e)
    }
}

impl From<exif::Error> for MetadataError {
    fn from(e: exif::Error) -> Self {
        MetadataError::Exif(e)
    }
}

impl From<rawler::RawlerError> for MetadataError {
    fn from(e: rawler::RawlerError) -> Self {
        MetadataError::Raw(e)
    }
}

impl std::fmt::Display for MetadataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetadataError::Io(e) => write!(f, "io error: {e}"),
            MetadataError::Exif(e) => write!(f, "exif error: {e}"),
            MetadataError::Raw(e) => write!(f, "raw decode error: {e}"),
            MetadataError::MissingCaptureTime => write!(f, "no DateTimeOriginal tag found"),
            MetadataError::InvalidCaptureTime(raw) => {
                write!(f, "could not parse capture time: {raw:?}")
            }
            MetadataError::NoPreviewAvailable => {
                write!(f, "RAW file has no embedded preview image")
            }
        }
    }
}

impl std::error::Error for MetadataError {}

/// Reads capture time, camera model, and dimensions from a file, dispatching
/// on extension: JPEG via EXIF, RAW formats via `rawler`.
pub fn read_metadata(path: &Path) -> Result<PhotoMetadata, MetadataError> {
    if is_raw_extension(path) {
        read_raw_metadata(path)
    } else {
        read_jpeg_metadata(path)
    }
}

/// Reads EXIF metadata (capture time, camera model, dimensions) from a JPEG file.
pub fn read_jpeg_metadata(path: &Path) -> Result<PhotoMetadata, MetadataError> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let exif = exif::Reader::new().read_from_container(&mut reader)?;

    let date_time_original = ascii_field(&exif, Tag::DateTimeOriginal);
    let sub_sec_time_original = ascii_field(&exif, Tag::SubSecTimeOriginal);
    let capture_time = parse_capture_time(date_time_original.as_deref(), sub_sec_time_original.as_deref())?;
    let camera_model = ascii_field(&exif, Tag::Model);
    let width = numeric_field(&exif, Tag::PixelXDimension);
    let height = numeric_field(&exif, Tag::PixelYDimension);
    let orientation = numeric_field(&exif, Tag::Orientation).map(|v| v as u16);

    Ok(PhotoMetadata {
        capture_time,
        camera_model,
        width,
        height,
        orientation,
    })
}

/// Reads metadata from a RAW file via `rawler`'s generalized metadata,
/// which exposes the same `DateTimeOriginal`/`SubSecTimeOriginal` shape as
/// plain EXIF regardless of manufacturer.
pub fn read_raw_metadata(path: &Path) -> Result<PhotoMetadata, MetadataError> {
    let source = RawSource::new(path)?;
    let decoder = rawler::get_decoder(&source)?;
    let params = RawDecodeParams::default();
    let meta = decoder.raw_metadata(&source, &params)?;

    let capture_time = parse_capture_time(
        meta.exif.date_time_original.as_deref(),
        meta.exif.sub_sec_time_original.as_deref(),
    )?;

    Ok(PhotoMetadata {
        capture_time,
        camera_model: Some(meta.model).filter(|s| !s.is_empty()),
        width: None,
        height: None,
        orientation: meta.exif.orientation,
    })
}

/// Extracts a RAW file's embedded preview image — not a real demosaic, just
/// reading the JPEG already stored inside the file — for use as a thumbnail
/// or loupe image, the same way `image::open` is used for plain JPEGs.
pub fn read_raw_preview(path: &Path) -> Result<DynamicImage, MetadataError> {
    let source = RawSource::new(path)?;
    let decoder = rawler::get_decoder(&source)?;
    let params = RawDecodeParams::default();
    decoder
        .full_image(&source, &params)?
        .ok_or(MetadataError::NoPreviewAvailable)
}

fn ascii_field(exif: &exif::Exif, tag: Tag) -> Option<String> {
    let field = exif.get_field(tag, In::PRIMARY)?;
    match &field.value {
        Value::Ascii(vals) => vals.first().map(|bytes| {
            String::from_utf8_lossy(bytes)
                .trim_matches(char::from(0))
                .trim()
                .to_string()
        }),
        _ => None,
    }
}

fn numeric_field(exif: &exif::Exif, tag: Tag) -> Option<u32> {
    let field = exif.get_field(tag, In::PRIMARY)?;
    field.value.get_uint(0)
}

/// Parses the EXIF-style `DateTimeOriginal` ("YYYY:MM:DD HH:MM:SS") plus an
/// optional subsecond digit string, shared by both the JPEG EXIF path and
/// `rawler`'s generalized RAW metadata — both expose the same shape.
fn parse_capture_time(
    date_time_original: Option<&str>,
    sub_sec_time_original: Option<&str>,
) -> Result<PrimitiveDateTime, MetadataError> {
    let raw = date_time_original.ok_or(MetadataError::MissingCaptureTime)?;

    let mut nums = raw
        .split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty());
    let mut next_u32 =
        |err: &str| -> Result<u32, MetadataError> {
            nums.next()
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| MetadataError::InvalidCaptureTime(format!("{raw} ({err})")))
        };

    let year = next_u32("year")? as i32;
    let month = next_u32("month")?;
    let day = next_u32("day")?;
    let hour = next_u32("hour")?;
    let minute = next_u32("minute")?;
    let second = next_u32("second")?;

    let month = Month::try_from(month as u8)
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.to_string()))?;
    let date = Date::from_calendar_date(year, month, day as u8)
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.to_string()))?;

    let subsec_nanos = sub_sec_time_original.map(parse_subsec_nanos).unwrap_or(0);
    let time = Time::from_hms_nano(hour as u8, minute as u8, second as u8, subsec_nanos)
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.to_string()))?;

    Ok(PrimitiveDateTime::new(date, time))
}

/// EXIF subsecond fields are ASCII digit strings representing a fraction of a
/// second (e.g. "08" means 0.08s), with no fixed digit count across cameras.
fn parse_subsec_nanos(raw: &str) -> u32 {
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return 0;
    }
    let digits = &digits[..digits.len().min(9)];
    let padded = format!("{digits:0<9}");
    padded.parse().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn example_path(name: &str) -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples")).join(name)
    }

    #[test]
    fn reads_nikon_jpeg_metadata() {
        let meta = read_jpeg_metadata(&example_path("DSC_3676.JPG")).unwrap();
        assert_eq!(meta.camera_model.as_deref(), Some("NIKON Z6_3"));
        assert_eq!(meta.width, Some(6048));
        assert_eq!(meta.height, Some(4032));
        assert_eq!(meta.capture_time.hour(), 9);
        assert_eq!(meta.capture_time.minute(), 16);
        assert_eq!(meta.capture_time.second(), 14);
    }

    #[test]
    fn parses_subsecond_precision_for_burst_ordering() {
        let a = read_jpeg_metadata(&example_path("DSC_3676.JPG")).unwrap();
        let b = read_jpeg_metadata(&example_path("DSC_3677.JPG")).unwrap();
        assert!(b.capture_time > a.capture_time);
        let gap = b.capture_time - a.capture_time;
        // Nikon Z6III high-speed burst is well under half a second between frames.
        assert!(gap.whole_milliseconds() > 0 && gap.whole_milliseconds() < 500);
    }

    #[test]
    fn parses_subsec_string_variants() {
        assert_eq!(parse_subsec_nanos("08"), 80_000_000);
        assert_eq!(parse_subsec_nanos("8"), 800_000_000);
        assert_eq!(parse_subsec_nanos(""), 0);
    }

    #[test]
    fn reads_nikon_nef_metadata_matching_its_paired_jpeg() {
        let jpeg = read_jpeg_metadata(&example_path("DSC_3742.JPG")).unwrap();
        let raw = read_raw_metadata(&example_path("DSC_3742.NEF")).unwrap();

        assert_eq!(raw.capture_time, jpeg.capture_time);
        assert_eq!(raw.camera_model.as_deref(), Some("Z 6 3"));
    }

    #[test]
    fn read_metadata_dispatches_on_extension() {
        let jpeg = read_metadata(&example_path("DSC_3742.JPG")).unwrap();
        let raw = read_metadata(&example_path("DSC_3742.NEF")).unwrap();
        assert_eq!(jpeg.capture_time, raw.capture_time);
    }

    #[test]
    fn extracts_raw_embedded_preview_at_full_resolution() {
        let preview = read_raw_preview(&example_path("DSC_3742.NEF")).unwrap();
        // Sensor active area (6064x4040 per EXIF) vs. the embedded preview's
        // own output crop (6048x4032) legitimately differ slightly; just
        // confirm it's a real, full-size image rather than a small thumbnail.
        assert!(preview.width() >= 6000);
        assert!(preview.height() >= 4000);
    }

    #[test]
    fn is_raw_extension_recognizes_nef_but_not_jpeg() {
        assert!(is_raw_extension(Path::new("foo.NEF")));
        assert!(is_raw_extension(Path::new("foo.nef")));
        assert!(!is_raw_extension(Path::new("foo.jpg")));
    }

    #[test]
    fn reads_orientation_for_landscape_and_both_portrait_directions() {
        let landscape = read_jpeg_metadata(&example_path("DSC_3676.JPG")).unwrap();
        assert_eq!(landscape.orientation, Some(1));

        let rotated_90 = read_jpeg_metadata(&example_path("DSC_3751.JPG")).unwrap();
        assert_eq!(rotated_90.orientation, Some(6));

        let rotated_270 = read_jpeg_metadata(&example_path("DSC_3766.JPG")).unwrap();
        assert_eq!(rotated_270.orientation, Some(8));
    }
}
