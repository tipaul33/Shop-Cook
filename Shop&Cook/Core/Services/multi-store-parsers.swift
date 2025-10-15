// MARK: - Multi-Store Receipt Parser Factory
// Supports: Aldi, Lidl, Rewe, Edeka, Penny, Netto (Germany)
//           Carrefour, Leclerc, Intermarché, Auchan, Casino (France)

import Foundation
import UIKit

// MARK: - Unified Parser Architecture

/// Main receipt parser protocol
protocol ReceiptParser {
    var patterns: ReceiptPatterns { get }
    func parse(from text: String) -> ParsedReceipt?
}

/// Store-specific patterns configuration
struct ReceiptPatterns {
    // Store identification
    let storeIdentifiers: [String]           // ["ALDI", "ALDI SÜD", "ALDT"]
    let storeName: String                    // Display name
    
    // Regex patterns
    let productLinePattern: NSRegularExpression
    let pricePattern: NSRegularExpression
    let totalPattern: NSRegularExpression
    
    // Section markers
    let sectionMarkers: SectionMarkers
    
    // Optional patterns for complex receipts
    let quantityPattern: NSRegularExpression?
    let weightPattern: NSRegularExpression?
    
    // Configuration flags
    let isMultiLineProduct: Bool
    let hasArticleNumbers: Bool              // 6-digit article numbers
    let priceLocation: PriceLocation         // Where prices appear
}

/// Defines where prices appear on receipt
enum PriceLocation {
    case sameLine           // "Product Name 2.50"
    case nextLine           // "Product Name\n2.50"
    case separateColumn     // "Product Name        2.50"
}

/// Section boundary markers
struct SectionMarkers {
    let productSectionStart: [String]        // Patterns to find start
    let productSectionEnd: [String]          // ["SUMME", "TOTAL", "GESAMT"]
    let ignoreLines: [String]                // ["MwSt", "USt", "Pfand"]
    let headerKeywords: [String]             // Skip these in header
}

// MARK: - Unified Base Parser

/// Base parser with common logic - eliminates code duplication
class UnifiedReceiptParser: ReceiptParser {
    let patterns: ReceiptPatterns
    let logger = ReceiptDebugLogger.shared
    
    init(patterns: ReceiptPatterns) {
        self.patterns = patterns
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("UNIFIED PARSER: \(patterns.storeName)")
        
        let lines = preprocessText(text)
        logger.log("Processing \(lines.count) lines")
        
        // 1. Extract date
        let date = extractDate(from: lines)
        
        // 2. Find product section boundaries
        guard let (startIdx, endIdx) = findProductSection(in: lines) else {
            logger.logError("Could not find product section")
            return nil
        }
        
        logger.log("Product section: lines \(startIdx) to \(endIdx)")
        
        // 3. Parse products
        let productLines = Array(lines[startIdx..<endIdx])
        let products = parseProducts(from: productLines)
        
        logger.logSuccess("Parsed \(products.count) products")
        
        // 4. Extract total
        var total = extractTotal(from: lines, afterLine: endIdx)
        
        // Fallback: calculate from products
        if total == 0.0 {
            total = products.map { $0.price }.reduce(0, +)
            logger.logWarning("No total found, calculated: €\(String(format: "%.2f", total))")
        }
        
        guard !products.isEmpty else {
            logger.logError("No products found")
            return nil
        }
        
        return ParsedReceipt(
            storeName: patterns.storeName,
            date: date,
            total: total,
            products: products
        )
    }
    
    // MARK: - Common Parsing Logic
    
    private func preprocessText(_ text: String) -> [String] {
        return text
            .replacingOccurrences(of: "€", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var startIdx: Int?
        var endIdx: Int?
        
        // Find start
        for (i, line) in lines.enumerated() {
            // Skip header lines
            let upper = line.uppercased()
            if patterns.sectionMarkers.headerKeywords.contains(where: { upper.contains($0) }) {
                continue
            }
            
            // Check start patterns
            for pattern in patterns.sectionMarkers.productSectionStart {
                if line.range(of: pattern, options: .regularExpression) != nil {
                    startIdx = i
                    logger.log("Product section starts at line \(i): \(line)")
                    break
                }
            }
            
            if startIdx != nil { break }
        }
        
        guard let start = startIdx else { return nil }
        
        // Find end
        for i in (start + 1)..<lines.count {
            let upper = lines[i].uppercased()
            if patterns.sectionMarkers.productSectionEnd.contains(where: { upper.contains($0) }) {
                endIdx = i
                logger.log("Product section ends at line \(i): \(lines[i])")
                break
            }
        }
        
        return (start, endIdx ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        var i = 0
        
        while i < lines.count {
            let line = lines[i]
            
            // Skip ignore lines
            if shouldIgnoreLine(line) {
                i += 1
                continue
            }
            
            // Try to parse based on price location
            switch patterns.priceLocation {
            case .sameLine:
                if let product = parseSameLineProduct(line) {
                    products.append(product)
                }
                i += 1
                
            case .nextLine:
                if let result = parseMultiLineProduct(lines: lines, startIndex: i) {
                    products.append(result.product)
                    i += result.linesConsumed
                } else {
                    i += 1
                }
                
            case .separateColumn:
                if let product = parseColumnProduct(line) {
                    products.append(product)
                }
                i += 1
            }
        }
        
        return products
    }
    
    private func parseSameLineProduct(_ line: String) -> ParsedProduct? {
        let nsRange = NSRange(line.startIndex..., in: line)
        
        guard let match = patterns.productLinePattern.firstMatch(in: line, range: nsRange) else {
            return nil
        }
        
        // Extract name and price based on capture groups
        guard let nameRange = Range(match.range(at: patterns.hasArticleNumbers ? 2 : 1), in: line),
              let priceRange = Range(match.range(at: patterns.hasArticleNumbers ? 3 : 2), in: line) else {
            return nil
        }
        
        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        let price = parsePrice(String(line[priceRange]))
        
        guard isFoodItem(name), price > 0 else { return nil }
        
        return ParsedProduct(
            rawLine: line,
            name: cleanProductName(name),
            price: price,
            section: categorizeProduct(name)
        )
    }
    
    private func parseMultiLineProduct(lines: [String], startIndex: Int) -> (product: ParsedProduct, linesConsumed: Int)? {
        guard startIndex < lines.count else { return nil }
        
        let line = lines[startIndex]
        
        // Look for price in next few lines
        for offset in 1...3 {
            let priceIdx = startIndex + offset
            guard priceIdx < lines.count else { break }
            
            let priceLine = lines[priceIdx]
            let nsRange = NSRange(priceLine.startIndex..., in: priceLine)
            
            if patterns.pricePattern.firstMatch(in: priceLine, range: nsRange) != nil {
                let price = parsePrice(priceLine)
                
                guard isFoodItem(line), price > 0 else { return nil }
                
                let product = ParsedProduct(
                    rawLine: line,
                    name: cleanProductName(line),
                    price: price,
                    section: categorizeProduct(line)
                )
                
                return (product, priceIdx + 1)
            }
        }
        
        return nil
    }
    
    private func parseColumnProduct(_ line: String) -> ParsedProduct? {
        let nsRange = NSRange(line.startIndex..., in: line)
        
        guard let match = patterns.productLinePattern.firstMatch(in: line, range: nsRange) else {
            return nil
        }
        
        // Similar to sameLine but handles column spacing
        return parseSameLineProduct(line)
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in max(0, afterLine - 5)..<min(lines.count, afterLine + 15) {
            let line = lines[i]
            let nsRange = NSRange(line.startIndex..., in: line)
            
            if let match = patterns.totalPattern.firstMatch(in: line, range: nsRange) {
                // Try to extract from capture group, or from whole match
                if match.numberOfRanges > 1, let priceRange = Range(match.range(at: 1), in: line) {
                    return parsePrice(String(line[priceRange]))
                } else if let matchRange = Range(match.range, in: line) {
                    return parsePrice(String(line[matchRange]))
                }
            }
        }
        
        return 0.0
    }
    
    private func extractDate(from lines: [String]) -> Date {
        let dateFormats = ["dd.MM.yyyy HH:mm", "dd.MM.yy HH:mm", "yyyy-MM-dd HH:mm"]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        for line in lines.prefix(20) {
            for format in dateFormats {
                dateFormatter.dateFormat = format
                if let date = dateFormatter.date(from: line) {
                    return date
                }
            }
        }
        
        return Date()
    }
    
    private func shouldIgnoreLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return patterns.sectionMarkers.ignoreLines.contains(where: { upper.contains($0) })
    }
    
    private func parsePrice(_ str: String) -> Double {
        let normalized = str
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "EUR", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(normalized) ?? 0.0
    }
    
    private func isFoodItem(_ name: String) -> Bool {
        let lower = name.lowercased()
        let nonFoodKeywords = ["pfand", "tüte", "tasche", "bag", "sac"]
        return !nonFoodKeywords.contains(where: { lower.contains($0) })
    }
    
    private func cleanProductName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    
    private func categorizeProduct(_ name: String) -> ProductSection {
        // Try ML classification first (if available)
        let mlResult = MLProductClassifier.shared.classify(name)
        
        // Use ML if confidence is high
        if mlResult.confidence > 0.7 {
            return mlResult.category
        }
        
        // Otherwise use rule-based classification
        let lower = name.lowercased()
        
        // Fridge
        if lower.contains("milch") || lower.contains("joghurt") || lower.contains("käse") ||
           lower.contains("butter") || lower.contains("wurst") || lower.contains("fleisch") {
            return .fridge
        }
        
        // Freezer
        if lower.contains("eis") || lower.contains("tiefkühl") || lower.contains("frozen") {
            return .freezer
        }
        
        return .pantry
    }
}

// MARK: - Legacy Store-Specific Parser Protocol (for compatibility)

protocol StoreReceiptParser {
    var storeName: String { get }
    func canParse(_ text: String) -> Bool
    func parse(from text: String) -> ParsedReceipt?
}

// MARK: - Example: Simplified Store Parsers Using Unified Architecture

/// Example: LIDL parser using unified architecture - only ~30 lines!
class UnifiedLidlParser: UnifiedReceiptParser, StoreReceiptParser {
    var storeName: String { patterns.storeName }
    
