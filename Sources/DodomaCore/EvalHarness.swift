import Foundation

/// What a corpus row is supposed to happen to.
public enum EvalLabel: String, Sendable, CaseIterable, Equatable {
    /// Latin gibberish that should be auto-fixed into Arabic.
    case autoArabic = "auto_ar"
    /// Arabic gibberish that should be auto-fixed into English.
    case autoEnglish = "auto_en"
    case suggest
    case ignore
}

public struct EvalRow: Sendable, Equatable {
    public let lineNumber: Int
    public let text: String
    public let expected: EvalLabel

    public init(lineNumber: Int, text: String, expected: EvalLabel) {
        self.lineNumber = lineNumber
        self.text = text
        self.expected = expected
    }
}

public struct EvalOutcome: Sendable {
    public let row: EvalRow
    public let predicted: EvalLabel
    /// Why, in one line: the ignore reason or the produced text and scores.
    public let detail: String

    public var isCorrect: Bool { predicted == row.expected }
    /// The canary: a row labelled `ignore` that got rewritten silently.
    public var isFalsePositive: Bool {
        row.expected == .ignore
            && (predicted == .autoArabic || predicted == .autoEnglish)
    }
}

public struct EvalReport: Sendable {
    public let outcomes: [EvalOutcome]

    public var failures: [EvalOutcome] { outcomes.filter { !$0.isCorrect } }
    public var falsePositives: [EvalOutcome] { outcomes.filter(\.isFalsePositive) }
    public var correctCount: Int { outcomes.filter(\.isCorrect).count }

    /// What `--eval` returns to the shell: non-zero when a row labelled
    /// `ignore` was rewritten without asking.
    public var exitCode: Int32 { falsePositives.isEmpty ? 0 : 1 }

    /// Rows labelled `auto_ar`/`auto_en` that were predicted correctly.
    public var autoAccuracy: Double {
        let autoRows = outcomes.filter {
            $0.row.expected == .autoArabic || $0.row.expected == .autoEnglish
        }
        guard !autoRows.isEmpty else { return 1 }
        return Double(autoRows.filter(\.isCorrect).count) / Double(autoRows.count)
    }

    public func count(expected: EvalLabel, predicted: EvalLabel) -> Int {
        outcomes.filter { $0.row.expected == expected && $0.predicted == predicted }.count
    }

    /// Human-readable confusion matrix, per-class precision/recall and the
    /// failing rows.
    public func render() -> String {
        var lines: [String] = []
        let labels = EvalLabel.allCases

        lines.append("rows \(outcomes.count)  correct \(correctCount)  "
            + String(format: "accuracy %.1f%%", 100 * Double(correctCount)
                / Double(max(outcomes.count, 1))))
        lines.append("")
        lines.append("confusion (rows = expected, columns = predicted)")
        lines.append("            " + labels.map { pad($0.rawValue, 10) }.joined())
        for expected in labels {
            let cells = labels.map { pad(String(count(expected: expected, predicted: $0)), 10) }
            lines.append(pad(expected.rawValue, 12) + cells.joined())
        }
        lines.append("")
        lines.append("class        precision  recall  support")
        for label in labels {
            let support = outcomes.filter { $0.row.expected == label }.count
            let predictedCount = outcomes.filter { $0.predicted == label }.count
            let hits = count(expected: label, predicted: label)
            let precision = predictedCount == 0 ? 1 : Double(hits) / Double(predictedCount)
            let recall = support == 0 ? 1 : Double(hits) / Double(support)
            lines.append(
                pad(label.rawValue, 13)
                    + pad(String(format: "%.2f", precision), 11)
                    + pad(String(format: "%.2f", recall), 8)
                    + String(support))
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("failures")
            for outcome in failures {
                lines.append(
                    "  line \(outcome.row.lineNumber): expected \(outcome.row.expected.rawValue), "
                        + "got \(outcome.predicted.rawValue)  |  \(outcome.row.text)")
                lines.append("      \(outcome.detail)")
            }
        }

        lines.append("")
        lines.append(
            falsePositives.isEmpty
                ? "false-positive canary: clean (no ignore row auto-applied)"
                : "false-positive canary: FAILED, \(falsePositives.count) ignore row(s) auto-applied")
        return lines.joined(separator: "\n")
    }

    private func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
    }
}

/// Runs a labelled corpus through the detector. Used by `--eval` and by the
/// test suite, which passes the committed fixture layouts so results do not
/// depend on the machine's enabled input sources.
public enum EvalHarness {
    public enum ParseError: Error, CustomStringConvertible {
        case badLine(Int, String)

        public var description: String {
            switch self {
            case .badLine(let number, let reason):
                return "corpus line \(number): \(reason)"
            }
        }
    }

    /// `text<TAB>label` per line. Blank lines and `#` comments are skipped.
    public static func parse(_ contents: String) throws -> [EvalRow] {
        var rows: [EvalRow] = []
        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let number = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = rawLine.components(separatedBy: "\t")
            guard parts.count == 2 else {
                throw ParseError.badLine(number, "expected exactly one tab")
            }
            let text = parts[0]
            guard let expected = EvalLabel(rawValue: parts[1].trimmingCharacters(in: .whitespaces))
            else {
                throw ParseError.badLine(
                    number,
                    "unknown label \(parts[1]); expected one of "
                        + EvalLabel.allCases.map(\.rawValue).joined(separator: " "))
            }
            guard !text.isEmpty else { throw ParseError.badLine(number, "empty text") }
            rows.append(EvalRow(lineNumber: number, text: text, expected: expected))
        }
        return rows
    }

    public static func run(
        rows: [EvalRow],
        detector: Detector,
        aggressiveness: Aggressiveness = .balanced,
        confidentScore: Double? = nil,
        keyboardType: UInt32? = nil
    ) -> EvalReport {
        EvalReport(outcomes: rows.map { evaluate($0, detector: detector,
            aggressiveness: aggressiveness, keyboardType: keyboardType) })
    }

    private static func evaluate(
        _ row: EvalRow, detector: Detector, aggressiveness: Aggressiveness, keyboardType: UInt32?
    ) -> EvalOutcome {
        guard
            let detection = detector.detect(
                text: row.text, aggressiveness: aggressiveness, keyboardType: keyboardType)
        else {
            return EvalOutcome(
                row: row, predicted: .ignore,
                detail: "unmappable: no key on the source layout types every character")
        }

        switch detection.decision {
        case .ignore(let reason):
            return EvalOutcome(row: row, predicted: .ignore, detail: reason)
        case .suggest(let fix):
            return EvalOutcome(row: row, predicted: .suggest, detail: describe(fix, detection))
        case .autoApply(let fix):
            let predicted: EvalLabel =
                fix.targetLayoutID == detector.arabicLayout.sourceID ? .autoArabic : .autoEnglish
            return EvalOutcome(row: row, predicted: predicted, detail: describe(fix, detection))
        }
    }

    private static func describe(_ fix: Fix, _ detection: Detector.Detection) -> String {
        guard let analysis = detection.analysis else { return fix.insertText }
        return String(
            format: "→ %@  cur %.2f alt %.2f gap %.2f caps %@ guards %@",
            fix.insertText, analysis.current.combined, analysis.alternate.combined,
            analysis.gap, fix.capsMode.rawValue, analysis.guards.summary)
    }
}
