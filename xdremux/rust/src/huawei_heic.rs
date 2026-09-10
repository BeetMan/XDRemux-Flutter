//! Read-only Huawei HDR HEIC recognition and diagnostics.
//!
//! Mate 70 samples use a standard ISO 21496-1 `tmap` graph plus Huawei's
//! HDR Vivid markers. This module deliberately does not decode or rewrite the
//! graph yet; it only answers whether the source is already a native Huawei
//! HDR file that Apple Photos can consume.

use crate::isobmff::{self, ParsedMeta, PropertyInfo};
use serde_json::json;
use std::path::Path;

const XTSTYLE_MIME: &[u8] = b"urn:com:huawei:photo:5:1:0:meta:xtstyle";
const HUAWEI_MIME_PREFIX: &[u8] = b"urn:com:huawei:photo:";
const ISO_TMAP_BRAND: &[u8] = b"tmap";
const XTSTYLE_OBSERVED_WIDTH: usize = 192;
const XTSTYLE_OBSERVED_HEIGHT: usize = 192;
const XTSTYLE_OBSERVED_PLANES: usize = 6;
const XTSTYLE_OBSERVED_PLANE_BYTES: usize =
    XTSTYLE_OBSERVED_WIDTH * XTSTYLE_OBSERVED_HEIGHT * std::mem::size_of::<u16>();
const XTSTYLE_OBSERVED_BYTES: usize = XTSTYLE_OBSERVED_PLANES * XTSTYLE_OBSERVED_PLANE_BYTES;
const RFDATAB_OBSERVED_HEADER_BYTES: usize = 64;
const RFDATAB_OBSERVED_MAGIC: &[u8] = b"obp8";

/// Read-only observations for the Huawei portrait resources found in Mate 70
/// HEIC files. The field names intentionally describe container structure and
/// byte shape; they do not assign depth units, channel semantics, or Apple
/// Portrait meaning to Huawei-private data.
#[derive(Debug, Clone)]
pub struct HuaweiPortraitReport {
    pub detected: bool,
    pub classification: String,
    pub safe_to_transform: bool,
    pub recommended_action: String,
    pub primary_item_id: u32,
    pub edof_item_id: Option<u32>,
    pub edof_dimensions: Option<(u32, u32)>,
    pub edof_tile_item_ids: Vec<u32>,
    pub edof_auxiliary_types: Vec<String>,
    pub edof_auxl_targets: Vec<u32>,
    pub edof_auxl_to_primary: bool,
    pub rf_data_b_item_id: Option<u32>,
    pub rf_data_b_bytes: Option<u64>,
    pub rf_data_b_cdsc_targets: Vec<u32>,
    pub rf_data_b_observed_magic: Option<String>,
    pub rf_data_b_observed_header_bytes: Option<u32>,
    pub rf_data_b_observed_plane_offset: Option<u32>,
    pub rf_data_b_observed_plane_dimensions: Option<(u32, u32)>,
    pub rf_data_b_observed_sample_bytes: Option<u32>,
    pub rf_data_b_observed_plane_bytes: Option<u64>,
    pub rf_data_b_observed_plane_complete: Option<bool>,
    pub rf_data_b_observed_remaining_bytes: Option<u64>,
    pub error: Option<String>,
}

impl HuaweiPortraitReport {
    fn to_json(&self) -> serde_json::Value {
        json!({
            "detected": self.detected,
            "classification": self.classification,
            "safeToTransform": self.safe_to_transform,
            "recommendedAction": self.recommended_action,
            "primaryItemId": self.primary_item_id,
            "edofItemId": self.edof_item_id,
            "edofDimensions": self
                .edof_dimensions
                .map(|(w, h)| json!({"width": w, "height": h})),
            "edofTileItemIds": self.edof_tile_item_ids,
            "edofTileCount": self.edof_tile_item_ids.len(),
            "edofAuxiliaryTypes": self.edof_auxiliary_types,
            "edofAuxlTargets": self.edof_auxl_targets,
            "edofAuxlToPrimary": self.edof_auxl_to_primary,
            "rfDataBItemId": self.rf_data_b_item_id,
            "rfDataBBytes": self.rf_data_b_bytes,
            "rfDataBCdscTargets": self.rf_data_b_cdsc_targets,
            "rfDataBObservedMagic": self.rf_data_b_observed_magic,
            "rfDataBObservedHeaderBytes": self.rf_data_b_observed_header_bytes,
            "rfDataBObservedPlaneOffset": self.rf_data_b_observed_plane_offset,
            "rfDataBObservedPlaneDimensions": self
                .rf_data_b_observed_plane_dimensions
                .map(|(w, h)| json!({"width": w, "height": h})),
            "rfDataBObservedSampleBytes": self.rf_data_b_observed_sample_bytes,
            "rfDataBObservedPlaneBytes": self.rf_data_b_observed_plane_bytes,
            "rfDataBObservedPlaneComplete": self.rf_data_b_observed_plane_complete,
            "rfDataBObservedRemainingBytes": self.rf_data_b_observed_remaining_bytes,
            "error": self.error,
        })
    }
}

