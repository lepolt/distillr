//! Burst-sequence detection: timestamp clustering and perceptual-hash
//! refinement.
//!
//! Timestamp clustering only for now; perceptual-hash refinement comes
//! later, once there's a real case that needs it. RAW+JPEG pairing lives
//! upstream in `cw-scan` (`PhotoSource`) — by the time a photo becomes a
//! `BurstItem` here, `path` is already the one path that represents it.

use std::path::PathBuf;

use time::{Duration, PrimitiveDateTime};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BurstItem {
    pub path: PathBuf,
    /// The paired RAW file, when `path` is a JPEG with a RAW file alongside
    /// it (see `cw_scan::PhotoSource`). Carried through grouping so
    /// Finalize can trash/copy it together with `path`.
    pub sidecar: Option<PathBuf>,
    pub capture_time: PrimitiveDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BurstGroup {
    pub items: Vec<BurstItem>,
}

impl BurstGroup {
    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

/// Comfortably larger than any real continuous-shooting interval (typically
/// tens to a few hundred ms), comfortably smaller than the pause between
/// separate moments (seconds, at minimum).
pub const DEFAULT_GAP_THRESHOLD: Duration = Duration::milliseconds(2000);

/// Groups items into burst sequences: a new group starts whenever the gap
/// from the previous item's capture time exceeds `gap_threshold`.
pub fn group_bursts(mut items: Vec<BurstItem>, gap_threshold: Duration) -> Vec<BurstGroup> {
    items.sort_by_key(|item| item.capture_time);

    let mut groups: Vec<BurstGroup> = Vec::new();
    for item in items {
        let starts_new_group = match groups.last().and_then(|g| g.items.last()) {
            Some(prev) => item.capture_time - prev.capture_time > gap_threshold,
            None => true,
        };
        if starts_new_group {
            groups.push(BurstGroup { items: vec![item] });
        } else {
            groups.last_mut().unwrap().items.push(item);
        }
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn examples_dir() -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples"))
    }

    fn load_real_items() -> Vec<BurstItem> {
        cw_scan::scan_folder(&examples_dir())
            .unwrap()
            .into_iter()
            .map(|source| {
                let meta = cw_metadata::read_metadata(&source.primary).unwrap();
                BurstItem {
                    path: source.primary,
                    sidecar: source.sidecar,
                    capture_time: meta.capture_time,
                }
            })
            .collect()
    }

    fn file_name(item: &BurstItem) -> &str {
        Path::new(&item.path).file_name().unwrap().to_str().unwrap()
    }

    #[test]
    fn groups_real_bursts_by_capture_gap() {
        let items = load_real_items();
        let groups = group_bursts(items, DEFAULT_GAP_THRESHOLD);

        let sizes: Vec<usize> = groups.iter().map(BurstGroup::len).collect();
        // Original 6 JPEG bursts, then a 9-shot RAW+JPEG burst
        // (DSC_3742-3750), then three portrait-JPEG bursts.
        assert_eq!(sizes, vec![20, 17, 6, 5, 12, 6, 9, 7, 8, 10]);

        assert_eq!(file_name(&groups[0].items[0]), "DSC_3676.JPG");
        assert_eq!(
            file_name(groups[0].items.last().unwrap()),
            "DSC_3695.JPG"
        );
        assert_eq!(file_name(&groups[1].items[0]), "DSC_3696.JPG");
        assert_eq!(file_name(&groups[5].items[0]), "DSC_3736.JPG");
        assert_eq!(
            file_name(groups[5].items.last().unwrap()),
            "DSC_3741.JPG"
        );

        assert_eq!(file_name(&groups[6].items[0]), "DSC_3742.JPG");
        assert_eq!(
            groups[6].items[0].sidecar.as_deref().and_then(|p| p.file_name()),
            Some(std::ffi::OsStr::new("DSC_3742.NEF")),
        );
        assert_eq!(
            file_name(groups[6].items.last().unwrap()),
            "DSC_3750.JPG"
        );

        assert_eq!(file_name(&groups[7].items[0]), "DSC_3751.JPG");
        assert_eq!(file_name(&groups[8].items[0]), "DSC_3758.JPG");
        assert_eq!(file_name(&groups[9].items[0]), "DSC_3766.JPG");
        assert_eq!(
            file_name(groups[9].items.last().unwrap()),
            "DSC_3775.JPG"
        );
    }

    #[test]
    fn groups_are_internally_sorted_by_capture_time() {
        let items = load_real_items();
        let groups = group_bursts(items, DEFAULT_GAP_THRESHOLD);
        for group in &groups {
            assert!(group
                .items
                .windows(2)
                .all(|w| w[0].capture_time <= w[1].capture_time));
        }
    }

    #[test]
    fn empty_input_yields_no_groups() {
        assert!(group_bursts(Vec::new(), DEFAULT_GAP_THRESHOLD).is_empty());
    }

    fn item(name: &str, capture_time: PrimitiveDateTime) -> BurstItem {
        BurstItem {
            path: PathBuf::from(name),
            sidecar: None,
            capture_time,
        }
    }

    #[test]
    fn single_item_yields_one_group() {
        let items = vec![item("a.jpg", PrimitiveDateTime::MIN)];
        let groups = group_bursts(items, DEFAULT_GAP_THRESHOLD);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].len(), 1);
    }

    #[test]
    fn gap_larger_than_threshold_splits_groups() {
        let base = PrimitiveDateTime::MIN;
        let items = vec![
            item("a.jpg", base),
            item("b.jpg", base + Duration::milliseconds(100)),
            item("c.jpg", base + Duration::seconds(10)),
        ];
        let groups = group_bursts(items, DEFAULT_GAP_THRESHOLD);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].len(), 2);
        assert_eq!(groups[1].len(), 1);
    }
}
