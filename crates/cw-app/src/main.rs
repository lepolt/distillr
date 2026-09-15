use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};

use cw_burst::{BurstGroup, BurstItem};

const THUMBNAIL_MAX_SIDE: u32 = 200;
const LOUPE_MAX_SIDE: u32 = 1400;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions::default();
    eframe::run_native(
        "cull-wizard",
        options,
        Box::new(|_cc| Ok(Box::new(CullWizardApp::default()))),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Decision {
    #[default]
    Undecided,
    Keep,
    Reject,
}

impl Decision {
    fn label(self) -> &'static str {
        match self {
            Decision::Undecided => "undecided",
            Decision::Keep => "KEEP",
            Decision::Reject => "REJECT",
        }
    }

    fn color(self) -> egui::Color32 {
        match self {
            Decision::Undecided => egui::Color32::GRAY,
            Decision::Keep => egui::Color32::from_rgb(90, 200, 90),
            Decision::Reject => egui::Color32::from_rgb(220, 90, 90),
        }
    }
}

const UNVIEWED_COLOR: egui::Color32 = egui::Color32::GRAY;
const VIEWED_UNDECIDED_COLOR: egui::Color32 = egui::Color32::from_rgb(230, 200, 60);
/// macOS system blue / a close match for the default Windows accent —
/// used for the primary action button in dialogs.
const ACCENT_COLOR: egui::Color32 = egui::Color32::from_rgb(10, 132, 255);

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

fn describe_failures(failures: &[(PathBuf, String)]) -> String {
    failures
        .iter()
        .map(|(path, err)| format!("{}: {err}", path.display()))
        .collect::<Vec<_>>()
        .join("; ")
}

struct ReviewState {
    group_index: usize,
    item_index: usize,
}

const MAX_COMPARE_PANELS: usize = 4;

struct CompareState {
    group_index: usize,
    /// One entry per visible panel. `None` means the slot ran out of
    /// replacement photos (everything else in the group got decided).
    slots: Vec<Option<PathBuf>>,
    focused: usize,
}

/// Keyboard cursor over the grid's thumbnails. `active_index` indexes into
/// that group's list of currently-visible (non-rejected) thumbnails, not
/// the group's full item list.
struct GridFocus {
    group_index: usize,
    active_index: usize,
}

#[derive(Default)]
struct CullWizardApp {
    source_folder: Option<PathBuf>,
    groups: Vec<BurstGroup>,
    thumbnails: HashMap<PathBuf, egui::TextureHandle>,
    thumbnails_total: usize,
    status: String,
    thumbnail_rx: Option<Receiver<(PathBuf, egui::TextureHandle)>>,
    decisions: HashMap<PathBuf, Decision>,
    viewed: HashSet<PathBuf>,
    review: Option<ReviewState>,
    loupe_cache: HashMap<PathBuf, egui::TextureHandle>,
    show_finalize: bool,
    finalize_trash_rejected: bool,
    finalize_copy_keepers: bool,
    finalize_destination: Option<PathBuf>,
    commit_status: Option<String>,
    /// Multi-selected thumbnails in the grid, used to seed Compare mode.
    selected: HashSet<PathBuf>,
    compare: Option<CompareState>,
    grid_focus: Option<GridFocus>,
}

impl CullWizardApp {
    fn choose_folder(&mut self, ctx: &egui::Context) {
        let Some(folder) = rfd::FileDialog::new().pick_folder() else {
            return;
        };
        self.load_folder(folder, ctx);
    }

    fn load_folder(&mut self, folder: PathBuf, ctx: &egui::Context) {
        self.groups.clear();
        self.thumbnails.clear();
        self.thumbnail_rx = None;
        self.decisions.clear();
        self.viewed.clear();
        self.review = None;
        self.loupe_cache.clear();
        self.show_finalize = false;
        self.finalize_destination = None;
        self.commit_status = None;
        self.selected.clear();
        self.compare = None;
        self.grid_focus = None;

        let paths = match cw_scan::scan_folder(&folder) {
            Ok(paths) => paths,
            Err(e) => {
                self.status = format!("Could not read {}: {e}", folder.display());
                self.source_folder = Some(folder);
                return;
            }
        };

        let mut items = Vec::with_capacity(paths.len());
        let mut unreadable = 0usize;
        for path in paths {
            match cw_metadata::read_jpeg_metadata(&path) {
                Ok(meta) => items.push(BurstItem {
                    path,
                    capture_time: meta.capture_time,
                }),
                Err(_) => unreadable += 1,
            }
        }

        let photo_count = items.len();
        self.groups = cw_burst::group_bursts(items, cw_burst::DEFAULT_GAP_THRESHOLD);

        let paths_to_load: Vec<PathBuf> = self
            .groups
            .iter()
            .flat_map(|group| group.items.iter().map(|item| item.path.clone()))
            .collect();
        self.thumbnails_total = paths_to_load.len();
        self.thumbnail_rx = Some(spawn_thumbnail_loaders(ctx.clone(), paths_to_load));

        self.status = format!(
            "{photo_count} photos in {} burst groups{}",
            self.groups.len(),
            if unreadable > 0 {
                format!(" ({unreadable} could not be read)")
            } else {
                String::new()
            }
        );
        self.source_folder = Some(folder);
    }

    /// Pulls any thumbnails finished by the background workers since the last
    /// frame. Non-blocking: returns immediately once the channel is drained.
    fn drain_ready_thumbnails(&mut self) {
        let Some(rx) = &self.thumbnail_rx else {
            return;
        };
        while let Ok((path, texture)) = rx.try_recv() {
            self.thumbnails.insert(path, texture);
        }
    }

    /// Opens review on `item_index`, or the nearest non-rejected item if
    /// that one has already been rejected (e.g. the plain "Review" button
    /// always requests index 0, which may itself be rejected).
    fn enter_review(&mut self, group_index: usize, item_index: usize) {
        let target = self
            .nearest_active_index(group_index, item_index)
            .unwrap_or(item_index);
        self.review = Some(ReviewState {
            group_index,
            item_index: target,
        });
    }

    fn current_review_path(&self) -> Option<PathBuf> {
        let review = self.review.as_ref()?;
        let group = self.groups.get(review.group_index)?;
        group.items.get(review.item_index).map(|i| i.path.clone())
    }

    fn is_active(&self, group: &BurstGroup, index: usize) -> bool {
        group
            .items
            .get(index)
            .map(|item| self.decisions.get(&item.path).copied().unwrap_or_default() != Decision::Reject)
            .unwrap_or(false)
    }

    /// Finds the nearest non-rejected item to `from_index` in `group_index`:
    /// `from_index` itself if active, otherwise the closest active item
    /// scanning forward, then backward. `None` if every item is rejected.
    fn nearest_active_index(&self, group_index: usize, from_index: usize) -> Option<usize> {
        let group = self.groups.get(group_index)?;
        if self.is_active(group, from_index) {
            return Some(from_index);
        }
        (from_index + 1..group.items.len())
            .find(|&i| self.is_active(group, i))
            .or_else(|| (0..from_index).rev().find(|&i| self.is_active(group, i)))
    }

    /// True once every photo in the group currently under review has been
    /// rejected — nothing left to show, so review should fall back to the
    /// grid (which renders this as an empty active row for that burst, plus
    /// everything tucked into its "Rejected" section).
    fn review_group_exhausted(&self) -> bool {
        match &self.review {
            Some(review) => self
                .nearest_active_index(review.group_index, review.item_index)
                .is_none(),
            None => false,
        }
    }

    /// Up to `count` active photos in `group_index`, starting at
    /// `start_index` and scanning forward — used to seed Compare mode from
    /// within single-photo Review (current photo + the next few).
    fn active_paths_from(&self, group_index: usize, start_index: usize, count: usize) -> Vec<PathBuf> {
        let Some(group) = self.groups.get(group_index) else {
            return Vec::new();
        };
        (start_index..group.items.len())
            .filter(|&i| self.is_active(group, i))
            .take(count)
            .map(|i| group.items[i].path.clone())
            .collect()
    }

