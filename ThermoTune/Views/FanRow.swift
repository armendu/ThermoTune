import SwiftUI

struct FanRow: View {
    let fan: FanInfo
    @Environment(HardwareMonitor.self) private var monitor
    @State private var targetRPM: Double = 0
    @State private var isEditing = false

    private var mode: FanMode { monitor.mode(of: fan) }
    private var isBusy: Bool { monitor.busyFans.contains(fan.id) }

    private var canControl: Bool {
        monitor.canControlFans && fan.maximum > fan.minimum && !isBusy
    }

    private var range: ClosedRange<Double> {
        fan.minimum...max(fan.maximum, fan.minimum + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(fan.name, systemImage: "fan")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: fan.actual > 0)
                    .font(.headline)
                speedText
                    .font(.callout.monospacedDigit())
                    .contentTransition(.numericText())
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                        .help("Switching modes can take about 10 seconds while macOS hands over fan control.")
                }
                Picker("Mode", selection: modeBinding) {
                    ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!canControl)
            }

            if mode == .manual {
                HStack {
                    Slider(value: $targetRPM, in: range, step: 100) {
                        Text("Target")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    } onEditingChanged: { editing in
                        isEditing = editing
                        if !editing { monitor.setMode(.manual, fan: fan, rpm: targetRPM) }
                    }
                    .controlSize(.small)
                    .disabled(!canControl)
                    Text(targetRPM.rpm)
                        .font(.callout.monospacedDigit())
                        .frame(width: 76, alignment: .trailing)
                }
            } else {
                ProgressView(value: min(fan.actual, fan.maximum), total: max(fan.maximum, 1))
                    .tint(mode == .max ? .red : .accentColor)
                    .help("\(Int(fan.minimum))–\(Int(fan.maximum)) RPM")
            }

            if mode == .automatic, fan.isControlUnlocked, !isBusy {
                Label("Held at minimum speed until every fan is back on Auto.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: syncTarget)
        .onChange(of: fan.target) { syncTarget() }
    }

    /// Current speed with the fan's ceiling, so a running fan always shows how
    /// far it could go: "2,321 / 6,800 RPM", or "Off · max 6,800 RPM".
    private var speedText: Text {
        let maximum = Int(fan.maximum).formatted()
        if fan.actual < 1 {
            return Text("Off").foregroundStyle(.secondary)
                + Text(" · max \(maximum) RPM").foregroundStyle(.tertiary)
        }
        return Text(Int(fan.actual).formatted()).foregroundStyle(.secondary)
            + Text(" / \(maximum) RPM").foregroundStyle(.tertiary)
    }

    private var modeBinding: Binding<FanMode> {
        Binding(
            get: { mode },
            set: { newMode in
                if newMode == .manual {
                    targetRPM = clamped(max(fan.actual, fan.minimum))
                }
                monitor.setMode(newMode, fan: fan, rpm: targetRPM)
            }
        )
    }

    private func syncTarget() {
        guard !isEditing else { return }
        targetRPM = clamped(fan.isManual ? fan.target : max(fan.actual, fan.minimum))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