    init() {
        let patterns = ReceiptPatterns(
            storeIdentifiers: ["LIDL", "LID"],
            storeName: "LIDL",
            productLinePattern: try! NSRegularExpression(
                pattern: #"^(.+?)\s+(\d{1,3}[.,]\d{2})\s*[AB]?$"#
            ),
            pricePattern: try! NSRegularExpression(
                pattern: #"\d{1,3}[.,]\d{2}"#
            ),
            totalPattern: try! NSRegularExpression(
                pattern: #"(?:SUMME|TOTAL|GESAMT).*?(\d{1,3}[.,]\d{2})"#
            ),
            sectionMarkers: SectionMarkers(
                productSectionStart: [#"^[A-ZÄÖÜa-zäöüß].+\d{1,3}[.,]\d{2}"#],
                productSectionEnd: ["SUMME", "TOTAL", "ZWISCHENSUMME"],
                ignoreLines: ["PFAND", "MWST", "UST"],
                headerKeywords: ["LIDL", "ADRESSE", "TEL"]
            ),
            quantityPattern: nil,
            weightPattern: nil,
            isMultiLineProduct: false,
            hasArticleNumbers: false,
            priceLocation: .sameLine
        )
        super.init(patterns: patterns)
    }
    
    func canParse(_ text: String) -> Bool {
        let upper = text.uppercased()
        return patterns.storeIdentifiers.contains(where: { upper.contains($0) })
    }
}

/// Example: REWE parser using unified architecture - only ~35 lines!
class UnifiedReweParser: UnifiedReceiptParser, StoreReceiptParser {
    var storeName: String { patterns.storeName }
    
    init() {
        let patterns = ReceiptPatterns(
            storeIdentifiers: ["REWE", "REW"],
            storeName: "REWE",
            productLinePattern: try! NSRegularExpression(
                pattern: #"^(\d{13})\s+(.+?)\s+(\d{1,3}[.,]\d{2})\s*[AB]?$"#
            ),
            pricePattern: try! NSRegularExpression(
                pattern: #"\d{1,3}[.,]\d{2}"#
            ),
            totalPattern: try! NSRegularExpression(
                pattern: #"(?:SUMME|GESAMT|EUR).*?(\d{1,3}[.,]\d{2})"#
            ),
            sectionMarkers: SectionMarkers(
                productSectionStart: [#"^\d{13}"#],  // EAN barcode
                productSectionEnd: ["SUMME", "ZWISCHENSUMME", "GESAMT"],
                ignoreLines: ["PFAND", "MWST", "MEHRWERTSTEUER"],
                headerKeywords: ["REWE", "MARKT"]
            ),
            quantityPattern: try! NSRegularExpression(
                pattern: #"^(\d+)\s+x\s+(\d+[.,]\d{2})"#
            ),
            weightPattern: nil,
            isMultiLineProduct: false,
            hasArticleNumbers: true,
            priceLocation: .sameLine
        )
        super.init(patterns: patterns)
    }
    
    func canParse(_ text: String) -> Bool {
        let upper = text.uppercased()
        return patterns.storeIdentifiers.contains(where: { upper.contains($0) })
    }
}

// MARK: - Intelligent Store Detection

/// Store detection result with confidence score
struct StoreMatch {
    let storeName: String
    let parser: StoreReceiptParser
    let confidence: Float
    let reasoning: [String: Float]  // Factor scores
}

/// Store types for fuzzy detection
enum StoreType {
    case aldiSued
    case aldiNord
    case lidl
    case rewe
    case edeka
    case unknown
}

/// Simple store match for fuzzy detection
struct SimpleStoreMatch {
    let store: StoreType
    let confidence: Float
}

/// ✅ FUZZY STORE DETECTION
class SmartStoreDetector {
    private let logger = ReceiptDebugLogger.shared
    
    func detect(from text: String) -> StoreMatch? {
        logger.section("FUZZY STORE DETECTION")
        
        let normalized = text.uppercased()
            .replacingOccurrences(of: "Ü", with: "U")
            .replacingOccurrences(of: "Ö", with: "O")
            .replacingOccurrences(of: "Ä", with: "A")
        
        // Check each store type
        var scores: [StoreType: Float] = [:]
        
        // ALDI detection
        if normalized.contains("ALDI") {
            var score: Float = 0.8  // Base score for name match
            
            if normalized.contains("SUD") || normalized.contains("SUED") {
                score = 0.95
            } else if normalized.contains("NORD") {
                score = 0.95
            }
            
            // Boost score if we see article number pattern
            if hasAldiArticleNumbers(text) {
                score = min(1.0, score + 0.1)
            }
            
            scores[.aldiSued] = score
        }
        
        // LIDL detection
        if normalized.contains("LIDL") {
            scores[.lidl] = 0.9
        }
        
        // REWE detection
        if normalized.contains("REWE") {
            scores[.rewe] = 0.9
        }
        
        // EDEKA detection
        if normalized.contains("EDEKA") {
            scores[.edeka] = 0.9
        }
        
        // Find best match
        guard let best = scores.max(by: { $0.value < $1.value }),
              best.value >= 0.5 else {  // Lower threshold!
            logger.logWarning("No store detected with sufficient confidence")
            return nil
        }
        
        // Convert StoreType to parser
        let parser = getParserForStoreType(best.key)
        
        logger.logSuccess("Detected: \(best.key) with confidence \(String(format: "%.1f%%", best.value * 100))")
        
        return StoreMatch(
            storeName: parser.storeName,
            parser: parser,
            confidence: best.value,
            reasoning: ["fuzzy_detection": best.value]
        )
    }
    
    private func hasAldiArticleNumbers(_ text: String) -> Bool {
        let pattern = try! NSRegularExpression(pattern: #"\b\d{6}\b"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.count >= 3
    }
    
    private func getParserForStoreType(_ storeType: StoreType) -> StoreReceiptParser {
        switch storeType {
        case .aldiSued, .aldiNord:
            return AldiParser()
        case .lidl:
            return LidlParser()
        case .rewe:
            return ReweParser()
        case .edeka:
            return EdekaParser()
        case .unknown:
            return GenericReceiptParser()
        }
    }
}

// MARK: - Parser Factory

final class ReceiptParserFactory {
    static let shared = ReceiptParserFactory()
        
        // Store-specific name patterns with OCR error tolerance
        let storePatterns: [String: [String]] = [
            "ALDI Süd": ["ALDI", "SÜD", "SUED", "ALDT", "ALDO", "S00D", "SOOD"],
            "ALDI Nord": ["ALDI", "NORD", "ALDT", "ALDO", "N0RD", "NORO"],
            "LIDL": ["LIDL", "LID", "L1DL"],
            "REWE": ["REWE", "REW"],
            "EDEKA": ["EDEKA", "EDEXA", "EDKA"],
            "PENNY": ["PENNY", "PENY"],
            "NETTO": ["NETTO", "NET0"],
            "Carrefour": ["CARREFOUR", "CARREF0UR"],
            "E.Leclerc": ["LECLERC", "LECLERK", "E.LECLERC"],
            "Intermarché": ["INTERMARCHE", "INTERMARCH"],
            "Auchan": ["AUCHAN", "AUCH4N"],
            "Casino": ["CASINO", "CASIN0"]
        ]
        
        guard let patterns = storePatterns[storeName] else { return 0.0 }
        
        var score: Float = 0.0
        var matchCount = 0
        
        for pattern in patterns {
            if upper.contains(pattern) {
                matchCount += 1
            }
        }
        
        // Score based on pattern matches
        if matchCount >= 2 {
            score = 1.0  // Strong match (multiple patterns)
        } else if matchCount == 1 {
            score = 0.7  // Moderate match (single pattern)
        }
        
        return score
    }
    
