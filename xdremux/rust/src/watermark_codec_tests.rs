use super::*;
use crate::container::test_support::tail_file;

const WIDTH: u32 = 320;
const HEIGHT: u32 = 480;
const WHITE: [u8; 3] = [255, 255, 255];

/// Donor file whose `watermark.master.params` stores `picture` for a
/// WIDTH x HEIGHT primary, laid out like the camera's end block.
fn donor_file(style: &str, picture: (u32, u32, u32, u32)) -> Vec<u8> {
    let (x, y, w, h) = picture;
    let (right, bottom) = ((x + w) as f32, (y + h) as f32);
    let words = [
        bottom, right, HEIGHT as f32, 0., 0., 0., x as f32, y as f32, right, bottom, x as f32,
        y as f32, right, bottom,
    ];
    let mut params = vec![0u8; 256];
    params[..4].copy_from_slice(&1f32.to_le_bytes());
    params[4..4 + style.len()].copy_from_slice(style.as_bytes());
    for (index, word) in words.iter().enumerate() {
        params[200 + index * 4..204 + index * 4].copy_from_slice(&word.to_le_bytes());
    }
    params[220..224].copy_from_slice(&[0xff; 4]);
    tail_file(&[("watermark.master.params", &params)])
}

fn inside(picture: (u32, u32, u32, u32), column: u32, row: u32) -> bool {
    let (x, y, w, h) = picture;
    column >= x && column < x + w && row >= y && row < y + h
}

/// Donor raster: a gradient photograph in `picture`, a `frame` colour around
/// it, and a line of sparse dark text 20 rows above the bottom edge.
fn donor_raster(picture: (u32, u32, u32, u32), frame: [u8; 3]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity((WIDTH * HEIGHT * 4) as usize);
    for row in 0..HEIGHT {
        for column in 0..WIDTH {
            let pixel = if inside(picture, column, row) {
                [(column * 200 / WIDTH) as u8, (row * 200 / HEIGHT) as u8, 90]
            } else if row == HEIGHT - 20 && (100..220).contains(&column) && column % 2 == 0 {
                [30, 30, 30]
            } else {
                frame
            };
            rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]);
        }
    }
    rgba
}

/// The returned edit: every colour of the donor changed, frame included.
fn edited(donor_rgba: &[u8]) -> Vec<u8> {
    donor_rgba
        .chunks_exact(4)
        .flat_map(|pixel| [pixel[0] / 2 + 40, pixel[1] / 2 + 30, pixel[2] / 2 + 20, 255])
        .collect()
}

/// Pixels of `restored` that differ from the donor outside `picture`, and
/// pixels that differ from the edit inside it.
fn mismatches(
    restored: &[u8],
    donor_rgba: &[u8],
    returned_rgba: &[u8],
    picture: (u32, u32, u32, u32),
) -> (usize, usize) {
    let (mut frame_wrong, mut picture_wrong) = (0, 0);
    for row in 0..HEIGHT {
        for column in 0..WIDTH {
            let at = ((row * WIDTH + column) * 4) as usize;
            if inside(picture, column, row) {
                picture_wrong += (restored[at..at + 4] != returned_rgba[at..at + 4]) as usize;
            } else {
                frame_wrong += (restored[at..at + 4] != donor_rgba[at..at + 4]) as usize;
            }
        }
    }
    (frame_wrong, picture_wrong)
}

#[test]
fn full_frame_is_restored_on_all_four_sides() {
    let picture = (20, 80, 280, 320);
    let donor = donor_file("hassel_style_master_mode_1", picture);
    let donor_rgba = donor_raster(picture, WHITE);
    let returned_rgba = edited(&donor_rgba);
    // Band detection finds the top and bottom bands only; the side borders
    // are in no row band.
    assert_eq!(
        detect_frame_bands(&donor_rgba, WIDTH, HEIGHT),
        Ok(vec![(0, 80), (400, HEIGHT)])
    );
    let mut restored = returned_rgba.clone();
    restore_watermark_canvas(&donor, &donor_rgba, &mut restored, WIDTH, HEIGHT).expect("restore");
    assert_eq!(mismatches(&restored, &donor_rgba, &returned_rgba, picture), (0, 0));
}