    /// Up to `needed` active photos in `group_index` not already occupying
    /// a Compare slot — used to refill a slot after its photo is decided,
    /// or to add slots when the panel count grows.
    fn compare_backfill_candidates(
        &self,
        group_index: usize,
        exclude: &HashSet<PathBuf>,
        needed: usize,
    ) -> Vec<PathBuf> {
        let Some(group) = self.groups.get(group_index) else {
            return Vec::new();
        };
        (0..group.items.len())
            .filter(|&i| self.is_active(group, i))
            .map(|i| group.items[i].path.clone())
            .filter(|path| !exclude.contains(path))
            .take(needed)
            .collect()
    }

    fn compare_group_exhausted(&self) -> bool {
        match &self.compare {
            Some(compare) => compare.slots.iter().all(Option::is_none),
            None => false,
        }
    }

    fn enter_compare(&mut self, group_index: usize, paths: Vec<PathBuf>) {
        if paths.is_empty() {
            return;
        }
        self.review = None;
        self.compare = Some(CompareState {
            group_index,
            slots: paths.into_iter().take(MAX_COMPARE_PANELS).map(Some).collect(),
            focused: 0,
        });
    }

    /// Resizes the visible panel count, backfilling new slots with active
    /// photos not already shown. Shrinking just drops the trailing slots —
    /// nothing is decided for them, so no state needs cleaning up.
    fn resize_compare(&mut self, panel_count: usize) {
        let panel_count = panel_count.clamp(1, MAX_COMPARE_PANELS);
        let Some(compare) = &self.compare else {
            return;
        };
        let group_index = compare.group_index;
        let current_len = compare.slots.len();

        if panel_count <= current_len {
            if let Some(compare) = self.compare.as_mut() {
                compare.slots.truncate(panel_count.max(1));
                if compare.focused >= compare.slots.len() {
                    compare.focused = compare.slots.len().saturating_sub(1);
                }
            }
            return;
        }

        let shown: HashSet<PathBuf> = compare.slots.iter().flatten().cloned().collect();
        let missing = panel_count - current_len;
        let fresh = self.compare_backfill_candidates(group_index, &shown, missing);

        if let Some(compare) = self.compare.as_mut() {
            let mut fresh = fresh.into_iter();
            while compare.slots.len() < panel_count {
                compare.slots.push(fresh.next());
            }
        }
    }

    /// Moves panel focus by `delta_col` (Left/Right, one panel at a time)
    /// and `delta_row` (Up/Down). In the 2x2 layout (4 panels) a row step
    /// is 2 positions, matching the two-column grid; in the single-row
    /// layout (2-3 panels) a row step wraps back to the same panel, since
    /// there's nothing above or below to move to. Wraps around at the ends.
    fn move_compare_focus(&mut self, delta_col: isize, delta_row: isize) {
        let Some(compare) = self.compare.as_mut() else {
            return;
        };
        let len = compare.slots.len() as isize;
        if len <= 0 {
            return;
        }
        let row_stride = if len > 3 { 2 } else { len };
        let delta = delta_col + delta_row * row_stride;
        compare.focused = (compare.focused as isize + delta).rem_euclid(len) as usize;
    }

    /// Records `decision` for whichever photo is in the focused panel, then
    /// refills that panel with the next available undecided photo from the
    /// group (or leaves it empty if none remain) — mirrors how single-photo
    /// review auto-advances after any decision.
    fn decide_focused_compare_panel(&mut self, decision: Decision) {
        let Some(compare) = self.compare.as_ref() else {
            return;
        };
        let group_index = compare.group_index;
        let focused = compare.focused;
        let Some(path) = compare.slots.get(focused).cloned().flatten() else {
            return;
        };

        self.decisions.insert(path, decision);

        let shown: HashSet<PathBuf> = self
            .compare
            .as_ref()
            .unwrap()
            .slots
            .iter()
            .flatten()
            .cloned()
            .collect();
        let replacement = self
            .compare_backfill_candidates(group_index, &shown, 1)
            .into_iter()
            .next();

        if let Some(compare) = self.compare.as_mut() {
            compare.slots[focused] = replacement;
        }
    }

    /// Moves the current review item by `delta` steps, counting only
    /// non-rejected items and skipping over rejected ones — so arrowing
    /// through a group never lands on (or passes visibly through) a photo
    /// that's already been rejected. Clamps at the nearest active item to
    /// either end once there's nothing further to move to.
    fn review_move(&mut self, delta: isize) {
        let Some(review) = self.review.as_ref() else {
            return;
        };
        let group_index = review.group_index;
        let start = review.item_index;
        let Some(group) = self.groups.get(group_index) else {
            return;
        };
        let len = group.items.len();
        if len == 0 {
            return;
        }

        let active: Vec<bool> = (0..len).map(|i| self.is_active(group, i)).collect();
        let step: isize = if delta >= 0 { 1 } else { -1 };
        let mut idx = start as isize;
        let mut target = active.get(start).copied().unwrap_or(false).then_some(start);
        let mut remaining = delta.unsigned_abs();

        while remaining > 0 {
            let next = idx + step;
            if next < 0 || next >= len as isize {
                break;
            }
            idx = next;
            if active[idx as usize] {
                target = Some(idx as usize);
                remaining -= 1;
            }
        }

        // Nothing found in the requested direction — this happens when the
        // starting item was just rejected and was the last active item that
        // way (e.g. rejecting the last photo in the group). Fall back to
        // the nearest active item in either direction, so rejecting the
        // last photo re-selects the previous one instead of leaving the
        // just-rejected photo showing.
        if target.is_none() {
            target = self.nearest_active_index(group_index, start);
        }

        if let (Some(target), Some(review)) = (target, self.review.as_mut()) {
            review.item_index = target;
        }
    }

    fn load_loupe_texture(&mut self, ctx: &egui::Context, path: &Path) {
        if self.loupe_cache.contains_key(path) {
            return;
        }
        let Ok(image) = image::open(path) else {
            return;
        };
        let large = image.thumbnail(LOUPE_MAX_SIDE, LOUPE_MAX_SIDE).into_rgba8();
        let size = [large.width() as usize, large.height() as usize];
        let color_image = egui::ColorImage::from_rgba_unmultiplied(size, large.as_raw());
        let texture = ctx.load_texture(
            format!("loupe-{}", path.display()),
            color_image,
            egui::TextureOptions::default(),
        );
        self.loupe_cache.insert(path.to_path_buf(), texture);
    }

    fn rejected_paths(&self) -> Vec<PathBuf> {
        self.paths_matching(|d| d == Decision::Reject)
    }

    /// Everything not explicitly rejected — Keep *and* Undecided. A review
    /// pass mostly presses X on the bad shots, so treating "keeper" as
    /// "anything not rejected" means a photo is never silently excluded
    /// from Finalize just because it was never explicitly marked Keep.
    fn keeper_paths(&self) -> Vec<PathBuf> {
        self.paths_matching(|d| d != Decision::Reject)
    }

    fn undecided_count(&self) -> usize {
        self.paths_matching(|d| d == Decision::Undecided).len()
    }

    fn paths_matching(&self, predicate: impl Fn(Decision) -> bool) -> Vec<PathBuf> {
        self.groups
            .iter()
            .flat_map(|group| group.items.iter())
            .filter(|item| predicate(self.decisions.get(&item.path).copied().unwrap_or_default()))
            .map(|item| item.path.clone())
            .collect()
    }