    /// Factor 2: Receipt structure analysis (30% weight)
    private func detectByStructure(_ lines: [String], storeName: String) -> Float {
        var score: Float = 0.0
        
        switch storeName {
        case "ALDI Süd", "ALDI Nord":
            // ALDI: 6-digit article numbers on separate lines
            let articleNumberCount = lines.filter { line in
                line.range(of: #"^\d{6}$"#, options: .regularExpression) != nil
            }.count
            
            if articleNumberCount > 5 {
                score = 1.0  // Strong ALDI indicator
            } else if articleNumberCount > 2 {
                score = 0.6  // Moderate indicator
            }
            
        case "LIDL":
            // LIDL: Simple "Product  Price" format, no article numbers
            let simpleLineCount = lines.filter { line in
                line.range(of: #"^[A-ZÄÖÜa-zäöüß].+\s+\d{1,3}[.,]\d{2}\s*[AB]?$"#, options: .regularExpression) != nil
            }.count
            
            let hasNoArticleNumbers = lines.filter { line in
                line.range(of: #"^\d{6,13}$"#, options: .regularExpression) != nil
            }.count == 0
            
            if simpleLineCount > 5 && hasNoArticleNumbers {
                score = 1.0
            } else if simpleLineCount > 3 {
                score = 0.6
            }
            
        case "REWE":
            // REWE: 13-digit EAN barcodes
            let eanCount = lines.filter { line in
                line.range(of: #"^\d{13}$"#, options: .regularExpression) != nil
            }.count
            
            if eanCount > 3 {
                score = 1.0
            } else if eanCount > 1 {
                score = 0.7
            }
            
        case "EDEKA":
            // EDEKA: Often has "E center" or "E aktiv markt"
            if lines.contains(where: { $0.uppercased().contains("E CENTER") || $0.uppercased().contains("E AKTIV") }) {
                score = 0.9
            }
            
        case "Carrefour":
            // Carrefour: French format with "€" symbol and specific keywords
            let hasFrenchTotal = lines.contains(where: { 
                $0.uppercased().contains("TOTAL") || $0.uppercased().contains("MONTANT")
            })
            if hasFrenchTotal {
                score = 0.7
            }
            
        default:
            score = 0.0
        }
        
        return score
    }
    
    /// Factor 3: Product pattern analysis (20% weight)
    private func detectByPatterns(_ lines: [String], storeName: String) -> Float {
        var score: Float = 0.0
        
        // Analyze footer/total section patterns
        let footerLines = Array(lines.suffix(15))
        
        switch storeName {
        case "ALDI Süd", "ALDI Nord":
            // ALDI: "Betrag" keyword for total
            if footerLines.contains(where: { $0.uppercased().contains("BETRAG") }) {
                score += 0.5
            }
            // ALDI: "K-U-N-D-E" section marker
            if footerLines.contains(where: { $0.uppercased().contains("K-U-N-D-E") }) {
                score += 0.5
            }
            
        case "LIDL":
            // LIDL: "SUMME" or "ZWISCHENSUMME"
            if footerLines.contains(where: { $0.uppercased().contains("SUMME") }) {
                score += 0.6
            }
            
        case "REWE":
            // REWE: "GESAMT EUR" pattern
            if footerLines.contains(where: { 
                $0.uppercased().contains("GESAMT") && $0.uppercased().contains("EUR")
            }) {
                score += 0.7
            }
            
        case "Carrefour":
            // Carrefour: "TOTAL TTC"
            if footerLines.contains(where: { $0.uppercased().contains("TOTAL TTC") }) {
                score = 1.0
            }
            
        case "E.Leclerc":
            // Leclerc: Specific footer patterns
            if footerLines.contains(where: { $0.uppercased().contains("TICKET") }) {
                score += 0.6
            }
            
        default:
            break
        }
        
        return min(score, 1.0)  // Cap at 1.0
    }
}

// MARK: - Parser Factory

final class ReceiptParserFactory {
    static let shared = ReceiptParserFactory()
    
    private let parsers: [StoreReceiptParser] = [
        // German stores
        AldiParser(),
        LidlParser(),
        ReweParser(),
        EdekaParser(),
        PennyParser(),
        NettoParser(),
        
        // French stores
        CarrefourParser(),
        LeclercParser(),
        IntermarcheParser(),
        AuchanParser(),
        CasinoParser()
    ]
    
    private lazy var smartDetector = SmartStoreDetector(parsers: parsers)
    private let confidenceScorer = ReceiptConfidenceScorer()
    
    func parseReceipt(from text: String) -> ParsedReceipt? {
        let logger = ReceiptDebugLogger.shared
        logger.section("SMART STORE DETECTION AND PARSING")
        logger.log("Input text length: \(text.count) characters")
        
        // Use intelligent multi-factor detection
        guard let match = smartDetector.detect(from: text) else {
            logger.logWarning("No store detected with sufficient confidence")
            return tryGenericParser(text)
        }
        
        logger.logSuccess("Detected: \(match.storeName) (confidence: \(String(format: "%.1f%%", match.confidence * 100)))")
        logger.logDebug("Reasoning - Name: \(String(format: "%.2f", match.reasoning["name"] ?? 0)), Structure: \(String(format: "%.2f", match.reasoning["structure"] ?? 0)), Pattern: \(String(format: "%.2f", match.reasoning["pattern"] ?? 0))")
        
        // Parse with detected store's parser
        if let receipt = match.parser.parse(from: text) {
            logger.logSuccess("Successfully parsed with \(match.storeName) parser")
            logger.log("Parsed \(receipt.products.count) products, total: €\(String(format: "%.2f", receipt.total))")
            
            // Calculate confidence score
            let confidence = confidenceScorer.score(receipt, ocrText: text, storeConfidence: match.confidence)
            logger.log("Receipt quality: \(confidence.rating.emoji) \(confidence.percentage)%")
            
            // Log warning if confidence is not high
            if confidence.rating == .medium {
                logger.logWarning("Medium confidence - user should review the results")
            } else if confidence.rating == .low {
                logger.logError("Low confidence - results may be unreliable")
            }
            
            return receipt
        } else {
            logger.logWarning("Failed to parse with \(match.storeName) parser despite confident detection")
            return tryGenericParser(text)
        }
    }
    
    /// Parse receipt with confidence scoring (returns detailed result)
    func parseReceiptWithConfidence(from text: String) -> ParsedReceiptWithConfidence? {
        guard let match = smartDetector.detect(from: text),
              let receipt = match.parser.parse(from: text) else {
            return nil
        }
        
        let confidence = confidenceScorer.score(receipt, ocrText: text, storeConfidence: match.confidence)
        
        // Collect issues
        var issues: [String] = []
        
        // Add confidence-based issues
        if confidence.rating == .low {
            issues.append("Low parsing confidence (\(confidence.percentage)%)")
        }
        
        // Add factor-specific issues
        if let productCountScore = confidence.factors["product_count"], productCountScore < 0.7 {
            issues.append("Unusual product count: \(receipt.products.count)")
        }
        
        if let totalScore = confidence.factors["total_consistency"], totalScore < 0.7 {
            let sum = receipt.products.map(\.price).reduce(0, +)
            issues.append("Total mismatch: €\(String(format: "%.2f", receipt.total)) vs sum €\(String(format: "%.2f", sum))")
        }
        
        return ParsedReceiptWithConfidence(
            receipt: receipt,
            confidence: confidence,
            issues: issues
        )
    }
    
    private func tryGenericParser(_ text: String) -> ParsedReceipt? {
        let logger = ReceiptDebugLogger.shared
        logger.logWarning("Attempting generic fallback parser...")
        
        let genericParser = GenericReceiptParser()
        if let receipt = genericParser.parse(from: text) {
            logger.logSuccess("Generic parser succeeded")
            logger.log("Parsed \(receipt.products.count) products, total: €\(String(format: "%.2f", receipt.total))")
            return receipt
        }
        
        logger.logError("All parsers failed, including generic fallback")
        return nil
    }
}

// MARK: - Confidence Scoring System

/// Receipt parsing result with confidence score
struct ParsedReceiptWithConfidence {
    let receipt: ParsedReceipt
    let confidence: ReceiptConfidence
    let issues: [String]
}

/// Confidence score breakdown
struct ReceiptConfidence {
    let overall: Float  // 0.0 - 1.0
    let factors: [String: Float]
    
    var rating: ConfidenceRating {
        switch overall {
        case 0.8...1.0: return .high
        case 0.5..<0.8: return .medium
        default: return .low
        }
    }
    
    var percentage: Int {
        Int(overall * 100)
    }
}

/// Confidence rating levels
enum ConfidenceRating {
    case high    // ✅ Green - Use automatically
    case medium  // ⚠️ Orange - Ask user to review
    case low     // ❌ Red - Needs manual correction
    
    var emoji: String {
        switch self {
        case .high: return "✅"
        case .medium: return "⚠️"
        case .low: return "❌"
        }
    }
    
    var description: String {
        switch self {
        case .high: return "High confidence - Ready to use"
        case .medium: return "Medium confidence - Please review"
        case .low: return "Low confidence - Manual correction needed"
        }
    }
}

/// Receipt confidence scorer
class ReceiptConfidenceScorer {
    private let logger = ReceiptDebugLogger.shared
    
    /// Calculate confidence score for a parsed receipt
    func score(_ receipt: ParsedReceipt, ocrText: String, storeConfidence: Float = 1.0) -> ReceiptConfidence {
        logger.section("CONFIDENCE SCORING")
        
        var factors: [String: Float] = [:]
        var issues: [String] = []
        
        // Factor 1: Product count (receipts rarely have <2 or >100 items)
        let productCount = receipt.products.count
        let productCountScore: Float
        if productCount >= 2 && productCount <= 100 {
            productCountScore = 1.0
        } else if productCount == 1 {
            productCountScore = 0.6
            issues.append("Only 1 product found - unusual for a receipt")
        } else if productCount > 100 {
            productCountScore = 0.4
            issues.append("Over 100 products - possible parsing error")
        } else {
            productCountScore = 0.2
            issues.append("No products found")
        }
        factors["product_count"] = productCountScore
        
        // Factor 2: Price validity (all prices > 0, reasonable range)
        let validPrices = receipt.products.filter { $0.price > 0 && $0.price < 1000 }.count
        let priceValidityScore = productCount > 0 ? Float(validPrices) / Float(productCount) : 0.0
        factors["price_validity"] = priceValidityScore
        
        if validPrices < productCount {
            let invalidCount = productCount - validPrices
            issues.append("\(invalidCount) product(s) with invalid prices")
        }
        
        // Factor 3: Total consistency (sum of items ≈ total)
        let itemsSum = receipt.products.map(\.price).reduce(0, +)
        let totalDiff = abs(itemsSum - receipt.total)
        let tolerance = max(receipt.total * 0.15, 0.5)  // 15% tolerance or €0.50
        let totalConsistencyScore: Float
        
        if receipt.total == 0.0 {
            totalConsistencyScore = 0.3
            issues.append("Total is €0.00")
        } else if totalDiff < tolerance {
            totalConsistencyScore = 1.0
        } else if totalDiff < tolerance * 2 {
            totalConsistencyScore = 0.7
            issues.append("Total differs from sum by €\(String(format: "%.2f", totalDiff))")
        } else {
            totalConsistencyScore = 0.4
            issues.append("Total (€\(String(format: "%.2f", receipt.total))) doesn't match sum (€\(String(format: "%.2f", itemsSum)))")
        }
        factors["total_consistency"] = totalConsistencyScore
        
        // Factor 4: Store detection confidence
        let storeDetectionScore: Float
        if receipt.storeName.uppercased() != "UNKNOWN" && receipt.storeName.uppercased() != "GENERIC" {
            storeDetectionScore = storeConfidence
        } else {
            storeDetectionScore = 0.3
            issues.append("Store not identified")
        }
        factors["store_detection"] = storeDetectionScore
        
        // Factor 5: OCR quality (check for garbled text)
        let garbledRatio = calculateGarbledTextRatio(ocrText)
        let ocrQualityScore = 1.0 - garbledRatio
        factors["ocr_quality"] = ocrQualityScore
        
        if garbledRatio > 0.3 {
            issues.append("High noise in OCR text (\(Int(garbledRatio * 100))% special chars)")
        }
        
        // Factor 6: Product name quality
        let productNames = receipt.products.map { $0.name }
        let avgNameLength = productNames.isEmpty ? 0 : productNames.map { $0.count }.reduce(0, +) / productNames.count
        let nameQualityScore: Float
        
        if avgNameLength > 3 && avgNameLength < 50 {
            nameQualityScore = 1.0
        } else if avgNameLength <= 3 {
            nameQualityScore = 0.4
            issues.append("Product names too short (avg: \(avgNameLength) chars)")
        } else {
            nameQualityScore = 0.6
            issues.append("Product names unusually long (avg: \(avgNameLength) chars)")
        }
        factors["name_quality"] = nameQualityScore
        
        // Factor 7: Date validity
        let dateScore: Float
        let now = Date()
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        
        if receipt.date > oneYearAgo && receipt.date < tomorrow {
            dateScore = 1.0
        } else if receipt.date < oneYearAgo {
            dateScore = 0.5
            issues.append("Receipt date is over 1 year old")
        } else {
            dateScore = 0.3
            issues.append("Receipt date is in the future")
        }
        factors["date_validity"] = dateScore
        
        // Calculate weighted average
        let weights: [String: Float] = [
            "product_count": 0.12,
            "price_validity": 0.18,
            "total_consistency": 0.25,
            "store_detection": 0.15,
            "ocr_quality": 0.12,
            "name_quality": 0.10,
            "date_validity": 0.08
        ]
        
        var overall: Float = 0.0
        for (key, value) in factors {
            overall += value * (weights[key] ?? 0.0)
        }
        
        let confidence = ReceiptConfidence(overall: overall, factors: factors)
        
        logger.log("Overall confidence: \(confidence.rating.emoji) \(String(format: "%.1f%%", overall * 100)) (\(confidence.rating.description))")
        logger.logDebug("Factor breakdown:")
        for (key, value) in factors.sorted(by: { $0.key < $1.key }) {
            logger.logDebug("  \(key): \(String(format: "%.2f", value))")
        }
        
        if !issues.isEmpty {
            logger.logWarning("Issues found:")
            for issue in issues {
                logger.logWarning("  - \(issue)")
            }
        }
        
        return confidence
    }
    
    /// Calculate ratio of garbled/special characters
    private func calculateGarbledTextRatio(_ text: String) -> Float {
        let totalChars = text.count
        guard totalChars > 0 else { return 0.0 }
        
        // Count problematic patterns
        var issueCount = 0
        
        // Excessive special characters (excluding normal punctuation)
        let normalChars = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".,€$£¥-/()"))
        let specialChars = text.unicodeScalars.filter { !normalChars.contains($0) }.count
        issueCount += specialChars
        
        // Nonsense patterns
        let nonsensePatterns = ["###", "|||", "___", "...", "***", "```"]
        for pattern in nonsensePatterns {
            issueCount += text.components(separatedBy: pattern).count - 1
        }
        
        return min(Float(issueCount) / Float(totalChars), 1.0)
    }
}

// MARK: - Array Extension for Average

extension Array where Element == Int {
    var average: Double {
        isEmpty ? 0 : Double(reduce(0, +)) / Double(count)
    }
}

extension Array where Element == Float {
    var average: Float {
        isEmpty ? 0 : reduce(0, +) / Float(count)
    }
}

// MARK: - Base Parser Helper

class BaseReceiptParser {
    let logger = ReceiptDebugLogger.shared
    
    func preprocess(_ text: String) -> [String] {
        return text
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    func parsePrice(_ str: String) -> Double {
        let normalized = str
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(normalized) ?? 0.0
    }
    
    func cleanProductName(_ name: String) -> String {
        var cleaned = name
        
        // Remove common patterns
        cleaned = cleaned.replacingOccurrences(
            of: #"\d+[\.,]?\d*\s*(G|KG|L|ML|CL|ST|STK|PCE|PCS|X)(?:\s|$)"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        
        return cleaned.isEmpty ? "Article" : cleaned
    }
    
    /// Filter out non-food items (cleaning, hygiene, household products)
    func isFoodItem(_ name: String) -> Bool {
        let lower = name.lowercased()
        
        // Non-food keywords (German + French)
        let nonFoodKeywords = [
            // Cleaning products
            "waschmittel", "spülmittel", "reiniger", "lessive", "nettoyant", "détergent",
            "putzmittel", "weichspüler", "entkalker", "javel", "ajax",
            // Hygiene products
            "shampoo", "duschgel", "seife", "zahnpasta", "deo", "deodorant",
            "creme", "crème", "lotion", "gel douche", "savon", "dentifrice",
            "kosmetik", "parfum", "maquillage", "rouge", "mascara",
            // Household items
            "müllbeutel", "alufolie", "frischhaltefolie", "papier", "serviette",
            "sac poubelle", "aluminium", "film alimentaire", "essuie-tout",
            "toilettenpapier", "küchenpapier", "papier toilette", "sopalin",
            // Other non-food
            "batterie", "glühbirne", "kerze", "ampoule", "pile", "bougie",
            "blumen", "fleur", "zeitschrift", "magazine"
        ]
        
        // Check if item contains non-food keywords
        for keyword in nonFoodKeywords {
            if lower.contains(keyword) {
                return false
            }
        }
        
        return true
    }
    
    func extractDate(from lines: [String], formats: [String]) -> Date {
        for line in lines.prefix(20) {
            for format in formats {
                let pattern = format
                    .replacingOccurrences(of: "dd", with: #"(\d{2})"#)
                    .replacingOccurrences(of: "MM", with: #"(\d{2})"#)
                    .replacingOccurrences(of: "yyyy", with: #"(\d{4})"#)
                    .replacingOccurrences(of: "yy", with: #"(\d{2})"#)
                    .replacingOccurrences(of: "HH", with: #"(\d{2})"#)
                    .replacingOccurrences(of: "mm", with: #"(\d{2})"#)
                
                if let match = line.range(of: pattern, options: .regularExpression) {
                    let dateStr = String(line[match])
                    let formatter = DateFormatter()
                    formatter.dateFormat = format
                    if let date = formatter.date(from: dateStr) {
                        return date
                    }
                }
            }
        }
        return Date()
    }
}

// MARK: - ========== GERMAN STORE PARSERS ==========

// ✅ ROBUST ALDI PARSER
final class AldiParser: BaseReceiptParser, StoreReceiptParser {
    var storeName: String = "ALDI"
    
    func canParse(_ text: String) -> Bool {
        let detector = SmartStoreDetector()
        let match = detector.detect(from: text)
        return match?.store == .aldiSued || match?.store == .aldiNord
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("ALDI PARSER - ROBUST")
        
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        logger.log("Processing \(lines.count) lines")
        
        // Extract all article numbers and product names
        var products: [ParsedProduct] = []
        
        // Pattern: Look for 6-digit article numbers
        let articlePattern = try! NSRegularExpression(pattern: #"\b(\d{6})\b"#)
        
        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            let matches = articlePattern.matches(in: line, range: nsRange)
            
            for match in matches {
                guard let articleRange = Range(match.range(at: 1), in: line) else { continue }
                
                let articleNumber = String(line[articleRange])
                
                // Extract product name after article number
                let afterArticle = String(line[line.index(articleRange.upperBound, offsetBy: 0, limitedBy: line.endIndex) ?? line.endIndex...])
                
                // Product name is the text until next article number or price
                var productName = ""
                
                if let nextMatch = articlePattern.firstMatch(
                    in: afterArticle, 
                    range: NSRange(afterArticle.startIndex..., in: afterArticle)
                ) {
                    // Stop at next article number
                    if let range = Range(nextMatch.range, in: afterArticle) {
                        productName = String(afterArticle[..<range.lowerBound])
                    }
                } else {
                    // Take everything until a price pattern
                    if let priceRange = afterArticle.range(of: #"\d{1,3}[,.]\d{2}"#, options: .regularExpression) {
                        productName = String(afterArticle[..<priceRange.lowerBound])
                    } else {
                        productName = afterArticle
                    }
                }
                
                productName = cleanProductName(productName)
                
                // Skip if name is too short or looks wrong
                guard productName.count > 2, !productName.contains("Kartennr") else {
                    continue
                }
                
                // Find price for this product
                var price: Double = 0.0
                
                // Look in current line and next few lines
                let searchLines = [line] + lines.dropFirst(lines.firstIndex(of: line) ?? 0).prefix(3)
                
                for searchLine in searchLines {
                    // Look for standalone price pattern
                    if let priceMatch = searchLine.range(of: #"\b(\d{1,3}[,.]\d{2})\b"#, options: .regularExpression) {
                        let priceStr = String(searchLine[priceMatch])
                        let potentialPrice = parsePrice(priceStr)
                        
                        // Reasonable price range for groceries
                        if potentialPrice > 0.1 && potentialPrice < 100.0 {
                            price = potentialPrice
                            break
                        }
                    }
                }
                
                if price > 0 {
                    let section = ProductClassifier.shared.guessSection(for: productName)
                    
                    products.append(ParsedProduct(
                        rawLine: line,
                        name: productName,
                        price: price,
                        section: section
                    ))
                    
                    logger.logDebug("✓ [\(articleNumber)] \(productName) - €\(String(format: "%.2f", price))")
                }
            }
        }
        
        // Extract date
        let date = extractDate(from: lines)
        
        // Extract total
        var total = extractTotal(from: lines)
        
        // If no total found, sum products
        if total == 0.0 {
            total = products.map(\.price).reduce(0, +)
        }
        
        // Remove duplicates (same article number + price)
        products = removeDuplicates(products)
        
        logger.logSuccess("Parsed \(products.count) products, total: €\(String(format: "%.2f", total))")
        
        guard !products.isEmpty else {
            logger.logError("No products found")
            return nil
        }
        
        return ParsedReceipt(
            storeName: "ALDI SÜD",
            date: date,
            total: total,
            products: products
        )
    }
    
    private func removeDuplicates(_ products: [ParsedProduct]) -> [ParsedProduct] {
        var seen: Set<String> = []
        var unique: [ParsedProduct] = []
        
        for product in products {
            let key = "\(product.name)_\(product.price)"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(product)
            }
        }
        
        return unique
    }
    
    private func extractDate(from lines: [String]) -> Date {
        for line in lines {
            if let match = line.range(of: #"\d{2}\.\d{2}\.\d{2,4}"#, options: .regularExpression) {
                let dateStr = String(line[match])
                let formatter = DateFormatter()
                formatter.dateFormat = dateStr.count > 8 ? "dd.MM.yyyy" : "dd.MM.yy"
                
                if let date = formatter.date(from: dateStr) {
                    logger.log("Found date: \(dateStr)")
                    return date
                }
            }
        }
        return Date()
    }
    
    private func extractTotal(from lines: [String]) -> Double {
        // Look for "Betrag" or "SUMME"
        for line in lines.reversed() {  // Start from bottom
            if line.uppercased().contains("BETRAG") || line.uppercased().contains("SUMME") {
                if let match = line.range(of: #"\d{1,3}[,.]\d{2}"#, options: .regularExpression) {
                    let total = parsePrice(String(line[match]))
                    logger.log("Found total: €\(String(format: "%.2f", total))")
                    return total
                }
            }
        }
        return 0.0
    }
    
    private func parsePrice(_ str: String) -> Double {
        let normalized = str.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0.0
    }
    
    private func cleanProductName(_ name: String) -> String {
        var cleaned = name
        
        // Remove article numbers that snuck in
        cleaned = cleaned.replacingOccurrences(of: #"\b\d{6}\b"#, with: "", options: .regularExpression)
        
        // Remove prices that snuck in
        cleaned = cleaned.replacingOccurrences(of: #"\d{1,3}[,.]\d{2}"#, with: "", options: .regularExpression)
        
        // Remove weight/quantity indicators
        cleaned = cleaned.replacingOccurrences(of: #"\d+\s*(g|kg|ml|l|x)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        
        // Remove extra whitespace
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Lidl Parser

final class LidlParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "LIDL"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("LIDL")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("LIDL PARSER")
        let lines = preprocess(text)
        
        let date = extractDate(from: lines, formats: ["dd.MM.yy HH:mm", "dd/MM/yyyy HH:mm"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        var end: Int?
        
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+,\d{2}$"#, options: .regularExpression) != nil {
                let isHeader = ["FILIALE", "STRASSE", "TEL", "MWST"].contains(where: { line.uppercased().contains($0) })
                if !isHeader {
                    start = i
                    break
                }
            }
        }
        
        guard let s = start else { return nil }
        
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("SUMME") || lines[i].uppercased().contains("GESAMT") {
                end = i
                break
            }
        }
        
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        
        for line in lines {
            // Lidl format: "PRODUCT NAME    3,99"
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+,\d{2})$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            let line = lines[i]
            if line.uppercased().contains("SUMME") || line.uppercased().contains("GESAMT") {
                if let match = line.range(of: #"(\d+,\d{2})"#, options: .regularExpression) {
                    return parsePrice(String(line[match]))
                }
            }
        }
        return 0.0
    }
}

// MARK: - Rewe Parser

final class ReweParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "REWE"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("REWE")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("REWE PARSER")
        
        let lines = text.components(separatedBy: .newlines)
        
        // Date extraction
        let date = extractDate(from: lines, formats: ["dd.MM.yyyy HH:mm", "dd.MM.yy HH:mm"])
        
        // Regex for basic pattern: Product + Price (optionally followed by A/B)
        let productRegex = try! NSRegularExpression(
            pattern: #"([A-ZÄÖÜa-zäöüß0-9\-\.\s\/]+?)\s+(\d{1,3},\d{2})\s?[AB]?"#,
            options: []
        )
        
        // Regex for quantities like "0,89 x 4 = 3,56" or "x3"
        let quantityRegex = try! NSRegularExpression(
            pattern: #"(\d{1,3},\d{2})\s?[xX]\s?(\d+)\s?[=]?\s?(\d{0,3},?\d{0,2})?"#,
            options: []
        )
        
        var products: [ParsedProduct] = []
        var lastProduct: String? = nil
        
        for line in lines {
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            let cleanLine = line
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "Â", with: "")
                .replacingOccurrences(of: "·", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !cleanLine.isEmpty else { continue }
            
            // Step 1: Detect lines with quantities
            if let match = quantityRegex.firstMatch(in: cleanLine, range: nsRange) {
                guard let unitR = Range(match.range(at: 1), in: cleanLine),
                      let qtyR = Range(match.range(at: 2), in: cleanLine) else { continue }
                
                let unitStr = String(cleanLine[unitR]).replacingOccurrences(of: ",", with: ".")
                let qty = Int(String(cleanLine[qtyR])) ?? 1
                let unitPrice = Double(unitStr) ?? 0.0
                
                var total = unitPrice * Double(qty)
                
                // If there's an explicit total in the match, use it
                if let totalR = Range(match.range(at: 3), in: cleanLine) {
                    let totalStr = String(cleanLine[totalR]).replacingOccurrences(of: ",", with: ".")
                    if !totalStr.isEmpty, let totalVal = Double(totalStr) {
                        total = totalVal
                    }
                }
                
                if let name = lastProduct {
                    // Only add food items
                    guard isFoodItem(name) else {
                        lastProduct = nil
                        continue
                    }
                    
                    let productName = qty > 1 ? "\(name) (\(qty)x)" : name
                    let item = ParsedProduct(
                        rawLine: cleanLine,
                        name: productName,
                        price: total,
                        section: categorize(name)
                    )
                    products.append(item)
                    lastProduct = nil
                }
                continue
            }
            
            // Step 2: Simple lines Product + Price
            let matches = productRegex.matches(in: cleanLine, range: nsRange)
            if matches.isEmpty {
                // If it's a descriptive line, keep it for later
                lastProduct = cleanLine
                continue
            }
            
            for match in matches {
                guard let nameR = Range(match.range(at: 1), in: cleanLine),
                      let priceR = Range(match.range(at: 2), in: cleanLine) else { continue }
                
                let name = String(cleanLine[nameR])
                    .replacingOccurrences(of: "€", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                let priceStr = String(cleanLine[priceR])
                    .replacingOccurrences(of: ",", with: ".")
                let price = Double(priceStr) ?? 0.0
                
                // Only add food items
                guard isFoodItem(name) else { continue }
                
                let item = ParsedProduct(
                    rawLine: cleanLine,
                    name: name,
                    price: price,
                    section: categorize(name)
                )
                products.append(item)
                lastProduct = name
            }
        }
        
        // Extract total
        var total = 0.0
        if let totalLine = lines.first(where: {
            $0.localizedCaseInsensitiveContains("ZU ZAHLEN") ||
            $0.localizedCaseInsensitiveContains("GESAMT") ||
            $0.localizedCaseInsensitiveContains("SUMME") ||
            $0.localizedCaseInsensitiveContains("BAR") ||
            $0.localizedCaseInsensitiveContains("KARTE")
        }),
        let match = totalLine.range(of: #"(\d{1,3},\d{2})"#, options: .regularExpression) {
            let totalStr = String(totalLine[match]).replacingOccurrences(of: ",", with: ".")
            total = Double(totalStr) ?? 0.0
        }
        
        guard !products.isEmpty else { return nil }
        
        return ParsedReceipt(
            storeName: storeName,
            date: date,
            total: total,
            products: products
        )
    }
    
    /// Categorize products based on keywords
    private func categorize(_ name: String) -> ProductSection {
        let lower = name.lowercased()
        
        // Skip PFAND (deposit) items
        if lower.contains("pfand") { return .unknown }
        
        // Fridge items
        if lower.contains("milch") || lower.contains("joghurt") ||
            lower.contains("käse") || lower.contains("butter") ||
            lower.contains("quark") || lower.contains("sahne") ||
            lower.contains("fleisch") || lower.contains("hähnchen") ||
            lower.contains("lachs") || lower.contains("wurst") ||
            lower.contains("schinken") {
            return .fridge
        }
        
        // Freezer items
        if lower.contains("eis") || lower.contains("tiefkühl") ||
            lower.contains("tk ") || lower.contains("frozen") {
            return .freezer
        }
        
        // Pantry items
        if lower.contains("brot") || lower.contains("mehl") ||
            lower.contains("pudding") || lower.contains("riegel") ||
            lower.contains("kaffee") || lower.contains("cola") ||
            lower.contains("wasser") || lower.contains("tee") ||
            lower.contains("apfel") || lower.contains("tomate") ||
            lower.contains("salat") || lower.contains("gurke") ||
            lower.contains("pasta") || lower.contains("nudeln") ||
            lower.contains("reis") || lower.contains("zucker") {
            return .pantry
        }
        
        return .unknown
    }
}

// MARK: - Edeka Parser

final class EdekaParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "EDEKA"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("EDEKA")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("EDEKA PARSER")
        
        let lines = text.components(separatedBy: .newlines)
        
        // Date extraction
        let date = extractDate(from: lines, formats: ["dd.MM.yyyy", "dd.MM.yy HH:mm"])
        
        // Regex for standard pattern: Product + Price
        let priceRegex = try! NSRegularExpression(
            pattern: #"([A-ZÄÖÜa-zäöüß0-9\-\.\s\/]+?)\s+(\d{1,3},\d{2})\s?[AB]?"#,
            options: []
        )
        
        // Regex for quantity lines (e.g., "0,89 x 3 = 2,67")
        let quantityRegex = try! NSRegularExpression(
            pattern: #"(\d{1,3},\d{2})\s?[xX]\s?(\d+)\s?[=]\s?(\d{1,3},\d{2})"#,
            options: []
        )
        
        // Patterns to ignore (subtotals, taxes, etc.)
        let ignorePatterns = [
            "Summe", "Gesamt", "MwSt", "Pfand", "USt", "Netto", "Zwischensumme"
        ]
        
        var products: [ParsedProduct] = []
        var lastProductName: String? = nil
        
        for line in lines {
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            let cleanLine = line
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "Â", with: "")
                .replacingOccurrences(of: "·", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !cleanLine.isEmpty else { continue }
            
            // Ignore subtotal lines
            if ignorePatterns.contains(where: { cleanLine.localizedCaseInsensitiveContains($0) }) {
                continue
            }
            
            // Ignore header or footer lines
            if cleanLine.contains("EDEKA") ||
                cleanLine.contains("GmbH") ||
                cleanLine.contains("Filiale") ||
                cleanLine.contains("Uhr") ||
                cleanLine.contains("Datum") {
                continue
            }
            
            // Step 1: Lines with quantity
            if let match = quantityRegex.firstMatch(in: cleanLine, range: nsRange) {
                guard let _ = Range(match.range(at: 1), in: cleanLine),
                      let qtyR = Range(match.range(at: 2), in: cleanLine),
                      let totalR = Range(match.range(at: 3), in: cleanLine) else { continue }
                
                let qty = Int(String(cleanLine[qtyR])) ?? 1
                let totalStr = String(cleanLine[totalR]).replacingOccurrences(of: ",", with: ".")
                let total = Double(totalStr) ?? 0.0
                
                if let name = lastProductName {
                    // Only add food items
                    guard isFoodItem(name) else {
                        lastProductName = nil
                        continue
                    }
                    
                    let productName = qty > 1 ? "\(name) (\(qty)x)" : name
                    let item = ParsedProduct(
                        rawLine: cleanLine,
                        name: productName,
                        price: total,
                        section: categorize(name)
                    )
                    products.append(item)
                    lastProductName = nil
                }
                continue
            }
            
            // Step 2: Simple lines (product + price)
            let matches = priceRegex.matches(in: cleanLine, range: nsRange)
            if matches.isEmpty {
                // If line contains only a product code (e.g., "205488"), ignore it
                if cleanLine.trimmingCharacters(in: .whitespaces).count < 5 { continue }
                
                // Otherwise, keep the name for the next line
                lastProductName = cleanLine
                continue
            }
            
            for match in matches {
                guard let nameR = Range(match.range(at: 1), in: cleanLine),
                      let priceR = Range(match.range(at: 2), in: cleanLine) else { continue }
                
                let name = String(cleanLine[nameR])
                    .replacingOccurrences(of: "€", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                let priceStr = String(cleanLine[priceR])
                    .replacingOccurrences(of: ",", with: ".")
                let price = Double(priceStr) ?? 0.0
                
                // Only add food items
                guard isFoodItem(name) else { continue }
                
                let item = ParsedProduct(
                    rawLine: cleanLine,
                    name: name,
                    price: price,
                    section: categorize(name)
                )
                products.append(item)
                lastProductName = name
            }
        }
        
        // Extract total
        var total = 0.0
        if let totalLine = lines.first(where: {
            $0.localizedCaseInsensitiveContains("ZU ZAHLEN") ||
            $0.localizedCaseInsensitiveContains("GESAMT") ||
            $0.localizedCaseInsensitiveContains("SUMME")
        }),
        let match = totalLine.range(of: #"(\d{1,3},\d{2})"#, options: .regularExpression) {
            let totalString = String(totalLine[match])
                .replacingOccurrences(of: ",", with: ".")
            total = Double(totalString) ?? 0.0
        }
        
        guard !products.isEmpty else { return nil }
        
        return ParsedReceipt(
            storeName: storeName,
            date: date,
            total: total,
            products: products
        )
    }
    
    /// Categorize products by keywords for inventory
    private func categorize(_ name: String) -> ProductSection {
        let lower = name.lowercased()
        
        // Skip PFAND (deposit) items
        if lower.contains("pfand") { return .unknown }
        
        // Fridge items
        if lower.contains("milch") || lower.contains("joghurt") ||
            lower.contains("käse") || lower.contains("butter") ||
            lower.contains("quark") || lower.contains("sahne") ||
            lower.contains("hähnchen") || lower.contains("fleisch") ||
            lower.contains("lachs") || lower.contains("wurst") ||
            lower.contains("schinken") {
            return .fridge
        }
        
        // Freezer items
        if lower.contains("eis") || lower.contains("tiefkühl") ||
            lower.contains("tk ") || lower.contains("frozen") {
            return .freezer
        }
        
        // Pantry items
        if lower.contains("brot") || lower.contains("pudding") ||
            lower.contains("riegel") || lower.contains("mehl") ||
            lower.contains("kaffee") || lower.contains("cola") ||
            lower.contains("tee") || lower.contains("wasser") ||
            lower.contains("apfel") || lower.contains("banane") ||
            lower.contains("salat") || lower.contains("tomate") ||
            lower.contains("pasta") || lower.contains("nudeln") ||
            lower.contains("reis") || lower.contains("zucker") {
            return .pantry
        }
        
        return .unknown
    }
}

// MARK: - Penny Parser

final class PennyParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "PENNY"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("PENNY")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("PENNY PARSER")
        // Similar to Rewe format
        let lines = preprocess(text)
        let date = extractDate(from: lines, formats: ["dd.MM.yy HH:mm"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+,\d{2}\s*[AB]?$"#, options: .regularExpression) != nil {
                start = i
                break
            }
        }
        guard let s = start else { return nil }
        
        var end: Int?
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("SUMME") {
                end = i
                break
            }
        }
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+,\d{2})\s*[AB]?$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else { continue }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            if lines[i].uppercased().contains("SUMME"),
               let match = lines[i].range(of: #"(\d+,\d{2})"#, options: .regularExpression) {
                return parsePrice(String(lines[i][match]))
            }
        }
        return 0.0
    }
}

// MARK: - Netto Parser

final class NettoParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "NETTO"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("NETTO")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("NETTO PARSER")
        let lines = preprocess(text)
        let date = extractDate(from: lines, formats: ["dd.MM.yy HH:mm"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+,\d{2}$"#, options: .regularExpression) != nil {
                start = i
                break
            }
        }
        guard let s = start else { return nil }
        
        var end: Int?
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("SUMME") {
                end = i
                break
            }
        }
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+,\d{2})$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else { continue }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            if lines[i].uppercased().contains("SUMME"),
               let match = lines[i].range(of: #"(\d+,\d{2})"#, options: .regularExpression) {
                return parsePrice(String(lines[i][match]))
            }
        }
        return 0.0
    }
}

// MARK: - ========== FRENCH STORE PARSERS ==========

// MARK: - Carrefour Parser

final class CarrefourParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "CARREFOUR"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("CARREFOUR")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("CARREFOUR PARSER")
        
