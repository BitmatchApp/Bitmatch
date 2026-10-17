// Core/Services/Camera/UnifiedMetadataDetectionService.swift
import Darwin
import Foundation

/// Unified service for detecting cameras via video and media file metadata
final class UnifiedMetadataDetectionService: Sendable {
    static let shared = UnifiedMetadataDetectionService()
    private init() {}
    
    // MARK: - Public Interface
    
    /// Detect camera from any metadata source (video or media files)
    func detectCameraFromMetadata(at url: URL) -> String? {
        // Try video metadata first (usually more reliable)
        if let videoResult = detectCameraFromVideo(at: url) {
            return videoResult
        }

        // A cancelled detection must not start another full scan.
        guard !Task.isCancelled else { return nil }

        // Fall back to media file metadata
        if let mediaResult = detectCameraFromMedia(at: url) {
            return mediaResult
        }

        return nil
    }
    
    // MARK: - Video Metadata Detection
    
    private func detectCameraFromVideo(at url: URL) -> String? {
        guard let videoFile = findVideoFile(at: url) else { return nil }
        
        #if os(macOS)
        // Try macOS metadata first (fastest and most reliable)
        if let result = extractVideoMetadataWithMdls(videoFile) {
            return result
        }

        // A cancellation during mdls must not launch another subprocess.
        guard !Task.isCancelled else { return nil }

        // Try ffprobe if available (more detailed)
        if let result = extractVideoMetadataWithFFProbe(videoFile) {
            return result
        }
        #endif
        
        return nil
    }
    
    // MARK: - Media File Metadata Detection
    
    private func detectCameraFromMedia(at url: URL) -> String? {
        let fm = FileManager.default
        
        // Media file extensions to analyze
        let mediaExtensions = ["JPG", "JPEG", "TIFF", "TIF", "DNG", "HEIC"]
        
        // Search for media files
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            var mediaFiles: [URL] = []
            
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                if mediaExtensions.contains(fileURL.pathExtension.uppercased()) {
                    mediaFiles.append(fileURL)
                    if mediaFiles.count >= 5 { break } // Analyze a few samples
                }
            }
            
