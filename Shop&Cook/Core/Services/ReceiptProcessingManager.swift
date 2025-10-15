// MARK: - Enhanced OCR Configuration for Better Receipt Recognition

import Foundation
import Vision
import UIKit
import Combine
import CoreImage
import SwiftUI
import AVFoundation
import VisionKit

// MARK: - Product destination (sections)

enum ProductSection: String, Codable, CaseIterable, Identifiable {
    case fridge = "frigo"
    case freezer = "freezer"
    case pantry = "pantry"
    case unknown = "other"
    
    var id: String { rawValue }
    
    /// Localized display name
    var localizedName: String {
        switch self {
        case .fridge:
            return "storage.fridge".localized
        case .freezer:
            return "storage.freezer".localized
        case .pantry:
            return "storage.pantry".localized
        case .unknown:
            return "storage.other".localized
        }
    }
}

// MARK: - Intermediate parsed models

struct ParsedProduct: Identifiable, Codable, Hashable {
    let id: UUID
    var rawLine: String
    var name: String
    var price: Double
    var section: ProductSection
    
    init(rawLine: String, name: String, price: Double, section: ProductSection = .unknown) {
        self.id = UUID()
        self.rawLine = rawLine
        self.name = name
        self.price = price
        self.section = section
    }
}

struct ParsedReceipt: Identifiable, Codable, Equatable {
    let id: UUID
    var storeName: String
    var date: Date
    var total: Double
    var products: [ParsedProduct]
    
    init(storeName: String, date: Date, total: Double, products: [ParsedProduct]) {
        self.id = UUID()
        self.storeName = storeName
        self.date = date
        self.total = total
        self.products = products
    }
    
    static func == (lhs: ParsedReceipt, rhs: ParsedReceipt) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Product Correction Manager

final class ProductCorrectionManager {
    static let shared = ProductCorrectionManager()
    private let fileURL: URL
    struct ProductCorrection: Codable {
        var canonicalName: String
        var section: ProductSection
    }
    private var corrections: [String: ProductCorrection] = [:]

    private init() {
        let filename = "ProductCorrections.json"
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: ProductCorrection].self, from: data) {
            corrections = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(corrections) {
            try? data.write(to: fileURL)
        }
    }

    func applyCorrection(to rawName: String) -> (String, ProductSection)? {
        let key = rawName.uppercased().trimmingCharacters(in: .whitespaces)
        if let c = corrections[key] { return (c.canonicalName, c.section) }
        return nil
    }

    func addCorrection(for rawName: String, canonicalName: String, section: ProductSection) {
        let key = rawName.uppercased().trimmingCharacters(in: .whitespaces)
        corrections[key] = .init(canonicalName: canonicalName, section: section)
        save()
    }
}

// MARK: - Simple Debug Logger

final class ReceiptDebugLogger {
    static let shared = ReceiptDebugLogger()
    
    private var logEntries: [LogEntry] = []
    private let maxLogEntries = 1000
    
    private init() {}
    
    enum LogLevel {
        case info
        case warning
        case error
        case success
        case debug
        case trace
    }
    
    struct LogEntry {
        let timestamp: Date
        let level: LogLevel
        let message: String
        let function: String
        let line: Int
        let file: String
    }
    
    func section(_ message: String, function: String = #function, line: Int = #line, file: String = #file) {
        log(message, level: .info, function: function, line: line, file: file)
        print("🔍 [RECEIPT DEBUG] \(message)")
    }
    
    func log(_ message: String, level: LogLevel = .info, function: String = #function, line: Int = #line, file: String = #file) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            function: function,
            line: line,
            file: URL(fileURLWithPath: file).lastPathComponent
        )
        
        logEntries.append(entry)
        
        // Keep only the most recent entries
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        
        let emoji: String
        switch level {
        case .info: emoji = "ℹ️"
        case .warning: emoji = "⚠️"
        case .error: emoji = "❌"
        case .success: emoji = "✅"
        case .debug: emoji = "🐛"
        case .trace: emoji = "🔍"
        }
        
        let timestamp = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
        print("\(emoji) [\(timestamp)] [RECEIPT DEBUG] \(message)")
    }
    
    func logError(_ message: String, error: Error? = nil, function: String = #function, line: Int = #line, file: String = #file) {
        var fullMessage = message
        if let error = error {
            fullMessage += " - Error: \(error.localizedDescription)"
        }
        log(fullMessage, level: .error, function: function, line: line, file: file)
    }
    
    func logSuccess(_ message: String, function: String = #function, line: Int = #line, file: String = #file) {
        log(message, level: .success, function: function, line: line, file: file)
    }
    
    func logWarning(_ message: String, function: String = #function, line: Int = #line, file: String = #file) {
        log(message, level: .warning, function: function, line: line, file: file)
    }
    
    func logDebug(_ message: String, function: String = #function, line: Int = #line, file: String = #file) {
        log(message, level: .debug, function: function, line: line, file: file)
    }
    
    func logTrace(_ message: String, function: String = #function, line: Int = #line, file: String = #file) {
        log(message, level: .trace, function: function, line: line, file: file)
    }
    
    // MARK: - Log Export and Analysis
    
    func exportLogs() -> String {
        var output = "=== RECEIPT PROCESSING LOGS ===\n"
        output += "Generated: \(Date())\n"
        output += "Total entries: \(logEntries.count)\n\n"
        
        for entry in logEntries {
            let timestamp = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .short, timeStyle: .medium)
            let level = String(describing: entry.level).uppercased()
            output += "[\(timestamp)] [\(level)] \(entry.file):\(entry.line) \(entry.function) - \(entry.message)\n"
        }
        
        return output
    }
    
    func getRecentLogs(count: Int = 50) -> [LogEntry] {
        return Array(logEntries.suffix(count))
    }
    
    func getLogsByLevel(_ level: LogLevel) -> [LogEntry] {
        return logEntries.filter { $0.level == level }
    }
    
    func clearLogs() {
        logEntries.removeAll()
        log("Logs cleared", level: .info)
    }
    
    func getErrorCount() -> Int {
        return getLogsByLevel(.error).count
    }
    
    func getWarningCount() -> Int {
        return getLogsByLevel(.warning).count
    }
}

final class EnhancedReceiptOCR {
    
    static let shared = EnhancedReceiptOCR()
    private let logger = ReceiptDebugLogger.shared
    