#[derive(Debug, Clone)]
pub struct HuaweiHeicReport {
    pub schema: &'static str,
    pub status: String,
    pub is_huawei_hdr: bool,
    pub recommended_action: String,
    pub brands: Vec<String>,
    pub item_count: usize,
    pub tmap_item_id: Option<u32>,
    pub base_item_id: Option<u32>,
    pub gain_map_item_id: Option<u32>,
    pub base_dimensions: Option<(u32, u32)>,
    pub gain_map_dimensions: Option<(u32, u32)>,
    pub has_tmap_brand: bool,
    pub has_tmap_graph: bool,
    pub has_hdr_vivid: bool,
    pub has_cuva_marker: bool,
    pub has_huawei_marker: bool,
    pub has_huawei_private_marker: bool,
    pub has_nclx: bool,
    pub nclx_transfer_characteristics: Vec<u16>,
    pub has_clli: bool,
    pub has_mdcv: bool,
    pub has_xtstyle: bool,
    pub xtstyle_bytes: Option<u64>,
    pub xtstyle_version: Option<u32>,
    pub xtstyle_header_f32: Option<Vec<f32>>,
    /// A conservative byte-shape observation, not a semantic coefficient map.
    pub xtstyle_observed_layout: Option<String>,
    pub xtstyle_grid_dimensions: Option<(u32, u32)>,
    pub xtstyle_plane_count: Option<u32>,
    pub xtstyle_nonzero_bytes: Option<u64>,
    pub xtstyle_nonzero_planes: Option<u32>,
    pub has_exif: bool,
    pub exif_bytes: Option<u64>,
    pub exif_make: Option<String>,
    pub exif_model: Option<String>,
    pub exif_orientation_value: Option<u16>,
    pub exif_orientation: Option<String>,
    pub has_gps: bool,
    pub gps_field_count: Option<u32>,
    pub focal_length_mm: Option<f64>,
    pub focal_length_35mm: Option<u16>,
    pub lens_model: Option<String>,
    pub exif_error: Option<String>,
    pub has_dfx_data: bool,
    pub item_types: Vec<String>,
    pub portrait: Option<HuaweiPortraitReport>,
    pub error: Option<String>,
}

impl HuaweiHeicReport {
    fn empty(status: impl Into<String>, brands: Vec<String>) -> Self {
        Self {
            schema: "xdremux-huawei-heic-v1",
            status: status.into(),
            is_huawei_hdr: false,
            recommended_action: "inspect".into(),
            brands,
            item_count: 0,
            tmap_item_id: None,
            base_item_id: None,
            gain_map_item_id: None,
            base_dimensions: None,
            gain_map_dimensions: None,
            has_tmap_brand: false,
            has_tmap_graph: false,
            has_hdr_vivid: false,
            has_cuva_marker: false,
            has_huawei_marker: false,
            has_huawei_private_marker: false,
            has_nclx: false,
            nclx_transfer_characteristics: Vec::new(),
            has_clli: false,
            has_mdcv: false,
            has_xtstyle: false,
            xtstyle_bytes: None,
            xtstyle_version: None,
            xtstyle_header_f32: None,
            xtstyle_observed_layout: None,
            xtstyle_grid_dimensions: None,
            xtstyle_plane_count: None,
            xtstyle_nonzero_bytes: None,
            xtstyle_nonzero_planes: None,
            has_exif: false,
            exif_bytes: None,
            exif_make: None,
            exif_model: None,
            exif_orientation_value: None,
            exif_orientation: None,
            has_gps: false,
            gps_field_count: None,
            focal_length_mm: None,
            focal_length_35mm: None,
            lens_model: None,
            exif_error: None,
            has_dfx_data: false,
            item_types: Vec::new(),
            portrait: None,
            error: None,
        }
    }

    /// Serialize a stable JSON report for Dart, probes, and future diagnostics.
    pub fn to_json(&self) -> String {
        let mut report = json!({
            "schema": self.schema,
            "status": self.status,
            "isHuaweiHdr": self.is_huawei_hdr,
            "applePhotosHdrCompatible": self.is_huawei_hdr,
            "recommendedAction": self.recommended_action,
            "brands": self.brands,
            "itemCount": self.item_count,
            "itemTypes": self.item_types,
            "tmapItemId": self.tmap_item_id,
            "baseItemId": self.base_item_id,
            "gainMapItemId": self.gain_map_item_id,
            "baseDimensions": self.base_dimensions.map(|(w, h)| json!({"width": w, "height": h})),
            "gainMapDimensions": self.gain_map_dimensions.map(|(w, h)| json!({"width": w, "height": h})),
            "hasTmapBrand": self.has_tmap_brand,
            "hasTmapGraph": self.has_tmap_graph,
            "hasHdrVivid": self.has_hdr_vivid,
            "hasCuvaMarker": self.has_cuva_marker,
            "hasHuaweiMarker": self.has_huawei_marker,
            "hasHuaweiPrivateMarker": self.has_huawei_private_marker,
            "hasNclx": self.has_nclx,
            "nclxTransferCharacteristics": self.nclx_transfer_characteristics,
            "hasClli": self.has_clli,
            "hasMdcv": self.has_mdcv,
            "hasXtstyle": self.has_xtstyle,
            "xtstyleBytes": self.xtstyle_bytes,
            "xtstyleVersion": self.xtstyle_version,
            "xtstyleHeaderFloat32": self.xtstyle_header_f32,
            "xtstyleObservedLayout": self.xtstyle_observed_layout,
            "xtstyleGridDimensions": self
                .xtstyle_grid_dimensions
                .map(|(w, h)| json!({"width": w, "height": h})),
            "xtstylePlaneCount": self.xtstyle_plane_count,
            "xtstyleNonzeroBytes": self.xtstyle_nonzero_bytes,
            "xtstyleNonzeroPlanes": self.xtstyle_nonzero_planes,
            "hasExif": self.has_exif,
            "exifBytes": self.exif_bytes,
            "exifMake": self.exif_make,
            "exifModel": self.exif_model,
            "exifOrientationValue": self.exif_orientation_value,
            "exifOrientation": self.exif_orientation,
            "hasGps": self.has_gps,
            "gpsFieldCount": self.gps_field_count,
            "focalLengthMm": self.focal_length_mm,
            "focalLength35mm": self.focal_length_35mm,
            "lensModel": self.lens_model,
            "exifError": self.exif_error,
            "hasDfxData": self.has_dfx_data,
            "hasHuaweiPortrait": self.portrait.as_ref().is_some_and(|portrait| portrait.detected),
            "error": self.error,
        });
        if let Some(portrait) = &self.portrait {
            report["huaweiPortrait"] = portrait.to_json();
        }
        report.to_string()
    }
}

