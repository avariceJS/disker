import SwiftUI
import DiskerCore

struct ApplicationDataLocationSuggestionRow: View {
    let suggestion: ApplicationDataLocationCandidate
    let statusText: String?
    let statusSymbol: String?
    let statusColor: Color?
    let isChecking: Bool
    let canCheck: Bool
    let isMeasurementDisabled: Bool
    let measurementTitle: LocalizedStringKey
    let onCheck: () -> Void
    let onMeasure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(suggestion.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if let statusText {
                            Label(statusText, systemImage: statusSymbol ?? "info.circle")
                                .font(.caption2)
                                .foregroundStyle(statusColor ?? .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            SWStatusBadge(text: "Not checked", style: .neutral)
                        }
                    }

                    Text(suggestion.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 6) {
                    if canCheck {
                        Button {
                            onCheck()
                        } label: {
                            if isChecking {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 128)
                            } else {
                                Label(statusText == nil ? "Check exact path" : "Check again", systemImage: "magnifyingglass")
                                    .frame(minWidth: 128, alignment: .leading)
                            }
                        }
                        .controlSize(.small)
                        .disabled(isChecking)
                        .help("Check only this exact folder path; no descendants or file contents are read")
                        .accessibilityLabel(accessibilityCheckLabel)
                        .accessibilityHint("Checks only this exact suggested path. It does not list descendants or read file contents.")
                    }

                    Button(action: onMeasure) {
                        Text(measurementTitle)
                            .frame(minWidth: 128, alignment: .leading)
                    }
                    .controlSize(.small)
                    .disabled(isMeasurementDisabled)
                    .help("Measurement starts only after you confirm this exact file or folder in the picker")
                    .accessibilityLabel(String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Choose an exact location to measure: %@",
                            comment: "VoiceOver label for selecting a specific suggested app-data location"
                        ),
                        suggestion.title
                    ))
                    .accessibilityHint("Opens a picker. Measurement starts only after you confirm this exact suggested path.")
                }
            }

            DisclosureGroup("Why this path is suggested") {
                Text(suggestion.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.caption2.weight(.medium))
            .padding(.leading, 32)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.7)
        }
    }

    private var symbol: String {
        switch suggestion.evidence {
        case .probablePreferencesFile:
            "doc.text"
        case .declaredSharedGroupClaim, .signatureCoveredSharedGroupClaim:
            "person.2"
        default:
            "folder"
        }
    }

    private var accessibilityCheckLabel: String {
        let key: String
        if isChecking {
            key = "Checking exact path: %@"
        } else if statusText == nil {
            key = "Check exact path: %@"
        } else {
            key = "Check this path again: %@"
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(key, comment: "VoiceOver label for checking one exact suggested app-data path"),
            suggestion.title
        )
    }
}
