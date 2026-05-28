import Foundation
import SwiftUI
import Observation

enum AppState {
    case idle
    case processing
    case completed
}

@Observable
@MainActor
final class XDRemuxViewModel {
    var state: AppState = .idle
    var totalFiles: Int = 0
    var processedCount: Int = 0
    var failedCount: Int = 0
    var currentFileName: String = ""
    
    private var processTask: Task<Void, Never>? = nil
    
    /// Maximum concurrent conversion tasks (conservative default to ensure ImageIO thread safety).
    private let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)
    
    func processFiles(from urls: [URL]) {
        // Enumerate all HEIC files asynchronously
        state = .processing
        totalFiles = 0
        processedCount = 0
        failedCount = 0
        currentFileName = "正在扫描文件..."
        
        processTask?.cancel()
        
        processTask = Task {
            var heicURLs: [URL] = []
            let fileManager = FileManager.default
            
            for url in urls {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                            for case let fileURL as URL in enumerator {
                                if fileURL.pathExtension.lowercased() == "heic" {
                                    heicURLs.append(fileURL)
                                }
                            }
                        }
                    } else if url.pathExtension.lowercased() == "heic" {
                        heicURLs.append(url)
                    }
                }
            }
            
            if Task.isCancelled {
                resetState()
                return
            }
            
            self.totalFiles = heicURLs.count
            
            guard self.totalFiles > 0 else {
                resetState()
                return
            }
            
            // Process files with limited concurrency and autoreleasepool isolation
            await Task.detached { [maxConcurrency] in
                await withTaskGroup(of: (URL, Bool).self) { group in
                    var iterator = heicURLs.makeIterator()
                    var inFlight = 0
                    
                    // Seed initial batch
                    while inFlight < maxConcurrency, let fileURL = iterator.next() {
                        inFlight += 1
                        group.addTask {
                            let success = autoreleasepool { () -> Bool in
                                do {
                                    let stem = fileURL.deletingPathExtension().lastPathComponent
                                    let outputURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(stem)_iso.heic")
                                    _ = try XDRemuxCore.convert(inputURL: fileURL, outputURL: outputURL, familyPreference: .auto, debugRootURL: nil)
                                    return true
                                } catch {
                                    print("Failed to convert \(fileURL.lastPathComponent): \(error)")
                                    return false
                                }
                            }
                            return (fileURL, success)
                        }
                    }
                    
                    // Process results and feed next file
                    for await (fileURL, success) in group {
                        if Task.isCancelled { break }
                        
                        await MainActor.run {
                            self.currentFileName = fileURL.lastPathComponent
                            self.processedCount += 1
                            if !success {
                                self.failedCount += 1
                            }
                        }
                        
                        // Feed next file into the group
                        if let nextURL = iterator.next() {
                            group.addTask {
                                let success = autoreleasepool { () -> Bool in
                                    do {
                                        let stem = nextURL.deletingPathExtension().lastPathComponent
                                        let outputURL = nextURL.deletingLastPathComponent().appendingPathComponent("\(stem)_iso.heic")
                                        _ = try XDRemuxCore.convert(inputURL: nextURL, outputURL: outputURL, familyPreference: .auto, debugRootURL: nil)
                                        return true
                                    } catch {
                                        print("Failed to convert \(nextURL.lastPathComponent): \(error)")
                                        return false
                                    }
                                }
                                return (nextURL, success)
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    self.state = .completed
                }
            }.value
        }
    }
    
    func cancelTask() {
        processTask?.cancel()
        // Do NOT call resetState() here — the background task will detect
        // cancellation and finish naturally into .completed state.
    }
    
    func acknowledgeCompletion() {
        resetState()
    }
    
    private func resetState() {
        state = .idle
        totalFiles = 0
        processedCount = 0
        failedCount = 0
        currentFileName = ""
    }
}