pub fn inspect_path(path: impl AsRef<Path>) -> Result<HuaweiHeicReport, String> {
    let data = std::fs::read(path).map_err(|error| format!("cannot read Huawei HEIC: {error}"))?;
    Ok(inspect_bytes(&data))
}

pub fn inspect_bytes(data: &[u8]) -> HuaweiHeicReport {
    let brands = ftyp_brands(data);
    let has_tmap_brand = brands
        .iter()
        .any(|brand| brand.as_bytes() == ISO_TMAP_BRAND);
    let has_huawei_marker = contains_any(data, &[b"HUAWEI", HUAWEI_MIME_PREFIX]);
    let has_cuva_marker = data
        .windows(b"_cuva".len())
        .any(|window| window == b"_cuva");

    let mut report = HuaweiHeicReport::empty(
        if brands.is_empty() {
            "not-isobmff"
        } else {
            "not-huawei"
        },
        brands,
    );
    report.has_tmap_brand = has_tmap_brand;
    report.has_huawei_marker = has_huawei_marker;
    report.has_cuva_marker = has_cuva_marker;

    let meta = match parse_source_meta(data) {
        Ok(meta) => meta,
        Err(error) => {
            if has_tmap_brand || has_huawei_marker {
                report.status = "invalid-or-incomplete-heif".into();
                report.error = Some(error);
            }
            return report;
        }
    };

    populate_report(&mut report, data, &meta);
    report
}

fn populate_report(report: &mut HuaweiHeicReport, data: &[u8], meta: &ParsedMeta) {
    report.item_count = meta.items.len();
    report.item_types = meta.items.iter().map(|item| item.itype.clone()).collect();

    let tmap_id = meta
        .items
        .iter()
        .find(|item| item.itype == "tmap")
        .map(|item| item.item_id);
    let named_base_id = meta.items.iter().find_map(|item| {
        (item.itype == "grid" && raw_contains(&item.raw_infe, b"base")).then_some(item.item_id)
    });
    let named_gain_id = meta.items.iter().find_map(|item| {
        (item.itype == "grid" && raw_contains(&item.raw_infe, b"gain map image"))
            .then_some(item.item_id)
    });
    let (base_id, gain_id) = tmap_id
        .map(|id| resolve_tmap_graph_items(meta, id, named_base_id, named_gain_id))
        .unwrap_or((named_base_id, named_gain_id));

    report.tmap_item_id = tmap_id;
    report.base_item_id = base_id;
    report.gain_map_item_id = gain_id;
    report.base_dimensions = base_id.and_then(|id| item_dimensions(meta, id));
    report.gain_map_dimensions = gain_id.and_then(|id| item_dimensions(meta, id));

    report.has_tmap_graph = tmap_id.is_some_and(|id| {
        let (Some(base), Some(gain)) = (base_id, gain_id) else {
            return false;
        };
        is_grid_item(meta, base)
            && is_grid_item(meta, gain)
            && meta.refs.iter().any(|reference| {
                reference.rtype == "dimg"
                    && reference.from == id
                    && reference.to.contains(&base)
                    && reference.to.contains(&gain)
            })
    });

    report.has_hdr_vivid = meta.items.iter().any(|item| item.itype == "it35");
    let xtstyle_id = meta
        .items
        .iter()
        .find(|item| item.itype == "mime" && raw_contains(&item.raw_infe, XTSTYLE_MIME))
        .map(|item| item.item_id);
    report.has_xtstyle = xtstyle_id.is_some();
    report.xtstyle_bytes = xtstyle_id.map(|id| item_data_size(meta, id));
    if let Some(item_id) = xtstyle_id {
        if let Some(payload) = item_data(data, meta, item_id) {
            report.xtstyle_bytes = Some(payload.len() as u64);
            let diagnostic = inspect_xtstyle_payload(&payload);
            report.xtstyle_version = diagnostic.version;
            report.xtstyle_header_f32 = diagnostic.header_f32;
            report.xtstyle_observed_layout = diagnostic.observed_layout;
            report.xtstyle_grid_dimensions = diagnostic.grid_dimensions;
            report.xtstyle_plane_count = diagnostic.plane_count;
            report.xtstyle_nonzero_bytes = Some(diagnostic.nonzero_bytes);
            report.xtstyle_nonzero_planes = diagnostic.nonzero_planes;
        }
    }

    let exif_id = meta
        .items
        .iter()
        .find(|item| item.itype == "Exif")
        .map(|item| item.item_id);
    report.has_exif = exif_id.is_some();
    report.exif_bytes = exif_id.map(|id| item_data_size(meta, id));
    if let Some(item_id) = exif_id {
        if let Some(payload) = item_data(data, meta, item_id) {
            report.exif_bytes = Some(payload.len() as u64);
            match inspect_exif_payload(&payload) {
                Ok(diagnostic) => {
                    report.exif_make = diagnostic.make;
                    report.exif_model = diagnostic.model;
                    report.exif_orientation_value = diagnostic.orientation_value;
                    report.exif_orientation = Some(diagnostic.orientation);
                    report.has_gps = diagnostic.has_gps;
                    report.gps_field_count = diagnostic.gps_field_count;
                    report.focal_length_mm = diagnostic.focal_length_mm;
                    report.focal_length_35mm = diagnostic.focal_length_35mm;
                    report.lens_model = diagnostic.lens_model;
                }
                Err(error) => report.exif_error = Some(error),
            }
        } else {
            report.exif_error = Some("Exif item payload is unavailable".into());
        }
    }

    report.has_dfx_data = meta
        .items
        .iter()
        .any(|item| item.itype == "mime" && raw_contains(&item.raw_infe, b"DfxData"));
    report.portrait = inspect_huawei_portrait(data, meta);
    report.has_huawei_private_marker = report.has_xtstyle
        || report.has_dfx_data
        || meta
            .items
            .iter()
            .any(|item| item.itype == "mime" && raw_contains(&item.raw_infe, HUAWEI_MIME_PREFIX));

    let nclx: Vec<u16> = meta.props.iter().filter_map(nclx_transfer).collect();
    report.has_nclx = !nclx.is_empty();
    report.nclx_transfer_characteristics = nclx;
    report.has_clli = meta.props.iter().any(|property| property.ptype == "clli");
    report.has_mdcv = meta.props.iter().any(|property| property.ptype == "mdcv");

    report.is_huawei_hdr = report.has_tmap_brand
        && report.has_tmap_graph
        && report.has_huawei_marker
        && report.has_huawei_private_marker;
    if report.is_huawei_hdr {
        report.status = "huawei-hdr".into();
        report.recommended_action = "skip-native-hdr".into();
    } else if report.has_tmap_brand && report.has_tmap_graph {
        report.status = "iso-tmap-heif".into();
    } else if report.has_huawei_marker {
        report.status = "huawei-heif-unclassified".into();
    } else {
        report.status = "not-huawei".into();
    }

    // Keep this diagnostic useful when a malformed source has a recognizable
    // marker but no complete metadata graph.
    if report.is_huawei_hdr && data.is_empty() {
        report.error = Some("empty HEIF data".into());
    }
}