    /// Perform OCR with optimized settings for receipts
    func recognizeText(
        from image: UIImage,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        logger.section("ENHANCED OCR PROCESSING")
        
        guard let cgImage = image.cgImage else {
            completion(.failure(OCRError.invalidImage))
            return
        }
        
        logger.log("Image size: \(image.size.width)x\(image.size.height)")
        logger.log("Scale: \(image.scale)")
        
        // Configure request with receipt-optimized settings
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                self.logger.log("OCR failed: \(error.localizedDescription)", level: .error)
                completion(.failure(error))
                return
            }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(.failure(OCRError.noResults))
                return
            }
            
            self.processObservations(observations, completion: completion)
        }
        
        // CRITICAL SETTINGS FOR RECEIPT OCR
        
        // 1. Use accurate recognition (slower but better for small text)
        request.recognitionLevel = .accurate
        
        // 2. DISABLE language correction (prevents "1.99" → "199")
        request.usesLanguageCorrection = false
        
        // 3. Set language priorities (receipt text is multilingual)
        request.recognitionLanguages = ["en-US", "de-DE", "fr-FR"]
        
        // 4. Minimum text height (ignore tiny disclaimers)
        request.minimumTextHeight = 0.015 // 1.5% of image height
        
        // 5. Custom words for better recognition
        request.customWords = [
            // Store names
            "ALDI", "LIDL", "REWE", "EDEKA", "PENNY", "NETTO",
            "CARREFOUR", "LECLERC",
            // Receipt keywords
            "EUR", "MwSt", "Summe", "Betrag", "Pfand",
            "SUMME", "TOTAL", "GESAMT", "ZWISCHENSUMME",
            "MWST", "TVA", "VAT", "TTC",
            // ALDI variants
            "SÜD", "SÜED", "NORD",
            // Payment methods
            "Eigenmarke", "Bio", "Kartenzahlung", "girocard",
            // Common products
            "MILCH", "MILK", "LAIT", "Milch", "Joghurt", "Käse", "Butter", "Sahne",
            "BROT", "BREAD", "PAIN", "KÄSE", "CHEESE", "FROMAGE"
        ]
        
        // 6. Automatic language detection
        request.automaticallyDetectsLanguage = true
        
        logger.log("OCR configuration:")
        logger.log("  Recognition level: accurate")
        logger.log("  Language correction: disabled")
        logger.log("  Languages: en-US, de-DE, fr-FR")
        logger.log("  Min text height: 1.5%")
        logger.log("  Custom words: \(request.customWords.count)")
        
        // Perform OCR on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: self.imageOrientation(from: image),
                options: [:]
            )
            
            do {
                let startTime = Date()
                try handler.perform([request])
                let duration = Date().timeIntervalSince(startTime)
                
                DispatchQueue.main.async {
                    self.logger.log("OCR completed in \(String(format: "%.2f", duration))s", level: .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.logger.log("Handler error: \(error.localizedDescription)", level: .error)
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Fixed OCR Text Extraction
    
    /// Extract text from observations with proper line reconstruction
    private func extractTextFromObservations(_ observations: [VNRecognizedTextObservation]) -> String {
        logger.log("Processing \(observations.count) text observations")
        
        // Sort by Y-coordinate (top to bottom)
        // Note: Vision uses bottom-left origin, so higher Y = higher on screen
        let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        logger.log("Sorted \(sorted.count) observations by Y-coordinate (top to bottom)")
        
        // Group observations into lines based on vertical proximity
        var lines: [[VNRecognizedTextObservation]] = []
        var currentLine: [VNRecognizedTextObservation] = []
        var lastY: CGFloat?
        
        // Threshold for grouping observations into same line
        // Adjust this if needed - smaller = stricter line separation
        let lineThreshold: CGFloat = 0.015
        
        for obs in sorted {
            let currentY = obs.boundingBox.midY
            
            if let lastY = lastY {
                // If Y-coordinate is close enough, add to current line
                if abs(currentY - lastY) < lineThreshold {
                    currentLine.append(obs)
                } else {
                    // Start new line
                    if !currentLine.isEmpty {
                        lines.append(currentLine)
                    }
                    currentLine = [obs]
                }
            } else {
                // First observation
                currentLine = [obs]
            }
            
            lastY = currentY
        }
        
        // Add last line
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        logger.log("Grouped into \(lines.count) text lines")
        
        // Extract text from each line, sorting observations left-to-right
        var extractedLines: [String] = []
        var totalChars = 0
        var totalConfidence: Float = 0
        
        for (lineIndex, lineObservations) in lines.enumerated() {
            // Sort observations in this line by X-coordinate (left to right)
            let sortedLine = lineObservations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            
            // Extract text from each observation
            var lineTexts: [String] = []
            var lineConfidence: Float = 0
            
            for obs in sortedLine {
                guard let candidate = obs.topCandidates(1).first else { continue }
                
                let text = candidate.string
                let confidence = candidate.confidence
                
                lineTexts.append(text)
                lineConfidence += confidence
                totalChars += text.count
            }
            
            // Calculate average confidence for this line
            if !lineObservations.isEmpty {
                lineConfidence /= Float(lineObservations.count)
                totalConfidence += lineConfidence
            }
            
            // Join texts with appropriate spacing
            let lineText = lineTexts.joined(separator: " ")
            
            if !lineText.isEmpty {
                extractedLines.append(lineText)
                
                // Debug: Log first few lines
                if lineIndex < 10 {
                    logger.logTrace("Line \(lineIndex): \(lineText.prefix(80))")
                }
            }
        }
        
        let avgConfidence = lines.isEmpty ? 0 : totalConfidence / Float(lines.count)
        
        logger.log("Extracted \(extractedLines.count) lines of text")
        logger.log("Average confidence: \(String(format: "%.2f", avgConfidence))")
        logger.logSuccess("Total characters: \(totalChars)")
        
        // Join all lines with newlines
        return extractedLines.joined(separator: "\n")
    }
    
    /// Alternative extraction method that treats each observation as a separate line
    /// Use this if the standard method still groups too much
    private func extractTextFromObservationsStrict(_ observations: [VNRecognizedTextObservation]) -> String {
        logger.log("Processing \(observations.count) text observations (STRICT MODE)")
        
        // Sort by Y-coordinate (top to bottom), then by X (left to right)
        let sorted = observations.sorted { obs1, obs2 in
            let y1 = obs1.boundingBox.midY
            let y2 = obs2.boundingBox.midY
            
            // If Y is very close, sort by X
            if abs(y1 - y2) < 0.008 {
                return obs1.boundingBox.minX < obs2.boundingBox.minX
            }
            
            return y1 > y2
        }
        
        logger.log("Sorted \(sorted.count) observations")
        
        // Extract text from each observation as separate line
        var lines: [String] = []
        var totalConfidence: Float = 0
        
        for (index, obs) in sorted.enumerated() {
            guard let candidate = obs.topCandidates(1).first else { continue }
            
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            let confidence = candidate.confidence
            
            if !text.isEmpty {
                lines.append(text)
                totalConfidence += confidence
                
                // Debug: Log first 20 lines
                if index < 20 {
                    logger.logTrace("[\(index)] \(text)")
                }
            }
        }
        
        let avgConfidence = lines.isEmpty ? 0 : totalConfidence / Float(lines.count)
        
        logger.log("Extracted \(lines.count) lines of text")
        logger.log("Average confidence: \(String(format: "%.2f", avgConfidence))")
        logger.logSuccess("Total characters: \(lines.map { $0.count }.reduce(0, +))")
        
        return lines.joined(separator: "\n")
    }
    
    private func processObservations(
        _ observations: [VNRecognizedTextObservation],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // CRITICAL: Use strict mode for better accuracy
        // This treats each observation as a separate line
        let extractedText = extractTextFromObservationsStrict(observations)
        
        if extractedText.isEmpty {
            logger.log("No text recognized", level: .error)
            completion(.failure(OCRError.noText))
        } else {
            completion(.success(extractedText))
        }
    }
    
    private func averageConfidence(_ lines: [(text: String, confidence: Float, box: CGRect)]) -> Float {
        guard !lines.isEmpty else { return 0.0 }
        let sum = lines.reduce(0.0) { $0 + $1.confidence }
        return sum / Float(lines.count)
    }
    
    private func imageOrientation(from image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
    
    enum OCRError: LocalizedError {
        case invalidImage
        case noResults
        case noText
        
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Cannot convert image for OCR"
            case .noResults: return "OCR produced no results"
            case .noText: return "No text recognized in image"
            }
        }
    }
}

// MARK: - Multi-Pass OCR Strategy for Difficult Receipts

final class MultiPassOCRStrategy {
    
    static let shared = MultiPassOCRStrategy()
    private let logger = ReceiptDebugLogger.shared
    
    /// Try multiple OCR strategies and combine results
    func recognizeWithMultiPass(
        image: UIImage,
        completion: @escaping (String?) -> Void
    ) {
        logger.section("MULTI-PASS OCR STRATEGY")
        
        var results: [String] = []
        let group = DispatchGroup()
        
        // Pass 1: Standard OCR
        group.enter()
        EnhancedReceiptOCR.shared.recognizeText(from: image) { result in
            if case .success(let text) = result {
                results.append(text)
                self.logger.log("Pass 1 (standard): \(text.count) chars", level: .success)
            }
            group.leave()
        }
        
        // Pass 2: Enhanced contrast image
        if let enhanced = applyEnhancement(image, level: .high) {
            group.enter()
            EnhancedReceiptOCR.shared.recognizeText(from: enhanced) { result in
                if case .success(let text) = result {
                    results.append(text)
                    self.logger.log("Pass 2 (enhanced): \(text.count) chars", level: .success)
                }
                group.leave()
            }
        }
        
        // Pass 3: Inverted (white on black)
        if let inverted = invertImage(image) {
            group.enter()
            EnhancedReceiptOCR.shared.recognizeText(from: inverted) { result in
                if case .success(let text) = result {
                    results.append(text)
                    self.logger.log("Pass 3 (inverted): \(text.count) chars", level: .success)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            self.logger.log("Multi-pass complete: \(results.count) passes succeeded")
            
            if results.isEmpty {
                completion(nil)
            } else {
                // Use longest result (usually has most text)
                let best = results.max(by: { $0.count < $1.count })
                self.logger.log("Selected best result: \(best?.count ?? 0) chars", level: .success)
                completion(best)
            }
        }
    }
    
    enum EnhancementLevel {
        case low, medium, high
    }
    
    private func applyEnhancement(_ image: UIImage, level: EnhancementLevel) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        
        let contrast: Float
        let brightness: Float
        
        switch level {
        case .low:
            contrast = 1.3
            brightness = 0.05
        case .medium:
            contrast = 1.6
            brightness = 0.1
        case .high:
            contrast = 2.5
            brightness = 0.15
        }
        
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        
        guard let output = filter.outputImage else { return nil }
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
    
    private func invertImage(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        
        let filter = CIFilter(name: "CIColorInvert")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        
        guard let output = filter.outputImage else { return nil }
        
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - OCR Post-Processing for Common Errors

final class OCRPostProcessor {
    
    static let shared = OCRPostProcessor()
    
    /// Fix common OCR mistakes
    func correctCommonErrors(_ text: String) -> String {
        var corrected = text
        
        // 1. Fix ALDI-specific OCR errors
        let aldiCorrections: [String: String] = [
            "ALDT" : "ALDI",     // I misread as T
            "ALDO" : "ALDI",     // I misread as O  
            "ALD1" : "ALDI",     // I misread as 1
            "S00D" : "SÜD",      // Ü misread as 00
            "SOOD" : "SÜD",      // Ü misread as OO
            "SOD" : "SÜD",       // Ü misread as O
            "SÚD" : "SÜD",       // Ü misread as Ú
            "SÛD" : "SÜD",       // Ü misread as Û
            "N0RD" : "NORD",     // O misread as 0
            "NORO" : "NORD",     // D misread as O
        ]
        
        for (wrong, right) in aldiCorrections {
            corrected = corrected.replacingOccurrences(of: wrong, with: right)
        }
        
        // 2. Fix number/letter confusion in price contexts
        let priceCorrections: [String: String] = [
            "O" : "0",  // Letter O → Zero (in numbers)
            "l" : "1",  // Lowercase L → One
            "I" : "1",  // Uppercase i → One
            "S" : "5",  // Sometimes S → 5
            "B" : "8",  // Sometimes B → 8
        ]
        
        // Apply in price contexts only
        let pricePattern = try! NSRegularExpression(pattern: #"(\d+[OlI]\d+[,.]\d{2})"#)
        let matches = pricePattern.matches(in: corrected, range: NSRange(corrected.startIndex..., in: corrected))
        
        for match in matches.reversed() {
            if let range = Range(match.range, in: corrected) {
                var segment = String(corrected[range])
                for (wrong, right) in priceCorrections {
                    segment = segment.replacingOccurrences(of: wrong, with: right)
                }
                corrected.replaceSubrange(range, with: segment)
            }
        }
        
        // 3. Fix common word errors
        corrected = corrected
            .replacingOccurrences(of: "SUI/1I/IE", with: "SUMME")
            .replacingOccurrences(of: "T0TAL", with: "TOTAL")
            .replacingOccurrences(of: "TQTAL", with: "TOTAL")
            .replacingOccurrences(of: "Dennan", with: "Datum")  // Common OCR error
            .replacingOccurrences(of: "Oni ine", with: "Online")
        
        // 4. Remove isolated special characters (OCR noise)
        corrected = corrected.replacingOccurrences(
            of: #"(?<!\S)[^\w\s€](?!\S)"#,
            with: "",
            options: .regularExpression
        )
        
        return corrected
    }
    
    /// Validate that text looks like a receipt
    func validateReceiptText(_ text: String) -> (isValid: Bool, confidence: Float, issues: [String]) {
        var confidence: Float = 1.0
        var issues: [String] = []
        
        // Check 1: Has price patterns
        let pricePattern = #"\d+[,.]\d{2}"#
        let regex = try! NSRegularExpression(pattern: pricePattern)
        let priceMatches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        if priceMatches.isEmpty {
            confidence -= 0.5
            issues.append("No price patterns found")
        }
        
        // Check 2: Has store keywords
        let storeKeywords = ["ALDI", "LIDL", "REWE", "EDEKA", "CARREFOUR", "LECLERC", "STORE", "MARKT"]
        let hasStore = storeKeywords.contains(where: { text.uppercased().contains($0) })
        
        if !hasStore {
            confidence -= 0.2
            issues.append("No store name detected")
        }
        
        // Check 3: Has total keyword
        let totalKeywords = ["SUMME", "TOTAL", "GESAMT"]
        let hasTotal = totalKeywords.contains(where: { text.uppercased().contains($0) })
        
        if !hasTotal {
            confidence -= 0.2
            issues.append("No total line detected")
        }
        
        // Check 4: Reasonable length
        if text.count < 100 {
            confidence -= 0.3
            issues.append("Text too short (\(text.count) chars)")
        }
        
        let isValid = confidence >= 0.3
        
        return (isValid, max(0, confidence), issues)
    }
}

// MARK: - Main ReceiptProcessingManager Class

@MainActor
final class ReceiptProcessingManager: NSObject, ObservableObject {

    @Published var isProcessing = false
    @Published var parsedReceipt: ParsedReceipt?
    @Published var editableProducts: [ParsedProduct] = []
    @Published var totalEditable: Double = 0.0
    @Published var errorMessage: String?

    private var scanner: VNDocumentCameraViewController?
    
    override init() {
        super.init()
    }

    // Public entry: open camera
    func startScan(from presenter: UIViewController) {
        guard VNDocumentCameraViewController.isSupported else {
            self.errorMessage = "La capture de documents n'est pas supportée sur cet appareil."
            return
        }
        let s = VNDocumentCameraViewController()
        s.delegate = self
        presenter.present(s, animated: true)
        self.scanner = s
    }
    
    // Public entry: process image from photo library
    func processImageFromLibrary(_ image: UIImage) {
        process(image: image)
    }

    // Process a single UIImage (can be from gallery too)
    func process(image: UIImage) {
        ReceiptDebugLogger.shared.section("Starting receipt processing")
        ReceiptDebugLogger.shared.log("Image size: \(image.size), scale: \(image.scale)")
        
        isProcessing = true
        errorMessage = nil

        // Use the enhanced auto-detection pipeline for both camera and library
        processReceiptWithAutoDetection(image: image)
    }

    // Apply user edits → save corrections → push to repositories
    func confirmEditsAndImport(storeOverride: String? = nil) {
        guard var receipt = parsedReceipt else { return }
        // Persist corrections and update products
        var fixed: [ParsedProduct] = []
        for p in editableProducts {
            // learn correction if user changed name/section
            if let original = receipt.products.first(where: { $0.id == p.id }), (original.name != p.name || original.section != p.section) {
                ProductCorrectionManager.shared.addCorrection(for: original.name, canonicalName: p.name, section: p.section)
            }
            fixed.append(p)
        }
        receipt.products = fixed
        receipt.total = totalEditable
        if let store = storeOverride { receipt.storeName = store }

        // Inject into repositories
        importIntoInventoryAndBudget(receipt: receipt)

        // publish
        self.parsedReceipt = receipt
    }

    private func importIntoInventoryAndBudget(receipt: ParsedReceipt) {
        // Map to your InventoryItem model
        for p in receipt.products {
            let inventoryItem = InventoryItem(
                name: p.name,
                category: p.section.rawValue,
                purchaseDate: receipt.date,
                expiryDate: nil, // Will be estimated later
                expirySource: .estimated,
                expiryConfidence: 0.5,
                quantity: 1.0,
                unit: "pcs",
                location: p.section.rawValue,
                isOpened: false,
                openedDate: nil,
                allergens: [],
                restrictions: [],
                isConsumed: false,
                addedAt: Date(),
                updatedAt: Date(),
                syncedToCloud: false,
                brand: nil,
                imageURL: nil,
                nutritionGrade: nil,
                ingredients: nil,
                productDatabaseId: nil
            )
            
            // Add to inventory repository
            InventoryRepository.shared.addItem(inventoryItem)
        }
        
        // Save inventory
        InventoryRepository.shared.saveNow()
        
        // Add to budget if BudgetRepository exists
        // BudgetRepository.shared.addExpense(amount: receipt.total, category: "Courses")
    }
}

// MARK: - Image Preprocessing (crop + enhance)

final class ReceiptImagePreprocessor {
    static let shared = ReceiptImagePreprocessor()
    private let context = CIContext()

    /// 🌈 Universal preprocessing for any receipt type
    func preprocess(_ uiImage: UIImage, completion: @escaping (UIImage?) -> Void) {
        ReceiptDebugLogger.shared.logDebug("Starting enhanced image preprocessing")
        
        // Step 1: Auto-crop receipt from background
        let croppedImage = autoCropReceipt(from: uiImage)
        
        // Step 2: Apply enhanced preprocessing to cropped image
        let enhanced = preprocessSync(croppedImage)
        completion(enhanced)
    }
    
    /// Synchronous preprocessing with advanced techniques
    private func preprocessSync(_ input: UIImage) -> UIImage {
        guard var ciImage = CIImage(image: input) else { 
            ReceiptDebugLogger.shared.logError("Failed to create CIImage")
            return input 
        }
        
        // Step 1: Orientation correction
        ciImage = ciImage.oriented(forExifOrientation: Int32(input.imageOrientation.rawValue))
        ReceiptDebugLogger.shared.logDebug("Step 1: Orientation corrected")
        
        // Step 2: Automatic brightness detection
        let avgBrightness = estimateBrightness(of: ciImage)
        ReceiptDebugLogger.shared.logDebug("Step 2: Estimated brightness: \(avgBrightness)")
        
        // Step 3: Automatic contrast and color balance
        ciImage = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0, // Desaturate for OCR
            kCIInputBrightnessKey: brightnessCorrection(for: avgBrightness),
            kCIInputContrastKey: contrastCorrection(for: avgBrightness)
        ])
        ReceiptDebugLogger.shared.logDebug("Step 3: Color controls applied")
        
        // Step 4: Gamma correction (better than simple brightness)
        ciImage = ciImage.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": gammaCorrection(for: avgBrightness)
        ])
        ReceiptDebugLogger.shared.logDebug("Step 4: Gamma correction applied")
        
        // Step 5: Text edge enhancement
        ciImage = ciImage.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2.0,
            kCIInputIntensityKey: 0.8
        ])
        ReceiptDebugLogger.shared.logDebug("Step 5: Text edges enhanced")
        
        // Step 6: Adaptive normalization (CLAHE)
        if let clahe = applyCLAHE(to: ciImage) {
            ciImage = clahe
            ReceiptDebugLogger.shared.logDebug("Step 6: CLAHE applied")
        }
        
        // Step 7: Binary conversion (black/white) for clear OCR
        ciImage = ciImage.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0.0),
            "inputMaxComponents": CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1.0)
        ])
        ReceiptDebugLogger.shared.logDebug("Step 7: Binary conversion applied")
        
        // Step 8: Residual noise cleanup
        ciImage = ciImage.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.02,
            "inputSharpness": 0.4
        ])
        ReceiptDebugLogger.shared.logDebug("Step 8: Noise reduction applied")
        
        // Final UIImage conversion
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { 
            ReceiptDebugLogger.shared.logError("Failed to create CGImage")
            return input 
        }
        
        ReceiptDebugLogger.shared.logSuccess("Enhanced preprocessing completed successfully")
        return UIImage(cgImage: cgImage, scale: input.scale, orientation: .up)
    }
    
    // MARK: - Receipt Detection and Cropping
    
    /// Automatically detects and crops the receipt from the background
    private func autoCropReceipt(from image: UIImage) -> UIImage {
        ReceiptDebugLogger.shared.logDebug("Starting automatic receipt cropping")
        ReceiptDebugLogger.shared.logDebug("Original image size: \(image.size)")
        
        guard let ciImage = CIImage(image: image) else {
            ReceiptDebugLogger.shared.logError("Failed to create CIImage for cropping")
            return image
        }
        
        // Method 1: Try edge detection + contour analysis
        ReceiptDebugLogger.shared.logDebug("Trying edge detection method...")
        if let croppedRect = detectReceiptWithEdges(ciImage) {
            ReceiptDebugLogger.shared.logSuccess("Receipt detected with edge detection: \(croppedRect)")
            return cropImage(image, to: croppedRect)
        }
        
        // Method 2: Try color-based segmentation
        ReceiptDebugLogger.shared.logDebug("Trying color segmentation method...")
        if let croppedRect = detectReceiptWithColorSegmentation(ciImage) {
            ReceiptDebugLogger.shared.logSuccess("Receipt detected with color segmentation: \(croppedRect)")
            return cropImage(image, to: croppedRect)
        }
        
        // Method 3: Try text-based detection
        ReceiptDebugLogger.shared.logDebug("Trying text detection method...")
        if let croppedRect = detectReceiptWithTextDetection(ciImage) {
            ReceiptDebugLogger.shared.logSuccess("Receipt detected with text detection: \(croppedRect)")
            return cropImage(image, to: croppedRect)
        }
        
        // Method 4: Try adaptive cropping based on image analysis
        ReceiptDebugLogger.shared.logDebug("Trying adaptive analysis method...")
        if let croppedRect = detectReceiptWithAdaptiveAnalysis(ciImage) {
            ReceiptDebugLogger.shared.logSuccess("Receipt detected with adaptive analysis: \(croppedRect)")
            return cropImage(image, to: croppedRect)
        }
        
        // Method 5: Try smart center cropping (for cases where receipt is centered)
        ReceiptDebugLogger.shared.logDebug("Trying smart center cropping method...")
        if let croppedRect = detectReceiptWithSmartCropping(ciImage) {
            ReceiptDebugLogger.shared.logSuccess("Receipt detected with smart cropping: \(croppedRect)")
            return cropImage(image, to: croppedRect)
        }
        
        ReceiptDebugLogger.shared.logWarning("All cropping methods failed, using full image")
        return image
    }
    
    /// Detects receipt using edge detection and contour analysis
    private func detectReceiptWithEdges(_ ciImage: CIImage) -> CGRect? {
        // Convert to grayscale
        let grayscale = ciImage.applyingFilter("CIColorMonochrome", parameters: [
            kCIInputColorKey: CIColor.white,
            kCIInputIntensityKey: 1.0
        ])
        
        // Apply edge detection
        let edges = grayscale.applyingFilter("CIEdges", parameters: [
            kCIInputIntensityKey: 1.0
        ])
        
        // Apply morphological operations to connect edges
        let dilated = edges.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: 3.0
        ])
        
        // Find contours by analyzing edge density
        return findLargestRectangularRegion(in: dilated)
    }
    
    /// Detects receipt using color segmentation (white receipt on colored background)
    private func detectReceiptWithColorSegmentation(_ ciImage: CIImage) -> CGRect? {
        // Create a mask for white/light regions (typical receipt color)
        let whiteMask = ciImage.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.8 // Threshold for white/light areas
        ])
        
        // Find the largest white region
        return findLargestRectangularRegion(in: whiteMask)
    }
    
    /// Detects receipt using Vision framework text detection (receipts have dense text)
    private func detectReceiptWithTextDetection(_ ciImage: CIImage) -> CGRect? {
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let image = UIImage(cgImage: cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                return nil
            }
            
            // Find the bounding box that contains most text observations
            return findReceiptBounds(from: observations, imageSize: image.size)
            
        } catch {
            ReceiptDebugLogger.shared.logError("Text detection failed: \(error)")
            return nil
        }
    }
    
    /// Finds receipt boundaries based on text observation density
    private func findReceiptBounds(from observations: [VNRecognizedTextObservation], imageSize: CGSize) -> CGRect? {
        guard !observations.isEmpty else { return nil }
        
        // Filter out low-confidence observations
        let validObservations = observations.filter { $0.confidence > 0.3 }
        
        if validObservations.isEmpty {
            return nil
        }
        
        // Find the bounding box that contains the most text
        var bestRect = CGRect.zero
        var maxTextDensity: CGFloat = 0
        
        // Try different grid positions to find the densest text region
        let gridSize: CGFloat = 50
        let stepSize: CGFloat = 25
        
        for x in stride(from: 0, to: imageSize.width - gridSize, by: stepSize) {
            for y in stride(from: 0, to: imageSize.height - gridSize, by: stepSize) {
                let testRect = CGRect(x: x, y: y, width: gridSize, height: gridSize)
                
                // Count text observations in this region
                let textCount = validObservations.filter { observation in
                    let boundingBox = observation.boundingBox
                    let rect = VNImageRectForNormalizedRect(boundingBox, Int(imageSize.width), Int(imageSize.height))
                    return testRect.intersects(rect)
                }.count
                
                let density = CGFloat(textCount) / (gridSize * gridSize)
                
                if density > maxTextDensity {
                    maxTextDensity = density
                    bestRect = testRect
                }
            }
        }
        
        // If we found a good text region, expand it to include all nearby text
        if maxTextDensity > 0.001 { // Minimum density threshold
            let expandedRect = expandRectToIncludeAllText(bestRect, observations: validObservations, imageSize: imageSize)
            
            // Add padding
            let padding: CGFloat = 30
            let paddedRect = CGRect(
                x: max(0, expandedRect.origin.x - padding),
                y: max(0, expandedRect.origin.y - padding),
                width: min(imageSize.width - expandedRect.origin.x + padding, expandedRect.width + 2 * padding),
                height: min(imageSize.height - expandedRect.origin.y + padding, expandedRect.height + 2 * padding)
            )
            
            ReceiptDebugLogger.shared.logDebug("Found receipt bounds using text detection: \(paddedRect)")
            return paddedRect
        }
        
        return nil
    }
    
    /// Expands a rectangle to include all text observations
    private func expandRectToIncludeAllText(_ initialRect: CGRect, observations: [VNRecognizedTextObservation], imageSize: CGSize) -> CGRect {
        var minX = initialRect.minX
        var minY = initialRect.minY
        var maxX = initialRect.maxX
        var maxY = initialRect.maxY
        
        for observation in observations {
            let boundingBox = observation.boundingBox
            let rect = VNImageRectForNormalizedRect(boundingBox, Int(imageSize.width), Int(imageSize.height))
            
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    /// Adaptive analysis that combines multiple detection methods
    private func detectReceiptWithAdaptiveAnalysis(_ ciImage: CIImage) -> CGRect? {
        // Analyze the image to determine the best approach
        let brightness = estimateBrightness(of: ciImage)
        
        // For very dark or very bright images, use different strategies
        if brightness < -0.5 {
            // Very dark image - look for bright regions
            return detectBrightRegions(in: ciImage)
        } else if brightness > 0.5 {
            // Very bright image - look for darker regions
            return detectDarkRegions(in: ciImage)
        } else {
            // Normal brightness - use contrast-based detection
            return detectContrastRegions(in: ciImage)
        }
    }
    
    /// Detects bright regions (for dark backgrounds)
    private func detectBrightRegions(in ciImage: CIImage) -> CGRect? {
        let brightMask = ciImage.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.7
        ])
        
        return findLargestRectangularRegion(in: brightMask)
    }
    
    /// Detects dark regions (for bright backgrounds)
    private func detectDarkRegions(in ciImage: CIImage) -> CGRect? {
        let darkMask = ciImage.applyingFilter("CIColorThreshold", parameters: [
            "inputThreshold": 0.3
        ])
        
        return findLargestRectangularRegion(in: darkMask)
    }
    
    /// Detects regions with high contrast
    private func detectContrastRegions(in ciImage: CIImage) -> CGRect? {
        // Apply contrast enhancement
        let contrast = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 2.0
        ])
        
        // Then apply edge detection
        let edges = contrast.applyingFilter("CIEdges", parameters: [
            kCIInputIntensityKey: 1.0
        ])
        
        return findLargestRectangularRegion(in: edges)
    }
    
    /// Smart center cropping for receipts that are likely centered in the image
    private func detectReceiptWithSmartCropping(_ ciImage: CIImage) -> CGRect? {
        let extent = ciImage.extent
        let imageSize = CGSize(width: extent.width, height: extent.height)
        
        // Try different receipt-like aspect ratios centered in the image
        let receiptAspectRatios: [CGFloat] = [0.4, 0.5, 0.6, 0.7] // Width/Height ratios
        
        for aspectRatio in receiptAspectRatios {
            // Calculate receipt dimensions
            let receiptHeight = min(imageSize.height * 0.8, imageSize.width / aspectRatio)
            let receiptWidth = receiptHeight * aspectRatio
            
            // Center the receipt in the image
            let x = (imageSize.width - receiptWidth) / 2
            let y = (imageSize.height - receiptHeight) / 2
            
            let candidateRect = CGRect(x: x, y: y, width: receiptWidth, height: receiptHeight)
            
            // Check if this region has good contrast (indicating a receipt)
            if hasGoodContrast(in: ciImage, rect: candidateRect) {
                return candidateRect
            }
        }
        
        return nil
    }
    
    /// Checks if a region has good contrast (indicating text/receipt content)
    private func hasGoodContrast(in ciImage: CIImage, rect: CGRect) -> Bool {
        // Crop the region
        let croppedImage = ciImage.cropped(to: rect)
        
        // Convert to grayscale
        let grayscale = croppedImage.applyingFilter("CIColorMonochrome", parameters: [
            kCIInputColorKey: CIColor.white,
            kCIInputIntensityKey: 1.0
        ])
        
        // Calculate standard deviation (measure of contrast)
        let extentVector = CIVector(
            x: grayscale.extent.origin.x,
            y: grayscale.extent.origin.y,
            z: grayscale.extent.size.width,
            w: grayscale.extent.size.height
        )
        
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: grayscale,
                kCIInputExtentKey: extentVector
            ]
        ),
        let _ = filter.outputImage else {
            return false
        }
        
        // For now, just check if the region isn't too uniform
        // A more sophisticated approach would calculate actual standard deviation
        return true // Placeholder - in a real implementation, we'd analyze the variance
    }
    
    /// Finds the largest rectangular region in a binary image
    private func findLargestRectangularRegion(in binaryImage: CIImage) -> CGRect? {
        let extent = binaryImage.extent
        
        // Sample the image to find white regions
        let sampleSize = CGSize(width: min(100, extent.width), height: min(100, extent.height))
        let scaleX = extent.width / sampleSize.width
        let scaleY = extent.height / sampleSize.height
        
        // Create a small version for analysis
        let scaledImage = binaryImage.transformed(by: CGAffineTransform(scaleX: 1/scaleX, y: 1/scaleY))
        
        // Analyze pixel data to find the largest white region
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        let width = Int(sampleSize.width)
        let height = Int(sampleSize.height)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * bytesPerPixel)
        defer { pixelData.deallocate() }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Find the largest rectangular white region
        var bestRect = CGRect.zero
        var bestArea: CGFloat = 0
        
        // Scan for rectangular regions
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let r = pixelData[pixelIndex]
                let g = pixelData[pixelIndex + 1]
                let b = pixelData[pixelIndex + 2]
                
                // Check if pixel is white/light
                if r > 200 && g > 200 && b > 200 {
                    // Find the largest rectangle starting from this point
                    if let rect = findLargestRectangleFrom(x: x, y: y, in: pixelData, width: width, height: height) {
                        let area = rect.width * rect.height
                        if area > bestArea {
                            bestArea = area
                            bestRect = rect
                        }
                    }
                }
            }
        }
        
        // Convert back to original image coordinates
        if bestArea > 0 {
            let scaledRect = CGRect(
                x: bestRect.origin.x * scaleX,
                y: bestRect.origin.y * scaleY,
                width: bestRect.width * scaleX,
                height: bestRect.height * scaleY
            )
            
            // Add some padding
            let padding: CGFloat = 20
            let paddedRect = CGRect(
                x: max(0, scaledRect.origin.x - padding),
                y: max(0, scaledRect.origin.y - padding),
                width: min(extent.width - scaledRect.origin.x + padding, scaledRect.width + 2 * padding),
                height: min(extent.height - scaledRect.origin.y + padding, scaledRect.height + 2 * padding)
            )
            
            return paddedRect
        }
        
        return nil
    }
    
    /// Finds the largest rectangle starting from a given point
    private func findLargestRectangleFrom(x: Int, y: Int, in pixelData: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CGRect? {
        var maxWidth = 0
        var maxHeight = 0
        
        // Find maximum width
        for w in 1...(width - x) {
            let pixelIndex = (y * width + x + w - 1) * 4
            let r = pixelData[pixelIndex]
            let g = pixelData[pixelIndex + 1]
            let b = pixelData[pixelIndex + 2]
            
            if r < 200 || g < 200 || b < 200 {
                break
            }
            maxWidth = w
        }
        
        // Find maximum height
        for h in 1...(height - y) {
            var allWhite = true
            for w in 0..<maxWidth {
                let pixelIndex = ((y + h - 1) * width + x + w) * 4
                let r = pixelData[pixelIndex]
                let g = pixelData[pixelIndex + 1]
                let b = pixelData[pixelIndex + 2]
                
                if r < 200 || g < 200 || b < 200 {
                    allWhite = false
                    break
                }
            }
            if !allWhite {
                break
            }
            maxHeight = h
        }
        
        // Only return rectangles that are reasonably large
        if maxWidth > 20 && maxHeight > 20 {
            return CGRect(x: x, y: y, width: maxWidth, height: maxHeight)
        }
        
        return nil
    }
    
    /// Crops an image to the specified rectangle
    private func cropImage(_ image: UIImage, to rect: CGRect) -> UIImage {
        guard let cgImage = image.cgImage else {
            ReceiptDebugLogger.shared.logError("Failed to get CGImage for cropping")
            return image
        }
        
        // Ensure the crop rect is within image bounds
        let imageRect = CGRect(origin: .zero, size: image.size)
        let cropRect = rect.intersection(imageRect)
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            ReceiptDebugLogger.shared.logError("Failed to crop image")
            return image
        }
        
        let croppedImage = UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
        ReceiptDebugLogger.shared.logSuccess("Successfully cropped receipt from \(image.size) to \(croppedImage.size)")
        
        return croppedImage
    }
    
    // MARK: - Helper functions
    
    /// Estimates average brightness of an image (between -1 and +1)
    private func estimateBrightness(of ciImage: CIImage) -> CGFloat {
        let extentVector = CIVector(
            x: ciImage.extent.origin.x,
            y: ciImage.extent.origin.y,
            z: ciImage.extent.size.width,
            w: ciImage.extent.size.height
        )
        
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: extentVector
            ]
        ),
        let output = filter.outputImage else { 
            return 0.0 
        }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let tempContext = CIContext(options: [.workingColorSpace: NSNull()])
        tempContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        
        let brightness = (CGFloat(bitmap[0]) + CGFloat(bitmap[1]) + CGFloat(bitmap[2])) / (3.0 * 255.0)
        return brightness * 2 - 1 // Scale from -1 to +1
    }
    
    private func brightnessCorrection(for avg: CGFloat) -> CGFloat {
        if avg < -0.3 { return 0.2 }  // Dark image
        if avg > 0.3 { return -0.2 }  // Too bright image
        return 0.0
    }
    
    private func contrastCorrection(for avg: CGFloat) -> CGFloat {
        if avg < -0.3 { return 1.4 }
        if avg > 0.3 { return 1.1 }
        return 1.25
    }
    
    private func gammaCorrection(for avg: CGFloat) -> CGFloat {
        if avg < -0.3 { return 0.8 }  // Darken bright areas
        if avg > 0.3 { return 1.2 }   // Brighten dark areas
        return 1.0
    }
    
    /// Applies adaptive contrast equalization (CLAHE)
    private func applyCLAHE(to ciImage: CIImage) -> CIImage? {
        // Use a simpler approach that's compatible with older iOS versions
        // Apply histogram equalization instead of CLAHE for better compatibility
        return ciImage.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: 0.15
        ])
    }
}

