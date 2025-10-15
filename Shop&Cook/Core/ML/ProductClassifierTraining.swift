//
//  ProductClassifierTraining.swift
//  Shop&Cook
//
//  ML-powered product classification training
//

import Foundation
import CreateML

#if os(macOS)

// MARK: - Training Data Management

/// Represents a single training example
struct ProductTrainingExample: Codable {
    let productName: String
    let category: String  // fridge, freezer, pantry, unknown
    let confidence: Float
    let source: String    // "user_correction", "initial", "validated"
    let timestamp: Date
}

/// Training data collection
struct ProductTrainingDataset: Codable {
    var examples: [ProductTrainingExample]
    var version: Int
    var lastUpdated: Date
    
    static let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("product_training_data.json")
}

// MARK: - Product Classifier Trainer

class ProductClassifierTrainer {
    
    /// Train a new ML model from collected data
    static func trainProductClassifier() throws {
        print("🤖 Starting ML product classifier training...")
        
        // 1. Load training data
        let dataset = try loadTrainingDataset()
        print("✅ Loaded \(dataset.examples.count) training examples")
        
        // 2. Convert to CreateML format
        let trainingTable = try createMLTable(from: dataset)
        print("✅ Created ML table with \(trainingTable.rows.count) rows")
        
        // 3. Split into training and validation
        let (training, validation) = trainingTable.randomSplit(by: 0.8)
        print("✅ Split: \(training.rows.count) training, \(validation.rows.count) validation")
        
        // 4. Train text classifier
        print("🔧 Training text classifier...")
        let classifier = try MLTextClassifier(
            trainingData: training,
            textColumn: "productName",
            labelColumn: "category"
        )
        
        // 5. Evaluate on validation set
        let evaluation = classifier.evaluation(on: validation)
        print("✅ Training complete!")
        print("📊 Validation Accuracy: \(String(format: "%.1f%%", evaluation.classificationError * 100))")
        
        // 6. Save model
        let modelURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProductClassifier.mlmodel")
        
        try classifier.write(to: modelURL)
        print("✅ Model saved to: \(modelURL.path)")
        
        // 7. Print detailed metrics
        printDetailedMetrics(evaluation)
    }
    
    /// Load training dataset from storage
    static func loadTrainingDataset() throws -> ProductTrainingDataset {
        let fileURL = ProductTrainingDataset.fileURL
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(ProductTrainingDataset.self, from: data)
        } else {
            // Return initial seed data
            return createInitialDataset()
        }
    }
    
    /// Create ML table from dataset
    static func createMLTable(from dataset: ProductTrainingDataset) throws -> MLDataTable {
        var productNames: [String] = []
        var categories: [String] = []
        
        for example in dataset.examples {
            productNames.append(example.productName)
            categories.append(example.category)
        }
        
        return try MLDataTable(dictionary: [
            "productName": productNames,
            "category": categories
        ])
    }
    
    /// Create initial training dataset with seed data
    static func createInitialDataset() -> ProductTrainingDataset {
        let seedExamples: [(String, String)] = [
            // Fridge items
            ("Milch", "fridge"),
            ("Vollmilch 3,5%", "fridge"),
            ("Joghurt", "fridge"),
            ("Käse", "fridge"),
            ("Butter", "fridge"),
            ("Sahne", "fridge"),
            ("Quark", "fridge"),
            ("Hähnchen", "fridge"),
            ("Fleisch", "fridge"),
            ("Wurst", "fridge"),
            ("Schinken", "fridge"),
            ("Lachs", "fridge"),
            ("Eier", "fridge"),
            ("Frischkäse", "fridge"),
            ("Mozzarella", "fridge"),
            
            // Freezer items
            ("Eis", "freezer"),
            ("Tiefkühl Pizza", "freezer"),
            ("TK Gemüse", "freezer"),
            ("Frozen Food", "freezer"),
            ("Eiscreme", "freezer"),
            ("Tiefkühlkost", "freezer"),
            
            // Pantry items
            ("Brot", "pantry"),
            ("Knäckebrot", "pantry"),
            ("Nudeln", "pantry"),
            ("Pasta", "pantry"),
            ("Reis", "pantry"),
            ("Mehl", "pantry"),
            ("Zucker", "pantry"),
            ("Salz", "pantry"),
            ("Öl", "pantry"),
            ("Tee", "pantry"),
            ("Kaffee", "pantry"),
            ("Saft", "pantry"),
            ("Mineralwasser", "pantry"),
            ("Schokolade", "pantry"),
            ("Kekse", "pantry"),
            ("Müsli", "pantry"),
            ("Apfel", "pantry"),
            ("Banane", "pantry"),
            ("Tomate", "pantry"),
            ("Salat", "pantry"),
            ("Avocado", "pantry"),
            
            // Unknown (non-food)
            ("Pfand", "unknown"),
            ("Tasche", "unknown"),
            ("Tüte", "unknown")
        ]
        
        let examples = seedExamples.map { (name, category) in
            ProductTrainingExample(
                productName: name,
                category: category,
                confidence: 1.0,
                source: "initial",
                timestamp: Date()
            )
        }
        
        return ProductTrainingDataset(
            examples: examples,
            version: 1,
            lastUpdated: Date()
        )
    }
    
    /// Print detailed evaluation metrics
    static func printDetailedMetrics(_ evaluation: MLClassifierMetrics) {
        print("\n📊 DETAILED EVALUATION METRICS:")
        print("─────────────────────────────────")
        print("Classification Error: \(String(format: "%.2f%%", evaluation.classificationError * 100))")
        
        if let confusionMatrix = evaluation.confusion {
            print("\n🔍 Confusion Matrix:")
            print(confusionMatrix)
        }
    }
}

// MARK: - User Correction Collection

/// Collects user corrections for ML training
class ProductCorrectionManager {
    static let shared = ProductCorrectionManager()
    
    private var corrections: [ProductTrainingExample] = []
    
    /// Record a user correction
    func recordCorrection(productName: String, correctedCategory: String, originalCategory: String) {
        let example = ProductTrainingExample(
            productName: productName,
            category: correctedCategory,
            confidence: 1.0,  // User corrections are high confidence
            source: "user_correction",
            timestamp: Date()
        )
        
        corrections.append(example)
        
        // Save periodically
        if corrections.count % 10 == 0 {
            try? saveCorrections()
        }
        
        print("✅ Recorded correction: \(productName) → \(correctedCategory) (was: \(originalCategory))")
    }
    
    /// Save corrections to training dataset
    func saveCorrections() throws {
        var dataset = try? ProductClassifierTrainer.loadTrainingDataset() 
            ?? ProductClassifierTrainer.createInitialDataset()
        
        // Add new corrections
        dataset.examples.append(contentsOf: corrections)
        dataset.lastUpdated = Date()
        dataset.version += 1
        
        // Save to file
        let data = try JSONEncoder().encode(dataset)
        try data.write(to: ProductTrainingDataset.fileURL)
        
        print("✅ Saved \(corrections.count) corrections to training dataset")
        print("📊 Total dataset size: \(dataset.examples.count) examples")
        
        corrections.removeAll()
    }
    
    /// Get statistics about collected data
    func getStatistics() -> (total: Int, byCategory: [String: Int]) {
        let dataset = (try? ProductClassifierTrainer.loadTrainingDataset()) 
            ?? ProductClassifierTrainer.createInitialDataset()
        
        var byCategory: [String: Int] = [:]
        for example in dataset.examples {
            byCategory[example.category, default: 0] += 1
        }
        
        return (dataset.examples.count, byCategory)
    }
}

#endif