    /// Runs whichever of the two Finalize actions the user checked:
    /// optionally copies every keeper (Keep + Undecided) to `destination`,
    /// and optionally moves every rejected photo to the OS trash (removing
    /// it from the loaded groups). Each action is independent — running
    /// only one, or neither is a no-op. Copied keepers are left in the
    /// grid, since only trashing actually removes something from the
    /// source. Only reachable from the grid (never while `self.review` is
    /// `Some`), so there's no review state to fix up afterwards.
    fn run_finalize(&mut self, trash_rejected: bool, copy_destination: Option<PathBuf>) {
        let mut messages = Vec::new();

        if let Some(dest) = copy_destination {
            let keepers = self.keeper_paths();
            let report = cw_actions::copy_paths(&keepers, &dest);
            messages.push(format!(
                "Copied {} photo{} to {}.",
                report.copied.len(),
                plural(report.copied.len()),
                dest.display()
            ));
            if !report.skipped_existing.is_empty() {
                messages.push(format!(
                    "{} already existed at the destination and were left as-is.",
                    report.skipped_existing.len()
                ));
            }
            if !report.failed.is_empty() {
                messages.push(format!(
                    "{} failed to copy — {}",
                    report.failed.len(),
                    describe_failures(&report.failed)
                ));
            }
        }

        if trash_rejected {
            let rejected = self.rejected_paths();
            if !rejected.is_empty() {
                let report = cw_actions::trash_paths(&rejected);
                let trashed: HashSet<PathBuf> = report.trashed.into_iter().collect();

                for group in &mut self.groups {
                    group.items.retain(|item| !trashed.contains(&item.path));
                }
                self.groups.retain(|group| !group.items.is_empty());

                for path in &trashed {
                    self.decisions.remove(path);
                    self.viewed.remove(path);
                    self.thumbnails.remove(path);
                    self.loupe_cache.remove(path);
                    self.selected.remove(path);
                }

                messages.push(format!(
                    "Trashed {} photo{}.",
                    trashed.len(),
                    plural(trashed.len())
                ));
                if !report.failed.is_empty() {
                    messages.push(format!(
                        "{} failed to trash — {}",
                        report.failed.len(),
                        describe_failures(&report.failed)
                    ));
                }
            }
        }

        if !messages.is_empty() {
            self.commit_status = Some(messages.join(" "));
        }
    }

    /// Border color reflecting both the decision and whether this photo has
    /// ever been shown in the loupe: green (kept), red (rejected), yellow
    /// (viewed but still undecided), gray (never viewed).
    fn border_color(&self, path: &Path) -> egui::Color32 {
        match self.decisions.get(path).copied().unwrap_or_default() {
            Decision::Keep => Decision::Keep.color(),
            Decision::Reject => Decision::Reject.color(),
            Decision::Undecided => {
                if self.viewed.contains(path) {
                    VIEWED_UNDECIDED_COLOR
                } else {
                    UNVIEWED_COLOR
                }
            }
        }
    }

