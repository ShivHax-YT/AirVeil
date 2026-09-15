import SwiftUI

enum LegalDocument: String, CaseIterable, Identifiable {
    case terms = "TERMS", privacy = "PRIVACY", cookies = "COOKIES"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terms: return "Terms of Use"
        case .privacy: return "Privacy Policy"
        case .cookies: return "Cookies & Local Storage"
        }
    }
    func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: rawValue, withExtension: "md", subdirectory: "Legal") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Offline policies stay available before permission choices and after setup.
struct LegalFooter: View {
    @State private var selected: LegalDocument?
    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { links }
                VStack(spacing: 0) { links }
            }
            Text("Read offline on this Mac")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $selected) { LegalDocumentView(document: $0) }
    }
    private var links: some View {
        ForEach(LegalDocument.allCases) { document in
            Button { selected = document } label: {
                Text(document.title).underline().font(.caption)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("legal-\(document.rawValue.lowercased())")
            .help("Read \(document.title) without opening a browser")
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 20)
                Button("Done") { dismiss() }
                    .controlSize(.large).keyboardShortcut(.cancelAction)
                    .frame(minHeight: 44)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let text = document.text() {
                        ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                            policyBlock(block)
                        }
                    } else {
                        Text("This policy could not be loaded. Reinstall AirVeil from its original download to restore the bundled documents.")
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .accessibilityLabel(document.title)
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 460, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder private func policyBlock(_ raw: String) -> some View {
        let block = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.hasPrefix("# ") {
            // The sheet already names this document.
            EmptyView()
        } else if block.hasPrefix("## ") {
            Text(String(block.dropFirst(3)))
                .font(.headline).padding(.top, 6).accessibilityAddTraits(.isHeader)
        } else if !block.isEmpty {
            Text((try? AttributedString(markdown: block,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                .font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