        let lines = text.components(separatedBy: .newlines)
        
        // Date extraction
        let date = extractDate(from: lines, formats: ["dd/MM/yyyy HH:mm", "dd/MM/yy"])
        
        // Regex for product + price (French format)
        let productRegex = try! NSRegularExpression(
            pattern: #"([A-Z0-9À-ÿ\.\-\s\/]+?)\s+(\d{1,3},\d{2})"#,
            options: []
        )
        
        // Lines to ignore
        let ignore = [
            "TOTAL", "ALIMENTAIRE", "NON ALIMENTAIRE",
            "DIVERS", "REMIS", "IMMEDIATE", "BEAUTÉ",
            "ENTRETIEN", "CARREFOUR", "BONUS", "COUPON",
            "TEL", "FLINS", "LEBONCOIN"
        ]
        
        var products: [ParsedProduct] = []
        var isInFoodSection = true // Start assuming food section
        
        for line in lines {
            let clean = line
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            
            guard !clean.isEmpty else { continue }
            
            // 🔹 Section detection - ONLY process food sections
            if clean.contains("ALIMENTAIRE") {
                isInFoodSection = true
                continue
            }
            if clean.contains("ENTRETIEN") || clean.contains("BEAUT") || 
               clean.contains("NON ALIMENTAIRE") || clean.contains("DIVERS") {
                isInFoodSection = false // Skip non-food sections
                continue
            }
            
            // 🔹 Skip if we're in a non-food section
            guard isInFoodSection else { continue }
            
            // 🔹 Ignore useless lines
            if ignore.contains(where: { clean.contains($0) }) { continue }
            
            // 🔹 Product + price detection
            let range = NSRange(location: 0, length: clean.utf16.count)
            let matches = productRegex.matches(in: clean, range: range)
            
            for match in matches {
                guard let nameRange = Range(match.range(at: 1), in: clean),
                      let priceRange = Range(match.range(at: 2), in: clean) else { continue }
                
                var name = String(clean[nameRange])
                    .replacingOccurrences(of: "Â", with: "")
                    .replacingOccurrences(of: "€", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                // Clean the name
                name = cleanProductName(name)
                
                let priceStr = String(clean[priceRange])
                    .replacingOccurrences(of: ",", with: ".")
                let price = Double(priceStr) ?? 0.0
            
            guard price > 0, name.count > 2 else { continue }
            
                // Only add food items
                guard isFoodItem(name) else { continue }
                
                // Classify food items into appropriate sections
            let section = ProductClassifier.shared.guessSection(for: name)
                
                products.append(
                    ParsedProduct(rawLine: line, name: name, price: price, section: section)
                )
            }
        }
        
        // 🔹 Extract total
        var total = 0.0
        if let totalLine = lines.first(where: { $0.uppercased().contains("TOTAL") }),
           let match = totalLine.range(of: #"(\d{1,3},\d{2})"#, options: .regularExpression) {
            let totalStr = String(totalLine[match]).replacingOccurrences(of: ",", with: ".")
            total = Double(totalStr) ?? 0.0
        }
        
        // If no total detected, sum up the prices
        if total == 0 {
            total = products.map { $0.price }.reduce(0, +)
        }
        
        guard !products.isEmpty else { return nil }
        
        return ParsedReceipt(
            storeName: storeName,
            date: date,
            total: total,
            products: products
        )
    }
}