fn inspect_huawei_portrait(data: &[u8], meta: &ParsedMeta) -> Option<HuaweiPortraitReport> {
    if !contains_any(data, &[b"HUAWEI", HUAWEI_MIME_PREFIX]) {
        return None;
    }
    let edof_item_id = meta
        .items
        .iter()
        .find(|item| item.itype == "grid" && raw_contains(&item.raw_infe, b"edof"))
        .map(|item| item.item_id);
    let rf_data_b_item_id = meta
        .items
        .iter()
        .find(|item| item.itype == "mime" && raw_contains(&item.raw_infe, b"RfDataB"))
        .map(|item| item.item_id);
    if edof_item_id.is_none() && rf_data_b_item_id.is_none() {
        return None;
    }

    let edof_tile_item_ids = edof_item_id
        .map(|item_id| reference_targets(meta, "dimg", item_id))
        .unwrap_or_default();
    let edof_auxl_targets = edof_item_id
        .map(|item_id| reference_targets(meta, "auxl", item_id))
        .unwrap_or_default();
    let edof_auxiliary_types = edof_item_id
        .map(|item_id| auxiliary_types_for_item(meta, item_id))
        .unwrap_or_default();
    let rf_data_b_cdsc_targets = rf_data_b_item_id
        .map(|item_id| reference_targets(meta, "cdsc", item_id))
        .unwrap_or_default();
    let rf_data_b_payload = rf_data_b_item_id.and_then(|item_id| item_data(data, meta, item_id));
    let rf_data_b_bytes = rf_data_b_item_id.map(|item_id| item_data_size(meta, item_id));
    let shape = rf_data_b_payload
        .as_deref()
        .and_then(observe_rf_data_b_shape);
    let complete = edof_item_id.is_some()
        && rf_data_b_item_id.is_some()
        && edof_tile_item_ids.iter().all(|item_id| {
            meta.items
                .iter()
                .any(|item| item.item_id == *item_id && item.itype == "hvc1")
        })
        && edof_auxl_targets.contains(&meta.primary_id)
        && edof_auxiliary_types
            .iter()
            .any(|value| value == "urn:com:huawei:photo:5:0:0:aux:unrefocusmap");
    let detected = edof_item_id.is_some() || rf_data_b_item_id.is_some();
    Some(HuaweiPortraitReport {
        detected,
        classification: if complete {
            "huawei-portrait".into()
        } else {
            "huawei-portrait-incomplete".into()
        },
        safe_to_transform: false,
        recommended_action: "inspect-only".into(),
        primary_item_id: meta.primary_id,
        edof_item_id,
        edof_dimensions: edof_item_id.and_then(|item_id| item_dimensions(meta, item_id)),
        edof_tile_item_ids,
        edof_auxiliary_types,
        edof_auxl_targets,
        edof_auxl_to_primary: edof_item_id.is_some_and(|item_id| {
            reference_targets(meta, "auxl", item_id).contains(&meta.primary_id)
        }),
        rf_data_b_item_id,
        rf_data_b_bytes,
        rf_data_b_cdsc_targets,
        rf_data_b_observed_magic: shape.as_ref().and_then(|shape| shape.magic.clone()),
        rf_data_b_observed_header_bytes: shape.as_ref().map(|shape| shape.header_bytes),
        rf_data_b_observed_plane_offset: shape.as_ref().map(|shape| shape.plane_offset),
        rf_data_b_observed_plane_dimensions: shape.as_ref().and_then(|shape| shape.dimensions),
        rf_data_b_observed_sample_bytes: shape.as_ref().and_then(|shape| shape.sample_bytes),
        rf_data_b_observed_plane_bytes: shape.as_ref().and_then(|shape| shape.plane_bytes),
        rf_data_b_observed_plane_complete: shape.as_ref().map(|shape| shape.plane_complete),
        rf_data_b_observed_remaining_bytes: shape.as_ref().and_then(|shape| shape.remaining_bytes),
        error: if rf_data_b_item_id.is_some() && rf_data_b_payload.is_none() {
            Some("RfDataB item payload is unavailable".into())
        } else {
            None
        },
    })
}

fn reference_targets(meta: &ParsedMeta, rtype: &str, from: u32) -> Vec<u32> {
    meta.refs
        .iter()
        .filter(|reference| reference.rtype == rtype && reference.from == from)
        .flat_map(|reference| reference.to.iter().copied())
        .collect()
}

