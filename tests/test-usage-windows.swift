import Foundation

private func window(_ used: Int, _ duration: Int?) -> UsageWindow {
    UsageWindow(usedPercent: used, resetsAt: nil, durationMinutes: duration)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("failed: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct UsageWindowClassificationTests {
    static func main() {
        let plus = UsageWindowClassifier.classify(
            primary: window(25, 300),
            secondary: window(70, 10_080)
        )
        expect(plus.short?.usedPercent == 25, "Plus short window")
        expect(plus.weekly?.usedPercent == 70, "Plus weekly window")

        let proLite = UsageWindowClassifier.classify(
            primary: window(24, 10_080),
            secondary: nil
        )
        expect(proLite.short == nil, "Pro Lite must not invent a five-hour window")
        expect(proLite.weekly?.usedPercent == 24, "Pro Lite weekly window")

        let shortOnly = UsageWindowClassifier.classify(
            primary: nil,
            secondary: window(12, 300)
        )
        expect(shortOnly.short?.usedPercent == 12, "a new short window is found in any position")
        expect(shortOnly.weekly == nil, "a removed weekly window stays absent")

        let newlyNamedFields = UsageWindowClassifier.classify(discovered: [
            window(33, 300), window(44, 10_080)
        ])
        expect(newlyNamedFields.short?.usedPercent == 33, "short window discovery is field-name independent")
        expect(newlyNamedFields.weekly?.usedPercent == 44, "weekly discovery is field-name independent")

        let reversed = UsageWindowClassifier.classify(
            primary: window(80, 10_080),
            secondary: window(10, 300)
        )
        expect(reversed.short?.usedPercent == 10, "duration wins over field position")
        expect(reversed.weekly?.usedPercent == 80, "reversed weekly window")

        let legacy = UsageWindowClassifier.classify(
            primary: window(5, nil),
            secondary: window(15, nil)
        )
        expect(legacy.short?.usedPercent == 5, "legacy primary fallback")
        expect(legacy.weekly?.usedPercent == 15, "legacy secondary fallback")

        print("usage window classification tests passed")
    }
}