// MARK: - E.Leclerc Parser

final class LeclercParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "E.LECLERC"
    
    func canParse(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("LECLERC") || upper.contains("E.LECLERC")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("LECLERC PARSER")
        let lines = preprocess(text)
        
        let date = extractDate(from: lines, formats: ["dd/MM/yyyy HH:mm:ss", "dd/MM/yy HH:mm"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        var end: Int?
        
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) != nil {
                let isHeader = ["MAGASIN", "AVENUE", "RUE", "TEL"].contains(where: { line.uppercased().contains($0) })
                if !isHeader {
                    start = i
                    break
                }
            }
        }
        
        guard let s = start else { return nil }
        
        for i in (s + 1)..<lines.count {
            let upper = lines[i].uppercased()
            if upper.contains("TOTAL") || upper.contains("SOUS-TOTAL") || upper.contains("CB") {
                end = i
                break
            }
        }
        
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        var i = 0
        
        while i < lines.count {
            let line = lines[i]
            
            // Leclerc sometimes has multi-line products
            // Line 1: "PRODUIT NAME"
            // Line 2: "1.000 kg x 2.50    2.50"
            if line.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) == nil {
                // This might be a product name line
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1]
                    if let product = parseMultiLineProduct(nameLine: line, priceLine: nextLine) {
                        products.append(product)
                        i += 2
                        continue
                    }
                }
            }
            
            // Single line product
            if let product = parseSingleLine(line) {
                products.append(product)
            }
            
            i += 1
        }
        
        return products
    }
    
    private func parseMultiLineProduct(nameLine: String, priceLine: String) -> ParsedProduct? {
        // Check if priceLine has quantity and price
        guard priceLine.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        
        let name = cleanProductName(nameLine)
        
        guard let priceMatch = priceLine.range(of: #"(\d+[,.]\d{2})$"#, options: .regularExpression) else {
            return nil
        }
        
        let price = parsePrice(String(priceLine[priceMatch]))
        
        guard price > 0, name.count > 2 else { return nil }
        
        let section = ProductClassifier.shared.guessSection(for: name)
        return ParsedProduct(rawLine: "\(nameLine) + \(priceLine)", name: name, price: price, section: section)
    }
    
    private func parseSingleLine(_ line: String) -> ParsedProduct? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+[,.]\d{2})$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line),
              let priceRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        
        let name = cleanProductName(String(line[nameRange]))
        let price = parsePrice(String(line[priceRange]))
        
        guard price > 0, name.count > 2 else { return nil }
        
        let section = ProductClassifier.shared.guessSection(for: name)
        return ParsedProduct(rawLine: line, name: name, price: price, section: section)
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            let line = lines[i]
            if line.uppercased().contains("TOTAL") {
                if let match = line.range(of: #"(\d+[,.]\d{2})"#, options: .regularExpression) {
                    return parsePrice(String(line[match]))
                }
            }
        }
        return 0.0
    }
}