fn auxiliary_types_for_item(meta: &ParsedMeta, item_id: u32) -> Vec<String> {
    let Some(entry) = meta
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == item_id)
    else {
        return Vec::new();
    };
    entry
        .associations
        .iter()
        .filter_map(|(index, _)| meta.props.iter().find(|property| property.index == *index))
        .filter(|property| property.ptype == "auxC")
        .filter_map(|property| {
            let payload = property.raw.get(12..)?;
            let end = payload
                .iter()
                .position(|byte| *byte == 0)
                .unwrap_or(payload.len());
            let value = std::str::from_utf8(&payload[..end]).ok()?.to_string();
            (!value.is_empty()).then_some(value)
        })
        .collect()
}

#[derive(Debug, Clone)]
struct RfDataBShape {
    magic: Option<String>,
    header_bytes: u32,
    plane_offset: u32,
    dimensions: Option<(u32, u32)>,
    sample_bytes: Option<u32>,
    plane_bytes: Option<u64>,
    plane_complete: bool,
    remaining_bytes: Option<u64>,
}

fn observe_rf_data_b_shape(payload: &[u8]) -> Option<RfDataBShape> {
    if payload.len() < RFDATAB_OBSERVED_HEADER_BYTES {
        return None;
    }
    let magic = (payload.get(4..8) == Some(RFDATAB_OBSERVED_MAGIC))
        .then(|| String::from_utf8_lossy(RFDATAB_OBSERVED_MAGIC).into_owned());
    // The observed RfDataB header stores these two 16-bit dimensions little-endian.
    let width = u16::from_le_bytes(payload[12..14].try_into().ok()?) as u32;
    let height = u16::from_le_bytes(payload[14..16].try_into().ok()?) as u32;
    if width == 0 || height == 0 {
        return None;
    }
    let plane_bytes = u64::from(width) * u64::from(height);
    let plane_offset = RFDATAB_OBSERVED_HEADER_BYTES as u32;
    let available = payload.len().saturating_sub(RFDATAB_OBSERVED_HEADER_BYTES) as u64;
    Some(RfDataBShape {
        magic,
        header_bytes: RFDATAB_OBSERVED_HEADER_BYTES as u32,
        plane_offset,
        dimensions: Some((width, height)),
        sample_bytes: Some(1),
        plane_bytes: Some(plane_bytes),
        plane_complete: available >= plane_bytes,
        remaining_bytes: (available >= plane_bytes).then_some(available - plane_bytes),
    })
}

fn parse_source_meta(data: &[u8]) -> Result<ParsedMeta, String> {
    isobmff::parse_source_meta(data)
}

fn ftyp_brands(data: &[u8]) -> Vec<String> {
    let Some(ftyp) = isobmff::find_box(data, b"ftyp", 0, data.len()) else {
        return Vec::new();
    };
    if ftyp.data_end.saturating_sub(ftyp.data_start) < 8 {
        return Vec::new();
    }
    let payload = &data[ftyp.data_start..ftyp.data_end];
    let mut brands = Vec::new();
    brands.push(String::from_utf8_lossy(&payload[..4]).into_owned());
    let mut offset = 8;
    while offset + 4 <= payload.len() {
        brands.push(String::from_utf8_lossy(&payload[offset..offset + 4]).into_owned());
        offset += 4;
    }
    brands
}

fn resolve_tmap_graph_items(
    meta: &ParsedMeta,
    tmap_id: u32,
    named_base_id: Option<u32>,
    named_gain_id: Option<u32>,
) -> (Option<u32>, Option<u32>) {
    let targets: Vec<u32> = meta
        .refs
        .iter()
        .filter(|reference| reference.rtype == "dimg" && reference.from == tmap_id)
        .flat_map(|reference| reference.to.iter().copied())
        .collect();
    let base_id = named_base_id.or_else(|| {
        targets
            .iter()
            .copied()
            .find(|item_id| *item_id == meta.primary_id)
            .or_else(|| {
                targets
                    .iter()
                    .copied()
                    .filter_map(|item_id| {
                        item_dimensions(meta, item_id).map(|dims| (item_id, dims))
                    })
                    .max_by_key(|(_, (width, height))| u64::from(*width) * u64::from(*height))
                    .map(|(item_id, _)| item_id)
            })
    });
    let gain_id = named_gain_id.or_else(|| {
        targets
            .iter()
            .copied()
            .find(|item_id| Some(*item_id) != base_id && is_grid_item(meta, *item_id))
    });
    (base_id, gain_id)
}

fn is_grid_item(meta: &ParsedMeta, item_id: u32) -> bool {
    meta.items
        .iter()
        .any(|item| item.item_id == item_id && item.itype == "grid")
}

fn item_dimensions(meta: &ParsedMeta, item_id: u32) -> Option<(u32, u32)> {
    let entry = meta
        .ipma_entries
        .iter()
        .find(|entry| entry.item_id == item_id)?;
    entry.associations.iter().find_map(|(index, _)| {
        let property = meta
            .props
            .iter()
            .find(|property| property.index == *index && property.ptype == "ispe")?;
        isobmff::ispe_dimensions(&property.raw).ok()
    })
}

#[derive(Debug, Clone)]
struct ExifDiagnostics {
    make: Option<String>,
    model: Option<String>,
    orientation_value: Option<u16>,
    orientation: String,
    has_gps: bool,
    gps_field_count: Option<u32>,
    focal_length_mm: Option<f64>,
    focal_length_35mm: Option<u16>,
    lens_model: Option<String>,
}

#[derive(Debug, Clone, Copy)]
struct TiffEntry {
    tag: u16,
    field_type: u16,
    count: u32,
    value_field_offset: usize,
}

