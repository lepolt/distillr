//! Folder walking, with RAW+JPEG pairing. Works on any path the OS
//! resolves, including a mounted SD card/camera volume — a removable
//! volume looks like any other folder to `std::fs`, so no special-casing
//! is needed. Scanning is flat (not recursive), so the caller needs to
//! point at the folder that directly contains the photos.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

use cw_metadata::is_raw_extension;

const JPEG_EXTENSIONS: &[&str] = &["jpg", "jpeg"];

/// One photo as found on disk. When a camera writes RAW+JPEG together,
/// both halves share a base filename (`DSC_1234.JPG` / `DSC_1234.NEF`) and
/// are folded into a single `PhotoSource` rather than appearing as two
/// separate photos.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhotoSource {
    /// Used for metadata reading, thumbnails/loupe display, and as the key
    /// everywhere decisions are tracked. The JPEG half of a pair when one
    /// exists (cheaper to decode than extracting a RAW preview), otherwise
    /// whichever single file is there.
    pub primary: PathBuf,
    /// The paired RAW file, when `primary` is a JPEG with a same-named RAW
    /// file alongside it. Never read directly for display — only trashed
    /// or copied together with `primary` so the pair moves as a unit.
    pub sidecar: Option<PathBuf>,
}

/// Lists photos directly inside `root` (non-recursive), pairing RAW+JPEG
/// files that share a base filename, sorted by the primary path.
pub fn scan_folder(root: &Path) -> io::Result<Vec<PhotoSource>> {
    let mut by_stem: HashMap<String, Vec<PathBuf>> = HashMap::new();

    for entry in std::fs::read_dir(root)? {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        if !path.is_file() || !is_photo_file(&path) {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        by_stem.entry(stem.to_string()).or_default().push(path);
    }

    let mut sources: Vec<PhotoSource> = by_stem
        .into_values()
        .filter_map(|mut paths| {
            paths.sort();
            let jpeg = paths
                .iter()
                .position(|p| is_jpeg(p))
                .map(|i| paths.remove(i));
            let raw = paths.into_iter().find(|p| is_raw_extension(p));
            match jpeg {
                Some(jpeg) => Some(PhotoSource {
                    primary: jpeg,
                    sidecar: raw,
                }),
                None => raw.map(|raw| PhotoSource {
                    primary: raw,
                    sidecar: None,
                }),
            }
        })
        .collect();

    sources.sort_by(|a, b| a.primary.cmp(&b.primary));
    Ok(sources)
}

fn is_photo_file(path: &Path) -> bool {
    is_jpeg(path) || is_raw_extension(path)
}

fn is_jpeg(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| JPEG_EXTENSIONS.iter().any(|jpg| ext.eq_ignore_ascii_case(jpg)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn examples_dir() -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples"))
    }

    fn file_name(path: &Path) -> &str {
        path.file_name().unwrap().to_str().unwrap()
    }

    #[test]
    fn finds_all_example_photos_sorted_by_primary() {
        let found = scan_folder(&examples_dir()).unwrap();
        // 91 standalone JPEGs (66 original + 15 + 10 portrait) + 9 RAW+JPEG pairs.
        assert_eq!(found.len(), 100);
        assert!(found.windows(2).all(|w| w[0].primary < w[1].primary));
        assert_eq!(file_name(&found[0].primary), "DSC_3676.JPG");
    }

    #[test]
    fn pairs_raw_and_jpeg_sharing_a_base_filename() {
        let found = scan_folder(&examples_dir()).unwrap();
        let paired = found
            .iter()
            .find(|s| file_name(&s.primary) == "DSC_3742.JPG")
            .expect("DSC_3742.JPG should be found");
        assert_eq!(
            paired.sidecar.as_deref().map(file_name),
            Some("DSC_3742.NEF")
        );
    }

    #[test]
    fn standalone_jpeg_has_no_sidecar() {
        let found = scan_folder(&examples_dir()).unwrap();
        let solo = found
            .iter()
            .find(|s| file_name(&s.primary) == "DSC_3676.JPG")
            .expect("DSC_3676.JPG should be found");
        assert_eq!(solo.sidecar, None);
    }

    #[test]
    fn raw_only_file_becomes_its_own_primary() {
        let dir = tempdir("raw-only");
        std::fs::write(dir.join("IMG_0001.NEF"), b"fake-raw").unwrap();

        let found = scan_folder(&dir).unwrap();

        assert_eq!(found.len(), 1);
        assert_eq!(file_name(&found[0].primary), "IMG_0001.NEF");
        assert_eq!(found[0].sidecar, None);

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn ignores_non_photo_files() {
        let dir = tempdir("ignore-others");
        std::fs::write(dir.join("notes.txt"), b"hi").unwrap();
        std::fs::write(dir.join("photo.JPG"), b"fake").unwrap();
        let found = scan_folder(&dir).unwrap();
        assert_eq!(found.len(), 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn tempdir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cw-scan-test-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
