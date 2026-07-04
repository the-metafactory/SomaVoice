import Foundation

/// FROZEN INTERFACE — future extraction point for `soma daemon`.
/// Do not add methods without updating voice-sight/VISION.md §4.
protocol Sense: AnyObject {
    /// One consented frame; nil if nothing is enrolled. NEVER captures a display.
    func capture() async throws -> SenseFrame?
    /// Answer a question about a frame. Routes by frame.tier: confidential →
    /// fully local (zero egress); open → cloud allowed. OCR-first within each.
    func describe(_ frame: SenseFrame, question: String) async throws -> String
    /// Cheap presence metadata (Phase 3; return nil until then).
    func now() -> String?
}

enum SenseTier { case confidential, open }   // set at pick-time; default .confidential

struct SenseFrame {
    let png: Data          // in-memory ONLY — never write to disk
    let ocrText: String    // Vision-framework OCR result (on-device)
    let appName: String
    let windowTitle: String
    let tier: SenseTier    // decides local-only vs cloud-allowed for describe()
}