struct TiffView<'a> {
    data: &'a [u8],
    little_endian: bool,
}

impl<'a> TiffView<'a> {
    fn u16(&self, offset: usize) -> Result<u16, String> {
        let bytes: [u8; 2] = self
            .data
            .get(offset..offset + 2)
            .ok_or("Exif TIFF u16 is truncated")?
            .try_into()
            .expect("two-byte TIFF u16");
        Ok(if self.little_endian {
            u16::from_le_bytes(bytes)
        } else {
            u16::from_be_bytes(bytes)
        })
    }

    fn u32(&self, offset: usize) -> Result<u32, String> {
        let bytes: [u8; 4] = self
            .data
            .get(offset..offset + 4)
            .ok_or("Exif TIFF u32 is truncated")?
            .try_into()
            .expect("four-byte TIFF u32");
        Ok(if self.little_endian {
            u32::from_le_bytes(bytes)
        } else {
            u32::from_be_bytes(bytes)
        })
    }

    fn read_ifd(&self, offset: usize) -> Result<Vec<TiffEntry>, String> {
        let count = self.u16(offset)? as usize;
        let entries_start = offset.checked_add(2).ok_or("Exif IFD offset overflow")?;
        let entries_len = count
            .checked_mul(12)
            .ok_or("Exif IFD entry count overflow")?;
        let entries_end = entries_start
            .checked_add(entries_len)
            .ok_or("Exif IFD length overflow")?;
        if entries_end.checked_add(4).is_none() || entries_end + 4 > self.data.len() {
            return Err("Exif IFD is truncated".into());
        }

        let mut entries = Vec::with_capacity(count);
        for index in 0..count {
            let entry = entries_start + index * 12;
            entries.push(TiffEntry {
                tag: self.u16(entry)?,
                field_type: self.u16(entry + 2)?,
                count: self.u32(entry + 4)?,
                value_field_offset: entry + 8,
            });
        }
        Ok(entries)
    }

    fn entry_bytes<'b>(&'b self, entry: &TiffEntry) -> Result<&'b [u8], String> {
        let type_size = match entry.field_type {
            1 | 2 | 6 | 7 => 1usize,
            3 => 2,
            4 | 9 => 4,
            5 | 10 => 8,
            other => return Err(format!("unsupported EXIF field type {other}")),
        };
        let total = type_size
            .checked_mul(usize::try_from(entry.count).map_err(|_| "EXIF count overflow")?)
            .ok_or("EXIF field length overflow")?;
        let start = if total <= 4 {
            entry.value_field_offset
        } else {
            self.u32(entry.value_field_offset)? as usize
        };
        let end = start
            .checked_add(total)
            .ok_or("EXIF field offset overflow")?;
        self.data
            .get(start..end)
            .ok_or_else(|| "EXIF field is outside the TIFF item".into())
    }

    fn entry_u32(&self, entry: &TiffEntry) -> Result<u32, String> {
        if entry.count != 1 {
            return Err("EXIF pointer/value must contain one value".into());
        }
        match entry.field_type {
            3 => Ok(self.u16(entry.value_field_offset)? as u32),
            4 => self.u32(entry.value_field_offset),
            other => Err(format!("unsupported EXIF integer field type {other}")),
        }
    }

    fn entry_ascii(&self, entry: &TiffEntry) -> Result<Option<String>, String> {
        if entry.field_type != 2 {
            return Ok(None);
        }
        let bytes = self.entry_bytes(entry)?;
        Ok(Some(
            String::from_utf8_lossy(bytes)
                .trim_end_matches('\0')
                .to_string(),
        ))
    }

    fn entry_rational(&self, entry: &TiffEntry) -> Result<Option<f64>, String> {
        if entry.field_type != 5 || entry.count != 1 {
            return Ok(None);
        }
        let bytes = self.entry_bytes(entry)?;
        let numerator = if self.little_endian {
            u32::from_le_bytes(bytes[0..4].try_into().expect("rational numerator"))
        } else {
            u32::from_be_bytes(bytes[0..4].try_into().expect("rational numerator"))
        };
        let denominator = if self.little_endian {
            u32::from_le_bytes(bytes[4..8].try_into().expect("rational denominator"))
        } else {
            u32::from_be_bytes(bytes[4..8].try_into().expect("rational denominator"))
        };
        if denominator == 0 {
            return Ok(None);
        }
        Ok(Some(numerator as f64 / denominator as f64))
    }
}

fn exif_find(entries: &[TiffEntry], tag: u16) -> Option<TiffEntry> {
    entries.iter().find(|entry| entry.tag == tag).copied()
}

fn exif_pointed_ifd(
    view: &TiffView<'_>,
    entries: &[TiffEntry],
    tag: u16,
) -> Result<Option<Vec<TiffEntry>>, String> {
    let Some(entry) = exif_find(entries, tag) else {
        return Ok(None);
    };
    let offset = view.entry_u32(&entry)? as usize;
    if offset == 0 {
        return Ok(None);
    }
    Ok(Some(view.read_ifd(offset)?))
}

fn exif_orientation_label(value: Option<u16>) -> String {
    match value.unwrap_or(1) {
        2 => "flip-horizontal",
        3 => "rotate-180",
        4 => "flip-vertical",
        5 => "transpose",
        6 => "rotate-90-clockwise",
        7 => "transverse",
        8 => "rotate-90-counterclockwise",
        _ => "normal",
    }
    .into()
}

