import Charts
import Monitor
import SwiftUI

/// Live, read-only gauges for storage, RAM, CPU, thermal state and battery, with a 60-second chart (spec §9).
struct MonitorView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    MonitorScreen(model: MonitorModel(app: app))
  }
}

private struct MonitorScreen: View {
  @State var model: MonitorModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          label("Space")
          GaugeView(title: "Storage", symbol: "internaldrive", value: model.storage?.usedFraction,
                    detail: model.storageText) {
            if model.photosOnDevice > 0 || model.library.library.inCloudBytes > 0 {
              VStack(alignment: .leading, spacing: Roll.Space.xs) {
                Rectangle().fill(.rollHairline).frame(height: Roll.hairlineWidth)
                if model.photosOnDevice > 0 {
                  FigureLine(title: "Photos and videos on this iPhone", value: ByteFormat.about(model.photosOnDevice))
                }
                if model.library.library.inCloudBytes > 0 {
                  FigureLine(title: "In iCloud or not checked yet (not counted above)",
                             value: ByteFormat.about(model.library.library.inCloudBytes), quiet: true)
                }
              }
            }
          }

          label("Memory and CPU")
          VStack(spacing: Roll.Space.s) {
            GaugeView(title: "Memory", symbol: "memorychip", value: model.sampler.memory?.usedFraction,
                      detail: model.ramText)
            GaugeView(title: "CPU", symbol: "cpu", value: model.cpuTotal,
                      detail: "\(model.sampler.perCoreLoad.count) cores") {
              if !model.sampler.perCoreLoad.isEmpty { CoreBars(loads: model.sampler.perCoreLoad) }
            }
          }

          label("Last 60 seconds")
          HistoryChart(samples: model.sampler.samples)
            .frame(height: 160)
            .rollCard()

          label("Device")
          VStack(spacing: Roll.Space.s) {
            GaugeView(title: "Battery", symbol: "battery.75percent",
                      value: model.sampler.batteryLevel.map(Double.init), detail: model.batteryText)
            RollGroup {
              ThermalRow(state: model.thermalText, color: thermalColor)
              RollRow(symbol: "clock", title: "Up for", trailing: model.uptimeText)
            }
          }

          Text(MonitorModel.footer)
            .font(Roll.Typeface.caption)
            .foregroundStyle(.rollInk3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Roll.Space.s)
            .padding(.horizontal, Roll.Space.xxs)
        }
        .padding(.horizontal, Roll.Space.page)
        .padding(.bottom, Roll.Space.xl)
      }
      .rollPage()
      .navigationTitle("Monitor")
      .onAppear { model.start() }
      .onDisappear { model.stop() }
    }
  }

  private func label(_ text: String) -> some View {
    SectionLabel(text)
      .padding(.horizontal, Roll.Space.xxs)
      .padding(.top, Roll.Space.l)
      .padding(.bottom, Roll.Space.s)
  }

  /// The thermal level's dot in brand: quiet while normal, ink when fair, ember when the iPhone is hot (serious or
  /// critical, the only warning state these readings have). Never green.
  private var thermalColor: Color {
    switch model.sampler.thermalState {
    case .nominal: .rollInk3
    case .fair: .rollInk
    case .serious, .critical: .rollEmber
    @unknown default: .rollInk3
    }
  }
}

/// "Photos and videos on this iPhone   about 12 GB", on the storage card.
private struct FigureLine: View {
  let title: String
  let value: String
  var quiet = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Roll.Space.xs) {
      Text(title)
        .font(Roll.Typeface.caption)
        .foregroundStyle(quiet ? .rollInk3 : .rollInk2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: Roll.Space.xs)
      Text(value)
        .font(Roll.Typeface.figure)
        .foregroundStyle(quiet ? .rollInk2 : .rollInk)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The thermal state in words with a dot (Normal / Fair / Serious / Critical), not a percentage:
/// `ProcessInfo.thermalState` is a level, not a measurement.
private struct ThermalRow: View {
  let state: String
  let color: Color

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      RollIconTile(symbol: "thermometer.medium")
      Text("Thermal").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
      Spacer(minLength: Roll.Space.xs)
      HStack(spacing: Roll.Space.xs) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(state).font(Roll.Typeface.figure).foregroundStyle(.rollInk2)
      }
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.vertical, Roll.Space.s)
    .frame(minHeight: 56)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thermal")
    .accessibilityValue(state)
  }
}

private struct CoreBars: View {
  let loads: [Double]

  var body: some View {
    HStack(alignment: .bottom, spacing: Roll.Space.xxs) {
      ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
        ZStack(alignment: .bottom) {
          RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.rollWell)
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.rollInk)
            .frame(height: max(3, 40 * load))
        }
        .frame(maxWidth: .infinity, maxHeight: 40)
      }
    }
    .frame(height: 40)
    .animation(Roll.Motion.ease, value: loads)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Per-core load")
    .accessibilityValue(loads.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: ", "))
  }
}

private struct HistoryChart: View {
  let samples: [DeviceSample]

  /// Memory in ink, CPU in ink2 and dashed: told apart without a decorative color.
  private static let series: KeyValuePairs<String, Color> = ["Memory": Roll.Palette.ink, "CPU": Roll.Palette.ink2]

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.s) {
      HStack(spacing: Roll.Space.m) {
        legend("Memory", color: .rollInk, dashed: false)
        legend("CPU", color: .rollInk2, dashed: true)
      }
      .accessibilityHidden(true)
      Chart {
        ForEach(samples, id: \.date) { sample in
          if let ram = sample.ramUsedFraction {
            LineMark(x: .value("Time", sample.date), y: .value("Load", ram), series: .value("Reading", "Memory"))
              .foregroundStyle(by: .value("Reading", "Memory"))
              .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
          }
          if let cpu = sample.cpuTotal {
            LineMark(x: .value("Time", sample.date), y: .value("Load", cpu), series: .value("Reading", "CPU"))
              .foregroundStyle(by: .value("Reading", "CPU"))
              .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 3]))
          }
        }
      }
      .chartForegroundStyleScale(Self.series)
      .chartLegend(.hidden)
      .chartYScale(domain: 0...1)
      .chartYAxis {
        AxisMarks(values: [0, 0.5, 1]) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: Roll.hairlineWidth)).foregroundStyle(.rollHairline)
          AxisValueLabel {
            Text("\(Int((value.as(Double.self) ?? 0) * 100))%")
              .font(Roll.Typeface.caption.monospacedDigit())
              .foregroundStyle(.rollInk3)
          }
        }
      }
      .chartXAxis(.hidden)
      .accessibilityLabel("Memory and CPU over the last minute")
    }
  }

  private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
    HStack(spacing: 6) {
      Path { path in
        path.move(to: CGPoint(x: 0, y: 1))
        path.addLine(to: CGPoint(x: 14, y: 1))
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : []))
      .frame(width: 14, height: 2)
      Text(title).font(Roll.Typeface.label).foregroundStyle(.rollInk2)
    }
  }
}

#if DEBUG
#Preview {
  PreviewHost { MonitorView() }
}
#endif