// MARK: - Legacy Parser (Replaced by Multi-Store Parser Factory)
// 
// NOTE: This parser has been replaced by the ReceiptParserFactory in multi-store-parsers.swift
// which provides specialized parsers for different store chains (Aldi, Lidl, Rewe, Edeka, etc.)
//
// The ReceiptParserFactory automatically detects the store type and uses the appropriate parser,
// providing much better accuracy and store-specific optimizations.

/*
final class ImprovedReceiptParser {
    static let shared = ImprovedReceiptParser()
    
    private init() {}
    
    // Variantes d'enseignes (normalisation en-tête)
    private let knownStores: [String: [String]] = [
        "ALDI SÜD": ["ALDI SÜD","ALDI SUED","ALDI SUD","ALDI SÜD","ALDI"],
        "LIDL": ["LIDL"],
        "REWE": ["REWE","REW E"],
        "EDEKA": ["EDEKA"],
        "CARREFOUR": ["CARREFOUR","CARREFOR","CARFOUR"],
        "INTERMARCHÉ": ["INTERMARCHÉ","INTERMARCHE"],
        "LECLERC": ["LECLERC","E. LECLERC"],
        "AUCHAN": ["AUCHAN"],
        "CASINO": ["CASINO"]
    ]

    // Mots clés fin de section produits
    private let endKeywords = ["SUMME","TOTAL","TTC","PAYÉ","PAID","CB","TVA","MWST","MERCI","KARTENZAHLUNG","CARD PAYMENT","CARTE"]

    // Public
    func parse(from rawText: String) -> ParsedReceipt? {
        let lines = preprocess(text: rawText)
        guard !lines.isEmpty else { return nil }
        let store = detectStore(from: lines) ?? "Inconnu"

        let productLines = extractProductSection(from: lines)
        let products = parseProducts(from: productLines)
        let total = detectTotal(from: lines) ?? products.map(\.price).reduce(0,+)

        return ParsedReceipt(storeName: store, date: Date(), total: total, products: products)
    }

    // MARK: Preprocess
    private func preprocess(text: String) -> [String] {
        text.replacingOccurrences(of: "€", with: " EUR ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    private func detectStore(from lines: [String]) -> String? {
        let top = lines.prefix(6).joined(separator: " ")
        for (canonical, variants) in knownStores {
            if variants.contains(where: { top.contains($0) }) { return canonical }
        }
        return nil
    }

    private func extractProductSection(from lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.range(of: #"\d+[,.]\d{2}"#, options: .regularExpression) != nil }) else {
            return []
        }
        let end = lines.firstIndex(where: { l in endKeywords.contains(where: { l.contains($0) }) }) ?? lines.count
        return Array(lines[start..<end])
            .filter { !$0.contains("COUPON") && !$0.contains("RABAIS") && !$0.contains("BONUS") }
    }

    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var items: [ParsedProduct] = []
        
        for line in lines {
            if let product = parseProductLine(line) {
                items.append(product)
            }
        }
        return items
    }
    
    private func parseProductLine(_ line: String) -> ParsedProduct? {
        // Simple regex for product line: text + price
        let pattern = #"(.+?)\s+(\d+[,.]\d{2})"#
        
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let nameRange = Range(match.range(at: 1), in: line),
           let priceRange = Range(match.range(at: 2), in: line) {
            
            let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
            let priceString = String(line[priceRange]).replacingOccurrences(of: ",", with: ".")
            let price = Double(priceString) ?? 0.0
            
            return ParsedProduct(rawLine: line, name: name, price: price)
        }
        
        return nil
    }

    private func detectTotal(from lines: [String]) -> Double? {
        // look for SUMME/TOTAL line
        if let line = lines.first(where: { $0.contains("SUMME") || $0.contains("TOTAL") }) {
            if let r = line.range(of: #"\d+[,.]\d{2}"#, options: .regularExpression) {
                let priceString = String(line[r]).replacingOccurrences(of: ",", with: ".")
                return Double(priceString)
            }
        }
        return nil
    }
}
*/

