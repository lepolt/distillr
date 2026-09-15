//! Folder/volume walking and source abstraction (folder vs SD card).
//!
//! Local-folder scanning only for now; SD card/volume sources come later.

use std::io;
use std::path::{Path, PathBuf};

const JPEG_EXTENSIONS: &[&str] = &["jpg", "jpeg"];

/// Lists JPEG files directly inside `root` (non-recursive), sorted by path.
pub fn scan_folder(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(root)?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.is_file() && is_jpeg(path))
        .collect();
    paths.sort();
    Ok(paths)
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

    #[test]
    fn finds_all_example_jpegs_sorted() {
        let found = scan_folder(&examples_dir()).unwrap();
        assert_eq!(found.len(), 66);
        assert!(found.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(
            found[0].file_name().unwrap().to_str().unwrap(),
            "DSC_3676.JPG"
        );
    }

    #[test]
    fn ignores_non_jpeg_files() {
        let dir = tempdir();
        std::fs::write(dir.join("notes.txt"), b"hi").unwrap();
        std::fs::write(dir.join("photo.JPG"), b"fake").unwrap();
        let found = scan_folder(&dir).unwrap();
        assert_eq!(found.len(), 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cw-scan-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