// MARK: - Intermarché Parser

final class IntermarcheParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "INTERMARCHÉ"
    
    func canParse(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("INTERMARCHE") || upper.contains("INTERMARCHÉ")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("INTERMARCHÉ PARSER")
        let lines = preprocess(text)
        
        let date = extractDate(from: lines, formats: ["dd/MM/yyyy HH:mm", "dd/MM/yy"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        var end: Int?
        
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) != nil {
                let isHeader = ["MAGASIN", "RUE", "TEL", "SIRET"].contains(where: { line.uppercased().contains($0) })
                if !isHeader {
                    start = i
                    break
                }
            }
        }
        
        guard let s = start else { return nil }
        
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("TOTAL") || lines[i].uppercased().contains("TTC") {
                end = i
                break
            }
        }
        
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+[,.]\d{2})$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            let line = lines[i]
            if line.uppercased().contains("TOTAL") {
                if let match = line.range(of: #"(\d+[,.]\d{2})"#, options: .regularExpression) {
                    return parsePrice(String(line[match]))
                }
            }
        }
        return 0.0
    }
}

// MARK: - Auchan Parser

final class AuchanParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "AUCHAN"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("AUCHAN")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("AUCHAN PARSER")
        let lines = preprocess(text)
        
        let date = extractDate(from: lines, formats: ["dd/MM/yyyy HH:mm", "dd/MM/yy"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        var end: Int?
        
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) != nil {
                let isHeader = ["HYPERMARCHE", "AVENUE", "RUE", "TEL"].contains(where: { line.uppercased().contains($0) })
                if !isHeader {
                    start = i
                    break
                }
            }
        }
        
        guard let s = start else { return nil }
        
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("TOTAL") || lines[i].uppercased().contains("A PAYER") {
                end = i
                break
            }
        }
        
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        
        for line in lines {
            // Auchan format: "PRODUCT NAME    3,99" or "PRODUCT NAME 3.99"
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s+(\d+[,.]\d{2})$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            let line = lines[i]
            if line.uppercased().contains("TOTAL") || line.uppercased().contains("A PAYER") {
                if let match = line.range(of: #"(\d+[,.]\d{2})"#, options: .regularExpression) {
                    return parsePrice(String(line[match]))
                }
            }
        }
        return 0.0
    }
}