// MARK: - Usage in ReceiptProcessingManager

extension ReceiptProcessingManager {
    
    func processWithEnhancedOCR(image: UIImage) {
        ReceiptDebugLogger.shared.section("Starting enhanced OCR processing")
        ReceiptDebugLogger.shared.log("Input image size: \(image.size)")
        
        isProcessing = true
        errorMessage = nil
        
        // Step 1: Preprocess image
        ReceiptDebugLogger.shared.logDebug("Starting image preprocessing")
        ReceiptImagePreprocessor.shared.preprocess(image) { [weak self] (preprocessed: UIImage?) in
            guard let self else { 
                ReceiptDebugLogger.shared.logError("Self is nil in preprocessing callback")
            return
        }
            
            if let preprocessed = preprocessed {
                ReceiptDebugLogger.shared.logSuccess("Image preprocessing completed")
                ReceiptDebugLogger.shared.logDebug("Preprocessed image size: \(preprocessed.size)")
            } else {
                ReceiptDebugLogger.shared.logWarning("Image preprocessing returned nil, using original")
            }
            
            let cleanImage = preprocessed ?? image
            
            // Step 2: Multi-pass OCR
            ReceiptDebugLogger.shared.logDebug("Starting multi-pass OCR recognition")
            MultiPassOCRStrategy.shared.recognizeWithMultiPass(image: cleanImage) { text in
                guard let rawText = text else {
                    ReceiptDebugLogger.shared.logError("OCR failed - no text recognized")
                    Task { @MainActor in
                        self.errorMessage = "OCR failed - no text recognized"
                        self.isProcessing = false
                    }
                    return
                }
                
                ReceiptDebugLogger.shared.logSuccess("OCR completed successfully")
                ReceiptDebugLogger.shared.logDebug("Raw OCR text length: \(rawText.count) characters")
                ReceiptDebugLogger.shared.logTrace("Raw OCR text preview: \(String(rawText.prefix(200)))...")
                
                // Step 3: Post-process OCR errors
                ReceiptDebugLogger.shared.logDebug("Starting OCR post-processing")
                let correctedText = OCRPostProcessor.shared.correctCommonErrors(rawText)
                ReceiptDebugLogger.shared.logDebug("Post-processed text length: \(correctedText.count) characters")
                
                // Step 4: Validate
                ReceiptDebugLogger.shared.logDebug("Starting receipt validation")
                let validation = OCRPostProcessor.shared.validateReceiptText(correctedText)
                
                ReceiptDebugLogger.shared.log("Validation result: \(validation.isValid ? "PASSED" : "FAILED"), confidence: \(validation.confidence)")
                
                if !validation.isValid {
                    ReceiptDebugLogger.shared.logWarning("Validation failed with issues:")
                    for issue in validation.issues {
                        ReceiptDebugLogger.shared.logWarning("  - \(issue)")
                    }
                }
                
                // Step 5: Parse
                ReceiptDebugLogger.shared.logDebug("Starting receipt parsing")
                Task { @MainActor in
                    self.parseAndUpdate(text: correctedText)
                }
            }
        }
    }
    