    /// Shows the Finalize dialog when `show_finalize` is set: two
    /// independent choices (trash the rejects, copy the keepers) the user
    /// can check on or off separately — doing only one is a normal case,
    /// not just doing both together — plus a destination picker for the
    /// copy and an explicit confirm step.
    fn render_finalize_dialog(&mut self, ui: &mut egui::Ui) {
        if !self.show_finalize {
            return;
        }

        let rejected_count = self.rejected_paths().len();
        let keeper_count = self.keeper_paths().len();
        let undecided_count = self.undecided_count();

        let mut confirmed = false;
        let mut cancelled = false;
        let mut pick_destination = false;

        let modal = egui::Modal::new(egui::Id::new("finalize"))
            .frame(
                egui::Frame::popup(ui.style())
                    .corner_radius(14u8)
                    .inner_margin(egui::Margin::same(20))
                    .shadow(egui::Shadow {
                        offset: [0, 12],
                        blur: 32,
                        spread: 0,
                        color: egui::Color32::from_black_alpha(90),
                    }),
            )
            .show(ui.ctx(), |ui| {
                ui.set_width(360.0);
                ui.heading("Finalize");
                ui.add_space(2.0);
                ui.weak("Choose what to do with this session's decisions.");
                ui.add_space(10.0);

                ui.add_enabled_ui(rejected_count > 0, |ui| {
                    ui.checkbox(
                        &mut self.finalize_trash_rejected,
                        format!(
                            "Move {rejected_count} rejected photo{} to the trash",
                            plural(rejected_count)
                        ),
                    );
                });
                ui.add_space(4.0);

                ui.add_enabled_ui(keeper_count > 0, |ui| {
                    ui.checkbox(
                        &mut self.finalize_copy_keepers,
                        format!(
                            "Copy {keeper_count} keeper photo{} to a destination folder",
                            plural(keeper_count)
                        ),
                    );
                });
                if undecided_count > 0 {
                    ui.add_space(2.0);
                    ui.colored_label(
                        VIEWED_UNDECIDED_COLOR,
                        format!("({undecided_count} of those are still undecided.)"),
                    );
                }

                if self.finalize_copy_keepers && keeper_count > 0 {
                    ui.add_space(6.0);
                    ui.indent("finalize_destination", |ui| {
                        ui.horizontal(|ui| {
                            ui.label("Destination:");
                            match &self.finalize_destination {
                                Some(dest) => {
                                    ui.weak(dest.display().to_string());
                                }
                                None => {
                                    ui.weak("(not chosen)");
                                }
                            }
                            if ui.button("Choose…").clicked() {
                                pick_destination = true;
                            }
                        });
                    });
                }

                ui.add_space(14.0);
                ui.separator();
                ui.add_space(10.0);

                let will_trash = self.finalize_trash_rejected && rejected_count > 0;
                let will_copy = self.finalize_copy_keepers && keeper_count > 0;
                let ready = (will_trash || will_copy)
                    && (!will_copy || self.finalize_destination.is_some());

                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let finalize_button = egui::Button::new(
                        egui::RichText::new("Finalize").color(egui::Color32::WHITE),
                    )
                    .fill(ACCENT_COLOR)
                    .corner_radius(6u8)
                    .min_size(egui::vec2(84.0, 0.0));
                    if ui.add_enabled(ready, finalize_button).clicked() {
                        confirmed = true;
                    }
                    if ui
                        .add(egui::Button::new("Cancel").corner_radius(6u8))
                        .clicked()
                    {
                        cancelled = true;
                    }
                });
            });
        if modal.backdrop_response.clicked() {
            cancelled = true;
        }

        if pick_destination {
            if let Some(dest) = rfd::FileDialog::new().pick_folder() {
                self.finalize_destination = Some(dest);
            }
        }

        if confirmed {
            let trash_rejected = self.finalize_trash_rejected && rejected_count > 0;
            let copy_destination = (self.finalize_copy_keepers && keeper_count > 0)
                .then(|| self.finalize_destination.take())
                .flatten();
            self.run_finalize(trash_rejected, copy_destination);
        }
        if confirmed || cancelled {
            self.show_finalize = false;
            self.finalize_destination = None;
        }
    }

    /// Renders one thumbnail and returns its click response, so callers can
    /// detect double-clicks without the frame consuming them itself.
    fn render_thumb(
        &self,
        ui: &mut egui::Ui,
        path: &Path,
        max_side: f32,
        focused: bool,
    ) -> egui::Response {
        let Some(texture) = self.thumbnails.get(path) else {
            return ui.label("…");
        };
        let selection_stroke = if self.selected.contains(path) {
            egui::Stroke::new(3.0, ACCENT_COLOR)
        } else {
            egui::Stroke::NONE
        };
        let focus_fill = if focused {
            egui::Color32::from_rgba_unmultiplied(10, 132, 255, 45)
        } else {
            egui::Color32::TRANSPARENT
        };
        let outer = egui::Frame::new()
            .stroke(selection_stroke)
            .fill(focus_fill)
            .inner_margin(2.0)
            .show(ui, |ui| {
                egui::Frame::new()
                    .stroke(egui::Stroke::new(2.0, self.border_color(path)))
                    .inner_margin(2.0)
                    .show(ui, |ui| {
                        ui.add(egui::Image::new(texture).max_width(max_side));
                    });
            });
        outer.response.interact(egui::Sense::click())
    }

    /// For every group, the full-group item indices of its currently
    /// visible (non-rejected) thumbnails, in display order.
    fn compute_active_lists(&self) -> Vec<Vec<usize>> {
        self.groups
            .iter()
            .map(|group| {
                group
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, item)| {
                        self.decisions.get(&item.path).copied().unwrap_or_default()
                            != Decision::Reject
                    })
                    .map(|(item_index, _)| item_index)
                    .collect()
            })
            .collect()
    }

    /// Moves the grid's keyboard cursor by `delta_col` and `delta_row`
    /// (row steps count `columns_per_row` positions), clamped within the
    /// focused group's visible thumbnails — mirrors Finder icon-view arrow
    /// navigation. Starts a cursor at the first visible thumbnail of the
    /// first non-empty group if there wasn't one yet.
    fn move_grid_focus(&mut self, delta_col: isize, delta_row: isize, columns_per_row: usize) {
        let active_lists = self.compute_active_lists();
        let current = self.grid_focus.as_ref().and_then(|f| {
            let len = active_lists.get(f.group_index)?.len();
            (len > 0).then_some((f.group_index, f.active_index.min(len - 1), len))
        });
        match current {
            Some((group_index, active_index, len)) => {
                let delta = delta_col + delta_row * columns_per_row as isize;
                let new_index = (active_index as isize + delta).clamp(0, len as isize - 1) as usize;
                self.grid_focus = Some(GridFocus {
                    group_index,
                    active_index: new_index,
                });
            }
            None => {
                if let Some((group_index, _)) =
                    active_lists.iter().enumerate().find(|(_, list)| !list.is_empty())
                {
                    self.grid_focus = Some(GridFocus {
                        group_index,
                        active_index: 0,
                    });
                }
            }
        }
    }

    /// Resolves the grid cursor to `(group_index, item_index)` in the
    /// group's full item list, for opening review on it.
    fn focused_grid_item(&self) -> Option<(usize, usize)> {
        let focus = self.grid_focus.as_ref()?;
        let active_lists = self.compute_active_lists();
        let item_index = *active_lists.get(focus.group_index)?.get(focus.active_index)?;
        Some((focus.group_index, item_index))
    }

    fn render_grid(&mut self, ui: &mut egui::Ui) {
        // (group_index, item_index within that group's full item list)
        let mut review_requested: Option<(usize, usize)> = None;
        let mut restore_requested: Option<PathBuf> = None;
        let mut compare_requested: Option<(usize, Vec<PathBuf>)> = None;
        let mut toggle_selection: Option<PathBuf> = None;
        let mut clicked_focus: Option<GridFocus> = None;
        let select_click = ui.input(|i| i.modifiers.command);

        let mut move_row: isize = 0;
        let mut move_col: isize = 0;
        let mut open_focused = false;
        ui.input(|i| {
            if i.key_pressed(egui::Key::ArrowUp) {
                move_row = -1;
            }
            if i.key_pressed(egui::Key::ArrowDown) {
                move_row = 1;
            }
            if i.key_pressed(egui::Key::ArrowLeft) {
                move_col = -1;
            }
            if i.key_pressed(egui::Key::ArrowRight) {
                move_col = 1;
            }
            if i.key_pressed(egui::Key::Enter) {
                open_focused = true;
            }
        });
        // Approximate thumbnail footprint (120px image + frame margins +
        // wrap spacing) to guess how many land in a row — used only to
        // decide how far Up/Down should jump, so it doesn't need to be
        // pixel-exact.
        let columns_per_row = (ui.available_width() / 132.0).floor().max(1.0) as usize;

        egui::ScrollArea::vertical().show(ui, |ui| {
            for (group_index, group) in self.groups.iter().enumerate() {
                let mut active = Vec::new();
                let mut rejected = Vec::new();
                for (item_index, item) in group.items.iter().enumerate() {
                    let is_rejected = self.decisions.get(&item.path).copied().unwrap_or_default()
                        == Decision::Reject;
                    if is_rejected {
                        rejected.push(item);
                    } else {
                        active.push((item_index, item));
                    }
                }
                let selected_in_group: Vec<PathBuf> = active
                    .iter()
                    .filter(|(_, item)| self.selected.contains(&item.path))
                    .map(|(_, item)| item.path.clone())
                    .collect();

                ui.horizontal(|ui| {
                    ui.heading(format!("Burst {} — {} photos", group_index + 1, group.len()));
                    if ui.button("Review").clicked() {
                        review_requested = Some((group_index, 0));
                    }
                    if selected_in_group.len() >= 2
                        && ui
                            .button(format!("Compare ({})", selected_in_group.len()))
                            .clicked()
                    {
                        compare_requested = Some((group_index, selected_in_group.clone()));
                    }
                });

                ui.horizontal_wrapped(|ui| {
                    for (slot, (item_index, item)) in active.iter().enumerate() {
                        let is_focused = self
                            .grid_focus
                            .as_ref()
                            .is_some_and(|f| f.group_index == group_index && f.active_index == slot);
                        let response = self.render_thumb(ui, &item.path, 120.0, is_focused);
                        if response.double_clicked() {
                            // Double-click any photo in the main filmstrip
                            // to jump straight into review, starting there.
                            review_requested = Some((group_index, *item_index));
                        } else if response.clicked() {
                            if select_click {
                                // Cmd/Ctrl-click toggles multi-select, used
                                // to seed Compare mode.
                                toggle_selection = Some(item.path.clone());
                            } else {
                                // A plain click moves the keyboard cursor
                                // here too, like clicking an icon in Finder.
                                clicked_focus = Some(GridFocus {
                                    group_index,
                                    active_index: slot,
                                });
                            }
                        }
                    }
                });

                if !rejected.is_empty() {
                    ui.add_space(4.0);
                    egui::CollapsingHeader::new(format!("Rejected ({})", rejected.len()))
                        .id_salt(("rejected-group", group_index))
                        .default_open(false)
                        .show(ui, |ui| {
                            ui.horizontal_wrapped(|ui| {
                                for item in &rejected {
                                    // Double-click a rejected photo to
                                    // restore it straight back to undecided.
                                    if self
                                        .render_thumb(ui, &item.path, 120.0, false)
                                        .double_clicked()
                                    {
                                        restore_requested = Some(item.path.clone());
                                    }
                                }
                            });
                        });
                }

                ui.add_space(12.0);
            }
        });

        if open_focused {
            if let Some((group_index, item_index)) = self.focused_grid_item() {
                review_requested = Some((group_index, item_index));
            }
        } else if move_row != 0 || move_col != 0 {
            self.move_grid_focus(move_col, move_row, columns_per_row);
        }
        if let Some(focus) = clicked_focus {
            self.grid_focus = Some(focus);
        }

        if let Some((group_index, item_index)) = review_requested {
            self.enter_review(group_index, item_index);
        }
        if let Some(path) = restore_requested {
            self.decisions.insert(path, Decision::Undecided);
        }
        if let Some(path) = toggle_selection {
            if !self.selected.remove(&path) {
                self.selected.insert(path);
            }
        }
        if let Some((group_index, paths)) = compare_requested {
            self.selected.clear();
            self.enter_compare(group_index, paths);
        }
    }

    /// Multi-panel compare view: 1-4 photos side by side, one focused panel
    /// that K/X/U act on, filename overlaid on each image.
    /// Draws one compare panel (focus border, decision border, image with a
    /// filename bar overlaid on top, or an empty-slot placeholder) and
    /// returns its click response so the caller can detect a focus click.
    fn render_compare_panel(
        &self,
        ui: &mut egui::Ui,
        slot: &Option<PathBuf>,
        is_focused: bool,
        max_height: f32,
    ) -> egui::Response {
        let focus_stroke = if is_focused {
            egui::Stroke::new(3.0, ACCENT_COLOR)
        } else {
            egui::Stroke::NONE
        };

        let outer = egui::Frame::new()
            .stroke(focus_stroke)
            .inner_margin(3.0)
            .show(ui, |ui| match slot {
                Some(path) => {
                    egui::Frame::new()
                        .stroke(egui::Stroke::new(2.0, self.border_color(path)))
                        .inner_margin(2.0)
                        .show(ui, |ui| {
                            if let Some(texture) = self.loupe_cache.get(path) {
                                let image_response = ui.add(
                                    egui::Image::new(texture)
                                        .max_width(ui.available_width())
                                        .max_height(max_height)
                                        .maintain_aspect_ratio(true),
                                );
                                let rect = image_response.rect;
                                let bar_height = 22.0;
                                let bar_rect = egui::Rect::from_min_size(
                                    rect.min,
                                    egui::vec2(rect.width(), bar_height),
                                );
                                ui.painter().rect_filled(
                                    bar_rect,
                                    0.0,
                                    egui::Color32::from_black_alpha(170),
                                );
                                let name = path
                                    .file_name()
                                    .map(|n| n.to_string_lossy().to_string())
                                    .unwrap_or_default();
                                ui.painter().text(
                                    bar_rect.center(),
                                    egui::Align2::CENTER_CENTER,
                                    name,
                                    egui::FontId::proportional(13.0),
                                    egui::Color32::WHITE,
                                );
                            } else {
                                ui.label("Loading…");
                            }
                        });
                }
                None => {
                    ui.set_min_height(max_height);
                    ui.centered_and_justified(|ui| {
                        ui.weak("No more photos");
                    });
                }
            });

        outer.response.interact(egui::Sense::click())
    }

    fn render_compare(&mut self, ui: &mut egui::Ui) {
        let mut move_col: isize = 0;
        let mut move_row: isize = 0;
        let mut decision_to_set: Option<Decision> = None;
        let mut escape_pressed = false;
        let mut collapse_to_single = false;
        let mut resize_to: Option<usize> = None;

        ui.input(|i| {
            if i.key_pressed(egui::Key::ArrowRight) {
                move_col = 1;
            }
            if i.key_pressed(egui::Key::ArrowLeft) {
                move_col = -1;
            }
            if i.key_pressed(egui::Key::ArrowDown) {
                move_row = 1;
            }
            if i.key_pressed(egui::Key::ArrowUp) {
                move_row = -1;
            }
            if i.key_pressed(egui::Key::K) {
                decision_to_set = Some(Decision::Keep);
            }
            if i.key_pressed(egui::Key::X) {
                decision_to_set = Some(Decision::Reject);
            }
            if i.key_pressed(egui::Key::U) {
                decision_to_set = Some(Decision::Undecided);
            }
            if i.key_pressed(egui::Key::Escape) {
                escape_pressed = true;
            }
            if i.key_pressed(egui::Key::Num1) {
                collapse_to_single = true;
            }
            if i.key_pressed(egui::Key::Num2) {
                resize_to = Some(2);
            }
            if i.key_pressed(egui::Key::Num3) {
                resize_to = Some(3);
            }
            if i.key_pressed(egui::Key::Num4) {
                resize_to = Some(4);
            }
        });

        let Some(compare) = self.compare.as_ref() else {
            return;
        };
        let group_index = compare.group_index;

        if escape_pressed {
            self.compare = None;
            return;
        }

        if collapse_to_single {
            let focused_path = self
                .compare
                .as_ref()
                .and_then(|c| c.slots.get(c.focused).cloned().flatten());
            self.compare = None;
            let item_index = focused_path
                .and_then(|path| {
                    self.groups
                        .get(group_index)?
                        .items
                        .iter()
                        .position(|item| item.path == path)
                })
                .unwrap_or(0);
            self.enter_review(group_index, item_index);
            return;
        }

        if move_col != 0 || move_row != 0 {
            self.move_compare_focus(move_col, move_row);
        }

        if let Some(decision) = decision_to_set {
            self.decide_focused_compare_panel(decision);
        }

        if let Some(n) = resize_to {
            self.resize_compare(n);
        }

        if self.compare_group_exhausted() {
            self.compare = None;
            return;
        }

        let compare = self.compare.as_ref().unwrap();
        let focused = compare.focused;
        let slots = compare.slots.clone();

        for path in slots.iter().flatten() {
            self.viewed.insert(path.clone());
            self.load_loupe_texture(ui.ctx(), path);
        }

        let mut back_clicked = false;
        let mut click_focus: Option<usize> = None;

        ui.horizontal(|ui| {
            if ui.button("Back to grid (Esc)").clicked() {
                back_clicked = true;
            }
            ui.label(format!(
                "Burst {} — comparing {} photo{}",
                group_index + 1,
                slots.len(),
                plural(slots.len())
            ));
        });
        ui.add_space(4.0);
        ui.label(
            "Arrows: focus panel   K: keep   X: reject   U: undo   1: single view   2/3/4: panel count   Esc: back to grid",
        );
        ui.add_space(6.0);

        let total_height = (ui.available_height() - 40.0).max(100.0);

        if slots.len() <= 3 {
            // 2 or 3 panels: one row, side by side — each gets the full
            // available height.
            ui.columns(slots.len(), |columns| {
                for (i, column) in columns.iter_mut().enumerate() {
                    let response =
                        self.render_compare_panel(column, &slots[i], i == focused, total_height);
                    if response.clicked() {
                        click_focus = Some(i);
                    }
                }
            });
        } else {
            // 4 panels: a 2x2 grid instead of a cramped single row, so each
            // photo still gets real screen space.
            let row_height = ((total_height - ui.spacing().item_spacing.y) / 2.0).max(80.0);
            for row in 0..2 {
                ui.columns(2, |columns| {
                    for col in 0..2 {
                        let i = row * 2 + col;
                        let response = self.render_compare_panel(
                            &mut columns[col],
                            &slots[i],
                            i == focused,
                            row_height,
                        );
                        if response.clicked() {
                            click_focus = Some(i);
                        }
                    }
                });
            }
        }

        if let Some(i) = click_focus {
            if let Some(compare) = self.compare.as_mut() {
                compare.focused = i;
            }
        }
        if back_clicked {
            self.compare = None;
        }
    }

    fn render_review(&mut self, ui: &mut egui::Ui) {
        let mut move_delta: isize = 0;
        let mut decision_to_set: Option<Decision> = None;
        let mut exit = false;
        let mut expand_to_compare: Option<usize> = None;

        ui.input(|i| {
            if i.key_pressed(egui::Key::ArrowRight) {
                move_delta = 1;
            }
            if i.key_pressed(egui::Key::ArrowLeft) {
                move_delta = -1;
            }
            if i.key_pressed(egui::Key::K) {
                decision_to_set = Some(Decision::Keep);
            }
            if i.key_pressed(egui::Key::X) {
                decision_to_set = Some(Decision::Reject);
            }
            if i.key_pressed(egui::Key::U) {
                decision_to_set = Some(Decision::Undecided);
            }
            if i.key_pressed(egui::Key::Escape) {
                exit = true;
            }
            if i.key_pressed(egui::Key::Num2) {
                expand_to_compare = Some(2);
            }
            if i.key_pressed(egui::Key::Num3) {
                expand_to_compare = Some(3);
            }
            if i.key_pressed(egui::Key::Num4) {
                expand_to_compare = Some(4);
            }
        });

        let Some(current_path) = self.current_review_path() else {
            self.review = None;
            return;
        };

        if let Some(decision) = decision_to_set {
            self.decisions.insert(current_path, decision);
            if move_delta == 0 {
                move_delta = 1;
            }
        }
        if move_delta != 0 {
            self.review_move(move_delta);
        }

        let Some(path) = self.current_review_path() else {
            self.review = None;
            return;
        };

        if self.review_group_exhausted() {
            self.review = None;
            return;
        }

        self.load_loupe_texture(ui.ctx(), &path);
        self.viewed.insert(path.clone());

        let review = self.review.as_ref().unwrap();
        let group_index = review.group_index;
        let item_index = review.item_index;

        if let Some(count) = expand_to_compare {
            let seed = self.active_paths_from(group_index, item_index, count);
            self.enter_compare(group_index, seed);
            return;
        }

        let group_paths: Vec<PathBuf> = self.groups[group_index]
            .items
            .iter()
            .map(|i| i.path.clone())
            .collect();
        let group_len = group_paths.len();
        let decision = self.decisions.get(&path).copied().unwrap_or_default();

        ui.horizontal(|ui| {
            if ui.button("Back to grid (Esc)").clicked() {
                exit = true;
            }
            ui.label(format!(
                "Burst {} — photo {} of {group_len}",
                group_index + 1,
                item_index + 1
            ));
            ui.colored_label(decision.color(), decision.label());
        });

        if exit {
            self.review = None;
            return;
        }

        ui.separator();

        if let Some(texture) = self.loupe_cache.get(&path) {
            let avail_height = (ui.available_height() - 140.0).max(100.0);
            egui::Frame::new()
                .stroke(egui::Stroke::new(3.0, self.border_color(&path)))
                .inner_margin(4.0)
                .show(ui, |ui| {
                    ui.add(
                        egui::Image::new(texture)
                            .max_height(avail_height)
                            .max_width(ui.available_width())
                            .maintain_aspect_ratio(true),
                    );
                });
        } else {
            ui.label("Loading…");
        }

        ui.add_space(8.0);
        ui.label(
            "Left/Right: navigate   K: keep   X: reject   U: undo   2/3/4: compare   Esc: back to grid",
        );
        ui.separator();

        let mut jump_to: Option<usize> = None;
        egui::ScrollArea::horizontal()
            .id_salt("filmstrip")
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    for (i, item_path) in group_paths.iter().enumerate() {
                        // Rejected photos are dropped from the filmstrip while
                        // reviewing; they still show up in the grid's own
                        // rejected row.
                        if self.decisions.get(item_path).copied().unwrap_or_default()
                            == Decision::Reject
                        {
                            continue;
                        }
                        let Some(thumb) = self.thumbnails.get(item_path) else {
                            continue;
                        };
                        let stroke_width = if i == item_index { 3.0 } else { 1.0 };
                        let inner = egui::Frame::new()
                            .stroke(egui::Stroke::new(stroke_width, self.border_color(item_path)))
                            .inner_margin(2.0)
                            .show(ui, |ui| {
                                ui.add(egui::Image::new(thumb).max_width(70.0).max_height(70.0))
                            });
                        if inner.response.interact(egui::Sense::click()).clicked() {
                            jump_to = Some(i);
                        }
                    }
                });
            });

        if let Some(i) = jump_to {
            if let Some(review) = self.review.as_mut() {
                review.item_index = i;
            }
        }
    }
}

