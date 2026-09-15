//! EXIF metadata reading and RAW embedded-preview extraction.
//!
//! JPEG support only for now; RAW (via `rawler`) comes later.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use exif::{In, Tag, Value};
use time::{Date, Month, PrimitiveDateTime, Time};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotoMetadata {
    pub capture_time: PrimitiveDateTime,
    pub camera_model: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Debug)]
pub enum MetadataError {
    Io(std::io::Error),
    Exif(exif::Error),
    MissingCaptureTime,
    InvalidCaptureTime(String),
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

impl std::fmt::Display for MetadataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MetadataError::Io(e) => write!(f, "io error: {e}"),
            MetadataError::Exif(e) => write!(f, "exif error: {e}"),
            MetadataError::MissingCaptureTime => write!(f, "no DateTimeOriginal tag found"),
            MetadataError::InvalidCaptureTime(raw) => {
                write!(f, "could not parse capture time: {raw:?}")
            }
        }
    }
}

impl std::error::Error for MetadataError {}

/// Reads EXIF metadata (capture time, camera model, dimensions) from a JPEG file.
pub fn read_jpeg_metadata(path: &Path) -> Result<PhotoMetadata, MetadataError> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let exif = exif::Reader::new().read_from_container(&mut reader)?;

    let capture_time = parse_capture_time(&exif)?;
    let camera_model = ascii_field(&exif, Tag::Model);
    let width = numeric_field(&exif, Tag::PixelXDimension);
    let height = numeric_field(&exif, Tag::PixelYDimension);

    Ok(PhotoMetadata {
        capture_time,
        camera_model,
        width,
        height,
    })
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

fn parse_capture_time(exif: &exif::Exif) -> Result<PrimitiveDateTime, MetadataError> {
    let raw =
        ascii_field(exif, Tag::DateTimeOriginal).ok_or(MetadataError::MissingCaptureTime)?;

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
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.clone()))?;
    let date = Date::from_calendar_date(year, month, day as u8)
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.clone()))?;

    let subsec_nanos = ascii_field(exif, Tag::SubSecTimeOriginal)
        .map(|s| parse_subsec_nanos(&s))
        .unwrap_or(0);
    let time = Time::from_hms_nano(hour as u8, minute as u8, second as u8, subsec_nanos)
        .map_err(|_| MetadataError::InvalidCaptureTime(raw.clone()))?;

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
}