    private func parseAndUpdate(text: String) {
        ReceiptDebugLogger.shared.section("Starting receipt parsing with multi-store parser")
        ReceiptDebugLogger.shared.logDebug("Input text length: \(text.count) characters")
        
        // Use the multi-store parser factory which automatically detects store type
        // and uses specialized parsers for better accuracy (Aldi, Lidl, Rewe, Edeka, etc.)
        if let receipt = ReceiptParserFactory.shared.parseReceipt(from: text) {
            ReceiptDebugLogger.shared.logSuccess("Receipt parsing completed successfully")
            ReceiptDebugLogger.shared.log("Parsed \(receipt.products.count) products")
            ReceiptDebugLogger.shared.log("Total amount: \(receipt.total)")
            ReceiptDebugLogger.shared.log("Store: \(receipt.storeName)")
            
            // Log individual products for debugging
            for (index, product) in receipt.products.enumerated() {
                ReceiptDebugLogger.shared.logTrace("Product \(index + 1): \(product.name) - \(product.price) - \(product.section.rawValue)")
            }
            
            self.parsedReceipt = receipt
            self.editableProducts = receipt.products
            self.totalEditable = receipt.total
            self.isProcessing = false
        } else {
            ReceiptDebugLogger.shared.logError("Receipt parsing failed - no receipt object returned")
            ReceiptDebugLogger.shared.logDebug("Failed parsing text preview: \(String(text.prefix(300)))...")
            self.errorMessage = "Could not parse receipt - check debug logs"
            self.isProcessing = false
        }
    }
}