/// Decodes and resizes thumbnails on a pool of background threads (sized to
/// available CPU cores) so folder loading never blocks the UI thread. Each
/// finished thumbnail is sent back over `tx` as soon as it's ready.
fn spawn_thumbnail_loaders(
    ctx: egui::Context,
    paths: Vec<PathBuf>,
) -> Receiver<(PathBuf, egui::TextureHandle)> {
    let (tx, rx) = mpsc::channel();
    let work = Arc::new(Mutex::new(paths.into_iter()));
    let worker_count = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);

    for _ in 0..worker_count {
        let work = Arc::clone(&work);
        let tx = tx.clone();
        let ctx = ctx.clone();
        std::thread::spawn(move || loop {
            let next = work.lock().unwrap().next();
            let Some(path) = next else {
                break;
            };
            if let Some(texture) = decode_thumbnail(&ctx, &path) {
                if tx.send((path, texture)).is_err() {
                    break;
                }
                ctx.request_repaint();
            }
        });
    }

    rx
}

fn decode_thumbnail(ctx: &egui::Context, path: &Path) -> Option<egui::TextureHandle> {
    let image = image::open(path).ok()?;
    let thumb = image
        .thumbnail(THUMBNAIL_MAX_SIDE, THUMBNAIL_MAX_SIDE)
        .into_rgba8();
    let size = [thumb.width() as usize, thumb.height() as usize];
    let color_image = egui::ColorImage::from_rgba_unmultiplied(size, thumb.as_raw());
    Some(ctx.load_texture(
        path.to_string_lossy(),
        color_image,
        egui::TextureOptions::default(),
    ))
}

