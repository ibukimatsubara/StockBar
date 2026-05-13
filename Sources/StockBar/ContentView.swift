import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: StockStore
    @State private var newSymbol: String = ""
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stockList
            Divider()
            addBar
            Divider()
            footer
            if showSettings {
                Divider()
                SettingsView()
                    .padding(12)
            }
        }
        .frame(width: 520)
    }

    private var header: some View {
        HStack {
            Text("StockBar").font(.headline)
            Spacer()
            Button(action: { store.toggleFocus() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.focusMode ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(store.focusMode ? "集中モード ON" : "集中モード OFF")
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.secondary.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var stockList: some View {
        List {
            ForEach(store.stocks) { stock in
                StockRow(stock: stock)
            }
            .onMove(perform: store.move)
        }
        .listStyle(.plain)
        .frame(minHeight: 240, idealHeight: CGFloat(min(max(store.stocks.count, 4) * 44, 480)), maxHeight: 480)
    }

    private var addBar: some View {
        HStack {
            TextField("銘柄コード (例: 7203.T, AAPL, ^N225)", text: $newSymbol)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addSymbol() }
            Button("追加") { addSymbol() }
                .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button(action: { showSettings.toggle() }) {
                Label("設定", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
            if let err = store.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button("終了") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addSymbol() {
        let s = newSymbol
        newSymbol = ""
        store.add(symbol: s)
    }
}

struct StockRow: View {
    @EnvironmentObject var store: StockStore
    let stock: Stock
    @State private var draftNickname: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 1) {
                TextField(stock.quote?.name ?? stock.symbol, text: $draftNickname)
                    .font(.system(size: 13, weight: .medium))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($nameFocused)
                    .help(stock.quote?.name ?? stock.symbol)
                    .onAppear { draftNickname = stock.nickname ?? "" }
                    .onChange(of: nameFocused) { focused in
                        if !focused {
                            store.setNickname(stock, to: draftNickname)
                        }
                    }
                    .onSubmit {
                        store.setNickname(stock, to: draftNickname)
                        nameFocused = false
                    }
                HStack(spacing: 6) {
                    Text(stock.symbol)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    sessionBadge(for: stock.quote?.session)
                }
            }

            Spacer()

            if let q = stock.quote {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(StockStore.formatPrice(q.price))
                        .font(.system(size: 12, design: .monospaced))
                    Text(String(format: "%+.2f%%", q.changePercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(q.change >= 0 ? .red : .green)
                }
            } else {
                Text("…").foregroundColor(.secondary)
            }

            Toggle("", isOn: Binding(
                get: { stock.visible },
                set: { _ in store.toggleVisible(stock) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button(action: { store.remove(stock) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .opacity(stock.visible ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func sessionBadge(for session: MarketSession?) -> some View {
        switch session {
        case .pre:
            badgeView("PRE", color: .orange)
        case .post:
            badgeView("AH", color: .purple)
        default:
            EmptyView()
        }
    }

    private func badgeView(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.4), lineWidth: 0.5)
            )
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: StockStore
    @StateObject private var launch = LaunchAtLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderRow(
                label: "切替間隔",
                value: $store.rotationInterval,
                range: 1...30,
                step: 1,
                format: { "\(Int($0))秒" }
            )
            simultaneousRow
            Toggle(isOn: Binding(
                get: { launch.isEnabled },
                set: { launch.setEnabled($0) }
            )) {
                Text("ログイン時に自動起動")
            }
            .toggleStyle(.checkbox)
            if let err = launch.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            Text("価格は表示直前に銘柄ごとに取得します。ポップオーバーを開くと一括で再取得します。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .font(.caption)
        .onAppear { launch.refresh() }
    }

    private var simultaneousRow: some View {
        let binding = Binding<Int>(
            get: { store.simultaneousCount },
            set: { store.simultaneousCount = min(max($0, 1), 6) }
        )
        return HStack(spacing: 8) {
            Text("同時表示").frame(width: 56, alignment: .leading)
            Spacer(minLength: 0)
            TextField("", value: binding, format: .number)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Text("銘柄")
                .font(.caption2)
                .foregroundColor(.secondary)
            Stepper("", value: binding, in: 1...6, step: 1)
                .labelsHidden()
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 56, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format(value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
                .foregroundColor(.secondary)
        }
    }

    private func formatSeconds(_ s: Double) -> String {
        let v = Int(s)
        if v < 60 { return "\(v)秒" }
        if v % 60 == 0 { return "\(v / 60)分" }
        return String(format: "%d分%02d秒", v / 60, v % 60)
    }
}