fn inspect_exif_payload(payload: &[u8]) -> Result<ExifDiagnostics, String> {
    let tiff_start = if payload.starts_with(b"II") || payload.starts_with(b"MM") {
        0
    } else {
        let offset = payload
            .get(0..4)
            .ok_or("Exif item is shorter than its TIFF offset")?;
        let offset = u32::from_be_bytes(offset.try_into().expect("four-byte Exif offset")) as usize;
        [
            offset,
            offset.checked_add(4).ok_or("Exif TIFF offset overflow")?,
        ]
        .into_iter()
        .find(|candidate| {
            payload
                .get(*candidate..)
                .is_some_and(|bytes| bytes.starts_with(b"II") || bytes.starts_with(b"MM"))
        })
        .ok_or("Exif TIFF offset is outside the item or not a TIFF header")?
    };
    let tiff = payload
        .get(tiff_start..)
        .ok_or("Exif TIFF start is outside the item")?;
    if tiff.len() < 8 {
        return Err("Exif TIFF header is truncated".into());
    }
    let little_endian = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return Err("Exif TIFF byte order is invalid".into()),
    };
    let view = TiffView {
        data: tiff,
        little_endian,
    };
    if view.u16(2)? != 42 {
        return Err("Exif TIFF magic is invalid".into());
    }

    let ifd0 = view.read_ifd(view.u32(4)? as usize)?;
    let exif_ifd = exif_pointed_ifd(&view, &ifd0, 0x8769)?.unwrap_or_default();
    let gps_ifd = exif_pointed_ifd(&view, &ifd0, 0x8825)?;

    let orientation_entry = exif_find(&ifd0, 0x0112);
    let orientation_value = orientation_entry
        .map(|entry| {
            view.entry_u32(&entry)
                .map(|value| value.min(u16::MAX as u32) as u16)
        })
        .transpose()?;
    let make = exif_find(&ifd0, 0x010f)
        .map(|entry| view.entry_ascii(&entry))
        .transpose()?
        .flatten();
    let model = exif_find(&ifd0, 0x0110)
        .map(|entry| view.entry_ascii(&entry))
        .transpose()?
        .flatten();
    let focal_length_mm = exif_find(&exif_ifd, 0x920a)
        .map(|entry| view.entry_rational(&entry))
        .transpose()?
        .flatten();
    let focal_length_35mm = exif_find(&exif_ifd, 0xa405)
        .map(|entry| {
            view.entry_u32(&entry)
                .map(|value| value.min(u16::MAX as u32) as u16)
        })
        .transpose()?;
    let lens_model = exif_find(&exif_ifd, 0xa434)
        .map(|entry| view.entry_ascii(&entry))
        .transpose()?
        .flatten();

    Ok(ExifDiagnostics {
        make,
        model,
        orientation_value,
        orientation: exif_orientation_label(orientation_value),
        has_gps: gps_ifd.is_some(),
        gps_field_count: gps_ifd.map(|entries| entries.len() as u32),
        focal_length_mm,
        focal_length_35mm,
        lens_model,
    })
}

#[derive(Debug, Clone)]
struct XtstyleDiagnostics {
    version: Option<u32>,
    header_f32: Option<Vec<f32>>,
    observed_layout: Option<String>,
    grid_dimensions: Option<(u32, u32)>,
    plane_count: Option<u32>,
    nonzero_bytes: u64,
    nonzero_planes: Option<u32>,
}

/// Read a metadata item using the already parsed iloc offsets.
///
/// The current Huawei samples use construction method 0 for `xtstyle`, but
/// method 1 is handled as well because it stores the item in the meta `idat`
/// payload. No bytes are interpreted beyond this diagnostic path.
fn item_data(data: &[u8], meta: &ParsedMeta, item_id: u32) -> Option<Vec<u8>> {
    let entry = meta
        .iloc_entries
        .iter()
        .find(|entry| entry.item_id == item_id)?;
    let idat_start = if entry.construction_method == 1 {
        let meta_box = isobmff::find_box(data, b"meta", 0, data.len())?;
        isobmff::parse_boxes(data, meta_box.data_start + 4, meta_box.data_end)
            .into_iter()
            .find(|child| &child.btype == b"idat")
            .map(|idat| idat.data_start)?
    } else {
        0
    };

    let mut output = Vec::new();
    for (offset, length) in &entry.extents {
        let start = if entry.construction_method == 1 {
            u64::try_from(idat_start).ok()?.checked_add(*offset)?
        } else {
            *offset
        };
        let end = start.checked_add(*length)?;
        let start = usize::try_from(start).ok()?;
        let end = usize::try_from(end).ok()?;
        output.extend_from_slice(data.get(start..end)?);
    }
    Some(output)
}

fn inspect_xtstyle_payload(payload: &[u8]) -> XtstyleDiagnostics {
    let version =
        (payload.len() >= 4).then(|| u32::from_le_bytes(payload[0..4].try_into().unwrap()));
    let header_f32 = (payload.len() >= 16).then(|| {
        vec![
            f32::from_le_bytes(payload[4..8].try_into().unwrap()),
            f32::from_le_bytes(payload[8..12].try_into().unwrap()),
            f32::from_le_bytes(payload[12..16].try_into().unwrap()),
        ]
    });
    let header_f32 = header_f32.filter(|values| values.iter().all(|value| value.is_finite()));
    let nonzero_bytes = payload.iter().filter(|byte| **byte != 0).count() as u64;

    // All three current standard-mode samples have exactly this byte shape.
    // It is deliberately reported as an observed layout rather than a
    // decoded coefficient meaning: the 16-bit slots include a header and a
    // mostly reserved tail, and their semantics are not established yet.
    let (observed_layout, grid_dimensions, plane_count, nonzero_planes) =
        if payload.len() == XTSTYLE_OBSERVED_BYTES {
            let nonzero_planes = payload
                .chunks_exact(XTSTYLE_OBSERVED_PLANE_BYTES)
                .filter(|plane| plane.iter().any(|byte| *byte != 0))
                .count() as u32;
            (
                Some("u16le[6][192][192]".into()),
                Some((
                    XTSTYLE_OBSERVED_WIDTH as u32,
                    XTSTYLE_OBSERVED_HEIGHT as u32,
                )),
                Some(XTSTYLE_OBSERVED_PLANES as u32),
                Some(nonzero_planes),
            )
        } else {
            (None, None, None, None)
        };

    XtstyleDiagnostics {
        version,
        header_f32,
        observed_layout,
        grid_dimensions,
        plane_count,
        nonzero_bytes,
        nonzero_planes,
    }
}

