import Foundation

/// Выживаемость технических терминов: сколько iOS/Swift-терминов из эталона уцелело в живой
/// расшифровке. Зачем отдельно от WER: почти все «ошибки» WER — это искажённые англоязычные
/// термины (§8), причём эталон сам их коверкает; WER вводит в заблуждение. Здесь меряем суть —
/// дошёл ли термин (после нормализации искажений глоссарием) до подсказки.
public struct TermSurvival: Sendable, Equatable, Codable {
    public let termsInReference: Int        // канонических терминов найдено в эталоне
    public let survivedInLive: Int          // из них присутствуют и в живой расшифровке
    public let missingTerms: [String]       // термины из эталона, пропавшие в живой

    /// Доля выживших терминов 0..1 (если терминов в эталоне нет — считаем 1, нечего терять).
    public var survivalRate: Double { termsInReference == 0 ? 1 : Double(survivedInLive) / Double(termsInReference) }
    public var survivalPercent: Int { Int((survivalRate * 100).rounded()) }
}

/// Результат автоматической оценки качества расшифровки сессии: эталон (целый файл,
/// один проход) против «живой» потоковой расшифровки, что использовалась в подсказках.
public struct TranscriptionEval: Sendable, Equatable, Codable {
    public let referenceText: String        // эталон: весь WAV одним проходом
    public let liveText: String             // что выдала живая потоковая расшифровка
    public let referenceWordCount: Int
    public let liveWordCount: Int
    public let wordErrors: Int              // word-level edit distance
    public let wordErrorRate: Double        // 0..1+ (errors / reference words)
    public let terms: TermSurvival          // выживаемость терминов (главная метрика, §8)

    /// Грубая «точность» живой расшифровки относительно эталона, %.
    public var accuracyPercent: Int { Int((max(0, 1 - wordErrorRate) * 100).rounded()) }
}

public enum TranscriptionEvaluator {

    /// Сравнить эталон и живую расшифровку (word-level WER + выживаемость терминов).
    public static func evaluate(
        referenceText: String,
        liveText: String,
        glossary: TermGlossary = .iosDefault
    ) -> TranscriptionEval {
        let ref = tokenize(referenceText)
        let live = tokenize(liveText)
        let errors = editDistance(ref, live)
        let wer = ref.isEmpty ? (live.isEmpty ? 0 : 1) : Double(errors) / Double(ref.count)
        return TranscriptionEval(
            referenceText: referenceText,
            liveText: liveText,
            referenceWordCount: ref.count,
            liveWordCount: live.count,
            wordErrors: errors,
            wordErrorRate: wer,
            terms: termSurvival(referenceText: referenceText, liveText: liveText, glossary: glossary)
        )
    }

    /// Сколько канонических терминов из эталона уцелело в живой расшифровке. Сначала чиним
    /// известные искажения глоссарием (эталон и живая сами коверкают термины), затем считаем
    /// присутствие каждого канонического термина как отдельной лексемы (не части слова).
    public static func termSurvival(
        referenceText: String,
        liveText: String,
        glossary: TermGlossary = .iosDefault
    ) -> TermSurvival {
        let ref = glossary.correct(referenceText).lowercased()
        let live = glossary.correct(liveText).lowercased()
        var inReference = 0
        var survived = 0
        var missing: [String] = []
        for term in glossary.canonicalTerms {
            let needle = term.lowercased()
            guard containsTerm(ref, needle) else { continue }
            inReference += 1
            if containsTerm(live, needle) { survived += 1 } else { missing.append(term) }
        }
        return TermSurvival(termsInReference: inReference, survivedInLive: survived, missingTerms: missing)
    }

    /// Записать отчёт (`evaluation.txt` + `evaluation.json`) в папку сессии.
    public static func writeReport(_ eval: TranscriptionEval, to folder: URL) {
        let txt = report(eval)
        try? Data(txt.utf8).write(to: folder.appending(path: "evaluation.txt"))
        if let json = try? JSONEncoder.prettyEncoder.encode(eval) {
            try? json.write(to: folder.appending(path: "evaluation.json"))
        }
    }

    public static func report(_ e: TranscriptionEval) -> String {
        """
        Оценка расшифровки (эталон = весь файл одним проходом vs живая потоковая)
        ─────────────────────────────────────────────────────────────────────
        Точность живой расшифровки: ≈\(e.accuracyPercent)%
        WER (word error rate):      \(String(format: "%.1f", e.wordErrorRate * 100))%
        Ошибок слов:                \(e.wordErrors) из \(e.referenceWordCount) (эталон)
        Слов: эталон \(e.referenceWordCount) · живых \(e.liveWordCount)

        Термины (iOS/Swift) выжили: \(e.terms.survivedInLive)/\(e.terms.termsInReference) (\(e.terms.survivalPercent)%) ← главная метрика, WER вводит в заблуждение
        Пропавшие термины:          \(e.terms.missingTerms.isEmpty ? "—" : e.terms.missingTerms.joined(separator: ", "))

        ── ЭТАЛОН (целый файл) ──────────────────────────────────────────────
        \(e.referenceText.isEmpty ? "(пусто)" : e.referenceText)

        ── ЖИВАЯ (использовалась в подсказках) ──────────────────────────────
        \(e.liveText.isEmpty ? "(пусто)" : e.liveText)
        """
    }

    /// Прочитать наш WAV (PCM16 моно, заголовок 44 байта) обратно в сэмплы [-1..1].
    public static func readWavSamples(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let start = 44
        var out = [Float]()
        out.reserveCapacity((data.count - start) / 2)
        var i = start
        while i + 1 < data.count {
            let value = Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
            out.append(Float(value) / 32767.0)
            i += 2
        }
        return out
    }

    // MARK: - Внутреннее

    /// Присутствует ли термин в тексте как отдельная лексема (не часть большего слова).
    /// Границу проверяем только на буквенно-цифровых краях термина: «arc» не сматчит «search»,
    /// но «async/await» и «@mainactor» матчатся корректно. Тексты короткие — наивный поиск ок.
    static func containsTerm(_ haystack: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        let h = Array(haystack)
        let t = Array(term)
        guard h.count >= t.count, let first = t.first, let last = t.last else { return false }
        let checkLeft = first.isLetter || first.isNumber
        let checkRight = last.isLetter || last.isNumber
        var i = 0
        while i + t.count <= h.count {
            if Array(h[i ..< i + t.count]) == t {
                let leftOK = !checkLeft || i == 0 || !(h[i - 1].isLetter || h[i - 1].isNumber)
                let rightIdx = i + t.count
                let rightOK = !checkRight || rightIdx == h.count || !(h[rightIdx].isLetter || h[rightIdx].isNumber)
                if leftOK && rightOK { return true }
            }
            i += 1
        }
        return false
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Расстояние Левенштейна по словам (вставка/удаление/замена = 1).
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}

private extension JSONEncoder {
    static var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
