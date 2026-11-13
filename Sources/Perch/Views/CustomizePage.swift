import PerchCore
import SwiftUI

struct CustomizePage: View {
    @Environment(AppHub.self) private var hub

    var body: some View {
        @Bindable var ws = hub.workspace
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cards").font(.system(size: 14, weight: .semibold))
                Text("Show, hide, resize and reorder. You can also drag a card by its handle.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(ws.data.settings.cards.enumerated()), id: \.element.id) { index, card in
                            row(card, index: index)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance").font(.system(size: 14, weight: .semibold))
                Toggle("Black & white", isOn: $ws.data.settings.blackAndWhite)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Clock").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 6) {
                        ForEach(ClockStyle.allCases, id: \.self) { style in
                            Button {
                                ws.data.settings.clockStyle = style
                            } label: {
                                ClockFace(text: "25:00", style: style, color: .white, maxWidth: 72)
                                    .scaleEffect(style == .dots ? 1 : 0.55)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(ws.data.settings.clockStyle == style ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .help(style.label)
                            .accessibilityLabel(style.label)
                        }
                    }
                }

                HStack {
                    Text("Default focus").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Stepper(value: $ws.data.settings.defaultFocusMinutes, in: 1...240, step: 5) {
                        Text("\(ws.data.settings.defaultFocusMinutes) min").font(.system(size: 12))
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ card: CardConfig, index: Int) -> some View {
        let ws = hub.workspace
        let last = ws.data.settings.cards.count - 1
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(hub.theme.card(card.kind)).frame(width: 14, height: 14)
            Toggle(card.kind.title, isOn: Binding(
                get: { ws.data.settings.cards[index].visible },
                set: { ws.data.settings.cards[index].visible = $0 }
            ))
            .toggleStyle(.checkbox).font(.system(size: 12)).frame(width: 90, alignment: .leading)
            // A width set by dragging matches no preset, so no segment shows as selected.
            Picker("", selection: Binding(
                get: { ws.data.settings.cards[index].weight },
                set: { ws.data.settings.cards[index].weight = $0 }
            )) {
                Text("S").tag(CardConfig.Width.narrow.weight)
                Text("M").tag(CardConfig.Width.regular.weight)
                Text("L").tag(CardConfig.Width.wide.weight)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 96).controlSize(.small)
            Spacer()
            IconButton(symbol: "chevron.up", help: "Move left", color: index == 0 ? .white.opacity(0.2) : .white.opacity(0.7), size: 10) {
                if index > 0 { ws.data.settings.cards.swapAt(index, index - 1) }
            }
            IconButton(symbol: "chevron.down", help: "Move right", color: index == last ? .white.opacity(0.2) : .white.opacity(0.7), size: 10) {
                if index < last { ws.data.settings.cards.swapAt(index, index + 1) }
            }
        }
        .padding(6)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }
}