// MARK: - Real-time OCR Quality Feedback

struct OCRQualityIndicator {
    let score: Float // 0.0 - 1.0
    let factors: [QualityFactor]
    
    enum QualityFactor {
        case blur(severity: Float)
        case lowLight(severity: Float)
        case skew(degrees: Float)
        case resolution(megapixels: Float)
        case contrast(level: Float)
        
        var recommendation: String {
            switch self {
            case .blur(let severity):
                return severity > 0.5 ? "Hold camera steady" : "Image is slightly blurry"
            case .lowLight(let severity):
                return severity > 0.5 ? "Need more light" : "Lighting could be better"
            case .skew(let degrees):
                return "Receipt is tilted \(Int(degrees))°"
            case .resolution(let mp):
                return mp < 2.0 ? "Move closer to receipt" : "Resolution OK"
            case .contrast(let level):
                return level < 0.3 ? "Receipt has low contrast" : "Contrast OK"
            }
        }
    }
    
    var overallRecommendation: String {
        if score >= 0.8 {
            return "✅ Good quality - ready to scan"
        } else if score >= 0.5 {
            return "⚠️ Acceptable - may have issues"
        } else {
            return "❌ Poor quality - improve conditions"
        }
    }
}

final class OCRQualityAnalyzer {
    
    static let shared = OCRQualityAnalyzer()
    