// MARK: - Casino Parser

final class CasinoParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "CASINO"
    
    func canParse(_ text: String) -> Bool {
        return text.uppercased().contains("CASINO")
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("CASINO PARSER")
        let lines = preprocess(text)
        
        let date = extractDate(from: lines, formats: ["dd/MM/yyyy HH:mm", "dd/MM/yy"])
        
        guard let (start, end) = findProductSection(in: lines) else { return nil }
        
        let products = parseProducts(from: Array(lines[start..<end]))
        let total = extractTotal(from: lines, afterLine: end)
        
        return ParsedReceipt(storeName: storeName, date: date, total: total, products: products)
    }
    
    private func findProductSection(in lines: [String]) -> (Int, Int)? {
        var start: Int?
        var end: Int?
        
        for (i, line) in lines.enumerated() {
            if line.range(of: #"\d+[,.]\d{2}$"#, options: .regularExpression) != nil {
                let isHeader = ["MAGASIN", "RUE", "TEL"].contains(where: { line.uppercased().contains($0) })
                if !isHeader {
                    start = i
                    break
                }
            }
        }
        
        guard let s = start else { return nil }
        
        for i in (s + 1)..<lines.count {
            if lines[i].uppercased().contains("TOTAL") || lines[i].uppercased().contains("TTC") {
                end = i
                break
            }
        }
        
        return (s, end ?? lines.count)
    }
    
    private func parseProducts(from lines: [String]) -> [ParsedProduct] {
        var products: [ParsedProduct] = []
        
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s{2,}(\d+[,.]\d{2})$"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let priceRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            
            let name = cleanProductName(String(line[nameRange]))
            let price = parsePrice(String(line[priceRange]))
            
            guard price > 0, name.count > 2 else { continue }
            
            let section = ProductClassifier.shared.guessSection(for: name)
            products.append(ParsedProduct(rawLine: line, name: name, price: price, section: section))
        }
        
        return products
    }
    
    private func extractTotal(from lines: [String], afterLine: Int) -> Double {
        for i in afterLine..<min(afterLine + 10, lines.count) {
            let line = lines[i]
            if line.uppercased().contains("TOTAL") {
                if let match = line.range(of: #"(\d+[,.]\d{2})"#, options: .regularExpression) {
                    return parsePrice(String(line[match]))
                }
            }
        }
        return 0.0
    }
}

// MARK: - ========== GENERIC FALLBACK PARSER ==========

// MARK: - Generic Receipt Parser

/// Generic parser used as fallback when no specific store is recognized
/// - Handles unknown or poorly printed receipts
/// - Tolerant to OCR errors
/// - Automatically detects product/price lines and totals
final class GenericReceiptParser: BaseReceiptParser, StoreReceiptParser {
    let storeName = "Unknown Store / Magasin Inconnu"
    
    func canParse(_ text: String) -> Bool {
        // This parser should not be in the main parser list
        // It's used as a manual fallback by the factory
        return false
    }
    
