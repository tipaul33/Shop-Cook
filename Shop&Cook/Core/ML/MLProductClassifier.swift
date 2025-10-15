//
//  MLProductClassifier.swift
//  Shop&Cook
//
//  ML-powered product classification for runtime use
//

import Foundation
import CoreML
import NaturalLanguage

// MARK: - ML Product Classification

/// ML-powered product classifier with fallback to rule-based
class MLProductClassifier {
    static let shared = MLProductClassifier()
    
    private var mlModel: MLModel?
    private let logger = ReceiptDebugLogger.shared
    
    private init() {
        loadModel()
    }
    
    /// Load the trained ML model
    private func loadModel() {
        // Try to load custom trained model
        let modelURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProductClassifier.mlmodel")
        
        if FileManager.default.fileExists(atPath: modelURL.path) {
            do {
                let compiledURL = try MLModel.compileModel(at: modelURL)
                mlModel = try MLModel(contentsOf: compiledURL)
                logger.logSuccess("Loaded custom ML product classifier")
            } catch {
                logger.logWarning("Failed to load ML model: \(error)")
                mlModel = nil
            }
        } else {
            logger.logDebug("No custom ML model found, using rule-based classification")
            mlModel = nil
        }
    }
    
    /// Classify a product using ML or fallback to rules
    func classify(_ productName: String) -> ClassificationResult {
        // Try ML first if available
        if let mlResult = classifyWithML(productName) {
            return mlResult
        }
        
        // Fallback to rule-based classification
        return classifyWithRules(productName)
    }
    
    /// Classify using ML model
    private func classifyWithML(_ productName: String) -> ClassificationResult? {
        guard let model = mlModel else { return nil }
        
        do {
            // Prepare input
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "productName": productName
            ])
            
            // Get prediction
            let prediction = try model.prediction(from: input)
            
            // Extract category and confidence
            guard let category = prediction.featureValue(for: "category")?.stringValue,
                  let probabilities = prediction.featureValue(for: "categoryProbability")?.dictionaryValue else {
                return nil
            }
            
            let confidence = (probabilities[category] as? Double).map { Float($0) } ?? 0.0
            
            logger.logDebug("ML classified '\(productName)' → \(category) (\(String(format: "%.0f%%", confidence * 100)))")
            
            return ClassificationResult(
                category: mapToProductSection(category),
                confidence: confidence,
                method: .machineLearning
            )
            
        } catch {
            logger.logWarning("ML classification failed: \(error)")
            return nil
        }
    }
    
    /// Classify using rule-based system (fallback)
    private func classifyWithRules(_ productName: String) -> ClassificationResult {
        let lower = productName.lowercased()
        
        // Skip non-food items
        if lower.contains("pfand") || lower.contains("tüte") || lower.contains("tasche") {
            return ClassificationResult(category: .unknown, confidence: 0.9, method: .rules)
        }
        
        // Fridge items
        if lower.contains("milch") || lower.contains("joghurt") || lower.contains("yogurt") ||
            lower.contains("käse") || lower.contains("butter") || lower.contains("quark") ||
            lower.contains("sahne") || lower.contains("rahm") || lower.contains("creme") ||
            lower.contains("hähnchen") || lower.contains("fleisch") || lower.contains("wurst") ||
            lower.contains("schinken") || lower.contains("lachs") || lower.contains("ei") ||
            lower.contains("mozzarella") || lower.contains("frischkäse") {
            return ClassificationResult(category: .fridge, confidence: 0.85, method: .rules)
        }
        
        // Freezer items
        if lower.contains("eis") || lower.contains("tiefkühl") || lower.contains("tk ") ||
            lower.contains("frozen") || (lower.contains("pizza") && lower.contains("tiefkühl")) {
            return ClassificationResult(category: .freezer, confidence: 0.85, method: .rules)
        }
        
        // Pantry items (default)
        return ClassificationResult(category: .pantry, confidence: 0.7, method: .rules)
    }
    
    /// Map string category to ProductSection enum
    private func mapToProductSection(_ category: String) -> ProductSection {
        switch category.lowercased() {
        case "fridge": return .fridge
        case "freezer": return .freezer
        case "pantry": return .pantry
        default: return .unknown
        }
    }
}

// MARK: - Classification Result

/// Result of product classification
struct ClassificationResult {
    let category: ProductSection
    let confidence: Float
    let method: ClassificationMethod
}

enum ClassificationMethod {
    case machineLearning
    case rules
    case hybrid
}

// MARK: - Feedback Loop Integration

/// Integrates ML classifier with user feedback
extension MLProductClassifier {
    
    /// Classify with feedback collection
    func classifyWithFeedback(_ productName: String, allowCorrection: Bool = true) -> ClassificationResult {
        let result = classify(productName)
        
        // Log for feedback loop
        if result.confidence < 0.6 {
            logger.logWarning("Low confidence classification: \(productName) → \(result.category) (\(String(format: "%.0f%%", result.confidence * 100)))")
        }
        
        return result
    }
    
    /// Record user correction for future training
    func recordUserCorrection(productName: String, correctCategory: ProductSection, predictedCategory: ProductSection) {
        #if os(macOS)
        let categoryString = categoryToString(correctCategory)
        let predictedString = categoryToString(predictedCategory)
        
        ProductCorrectionManager.shared.recordCorrection(
            productName: productName,
            correctedCategory: categoryString,
            originalCategory: predictedString
        )
        #endif
    }
    
    private func categoryToString(_ category: ProductSection) -> String {
        switch category {
        case .fridge: return "fridge"
        case .freezer: return "freezer"
        case .pantry: return "pantry"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Training Data Export for CreateML App

#if os(macOS)

/// Export training data to CSV for CreateML app
class TrainingDataExporter {
    
    /// Export to CSV format for CreateML
    static func exportToCSV() throws {
        let dataset = try ProductClassifierTrainer.loadTrainingDataset()
        
        var csv = "productName,category\n"
        
        for example in dataset.examples {
            let escapedName = example.productName.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(escapedName)\",\(example.category)\n"
        }
        
        let csvURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("product_training_data.csv")
        
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        
        print("✅ Exported \(dataset.examples.count) examples to CSV")
        print("📁 Location: \(csvURL.path)")
        print("\n💡 Import this CSV in CreateML app to train visually!")
    }
}

#endif