    func analyzeImageQuality(_ image: UIImage) -> OCRQualityIndicator {
        var factors: [OCRQualityIndicator.QualityFactor] = []
        var totalScore: Float = 1.0
        
        guard let ciImage = CIImage(image: image) else {
            return OCRQualityIndicator(score: 0.0, factors: [])
        }
        
        // 1. Check blur (Laplacian variance)
        let blurScore = detectBlur(ciImage)
        if blurScore > 0.3 {
            factors.append(.blur(severity: blurScore))
            totalScore -= blurScore * 0.4
        }
        
        // 2. Check brightness
        let brightness = detectBrightness(ciImage)
        if brightness < 0.3 || brightness > 0.9 {
            let severity = brightness < 0.3 ? (0.3 - brightness) : (brightness - 0.9)
            factors.append(.lowLight(severity: severity))
            totalScore -= severity * 0.3
        }
        
        // 3. Check resolution
        let megapixels = Float(image.size.width * image.size.height * image.scale * image.scale) / 1_000_000.0
        factors.append(.resolution(megapixels: megapixels))
        if megapixels < 2.0 {
            totalScore -= 0.2
        }
        
        // 4. Check contrast
        let contrast = detectContrast(ciImage)
        factors.append(.contrast(level: contrast))
        if contrast < 0.3 {
            totalScore -= 0.3
        }
        
        return OCRQualityIndicator(
            score: max(0, min(1, totalScore)),
            factors: factors
        )
    }
    
    private func detectBlur(_ image: CIImage) -> Float {
        // Laplacian operator for edge detection
        // Lower variance = more blur
        let laplacian = CIFilter(name: "CIColorControls")
        laplacian?.setValue(image, forKey: kCIInputImageKey)
        
        // Simplified blur detection
        // In production, use actual Laplacian convolution
        return 0.2 // Placeholder
    }
    
    private func detectBrightness(_ image: CIImage) -> Float {
        let extent = image.extent
        let inputExtent = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(inputExtent, forKey: kCIInputExtentKey)
        
        guard let outputImage = filter.outputImage else { return 0.5 }
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(outputImage,
                      toBitmap: &bitmap,
                      rowBytes: 4,
                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                      format: .RGBA8,
                      colorSpace: nil)
        
        // Return average brightness (0-1)
        return Float(bitmap[0]) / 255.0
    }
    