    func parse(from text: String) -> ParsedReceipt? {
        logger.section("GENERIC FALLBACK PARSER")
        
        let lines = text.components(separatedBy: .newlines)
        
        // Date extraction (try common formats)
        let date = extractDate(from: lines, formats: [
            "dd.MM.yy HH:mm",
            "dd.MM.yyyy HH:mm",
            "dd/MM/yyyy HH:mm",
            "dd/MM/yy HH:mm"
        ])
        
        // Regex for standard product + price (tolerant)
        let productRegex = try! NSRegularExpression(
            pattern: #"([A-ZÄÖÜa-zäöüß0-9\-\.\s\/]+?)\s+(\d{1,3},\d{2})"#,
            options: []
        )
        
        // Regex for quantity lines (e.g., "0,89 x 3 = 2,67")
        let quantityRegex = try! NSRegularExpression(
            pattern: #"(\d{1,3},\d{2})\s?[xX]\s?(\d+)\s?[=]?\s?(\d{0,3},?\d{0,2})?"#,
            options: []
        )
        
        // Useless lines to ignore
        let ignoreKeywords = [
            "Summe", "Total", "MwSt", "Gesamt", "USt", "Netto", "Zwischensumme", "TSE", "Beleg", "Nr."
        ]
        
        var products: [ParsedProduct] = []
        var lastProductName: String? = nil
        
        for line in lines {
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            let cleanedLine = line
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "Â", with: "")
                .replacingOccurrences(of: "·", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !cleanedLine.isEmpty else { continue }
            
            // Ignore total, tax lines, etc.
            if ignoreKeywords.contains(where: { cleanedLine.localizedCaseInsensitiveContains($0) }) {
                continue
            }
            
            // Step 1: Lines with quantity
            if let match = quantityRegex.firstMatch(in: cleanedLine, range: nsRange) {
                guard let unitR = Range(match.range(at: 1), in: cleanedLine),
                      let qtyR = Range(match.range(at: 2), in: cleanedLine) else { continue }
                
                let unitStr = String(cleanedLine[unitR]).replacingOccurrences(of: ",", with: ".")
                let qty = Int(String(cleanedLine[qtyR])) ?? 1
                let unitPrice = Double(unitStr) ?? 0.0
                
                var total = unitPrice * Double(qty)
                
                // If explicit total in match, use it
                if let totalR = Range(match.range(at: 3), in: cleanedLine) {
                    let totalStr = String(cleanedLine[totalR]).replacingOccurrences(of: ",", with: ".")
                    if !totalStr.isEmpty, let totalValue = Double(totalStr) {
                        total = totalValue
                    }
                }
                
                if let name = lastProductName {
                    // Only add food items
                    guard isFoodItem(name) else {
                        lastProductName = nil
                        continue
                    }
                    
                    let productName = qty > 1 ? "\(name) (\(qty)x)" : name
                    let item = ParsedProduct(
                        rawLine: cleanedLine,
                        name: productName,
                        price: total,
                        section: categorize(name)
                    )
                    products.append(item)
                    lastProductName = nil
                }
                continue
            }
            
            // Step 2: Simple lines product + price
            let matches = productRegex.matches(in: cleanedLine, range: nsRange)
            if matches.isEmpty {
                // Just a product description
                lastProductName = cleanedLine
                continue
            }
            
            for match in matches {
                guard let nameR = Range(match.range(at: 1), in: cleanedLine),
                      let priceR = Range(match.range(at: 2), in: cleanedLine) else { continue }
                
                let name = String(cleanedLine[nameR])
                    .replacingOccurrences(of: "€", with: "")
                    .trimmingCharacters(in: .whitespaces)
                
                let priceStr = String(cleanedLine[priceR]).replacingOccurrences(of: ",", with: ".")
                let price = Double(priceStr) ?? 0.0
                
                // Only add food items
                guard isFoodItem(name) else { continue }
                
                let item = ParsedProduct(
                    rawLine: cleanedLine,
                    name: name,
                    price: price,
                    section: categorize(name)
                )
                products.append(item)
                lastProductName = name
            }
        }
        
        // Step 3: Extract total
        var total = 0.0
        if let totalLine = lines.first(where: {
            $0.localizedCaseInsensitiveContains("ZU ZAHLEN") ||
            $0.localizedCaseInsensitiveContains("GESAMT") ||
            $0.localizedCaseInsensitiveContains("SUMME") ||
            $0.localizedCaseInsensitiveContains("TOTAL")
        }),
        let match = totalLine.range(of: #"(\d{1,3},\d{2})"#, options: .regularExpression) {
            let totalStr = String(totalLine[match]).replacingOccurrences(of: ",", with: ".")
            total = Double(totalStr) ?? 0.0
        }
        
        // If no total detected, sum up the prices
        if total == 0 {
            total = products.map { $0.price }.reduce(0, +)
        }
        
        guard !products.isEmpty else { return nil }
        
        return ParsedReceipt(
            storeName: storeName,
            date: date,
            total: total,
            products: products
        )
    }
    
    /// Simple categorization for auto-classification
    private func categorize(_ name: String) -> ProductSection {
        let lower = name.lowercased()
        
        // Skip PFAND (deposit) items
        if lower.contains("pfand") { return .unknown }
        
        // Fridge items
        if lower.contains("milch") || lower.contains("joghurt") ||
            lower.contains("käse") || lower.contains("butter") ||
            lower.contains("quark") || lower.contains("sahne") ||
            lower.contains("fleisch") || lower.contains("hähnchen") ||
            lower.contains("fisch") || lower.contains("lachs") ||
            lower.contains("wurst") || lower.contains("schinken") {
            return .fridge
        }
        
        // Freezer items
        if lower.contains("eis") || lower.contains("tiefkühl") ||
            lower.contains("tk ") || lower.contains("frozen") {
            return .freezer
        }
        
        // Pantry items
        if lower.contains("brot") || lower.contains("reis") ||
            lower.contains("nudel") || lower.contains("pudding") ||
            lower.contains("kaffee") || lower.contains("cola") ||
            lower.contains("wasser") || lower.contains("tee") ||
            lower.contains("saft") || lower.contains("apfel") ||
            lower.contains("tomate") || lower.contains("salat") ||
            lower.contains("banane") || lower.contains("pasta") ||
            lower.contains("mehl") || lower.contains("zucker") {
            return .pantry
        }
        
        return .unknown
    }
}

// MARK: - Product Classifier

final class ProductClassifier {
    static let shared = ProductClassifier()
    
    private init() {}
    
    func guessSection(for name: String) -> ProductSection {
        let u = name.uppercased()
        for (section, keys) in enhancedKeywordMapping {
            if keys.contains(where: { u.contains($0) }) {
                return section
            }
        }
        return .unknown
    }
    
    private var enhancedKeywordMapping: [ProductSection: [String]] {
        return [
            .fridge: [
                // German
                "YAOURT", "LAIT", "FROMAGE", "JAMBON", "OEUF", "EIER", "SALAT", "WURST",
                "HÄHN", "HAEHN", "MÜNCH", "MUENCH", "FRISCH", "FRESH", "BUTTER", "CREAM",
                "YOGURT", "CHEESE", "MILK", "HAM", "EGGS", "SCHINKEN", "QUARK", "JOGHURT",
                // French
                "YAOURT", "YOGOURT", "LAIT", "FROMAGE", "JAMBON", "ŒUFS", "OEUFS", "BEURRE",
                "CRÈME", "CREME", "JAMBON", "SAUCISSE", "VIANDE", "POULET", "BŒUF", "BOEUF"
            ],
            .freezer: [
                // German
                "SURGELÉ", "SURGELE", "GLACE", "TIEFKÜHL", "TIEFKUHL", "TK", "EIS",
                "PIZZA SURGE", "FROZEN", "ICE CREAM",
                // French
                "SURGELÉ", "SURGELE", "CONGELÉ", "CONGELE", "GLACE", "GLACÉ", "GLACE",
                "PIZZA SURGEL", "FRITES SURGEL", "LÉGUMES SURGEL"
            ],
            .pantry: [
                // German - Dry goods and pantry items
                "PÂTES", "PATES", "RIZ", "FARINE", "SUCRE", "HUILE", "BOÎTE", "BOITE",
                "WRAPS", "BROT", "BREZEL", "KOMPOST", "TASCHEN", "BEUTEL", "PASTA",
                "RICE", "FLOUR", "SUGAR", "OIL", "BREAD", "CEREAL", "NUDELN", "MEHL",
                // German - Fruits and vegetables (merged)
                "POMME", "APPLE", "BANANE", "BANANA", "ORANGE", "CAROTTE", "CARROT",
                "TOMATO", "TOMATES", "FRUIT", "LÉGUME", "LEGUME", "VEGETABLE", "SPINACH",
                "SALAD", "ONION", "GARLIC", "OBST", "GEMÜSE", "GEMUESE",
                // French - Dry goods and pantry items
                "PÂTES", "PATES", "RIZ", "FARINE", "SUCRE", "HUILE", "CONSERVE", "BOÎTE",
                "PAIN", "CÉRÉALES", "CEREALES", "BISCUIT", "GÂTEAU", "GATEAU", "CONFITURE",
                // French - Fruits and vegetables (merged)
                "POMME", "BANANE", "ORANGE", "CAROTTE", "TOMATE", "FRUIT", "LÉGUME", "LEGUME",
                "ÉPINARD", "EPINARD", "SALADE", "OIGNON", "AIL", "POIREAU", "COURGETTE",
                "AUBERGINE", "POIVRON", "FRAISE", "POIRE", "RAISIN", "CITRON"
            ]
        ]
    }
}

// MARK: - Note: Enhanced Product Classifier functionality is now integrated into the main class

// MARK: - Updated Processing Manager

extension ReceiptProcessingManager {
    
    /// Main entry point - automatically detects store and uses appropriate parser
    func processReceiptWithAutoDetection(image: UIImage) {
        isProcessing = true
        errorMessage = nil
        
        // Clear debug log (if needed, can be implemented later)
        // ReceiptDebugLogger.shared.clear()
        
        // Preprocess image
        ReceiptImagePreprocessor.shared.preprocess(image) { [weak self] preprocessed in
            guard let self else { return }
            
            let cleanImage = preprocessed ?? image
            
            // Enhanced OCR
            EnhancedReceiptOCR.shared.recognizeText(from: cleanImage) { result in
                switch result {
                case .success(let rawText):
                    // Post-process OCR
                    let correctedText = OCRPostProcessor.shared.correctCommonErrors(rawText)
                    
                    // Use factory to auto-detect and parse
                    if let receipt = ReceiptParserFactory.shared.parseReceipt(from: correctedText) {
                        Task { @MainActor in
                            self.parsedReceipt = receipt
                            self.editableProducts = receipt.products
                            self.totalEditable = receipt.total
                            self.isProcessing = false
                            
                            print("✅ Successfully parsed receipt")
                            print("   Store: \(receipt.storeName)")
                            print("   Products: \(receipt.products.count)")
                            print("   Total: €\(String(format: "%.2f", receipt.total))")
                        }
                    } else {
                        Task { @MainActor in
                            self.errorMessage = "Could not parse receipt. Check debug logs."
                            self.isProcessing = false
                            
                            // Debug: Parsing failed
                            print("=== PARSING FAILED ===")
                            print("Text: \(rawText)")
                            print("Corrected text: \(correctedText)")
                        }
                    }
                    
                case .failure(let error):
                    Task { @MainActor in
                        self.errorMessage = "OCR failed: \(error.localizedDescription)"
                        self.isProcessing = false
                    }
                }
            }
        }
    }
}

// MARK: - Usage Example

/*
 // In your SwiftUI view:
 
 Button("Scan Receipt") {
     if let image = capturedImage {
         // Automatically detects store and uses correct parser
         receiptManager.processReceiptWithAutoDetection(image: image)
     }
 }
 
 // The factory will:
 // 1. Try each store-specific parser
 // 2. Use the one that matches
 // 3. Fall back to generic parser if no match
 
 // Supported stores:
 // 🇩🇪 Germany: Aldi, Lidl, Rewe, Edeka, Penny, Netto
 // 🇫🇷 France: Carrefour, Leclerc, Intermarché, Auchan, Casino
 */
