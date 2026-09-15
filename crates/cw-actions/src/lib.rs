//! Finalize actions: trashing rejected photos and copying keepers to a
//! destination folder.

use std::path::{Path, PathBuf};

#[derive(Debug, Default)]
pub struct TrashReport {
    pub trashed: Vec<PathBuf>,
    pub failed: Vec<(PathBuf, String)>,
}

impl TrashReport {
    pub fn is_success(&self) -> bool {
        self.failed.is_empty()
    }
}

/// Moves each path to the OS trash/recycle bin — never a hard delete.
/// Keeps going past individual failures (a file already gone, permissions,
/// etc.) instead of aborting the whole batch on the first error.
pub fn trash_paths(paths: &[PathBuf]) -> TrashReport {
    let mut report = TrashReport::default();
    for path in paths {
        match trash::delete(path) {
            Ok(()) => report.trashed.push(path.clone()),
            Err(e) => report.failed.push((path.clone(), e.to_string())),
        }
    }
    report
}

#[derive(Debug, Default)]
pub struct CopyReport {
    pub copied: Vec<PathBuf>,
    /// A file with the same name already existed at the destination, so it
    /// was left alone rather than silently overwritten.
    pub skipped_existing: Vec<PathBuf>,
    pub failed: Vec<(PathBuf, String)>,
}

impl CopyReport {
    pub fn is_success(&self) -> bool {
        self.failed.is_empty()
    }
}

/// Copies each path into `destination` (created if it doesn't exist yet),
/// keeping the original file name. Originals are left in place — this is a
/// copy, not a move. A name already present at the destination is skipped
/// rather than overwritten, so re-running Finalize after a partial copy
/// (or across sessions into the same destination) never clobbers a file.
pub fn copy_paths(paths: &[PathBuf], destination: &Path) -> CopyReport {
    let mut report = CopyReport::default();

    if let Err(e) = std::fs::create_dir_all(destination) {
        for path in paths {
            report
                .failed
                .push((path.clone(), format!("could not create destination: {e}")));
        }
        return report;
    }

    for path in paths {
        let Some(file_name) = path.file_name() else {
            report
                .failed
                .push((path.clone(), "path has no file name".to_string()));
            continue;
        };
        let dest_path = destination.join(file_name);
        if dest_path.exists() {
            report.skipped_existing.push(path.clone());
            continue;
        }
        match std::fs::copy(path, &dest_path) {
            Ok(_) => report.copied.push(path.clone()),
            Err(e) => report.failed.push((path.clone(), e.to_string())),
        }
    }

    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_file(name: &str, contents: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cw-actions-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn trashes_existing_files_and_reports_them() {
        let a = temp_file("a.jpg", b"a");
        let b = temp_file("b.jpg", b"b");

        let report = trash_paths(&[a.clone(), b.clone()]);

        assert!(report.is_success());
        assert_eq!(report.trashed, vec![a.clone(), b.clone()]);
        assert!(!a.exists());
        assert!(!b.exists());
    }

    #[test]
    fn missing_file_is_reported_as_a_failure_without_aborting_the_batch() {
        let real = temp_file("real.jpg", b"x");
        let missing = real.parent().unwrap().join("does-not-exist.jpg");

        let report = trash_paths(&[missing.clone(), real.clone()]);

        assert!(!report.is_success());
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].0, missing);
        assert_eq!(report.trashed, vec![real.clone()]);
        assert!(!real.exists());
    }

    fn temp_dir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cw-actions-test-{label}-{}-{}",
            std::process::id(),
            fastrand_id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    // No external RNG dependency for a test-only unique suffix.
    fn fastrand_id() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    #[test]
    fn copies_files_to_a_new_destination_leaving_originals_in_place() {
        let src = temp_dir("copy-src");
        let dest = temp_dir("copy-dest");
        std::fs::remove_dir(&dest).unwrap(); // copy_paths should create it

        let a = src.join("a.jpg");
        let b = src.join("b.jpg");
        fs::write(&a, b"a").unwrap();
        fs::write(&b, b"b").unwrap();

        let report = copy_paths(&[a.clone(), b.clone()], &dest);

        assert!(report.is_success());
        assert_eq!(report.copied, vec![a.clone(), b.clone()]);
        assert!(a.exists(), "original should be untouched by a copy");
        assert!(dest.join("a.jpg").exists());
        assert!(dest.join("b.jpg").exists());
        assert_eq!(fs::read(dest.join("a.jpg")).unwrap(), b"a");
    }

    #[test]
    fn skips_rather_than_overwrites_an_existing_destination_file() {
        let src = temp_dir("copy-src-existing");
        let dest = temp_dir("copy-dest-existing");

        let a = src.join("a.jpg");
        fs::write(&a, b"new-content").unwrap();
        fs::write(dest.join("a.jpg"), b"already-there").unwrap();

        let report = copy_paths(&[a.clone()], &dest);

        assert!(report.copied.is_empty());
        assert_eq!(report.skipped_existing, vec![a]);
        assert_eq!(fs::read(dest.join("a.jpg")).unwrap(), b"already-there");
    }
}