fn item_data_size(meta: &ParsedMeta, item_id: u32) -> u64 {
    meta.iloc_entries
        .iter()
        .find(|entry| entry.item_id == item_id)
        .map(|entry| entry.extents.iter().map(|(_, length)| *length).sum())
        .unwrap_or(0)
}

fn nclx_transfer(property: &PropertyInfo) -> Option<u16> {
    if property.ptype != "colr" || property.raw.len() < 18 {
        return None;
    }
    (&property.raw[8..12] == b"nclx")
        .then(|| u16::from_be_bytes([property.raw[14], property.raw[15]]))
}

fn raw_contains(raw: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && raw.windows(needle.len()).any(|window| window == needle)
}

fn contains_any(data: &[u8], needles: &[&[u8]]) -> bool {
    needles.iter().any(|needle| raw_contains(data, needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tmap_brands_from_ftyp() {
        let mut data = Vec::new();
        data.extend_from_slice(&24u32.to_be_bytes());
        data.extend_from_slice(b"ftyp");
        data.extend_from_slice(b"heic");
        data.extend_from_slice(&0u32.to_be_bytes());
        data.extend_from_slice(b"mif1");
        data.extend_from_slice(b"tmap");
        assert_eq!(ftyp_brands(&data), vec!["heic", "mif1", "tmap"]);
    }

    #[test]
    fn nclx_transfer_reads_transfer_field() {
        let property = PropertyInfo {
            index: 1,
            ptype: "colr".into(),
            raw: vec![
                0, 0, 0, 19, b'c', b'o', b'l', b'r', b'n', b'c', b'l', b'x', 0, 9, 0, 18, 0, 9,
                0x80,
            ],
        };
        assert_eq!(nclx_transfer(&property), Some(18));
    }

    #[test]
    fn parses_observed_xtstyle_header_and_shape() {
        let mut payload = vec![0u8; XTSTYLE_OBSERVED_BYTES];
        payload[0..4].copy_from_slice(&5u32.to_le_bytes());
        for (offset, value) in [(4, 0.5f32), (8, 0.5f32), (12, 0.5f32)] {
            payload[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        payload[XTSTYLE_OBSERVED_PLANE_BYTES + 2] = 1;

        let diagnostic = inspect_xtstyle_payload(&payload);
        assert_eq!(diagnostic.version, Some(5));
        assert_eq!(diagnostic.header_f32, Some(vec![0.5, 0.5, 0.5]));
        assert_eq!(
            diagnostic.observed_layout.as_deref(),
            Some("u16le[6][192][192]")
        );
        assert_eq!(diagnostic.grid_dimensions, Some((192, 192)));
        assert_eq!(diagnostic.plane_count, Some(6));
        assert_eq!(diagnostic.nonzero_planes, Some(2));
        assert_eq!(diagnostic.nonzero_bytes, 5);
    }

    #[test]
    fn keeps_xtstyle_header_diagnostic_for_unknown_length() {
        let mut payload = vec![0u8; 32];
        payload[0..4].copy_from_slice(&5u32.to_le_bytes());
        payload[4..8].copy_from_slice(&0.5f32.to_le_bytes());
        payload[8..12].copy_from_slice(&0.5f32.to_le_bytes());
        payload[12..16].copy_from_slice(&0.5f32.to_le_bytes());

        let diagnostic = inspect_xtstyle_payload(&payload);
        assert_eq!(diagnostic.version, Some(5));
        assert!(diagnostic.header_f32.is_some());
        assert!(diagnostic.observed_layout.is_none());
        assert_eq!(diagnostic.nonzero_bytes, 4);
    }

    #[test]
    fn observes_rfdatab_plane_shape_without_assigning_depth_semantics() {
        let mut payload = vec![0u8; RFDATAB_OBSERVED_HEADER_BYTES + 1024 * 768 + 11];
        payload[4..8].copy_from_slice(RFDATAB_OBSERVED_MAGIC);
        payload[12..14].copy_from_slice(&1024u16.to_le_bytes());
        payload[14..16].copy_from_slice(&768u16.to_le_bytes());
        let diagnostic = observe_rf_data_b_shape(&payload).expect("shape");
        assert_eq!(diagnostic.magic.as_deref(), Some("obp8"));
        assert_eq!(diagnostic.dimensions, Some((1024, 768)));
        assert_eq!(diagnostic.sample_bytes, Some(1));
        assert_eq!(diagnostic.plane_bytes, Some(1024 * 768));
        assert!(diagnostic.plane_complete);
        assert_eq!(diagnostic.remaining_bytes, Some(11));

        payload[4..8].copy_from_slice(&[0x3a, 0xa8, 0xce, 0x38]);
        let variant = observe_rf_data_b_shape(&payload).expect("variant shape");
        assert!(variant.magic.is_none());
        assert_eq!(variant.dimensions, Some((1024, 768)));
    }

    #[test]
    fn exif_orientation_out_of_range_is_normal() {
        assert_eq!(exif_orientation_label(Some(0)), "normal");
        assert_eq!(exif_orientation_label(Some(9)), "normal");
        assert_eq!(exif_orientation_label(Some(6)), "rotate-90-clockwise");
    }

    #[test]
    fn non_heif_input_is_not_huawei() {
        let report = inspect_bytes(b"not a HEIF");
        assert_eq!(report.status, "not-isobmff");
        assert!(!report.is_huawei_hdr);
    }
}