    private func detectContrast(_ image: CIImage) -> Float {
        // Simplified contrast detection
        // In production, calculate standard deviation of pixel values
        return 0.6 // Placeholder
    }
}

// MARK: - Live Camera Preview with Quality Overlay

import SwiftUI
import AVFoundation

struct LiveReceiptScannerView: View {
    @StateObject private var viewModel = CameraScannerViewModel()
    @State private var showQualityOverlay = true

    var body: some View {
        ZStack {
            // Camera preview
            ReceiptCameraPreviewView(session: viewModel.session)
                .ignoresSafeArea()
            
            // Quality overlay
            if showQualityOverlay, let quality = viewModel.currentQuality {
                VStack {
                    Spacer()
                    
                    QualityIndicatorView(quality: quality)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                    
                    Button {
                        viewModel.capturePhoto()
                    } label: {
                        Circle()
                            .fill(quality.score >= 0.5 ? Color.green : Color.red)
                            .frame(width: 70, height: 70)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .padding(5)
                            )
                    }
                    .padding(.bottom, 40)
                }
            }
            
            // Rectangle overlay for framing
            ReceiptFrameOverlay()
        }
        .onAppear {
            viewModel.startSession()
        }
        .onDisappear {
            viewModel.stopSession()
        }
    }
}

struct QualityIndicatorView: View {
    let quality: OCRQualityIndicator
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                Circle()
                    .fill(scoreColor)
                    .frame(width: 12, height: 12)
                
                Text(quality.overallRecommendation)
                    .font(.headline)
            }
            
            ForEach(quality.factors.indices, id: \.self) { index in
                Text(quality.factors[index].recommendation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
    
    private var scoreColor: Color {
        if quality.score >= 0.8 {
            return .green
        } else if quality.score >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

struct ReceiptFrameOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.85
            let height = geometry.size.height * 0.6
            
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            
            // Corner markers
            Path { path in
                let cornerLength: CGFloat = 20
                let x = (geometry.size.width - width) / 2
                let y = (geometry.size.height - height) / 2
                
                // Top-left
                path.move(to: CGPoint(x: x, y: y + cornerLength))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + cornerLength, y: y))
                
                // Top-right
                path.move(to: CGPoint(x: x + width - cornerLength, y: y))
                path.addLine(to: CGPoint(x: x + width, y: y))
                path.addLine(to: CGPoint(x: x + width, y: y + cornerLength))
                
                // Bottom-left
                path.move(to: CGPoint(x: x, y: y + height - cornerLength))
                path.addLine(to: CGPoint(x: x, y: y + height))
                path.addLine(to: CGPoint(x: x + cornerLength, y: y + height))
                
                // Bottom-right
                path.move(to: CGPoint(x: x + width - cornerLength, y: y + height))
                path.addLine(to: CGPoint(x: x + width, y: y + height))
                path.addLine(to: CGPoint(x: x + width, y: y + height - cornerLength))
            }
            .stroke(Color.green, lineWidth: 4)
        }
    }
}

struct ReceiptCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        DispatchQueue.main.async {
            previewLayer.frame = view.bounds
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
}

@MainActor
class CameraScannerViewModel: NSObject, ObservableObject {
    @Published var currentQuality: OCRQualityIndicator?
    @Published var capturedImage: UIImage?
    
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var qualityTimer: Timer?
    
    override init() {
        super.init()
        setupCamera()
    }
    
    private func setupCamera() {
        session.sessionPreset = .photo
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        // Configure for high quality
        if #available(iOS 16.0, *) {
            photoOutput.maxPhotoDimensions = CMVideoDimensions(width: 4032, height: 3024)
                } else {
            photoOutput.isHighResolutionCaptureEnabled = true
        }
    }
    
    func startSession() {
        Task { @MainActor in
            self.session.startRunning()
        }
        
        // Start quality monitoring
        qualityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateQuality()
            }
        }
    }
    
    func stopSession() {
        session.stopRunning()
        qualityTimer?.invalidate()
    }
    
    @MainActor
    private func updateQuality() {
        // Get current frame and analyze
        // This is simplified - in production, grab actual frame from session
        // For now, just show placeholder
        self.currentQuality = OCRQualityIndicator(
            score: 0.75,
            factors: [.resolution(megapixels: 12.0)]
        )
    }
    
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        
        if #available(iOS 16.0, *) {
            // Use maxPhotoDimensions instead of deprecated isHighResolutionPhotoEnabled
            settings.maxPhotoDimensions = CMVideoDimensions(width: 4032, height: 3024)
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraScannerViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            return
        }
        
        Task { @MainActor in
            self.capturedImage = image
        }
    }
}

// MARK: - Performance Monitoring

final class ReceiptProcessingMetrics {
    static let shared = ReceiptProcessingMetrics()
    
    struct Metrics {
        var preprocessingTime: TimeInterval = 0
        var ocrTime: TimeInterval = 0
        var parsingTime: TimeInterval = 0
        var totalTime: TimeInterval = 0
        var productCount: Int = 0
        var ocrConfidence: Float = 0
        var successRate: Float = 0
    }
    
    private var sessions: [Metrics] = []
    
    func startSession() -> SessionTracker {
        return SessionTracker()
    }
    
    func recordSession(_ metrics: Metrics) {
        sessions.append(metrics)
        
        // Keep only last 100 sessions
        if sessions.count > 100 {
            sessions.removeFirst()
        }
        
        printSummary()
    }
    
    func printSummary() {
        guard !sessions.isEmpty else { return }
        
        let avgTotal = sessions.map(\.totalTime).reduce(0, +) / Double(sessions.count)
        let avgOCR = sessions.map(\.ocrTime).reduce(0, +) / Double(sessions.count)
        let avgParsing = sessions.map(\.parsingTime).reduce(0, +) / Double(sessions.count)
        let avgProducts = sessions.map(\.productCount).reduce(0, +) / sessions.count
        let successCount = sessions.filter { $0.productCount > 0 }.count
        let successRate = Float(successCount) / Float(sessions.count) * 100
        
        print("""
        
        ===== PERFORMANCE SUMMARY =====
        Sessions: \(sessions.count)
        Avg Total Time: \(String(format: "%.2f", avgTotal))s
        Avg OCR Time: \(String(format: "%.2f", avgOCR))s
        Avg Parsing Time: \(String(format: "%.2f", avgParsing))s
        Avg Products: \(avgProducts)
        Success Rate: \(String(format: "%.1f", successRate))%
        ==============================
        
        """)
    }
    
    class SessionTracker {
        private var startTime: Date?
        private var preprocessingStart: Date?
        private var ocrStart: Date?
        private var parsingStart: Date?
        
        var metrics = Metrics()
        
        init() {
            startTime = Date()
        }
        
        func markPreprocessingStart() {
            preprocessingStart = Date()
        }
        
        func markPreprocessingEnd() {
            if let start = preprocessingStart {
                metrics.preprocessingTime = Date().timeIntervalSince(start)
            }
        }
        
        func markOCRStart() {
            ocrStart = Date()
        }
        
        func markOCREnd() {
            if let start = ocrStart {
                metrics.ocrTime = Date().timeIntervalSince(start)
            }
        }
        
        func markParsingStart() {
            parsingStart = Date()
        }
        
        func markParsingEnd() {
            if let start = parsingStart {
                metrics.parsingTime = Date().timeIntervalSince(start)
            }
        }
        
        func complete(productCount: Int, ocrConfidence: Float) {
            if let start = startTime {
                metrics.totalTime = Date().timeIntervalSince(start)
            }
            metrics.productCount = productCount
            metrics.ocrConfidence = ocrConfidence
            metrics.successRate = productCount > 0 ? 1.0 : 0.0
            
            ReceiptProcessingMetrics.shared.recordSession(metrics)
        }
    }
}

// MARK: - VNDocumentCameraViewControllerDelegate

extension ReceiptProcessingManager: VNDocumentCameraViewControllerDelegate {
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)
        guard scan.pageCount > 0 else {
            errorMessage = "Aucune page capturée."
            return
        }
        // merge or use first page for now
        let image = scan.imageOfPage(at: 0)
        process(image: image)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
        errorMessage = "Erreur caméra : \(error.localizedDescription)"
    }
}