            // Try to extract camera info from media files. Spotlight/mdls is
            // macOS-only; iOS media metadata comes from the other services.
            // A cancelled detection must not start another subprocess.
            for mediaFile in mediaFiles {
                #if os(macOS)
                guard !Task.isCancelled else { return nil }
                if let cameraInfo = extractCameraFromMediaFile(mediaFile) {
                    return cameraInfo
                }
                #endif
            }
        }
        
        return nil
    }
    
    // MARK: - File Discovery
    
    private func findVideoFile(at url: URL) -> URL? {
        let fm = FileManager.default
        let videoExtensions = ["MP4", "MOV", "M4V", "AVI", "MKV", "HEVC"]
        
        // Search recursively for video files
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if Task.isCancelled { return nil }
                if videoExtensions.contains(fileURL.pathExtension.uppercased()) {
                    return fileURL
                }
            }
        }
        
        return nil
    }
    
    // MARK: - macOS-specific Metadata Extraction
    
    #if os(macOS)
    /// Camera metadata is advisory. Bound captured stdout and drain it while
    /// the child runs: waiting for exit before reading can deadlock when the
    /// pipe fills, and readDataToEndOfFile can retain arbitrary output.
    static let maximumMetadataOutputBytes = 256 * 1024

    /// `onStarted` is an invocation-specific test hook, nil in production.
    func captureMetadataOutput(_ task: Process, onStarted: (() -> Void)? = nil) -> (data: Data, exitStatus: Int32)? {
        guard !Task.isCancelled else { return nil }

        let pipe = Pipe()
        task.standardOutput = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        let readFD = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(readFD, F_GETFL)
        guard oldFlags >= 0,
              fcntl(readFD, F_SETFL, oldFlags | O_NONBLOCK) == 0 else { return nil }

        let terminated = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in terminated.signal() }
        do {
            try task.run()
        } catch {
            return nil
        }
        try? pipe.fileHandleForWriting.close()
        onStarted?()

        func stopChild() {
            guard task.isRunning else { return }
            task.terminate()
            if terminated.wait(timeout: .now() + .seconds(2)) == .timedOut,
               task.isRunning {
                // A metadata helper that ignores TERM must not outlive the
                // cancelled hint. Process still owns this live child here.
                _ = Darwin.kill(task.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + .seconds(1))
            }
        }
        defer { stopChild() }

        var output = Data()
        output.reserveCapacity(Self.maximumMetadataOutputBytes)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let bufferSize = buffer.count
        let clock = ContinuousClock()
        var directChildExitedAt: ContinuousClock.Instant?

        while true {
            guard !Task.isCancelled else { return nil }
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(readFD, bytes.baseAddress, bufferSize)
            }
            if bytesRead > 0 {
                guard output.count + bytesRead <= Self.maximumMetadataOutputBytes else {
                    return nil
                }
                output.append(contentsOf: buffer[..<bytesRead])
                continue
            }
            if bytesRead == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }

            if !task.isRunning {
                if directChildExitedAt == nil { directChildExitedAt = clock.now }
                if let directChildExitedAt,
                   clock.now - directChildExitedAt >= .seconds(2) {
                    // A descendant may still hold the pipe after the direct
                    // metadata process exits. That is not usable evidence.
                    return nil
                }
            }
            _ = terminated.wait(timeout: .now() + .milliseconds(50))
        }

        while task.isRunning {
            guard !Task.isCancelled else { return nil }
            _ = terminated.wait(timeout: .now() + .milliseconds(50))
        }
        guard !Task.isCancelled else { return nil }
        return (output, task.terminationStatus)
    }

    private func extractVideoMetadataWithMdls(_ videoFile: URL) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/mdls"
        task.arguments = ["-name", "kMDItemAcquisitionMake", "-name", "kMDItemAcquisitionModel", videoFile.path]

        guard let (data, _) = captureMetadataOutput(task) else { return nil }
        let output = String(data: data, encoding: .utf8) ?? ""

        return parseMdlsOutput(output)
    }

    private func extractVideoMetadataWithFFProbe(_ videoFile: URL) -> String? {
        let task = Process()
        task.launchPath = "/usr/local/bin/ffprobe"
        task.arguments = [
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "format_tags=make,model",
            "-of", "csv=p=0",
            videoFile.path
        ]

        guard let (data, status) = captureMetadataOutput(task),
              status == 0 else {
            // FFProbe not available or detection cancelled, continue
            return nil
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        return parseFFProbeOutput(output)
    }
    
    private func extractCameraFromMediaFile(_ mediaFile: URL) -> String? {
        // Use macOS metadata system
        if let metadataItem = NSMetadataItem(url: mediaFile) {
            var make: String?
            var model: String?
            
            // Try to get camera make
            if let cameraMake = metadataItem.value(forAttribute: "kMDItemAcquisitionMake" as String) as? String {
                make = cameraMake
            }
            
            // Try to get camera model
            if let cameraModel = metadataItem.value(forAttribute: "kMDItemAcquisitionModel" as String) as? String {
                model = cameraModel
            }
            
            return formatCameraInfo(make: make, model: model)
        }
        
        return nil
    }
    #endif
    
    // MARK: - Output Parsing
    
    private func parseMdlsOutput(_ output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        var make: String?
        var model: String?
        
        for line in lines {
            if line.contains("kMDItemAcquisitionMake") {
                let components = line.components(separatedBy: "= ")
                if components.count > 1 {
                    make = components[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            if line.contains("kMDItemAcquisitionModel") {
                let components = line.components(separatedBy: "= ")
                if components.count > 1 {
                    model = components[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }
        
        return formatCameraInfo(make: make, model: model)
    }
    
    private func parseFFProbeOutput(_ output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let components = line.components(separatedBy: ",")
            if components.count >= 2 {
                let make = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let model = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return formatCameraInfo(make: make.isEmpty ? nil : make, model: model.isEmpty ? nil : model)
            }
        }
        return nil
    }
    
    private func formatCameraInfo(make: String?, model: String?) -> String? {
        // mdls prints "(null)" for a missing attribute; that is no answer,
        // not a camera named "(null)" (audit finding C).
        func present(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty, trimmed != "(null)" else { return nil }
            return trimmed
        }
        switch (present(make), present(model)) {
        case (let m?, let mod?):
            return "\(m) \(mod)"
        case (let m?, nil):
            return m
        case (nil, let mod?):
            return mod
        case (nil, nil):
            return nil
        }
    }
}
