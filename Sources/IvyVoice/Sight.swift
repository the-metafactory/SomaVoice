import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import CoreImage
import CoreMedia

/// Ivy's one eye. Capture is a per-request GLANCE, never a gaze:
///   enroll (the macOS picker IS the consent act) → capture ONE window →
///   OCR on-device → describe() routes by tier → the frame dies with the turn.
///
/// Display-capture APIs are deliberately absent: only a picker-produced
/// `SCContentFilter` is ever captured (VISION.md invariant 3). No filter →
/// `capture()` returns nil and the caller speaks an instruction; it never falls
/// back to grabbing the screen.
final class Sight: NSObject, Sense, SCContentSharingPickerObserver {
    /// The consented window filter + its trust tier, cached at pick-time.
    private var cachedFilter: SCContentFilter?
    private var pendingTier: SenseTier = .confidential   // tier for the NEXT pick
    private var cachedTier: SenseTier = .confidential
    private var cachedAppName: String = "a window"

    private let ciContext = CIContext()
    private let local = LocalReasoner()
    private let anthropic = AnthropicVision()

    /// Fired on the main thread after a successful pick, with the enrolled tier.
    /// Wired by Conversation to speak the tier confirmation.
    var onEnrolled: ((SenseTier) -> Void)?

    /// Max long edge for the uploaded PNG (Haiku 4.5 vision cap).
    private let maxEdge = 1568

    // MARK: - Enrollment (the picker is consent)

    /// Present the system window picker. `tier` is stamped onto the window that
    /// gets picked. Default `.confidential` (fail-safe). Must run on the main
    /// actor — it touches Control Center UI.
    @MainActor
    func enroll(tier: SenseTier) {
        pendingTier = tier
        // Best-effort app label: the app the principal was looking at when he
        // asked. SCContentFilter exposes no window title; this is metadata only.
        cachedAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "a window"

        let picker = SCContentSharingPicker.shared
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = .singleWindow          // one window only — never a display
        picker.defaultConfiguration = cfg
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        cachedFilter = filter
        cachedTier = pendingTier
        let tier = cachedTier
        NSLog("[Sight] enrolled: tier=%@ %.0fx%.0f scale=%.1f",
              tier == .confidential ? "confidential" : "open",
              filter.contentRect.width, filter.contentRect.height, filter.pointPixelScale)
        Task { @MainActor in self.onEnrolled?(tier) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // No change — a cancelled pick leaves any prior enrollment intact.
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        // Picker failed to open; capture() will simply report nothing enrolled.
    }

    // MARK: - Sense

    func capture() async throws -> SenseFrame? {
        guard let filter = cachedFilter else {
            NSLog("[Sight] capture: NO filter enrolled")
            return nil                                        // nothing enrolled
        }

        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = max(1, Int(filter.contentRect.width * scale))
        cfg.height = max(1, Int(filter.contentRect.height * scale))
        cfg.captureResolution = .best
        NSLog("[Sight] capturing %dx%d", cfg.width, cfg.height)

        let cg: CGImage
        do {
            // One-frame SCStream grab from the picker's filter — the picker's
            // per-selection consent authorizes the stream, so this needs NO global
            // Screen Recording grant (unlike SCScreenshotManager). Invariant 3.
            cg = try await OneFrameGrabber(ciContext: ciContext).grab(filter: filter, config: cfg)
        } catch {
            NSLog("[Sight] capture FAILED: %@ (%@)", error.localizedDescription, String(describing: error))
            throw error                                       // surfaced distinctly by the caller
        }

        // OCR the full-resolution image (better than the downscaled one), then
        // shrink for the (open-tier only) upload. PNG lives in a Data var — no disk.
        let ocr = Self.ocr(cg)
        let png = Self.downscaledPNG(cg, maxEdge: maxEdge, ctx: ciContext)
        NSLog("[Sight] captured ok: png=%d bytes, ocr=%d chars", png.count, ocr.count)

        return SenseFrame(png: png, ocrText: ocr, appName: cachedAppName,
                          windowTitle: "", tier: cachedTier)
    }

    /// The tier router. The tier check is the first line and has no else-that-leaks:
    /// an unrecognized tier is treated as confidential (VISION.md invariant 1).
    func describe(_ frame: SenseFrame, question: String) async throws -> String {
        if frame.tier == .confidential {
            return try await local.answer(frame: frame, question: question)
        }
        // Open tier only: default to OCR text; send pixels only when the question
        // is spatial or OCR is too thin (PLAN §1.4 / detail #4).
        let spatial = ["layout", "color", "farbe", "diagram", "chart", "image",
                       "bild", "where", "wo", "arrange", "look like", "aussehen"]
        let q = question.lowercased()
        let needsPixels = frame.ocrText.count < 20 || spatial.contains { q.contains($0) }
        return needsPixels
            ? try await anthropic.describeImage(frame: frame, question: question)
            : try await anthropic.describeText(frame: frame, question: question)
    }

    func now() -> String? { nil }   // Phase 3

    // MARK: - Helpers

    /// On-device OCR (DE + EN), accurate level. Offline, free, no egress.
    private static func ocr(_ cg: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        let obs = req.results ?? []
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Lanczos downscale so the long edge ≤ maxEdge, then PNG-encode into Data.
    private static func downscaledPNG(_ cg: CGImage, maxEdge: Int, ctx: CIContext) -> Data {
        let longEdge = max(cg.width, cg.height)
        var out = cg
        if longEdge > maxEdge {
            let scale = CGFloat(maxEdge) / CGFloat(longEdge)
            let ci = CIImage(cgImage: cg)
            if let f = CIFilter(name: "CILanczosScaleTransform") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(scale, forKey: kCIInputScaleKey)
                f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let scaled = f.outputImage,
                   let rendered = ctx.createCGImage(scaled, from: scaled.extent) {
                    out = rendered
                }
            }
        }
        let rep = NSBitmapImageRep(cgImage: out)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// Grabs exactly one complete frame via `SCStream` started from a picker-produced
/// filter, then stops. The picker's per-selection consent authorizes the stream,
/// so this path needs NO global Screen Recording grant and triggers no monthly
/// re-nag — unlike `SCScreenshotManager`, which does its own TCC check (VISION.md
/// invariant 3). Resumes its continuation exactly once (lock-guarded).
private final class OneFrameGrabber: NSObject, SCStreamOutput {
    enum GrabError: Error { case timeout, noImage }

    private let ciContext: CIContext
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var finished = false
    private let lock = NSLock()

    init(ciContext: CIContext) { self.ciContext = ciContext }

    func grab(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        // Backstop: if no complete frame ever arrives and no error fires, don't hang.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.finish(.failure(GrabError.timeout))
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
            self.continuation = cont
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream
            do {
                let queue = DispatchQueue(label: "ai.metafactory.ivyvoice.sight")
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                stream.startCapture { [weak self] error in
                    if let error { self?.finish(.failure(error)) }
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // Accept only a complete frame (skip idle/blank/started statuses).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvImageBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            finish(.failure(GrabError.noImage)); return
        }
        finish(.success(cg))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        stream?.stopCapture { _ in }
        cont?.resume(with: result)
    }
}