impl eframe::App for CullWizardApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.drain_ready_thumbnails();

        egui::Frame::central_panel(&ui.style()).show(ui, |ui| {
            if self.compare.is_some() {
                self.render_compare(ui);
                return;
            }

            if self.review.is_some() {
                self.render_review(ui);
                return;
            }

            ui.horizontal(|ui| {
                if ui.button("Choose folder…").clicked() {
                    self.choose_folder(ui.ctx());
                }
                if let Some(folder) = &self.source_folder {
                    ui.label(folder.display().to_string());
                }
                if !self.groups.is_empty() && ui.button("Finalize…").clicked() {
                    self.show_finalize = true;
                    self.finalize_trash_rejected = true;
                    self.finalize_copy_keepers = true;
                }
            });

            if !self.status.is_empty() {
                ui.label(&self.status);
            }
            if let Some(status) = self.commit_status.clone() {
                ui.label(status);
            }
            if self.thumbnails_total > 0 && self.thumbnails.len() < self.thumbnails_total {
                ui.label(format!(
                    "Loading thumbnails: {}/{}",
                    self.thumbnails.len(),
                    self.thumbnails_total
                ));
            }

            self.render_finalize_dialog(ui);

            ui.separator();

            if self.groups.is_empty() {
                ui.label("Choose a folder of JPEGs to get started.");
                return;
            }

            self.render_grid(ui);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    fn examples_dir() -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../examples"))
    }

    fn wait_for_thumbnails(app: &mut CullWizardApp, total: usize) {
        let deadline = Instant::now() + Duration::from_secs(60);
        while app.thumbnails.len() < total && Instant::now() < deadline {
            app.drain_ready_thumbnails();
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Each thumbnail-loading test spawns its own worker pool sized to all
    /// CPU cores. Rust's test harness runs tests in parallel by default, so
    /// without this lock, multiple tests' pools oversubscribe the machine at
    /// once and (in unoptimized debug builds especially) can blow the wait
    /// deadline. Real usage never runs more than one pool at a time.
    static PIPELINE_TEST_LOCK: Mutex<()> = Mutex::new(());

    /// Exercises the full scan -> metadata -> burst -> background-thumbnail
    /// pipeline against the real sample JPEGs, without a native window.
    #[test]
    fn loads_real_folder_into_burst_groups_with_thumbnails() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(examples_dir(), &ctx);

        let sizes: Vec<usize> = app.groups.iter().map(BurstGroup::len).collect();
        assert_eq!(sizes, vec![20, 17, 6, 5, 12, 6]);
        let total_photos: usize = sizes.iter().sum();
        assert!(app.status.contains(&format!("{total_photos} photos")));
        assert!(app.status.contains("6 burst groups"));

        wait_for_thumbnails(&mut app, total_photos);
        assert_eq!(app.thumbnails.len(), total_photos);
    }

    #[test]
    fn review_navigation_and_decisions_work_on_real_group() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let total_photos: usize = app.groups.iter().map(BurstGroup::len).sum();
        wait_for_thumbnails(&mut app, total_photos);

        app.enter_review(0, 0); // Burst 1, 20 photos
        assert_eq!(app.review.as_ref().unwrap().item_index, 0);

        let first_path = app.current_review_path().unwrap();
        app.decisions.insert(first_path.clone(), Decision::Keep);
        app.review_move(1);
        assert_eq!(app.review.as_ref().unwrap().item_index, 1);

        let second_path = app.current_review_path().unwrap();
        assert_ne!(first_path, second_path);
        app.decisions.insert(second_path, Decision::Reject);

        // Can't move past the start or end of the group.
        app.review_move(-100);
        assert_eq!(app.review.as_ref().unwrap().item_index, 0);
        app.review_move(100);
        assert_eq!(app.review.as_ref().unwrap().item_index, 19);

        assert_eq!(app.decisions.get(&first_path), Some(&Decision::Keep));
    }

    #[test]
    fn loupe_texture_loads_for_current_review_item() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        app.enter_review(0, 0);

        let path = app.current_review_path().unwrap();
        app.load_loupe_texture(&ctx, &path);
        assert!(app.loupe_cache.contains_key(&path));
    }

    #[test]
    fn enter_review_opens_on_the_requested_item() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);

        let expected_path = app.groups[0].items[5].path.clone();
        app.enter_review(0, 5);

        assert_eq!(app.review.as_ref().unwrap().item_index, 5);
        assert_eq!(app.current_review_path(), Some(expected_path));
    }

    #[test]
    fn border_color_reflects_decision_and_viewed_state() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path = app.groups[0].items[0].path.clone();

        // Never viewed, no decision: gray.
        assert_eq!(app.border_color(&path), UNVIEWED_COLOR);

        // Viewed (as review does on every frame it shows a photo), still
        // undecided: yellow.
        app.viewed.insert(path.clone());
        assert_eq!(app.border_color(&path), VIEWED_UNDECIDED_COLOR);

        // Kept: green, regardless of viewed state.
        app.decisions.insert(path.clone(), Decision::Keep);
        assert_eq!(app.border_color(&path), Decision::Keep.color());

        // Rejected: red.
        app.decisions.insert(path.clone(), Decision::Reject);
        assert_eq!(app.border_color(&path), Decision::Reject.color());
    }

    #[test]
    fn review_navigation_skips_over_rejected_items() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();

        // Reject index 1 up front, as if it had been rejected in an earlier
        // review pass or from the grid's rejected row.
        app.decisions.insert(path_at(&app, 1), Decision::Reject);

        // Opening review right on the rejected index snaps forward to the
        // nearest active item instead of showing the rejected photo.
        app.enter_review(0, 1);
        assert_eq!(app.current_review_path(), Some(path_at(&app, 2)));

        // Arrowing left from there skips back over the rejected item 1 and
        // lands on 0, never stopping on 1.
        app.review_move(-1);
        assert_eq!(app.current_review_path(), Some(path_at(&app, 0)));

        // Arrowing right again skips 1 and returns to 2.
        app.review_move(1);
        assert_eq!(app.current_review_path(), Some(path_at(&app, 2)));
    }

    #[test]
    fn rejecting_current_item_advances_past_it_to_the_next_active_item() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();

        app.enter_review(0, 0);
        let rejected_path = app.current_review_path().unwrap();

        // Mirrors what render_review does on X: record the decision, then
        // advance by one active step.
        app.decisions.insert(rejected_path.clone(), Decision::Reject);
        app.review_move(1);

        let now_showing = app.current_review_path().unwrap();
        assert_eq!(now_showing, path_at(&app, 1));
        assert_ne!(now_showing, rejected_path);
    }

    #[test]
    fn rejecting_the_last_active_photo_reselects_the_previous_one() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();

        // Reject everything except the last two photos in the burst, then
        // open review right on the last one.
        for i in 0..18 {
            app.decisions.insert(path_at(&app, i), Decision::Reject);
        }
        app.enter_review(0, 19);
        assert_eq!(app.current_review_path(), Some(path_at(&app, 19)));

        let last_path = app.current_review_path().unwrap();
        app.decisions.insert(last_path, Decision::Reject);
        app.review_move(1); // mirrors the auto-advance render_review does on X

        assert_eq!(
            app.current_review_path(),
            Some(path_at(&app, 18)),
            "rejecting the last active photo should fall back to the previous active one"
        );
        assert!(!app.review_group_exhausted());
    }

    #[test]
    fn rejecting_the_only_remaining_photo_leaves_the_group_exhausted() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3683.JPG"]);
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 1);
        app.enter_review(0, 0);
        let only_path = app.current_review_path().unwrap();

        app.decisions.insert(only_path, Decision::Reject);
        app.review_move(1);

        assert!(
            app.review_group_exhausted(),
            "no active photos remain, so review should treat the group as exhausted"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn enter_compare_seeds_slots_and_focuses_first_panel() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        let seed = vec![path_at(&app, 0), path_at(&app, 1), path_at(&app, 2)];

        app.enter_compare(0, seed.clone());

        let compare = app.compare.as_ref().unwrap();
        assert_eq!(compare.group_index, 0);
        assert_eq!(compare.focused, 0);
        assert_eq!(
            compare.slots,
            seed.into_iter().map(Some).collect::<Vec<_>>()
        );
    }

    #[test]
    fn move_compare_focus_wraps_around() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        app.enter_compare(0, vec![path_at(&app, 0), path_at(&app, 1), path_at(&app, 2)]);

        app.move_compare_focus(1, 0);
        assert_eq!(app.compare.as_ref().unwrap().focused, 1);
        app.move_compare_focus(1, 0);
        assert_eq!(app.compare.as_ref().unwrap().focused, 2);
        app.move_compare_focus(1, 0);
        assert_eq!(app.compare.as_ref().unwrap().focused, 0, "should wrap forward");
        app.move_compare_focus(-1, 0);
        assert_eq!(app.compare.as_ref().unwrap().focused, 2, "should wrap backward");
    }

    #[test]
    fn move_compare_focus_up_down_moves_by_row_in_2x2_layout() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        app.enter_compare(
            0,
            vec![
                path_at(&app, 0),
                path_at(&app, 1),
                path_at(&app, 2),
                path_at(&app, 3),
            ],
        );
        // Panel layout is 2x2, row-major: [0 1] / [2 3].
        assert_eq!(app.compare.as_ref().unwrap().focused, 0);

        app.move_compare_focus(0, 1); // Down: top-left -> bottom-left
        assert_eq!(app.compare.as_ref().unwrap().focused, 2);
        app.move_compare_focus(1, 0); // Right: bottom-left -> bottom-right
        assert_eq!(app.compare.as_ref().unwrap().focused, 3);
        app.move_compare_focus(0, -1); // Up: bottom-right -> top-right
        assert_eq!(app.compare.as_ref().unwrap().focused, 1);
    }

    #[test]
    fn move_compare_focus_up_down_is_a_no_op_in_single_row_layout() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        app.enter_compare(0, vec![path_at(&app, 0), path_at(&app, 1), path_at(&app, 2)]);

        app.move_compare_focus(0, 1); // Down: nothing below a single row
        assert_eq!(app.compare.as_ref().unwrap().focused, 0);
        app.move_compare_focus(0, -1); // Up: nothing above a single row
        assert_eq!(app.compare.as_ref().unwrap().focused, 0);
    }

    #[test]
    fn deciding_focused_panel_records_decision_and_refills_from_group() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        let (p0, p1, p2, p3) = (
            path_at(&app, 0),
            path_at(&app, 1),
            path_at(&app, 2),
            path_at(&app, 3),
        );
        app.enter_compare(0, vec![p0.clone(), p1.clone(), p2.clone()]);

        app.decide_focused_compare_panel(Decision::Keep);

        assert_eq!(app.decisions.get(&p0), Some(&Decision::Keep));
        let compare = app.compare.as_ref().unwrap();
        assert_eq!(
            compare.slots,
            vec![Some(p3), Some(p1), Some(p2)],
            "the decided slot should refill with the next photo not already shown"
        );
        assert_eq!(compare.focused, 0, "focus stays on the refilled slot");
    }

    #[test]
    fn deciding_panel_with_no_replacement_available_leaves_it_empty() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3684.JPG", "DSC_3685.JPG"]);
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 2);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        let (p0, p1) = (path_at(&app, 0), path_at(&app, 1));
        app.enter_compare(0, vec![p0.clone(), p1.clone()]);

        app.decide_focused_compare_panel(Decision::Reject);

        assert_eq!(app.compare.as_ref().unwrap().slots, vec![None, Some(p1)]);
        assert!(!app.compare_group_exhausted(), "one panel still has a photo");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn compare_mode_exits_when_every_panel_is_empty() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3686.JPG"]);
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 1);
        let only_path = app.groups[0].items[0].path.clone();
        app.enter_compare(0, vec![only_path]);

        app.decide_focused_compare_panel(Decision::Reject);

        assert!(app.compare_group_exhausted());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resize_compare_grows_with_fresh_photos_in_order() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        app.enter_compare(0, vec![path_at(&app, 0), path_at(&app, 1)]);

        app.resize_compare(4);

        assert_eq!(
            app.compare.as_ref().unwrap().slots,
            vec![
                Some(path_at(&app, 0)),
                Some(path_at(&app, 1)),
                Some(path_at(&app, 2)),
                Some(path_at(&app, 3)),
            ]
        );
    }

    #[test]
    fn resize_compare_shrinks_by_dropping_trailing_panels() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        app.enter_compare(
            0,
            vec![
                path_at(&app, 0),
                path_at(&app, 1),
                path_at(&app, 2),
                path_at(&app, 3),
            ],
        );
        app.move_compare_focus(3, 0); // focus the last panel (index 3)

        app.resize_compare(2);

        let compare = app.compare.as_ref().unwrap();
        assert_eq!(
            compare.slots,
            vec![Some(path_at(&app, 0)), Some(path_at(&app, 1))]
        );
        assert_eq!(
            compare.focused, 1,
            "focus should clamp into range after shrinking"
        );
    }

    #[test]
    fn move_grid_focus_starts_a_cursor_when_none_exists() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        assert!(app.grid_focus.is_none());

        app.move_grid_focus(0, 1, 5);

        let focus = app.grid_focus.as_ref().unwrap();
        assert_eq!(focus.group_index, 0);
        assert_eq!(focus.active_index, 0);
    }

    #[test]
    fn move_grid_focus_moves_by_row_and_column() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        app.grid_focus = Some(GridFocus {
            group_index: 0,
            active_index: 0,
        });

        app.move_grid_focus(1, 0, 5); // right one column
        assert_eq!(app.grid_focus.as_ref().unwrap().active_index, 1);

        app.move_grid_focus(0, 1, 5); // down one row (5 columns/row)
        assert_eq!(app.grid_focus.as_ref().unwrap().active_index, 6);

        app.move_grid_focus(0, -1, 5); // back up one row
        assert_eq!(app.grid_focus.as_ref().unwrap().active_index, 1);
    }

    #[test]
    fn move_grid_focus_clamps_at_group_bounds() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx); // Burst 1 has 20 photos
        app.grid_focus = Some(GridFocus {
            group_index: 0,
            active_index: 0,
        });

        app.move_grid_focus(-1, 0, 5);
        assert_eq!(app.grid_focus.as_ref().unwrap().active_index, 0);

        app.grid_focus = Some(GridFocus {
            group_index: 0,
            active_index: 19,
        });
        app.move_grid_focus(0, 1, 5); // one more row past the end
        assert_eq!(app.grid_focus.as_ref().unwrap().active_index, 19);
    }

    #[test]
    fn move_grid_focus_only_counts_visible_non_rejected_photos() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        let path_at = |app: &CullWizardApp, i: usize| app.groups[0].items[i].path.clone();
        // Reject item 1, so the visible sequence is [0, 2, 3, 4, ...].
        app.decisions.insert(path_at(&app, 1), Decision::Reject);
        app.grid_focus = Some(GridFocus {
            group_index: 0,
            active_index: 0,
        });

        app.move_grid_focus(1, 0, 5); // one step right in the visible list

        let (group_index, item_index) = app.focused_grid_item().unwrap();
        assert_eq!(group_index, 0);
        assert_eq!(item_index, 2, "should skip the rejected item at index 1");
    }

    #[test]
    fn focused_grid_item_resolves_to_full_group_item_index() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();
        app.load_folder(examples_dir(), &ctx);
        app.grid_focus = Some(GridFocus {
            group_index: 0,
            active_index: 5,
        });

        assert_eq!(app.focused_grid_item(), Some((0, 5)));
    }

    /// Copies a couple of real sample JPEGs into a disposable temp folder,
    /// so commit tests can actually trash files without touching the shared
    /// `examples/` fixtures every other test in this suite depends on.
    fn disposable_copy_of_examples(names: &[&str]) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cw-app-commit-test-{}-{}",
            std::process::id(),
            names.join("-")
        ));
        std::fs::create_dir_all(&dir).unwrap();
        for name in names {
            std::fs::copy(examples_dir().join(name), dir.join(name)).unwrap();
        }
        dir
    }

    #[test]
    fn finalize_trashes_rejected_and_copies_keepers_leaving_originals() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3676.JPG", "DSC_3677.JPG"]);
        let dest = std::env::temp_dir().join(format!(
            "cw-app-finalize-dest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 2);
        assert_eq!(app.groups.len(), 1);
        assert_eq!(app.groups[0].len(), 2);

        let rejected_path = app.groups[0].items[0].path.clone();
        // Second photo is left Undecided on purpose: "keeper" means
        // anything not explicitly rejected, so it should still get copied.
        let kept_path = app.groups[0].items[1].path.clone();
        app.decisions.insert(rejected_path.clone(), Decision::Reject);

        assert_eq!(app.rejected_paths(), vec![rejected_path.clone()]);
        assert_eq!(app.keeper_paths(), vec![kept_path.clone()]);
        app.run_finalize(true, Some(dest.clone()));

        assert!(!rejected_path.exists(), "trashed file should be gone");
        assert!(kept_path.exists(), "untouched original should remain");
        assert!(
            dest.join(kept_path.file_name().unwrap()).exists(),
            "keeper should be copied to the destination"
        );
        assert!(!dest.join(rejected_path.file_name().unwrap()).exists());

        assert_eq!(app.groups.len(), 1);
        assert_eq!(app.groups[0].len(), 1);
        assert_eq!(app.groups[0].items[0].path, kept_path);
        assert!(!app.decisions.contains_key(&rejected_path));
        assert!(!app.thumbnails.contains_key(&rejected_path));
        let status = app.commit_status.as_deref().unwrap();
        assert!(status.contains("Copied 1 photo"));
        assert!(status.contains("Trashed 1 photo."));

        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&dest).ok();
    }

    #[test]
    fn finalize_can_empty_a_group_entirely() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3678.JPG"]);
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 1);
        let only_path = app.groups[0].items[0].path.clone();
        app.decisions.insert(only_path, Decision::Reject);

        // No keepers, so no destination is needed at all.
        assert!(app.keeper_paths().is_empty());
        app.run_finalize(true, None);

        assert!(app.groups.is_empty());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn finalize_can_trash_without_copying_keepers() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3679.JPG", "DSC_3680.JPG"]);
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 2);
        let rejected_path = app.groups[0].items[0].path.clone();
        let kept_path = app.groups[0].items[1].path.clone();
        app.decisions.insert(rejected_path.clone(), Decision::Reject);

        // "Move to trash" checked, "copy keepers" unchecked: no destination
        // passed at all, so the keeper must be left untouched in place.
        app.run_finalize(true, None);

        assert!(!rejected_path.exists(), "rejected file should be trashed");
        assert!(kept_path.exists(), "keeper should still be at its original path");
        assert_eq!(app.groups.len(), 1);
        assert_eq!(app.groups[0].items[0].path, kept_path);
        let status = app.commit_status.as_deref().unwrap();
        assert!(status.contains("Trashed 1 photo."));
        assert!(!status.contains("Copied"));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn finalize_can_copy_keepers_without_trashing_rejected() {
        let _guard = PIPELINE_TEST_LOCK.lock().unwrap();
        let dir = disposable_copy_of_examples(&["DSC_3681.JPG", "DSC_3682.JPG"]);
        let dest = std::env::temp_dir().join(format!(
            "cw-app-finalize-copy-only-dest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let ctx = egui::Context::default();
        let mut app = CullWizardApp::default();

        app.load_folder(dir.clone(), &ctx);
        wait_for_thumbnails(&mut app, 2);
        let rejected_path = app.groups[0].items[0].path.clone();
        let kept_path = app.groups[0].items[1].path.clone();
        app.decisions.insert(rejected_path.clone(), Decision::Reject);

        // "Copy keepers" checked, "move to trash" unchecked: the rejected
        // photo must still be sitting right where it was, still marked
        // Reject, so it shows up in next time's Rejected row.
        app.run_finalize(false, Some(dest.clone()));

        assert!(
            rejected_path.exists(),
            "rejected file should be untouched when trashing is unchecked"
        );
        assert_eq!(app.groups[0].len(), 2, "nothing removed from the group");
        assert_eq!(
            app.decisions.get(&rejected_path),
            Some(&Decision::Reject),
            "still marked rejected for a future Finalize"
        );
        assert!(dest.join(kept_path.file_name().unwrap()).exists());
        let status = app.commit_status.as_deref().unwrap();
        assert!(status.contains("Copied 1 photo"));
        assert!(!status.contains("Trashed"));

        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&dest).ok();
    }
}
