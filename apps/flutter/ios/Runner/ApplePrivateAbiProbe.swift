import CoreImage
import Darwin
import Foundation
import UIKit

/// Research probe: checks which Apple private ABI classes the upstream
/// XDRemuxAppleFeatures pipeline relies on exist on this iOS device.
///
/// The upstream macOS build shells out to runtime-compiled helper
/// executables (AppleNativeToolchain / Process). iOS cannot spawn
/// processes, so before porting the pipeline in-process we need to know
/// whether the private classes it probes are present on iOS at all.
///
/// Read-only: dlopen + NSClassFromString + selector checks only. Nothing
/// is invoked. Results are printed to stdout (visible via flutter run)
/// and logged with os_log.
enum ApplePrivateAbiProbe {
  private static let classNameToFramework: [(String, String)] = [
    // NeutrinoCore (style engine)
    ("_NUSemanticStyleProperties", "NeutrinoCore"),
    ("_NUStyleEngineConfiguration", "NeutrinoCore"),
    ("_NUStyleTransferApplyProcessor", "NeutrinoCore"),
    ("_NUStyleTransferLearnProcessor", "NeutrinoCore"),
    ("_NUStyleTransferThumbnailProcessor", "NeutrinoCore"),
    ("NUColorSpace", "NeutrinoCore"),
    ("NUStyleTransferNode", "NeutrinoCore"),
    // CoreImage internal smart-style CMI stack
    ("CMIGuidedFilter", "CoreImage"),
    ("CMISmartStyleMetalRendererV1", "CoreImage"),
    ("CMISmartStyleUtilitiesV1", "CoreImage"),
    ("CMIStyleEngineProcessor", "CoreImage"),
    // PhotoImaging (Photos editing pipeline)
    ("PISemanticStyleFilter", "PhotoImaging"),
    ("PISemanticStyleProcessor", "PhotoImaging"),
    ("PISemanticStyleRenderer", "PhotoImaging"),
    // PhotosUI/PhotoLibrary persistence internals
    ("PLPhotoEditImportProperties", "PhotoLibraryServices (media-toold-adjacent)"),
    ("PLPhotoEditPersistenceManager", "PhotoLibraryServices"),
    ("PLPhotoEditRenderer", "PhotoLibraryServices"),
    ("PLPhotoEditSource", "PhotoLibraryServices"),
  ]

  private static let frameworks = [
    "NeutrinoCore",
    "PhotoImaging",
    "CoreMediaIO",
  ]

  static func frameworkPath(_ name: String) -> String {
    "/System/Library/PrivateFrameworks/\(name).framework/\(name)"
  }

  static func run() {
    print("[XDRemuxProbe] ===== Apple private ABI probe start =====")
    print("[XDRemuxProbe] device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)")

    // 1. dlopen private frameworks without RTLD_NOLOAD would fault if the
    //    image is missing? No: dlopen returns nil, that is safe. But to keep
    //    this strictly read-only we first probe with RTLD_NOLOAD (find only)
    //    and fall back to a real dlopen for NeutrinoCore, mirroring what the
    //    upstream validator does on macOS.
    for fw in frameworks {
      let path = frameworkPath(fw)
      let pathCString = strdup(path)
      defer { free(pathCString) }
      let handleNoLoad = dlopen(pathCString, RTLD_LAZY | RTLD_NOLOAD)
      let alreadyLoaded = handleNoLoad != nil
      let handle = handleNoLoad ?? dlopen(pathCString, RTLD_LAZY)
      let status = handle != nil ? (alreadyLoaded ? "loaded(was already in process)" : "loaded(dlopen ok)") : "MISSING"
      print("[XDRemuxProbe] framework \(fw): \(status)")
      if let handle, !alreadyLoaded { dlclose(handle) }
    }

    // 2. Class + selector presence. CoreImage CMI classes may only appear
    //    after CoreImage has been exercised; load CoreImage explicitly first.
    let ci = CIContext(options: [:])
    _ = ci

    var present = 0
    var absent = 0
    for (name, fw) in classNameToFramework {
      let cls: AnyClass? = NSClassFromString(name)
      if let cls {
        present += 1
        let image = class_getImageName(cls).map { String(cString: $0) } ?? "?"
        print("[XDRemuxProbe] class \(name) [\(fw)]: PRESENT (\(image))")
      } else {
        absent += 1
        print("[XDRemuxProbe] class \(name) [\(fw)]: absent")
      }
    }

    // 3. Selector checks on the two classes the upstream validator and
    //    learn-node probe actually call into.
    if let props = NSClassFromString("_NUSemanticStyleProperties") {
      let sel = NSSelectorFromString("semanticStylePropertiesFromImageMetadata:error:")
      let has = class_getClassMethod(props, sel) != nil
      print("[XDRemuxProbe] _NUSemanticStyleProperties.semanticStylePropertiesFromImageMetadata:error: \(has ? "responds" : "selector missing")")
    }
    if let node = NSClassFromString("NUStyleTransferNode") {
      for selName in [
        "learnProcessor", "applyProcessor", "thumbnailProcessor",
        "usingSharedRenderer", "styleEngineConfiguration",
      ] {
        let sel = NSSelectorFromString(selName)
        let has = class_getInstanceMethod(node, sel) != nil || class_getClassMethod(node, sel) != nil
        print("[XDRemuxProbe] NUStyleTransferNode.\(selName): \(has ? "responds" : "selector missing")")
      }
    }

    print("[XDRemuxProbe] summary: \(present) present, \(absent) absent of \(classNameToFramework.count) probed classes")
    print("[XDRemuxProbe] ===== probe end =====")
  }
}