#[test]
fn bottom_bar_is_restored_where_band_detection_gives_up() {
    let picture = (0, 0, WIDTH, 400);
    let donor = donor_file("hassel_style_1", picture);
    let donor_rgba = donor_raster(picture, WHITE);
    let returned_rgba = edited(&donor_rgba);
    // The photograph reaches the top corners, so the corners disagree.
    assert!(detect_frame_bands(&donor_rgba, WIDTH, HEIGHT).is_err());
    let mut restored = returned_rgba.clone();
    restore_watermark_canvas(&donor, &donor_rgba, &mut restored, WIDTH, HEIGHT).expect("restore");
    assert_eq!(mismatches(&restored, &donor_rgba, &returned_rgba, picture), (0, 0));
}

#[test]
fn dark_frame_is_restored_like_a_white_one() {
    let picture = (20, 80, 280, 320);
    let donor = donor_file("hassel_style_4", picture);
    let donor_rgba = donor_raster(picture, [16, 16, 16]);
    let returned_rgba = edited(&donor_rgba);
    let mut restored = returned_rgba.clone();
    restore_watermark_canvas(&donor, &donor_rgba, &mut restored, WIDTH, HEIGHT).expect("restore");
    assert_eq!(mismatches(&restored, &donor_rgba, &returned_rgba, picture), (0, 0));
}

#[test]
fn stored_rect_without_a_frame_in_the_pixels_is_not_used() {
    // The entry says there is a frame, the donor image is photograph all
    // over: nothing is copied and the restore fails closed.
    let picture = (20, 80, 280, 320);
    let donor = donor_file("hassel_style_master_mode_1", picture);
    let donor_rgba = donor_raster((0, 0, WIDTH, HEIGHT), WHITE);
    assert_eq!(stored_frame_picture_rect(&donor, &donor_rgba, WIDTH, HEIGHT), None);
    let returned_rgba = edited(&donor_rgba);
    let mut restored = returned_rgba.clone();
    assert!(restore_watermark_canvas(&donor, &donor_rgba, &mut restored, WIDTH, HEIGHT).is_err());
    assert_eq!(restored, returned_rgba);
}

#[test]
fn unsampled_style_keeps_band_detection() {
    // Same frame, a style whose end block has not been checked: the rows of
    // the two bands come back, the side borders stay as edited.
    let picture = (20, 80, 280, 320);
    let donor = donor_file("hassel_style_2", picture);
    let donor_rgba = donor_raster(picture, WHITE);
    assert_eq!(stored_frame_picture_rect(&donor, &donor_rgba, WIDTH, HEIGHT), None);
    let returned_rgba = edited(&donor_rgba);
    let mut restored = returned_rgba.clone();
    restore_watermark_canvas(&donor, &donor_rgba, &mut restored, WIDTH, HEIGHT).expect("restore");
    let (frame_wrong, picture_wrong) =
        mismatches(&restored, &donor_rgba, &returned_rgba, picture);
    // Two borders of 20 columns over the 320 picture rows.
    assert_eq!((frame_wrong, picture_wrong), (2 * 20 * 320, 0));
}

#[test]
fn stored_rect_reads_the_three_checked_styles() {
    let picture = (20, 80, 280, 320);
    for style in ["hassel_style_1", "hassel_style_4", "hassel_style_master_mode_1"] {
        let donor = donor_file(style, picture);
        assert_eq!(
            container::watermark_frame_picture_rect(&donor, WIDTH, HEIGHT),
            Some(picture),
            "{style}"
        );
        // The entry describes another image size.
        assert_eq!(container::watermark_frame_picture_rect(&donor, WIDTH, HEIGHT + 2), None);
    }
    // A rectangle that is the whole image leaves no frame to restore.
    let donor = donor_file("hassel_style_1", (0, 0, WIDTH, HEIGHT));
    assert_eq!(container::watermark_frame_picture_rect(&donor, WIDTH, HEIGHT), None);
    assert_eq!(container::watermark_frame_picture_rect(&tail_file(&[]), WIDTH, HEIGHT), None);
}

#[test]
fn device_name_alone_is_not_a_rendered_watermark() {
    let device = [0u8; 80];
    let only_device = tail_file(&[("watermark.device", &device)]);
    assert!(container::has_watermark_entries(&only_device));
    assert!(!container::has_rendered_watermark(&only_device));
    assert!(!container::has_rendered_watermark(&tail_file(&[("filter.info", &device)])));
    for name in ["watermark", "watermark.config", "watermark.params", "watermark.master.params"] {
        let file = tail_file(&[("watermark.device", &device), (name, &device)]);
        assert!(container::has_rendered_watermark(&file), "{name}");
    }
}
