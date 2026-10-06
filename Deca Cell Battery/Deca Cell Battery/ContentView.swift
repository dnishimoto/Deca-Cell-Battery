// MARK: - View

import SwiftUI

struct ContentView: View {

    @StateObject private var engine = QRTLBatteryEngine()

    // ============================================================
    // BATTERY CHARGE PERCENT
    // ============================================================

    private var chargePercent: Double {

        guard !engine.cells.isEmpty else {
            return 0.0
        }

        let averageSOC = engine.cells.reduce(0.0) {
            $0 + $1.soc
        } / Double(engine.cells.count)

        return averageSOC * 100.0
    }

    // ============================================================
    // HAS CHARGING STARTED?
    // ============================================================

    private var chargingHasStarted: Bool {
        engine.generation > 0 ||
        engine.simulatedTimeS > 0.0 ||
        chargePercent > 0.0 ||
        engine.isRunning ||
        engine.status == "Charge complete"
    }

    // ============================================================
    // BODY
    // ============================================================

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(spacing: 16) {

                    header
                    targetPanel
                    chargePanel
                    caPanel
                    resultPanel
                    equationPanel
                    assumptionsPanel
                }
                .padding()
            }

            .toolbar {

                ToolbarItemGroup(placement: .topBarTrailing) {

                    Button("RESET") {
                        engine.reset()
                    }

                    Button("RUN CA") {
                        engine.run()
                    }
                    .disabled(engine.isRunning)
                }
            }
        }
    }

    // ============================================================
    // HEADER
    // ============================================================

    private var header: some View {

        VStack(alignment: .leading, spacing: 8) {

            Text("QRTL Battery")
                .font(.largeTitle)
                .bold()

            Text(engine.status)
                .font(.headline)

            HStack {

                Text("Generation: \(engine.generation)")

                Spacer()

                Text(
                    "Time: \(engine.simulatedTimeS / 60.0, specifier: "%.1f") min"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // ============================================================
    // TARGET PANEL
    // ============================================================

    private var targetPanel: some View {

        GroupBox("BATTERY TARGETS") {

            VStack(alignment: .leading, spacing: 8) {

                targetRow(
                    name: "Target Energy",
                    value: "\(QRTLConstants.targetEnergyKWh) kWh"
                )

                targetRow(
                    name: "Target Charge Power",
                    value: String(
                        format: "%.1f MW",
                        QRTLConstants.targetChargePowerW / 1_000_000.0
                    )
                )

                targetRow(
                    name: "Maximum Mass",
                    value: String(
                        format: "%.0f kg",
                        QRTLConstants.maximumPackMassKg
                    )
                )

                targetRow(
                    name: "Target Specific Energy",
                    value: String(
                        format: "%.0f Wh/kg",
                        QRTLConstants.targetSpecificEnergyWhKg
                    )
                )

                targetRow(
                    name: "Maximum Temperature",
                    value: String(
                        format: "%.0f °C",
                        QRTLConstants.maximumTemperatureC
                    )
                )
            }
        }
    }

    // ============================================================
    // BATTERY CHARGE BAR
    // ============================================================

    // ============================================================
    // BATTERY CHARGE BAR
    // ============================================================

    private var chargePanel: some View {

        GroupBox("BATTERY CHARGE") {

            VStack(alignment: .leading, spacing: 12) {

                HStack {

                    Text("Charge")
                        .font(.headline)

                    Spacer()

                    Text(
                        "\(chargePercent, specifier: "%.1f")%"
                    )
                    .font(.title2)
                    .bold()
                    .monospacedDigit()
                }

                // ====================================================
                // ELAPSED CHARGE TIME
                // ====================================================

                HStack {

                    Text("Elapsed Charge Time")
                        .font(.headline)

                    Spacer()

                    Text(
                        "\(engine.simulatedTimeS / 60.0, specifier: "%.1f") min"
                    )
                    .font(.title3)
                    .bold()
                    .monospacedDigit()
                }

                GeometryReader { geometry in

                    ZStack(alignment: .leading) {

                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.gray.opacity(0.20))

                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                chargePercent >= 99.9
                                ? Color.green
                                : Color.blue
                            )
                            .frame(
                                width:
                                    geometry.size.width *
                                    CGFloat(
                                        min(
                                            max(
                                                chargePercent / 100.0,
                                                0.0
                                            ),
                                            1.0
                                        )
                                    )
                            )
                    }
                }
                .frame(height: 24)

                HStack {

                    Text("0%")

                    Spacer()

                    Text("50%")

                    Spacer()

                    Text("100%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {

                    Circle()
                        .fill(
                            chargePercent >= 99.9
                            ? Color.green
                            : Color.blue
                        )
                        .frame(width: 8, height: 8)

                    if chargePercent >= 99.9 {

                        Text("Charge complete")

                    } else {

                        Text("Charging")
                    }

                    Spacer()

                    Text(
                        "\(engine.cells.count) CA cells"
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    // ============================================================
    // CA GRID
    // ============================================================

    private var caPanel: some View {

        GroupBox("CELLULAR AUTOMATON") {

            let width = QRTLConstants.caWidth
            let height = QRTLConstants.caHeight

            LazyVGrid(
                columns: Array(
                    repeating:
                        GridItem(
                            .flexible(),
                            spacing: 1
                        ),
                    count: width
                ),
                spacing: 1
            ) {

                ForEach(
                    0..<(width * height),
                    id: \.self
                ) { index in

                    if index < engine.cells.count {

                        let cell =
                            engine.cells[index]

                        Rectangle()
                            .fill(color(for: cell))
                            .aspectRatio(
                                1,
                                contentMode: .fit
                            )
                    }
                }
            }
            .padding(4)
        }
    }

    // ============================================================
    // CELL COLOR
    // ============================================================

    private func color(
        for cell: QRTLCAChargeCell
    ) -> Color {

        switch cell.state {

        case .empty:
            return Color.gray.opacity(0.25)

        case .receiving:
            return Color.blue

        case .reacting:
            return Color.orange

        case .charged:
            return Color.green

        case .thermal:
            return Color.red

        case .damaged:
            return Color.black
        }
    }

    // ============================================================
    // RESULT PANEL
    // ============================================================

    private var resultPanel: some View {

        GroupBox("SIMULATION RESULT") {

            VStack(alignment: .leading, spacing: 8) {

                if !chargingHasStarted {

                    VStack(alignment: .leading, spacing: 8) {

                        Text("NOT EVALUATED")
                            .font(.title2)
                            .bold()

                        Text(
                            "Start the charging simulation to evaluate the battery design."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Divider()

                        resultRow(
                            "Battery Charge",
                            "0.00%"
                        )

                        resultRow(
                            "Usable Energy",
                            "0.0 kWh"
                        )

                        resultRow(
                            "Power Capability",
                            String(
                                format: "%.2f MW",
                                QRTLConstants.targetChargePowerW /
                                1_000_000.0
                            )
                        )

                        resultRow(
                            "Charge Time",
                            "—"
                        )

                        resultRow(
                            "Pack Mass",
                            "—"
                        )

                        resultRow(
                            "Specific Energy",
                            "—"
                        )

                        resultRow(
                            "Efficiency",
                            "—"
                        )

                        resultRow(
                            "Maximum Temperature",
                            "—"
                        )

                        resultRow(
                            "Maximum Stress",
                            "—"
                        )
                    }

                } else {

                    resultRow(
                        "Battery Charge",
                        String(
                            format: "%.2f%%",
                            chargePercent
                        )
                    )

                    resultRow(
                        "Usable Energy",
                        String(
                            format: "%.1f kWh",
                            engine.result.usableEnergyKWh
                        )
                    )

                    resultRow(
                        "Power Capability",
                        String(
                            format: "%.2f MW",
                            engine.result.powerCapabilityW /
                            1_000_000.0
                        )
                    )

                    resultRow(
                        "Charge Time",
                        String(
                            format: "%.1f min",
                            engine.result.chargeTimeHours * 60.0
                        )
                    )

                    resultRow(
                        "Pack Mass",
                        String(
                            format: "%.1f kg",
                            engine.result.packMassKg
                        )
                    )

                    resultRow(
                        "Specific Energy",
                        String(
                            format: "%.0f Wh/kg",
                            engine.result.specificEnergyWhKg
                        )
                    )

                    resultRow(
                        "Efficiency",
                        String(
                            format: "%.2f%%",
                            engine.result.efficiency * 100.0
                        )
                    )

                    resultRow(
                        "Maximum Temperature",
                        String(
                            format: "%.1f °C",
                            engine.result.maxTemperatureC
                        )
                    )

                    resultRow(
                        "Maximum Stress",
                        String(
                            format: "%.1f MPa",
                            engine.result.maximumStressMPa / 1_000_000.0
                        )
                    )

                    Divider()

                    Text(
                        engine.result.overallPass
                        ? "PASS"
                        : "FAIL"
                    )
                    .font(.title2)
                    .bold()
                    .foregroundStyle(
                        engine.result.overallPass
                        ? .green
                        : .red
                    )

                    if !engine.result.overallPass &&
                        !engine.result.failureReasons.isEmpty {

                        VStack(alignment: .leading, spacing: 4) {

                            Text("Failure Reasons")
                                .font(.headline)

                            ForEach(
                                engine.result.failureReasons,
                                id: \.self
                            ) { reason in

                                Text("• \(reason)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    // EQUATIONS
    // ============================================================

    private var equationPanel: some View {

        GroupBox("MODEL EQUATIONS") {

            VStack(alignment: .leading, spacing: 8) {

                Text("SOC")
                    .bold()

                Text(
                    "SOC changes from applied charging current, local transport, and cell acceptance."
                )

                Text("Lithium-ion transport")
                    .bold()

                Text(
                    "Li⁺ flux is estimated from concentration and electrochemical potential gradients."
                )

                Text("Nernst")
                    .bold()

                Text(
                    "Equilibrium voltage changes with lithium and sulfur state."
                )

                Text("Resonator")
                    .bold()

                Text(
                    "The 1 MHz resonator is modeled using stored energy, Q factor, amplitude, and damping."
                )

                Text("Thermal")
                    .bold()

                Text(
                    "Heat is estimated from ohmic, reaction, resonator, and reversible contributions."
                )

                Text("Mechanical")
                    .bold()

                Text(
                    "Resonator displacement produces estimated strain and stress."
                )
            }
            .font(.caption)
        }
    }

    // ============================================================
    // ASSUMPTIONS
    // ============================================================

    private var assumptionsPanel: some View {

        GroupBox("ASSUMPTIONS") {

            VStack(alignment: .leading, spacing: 6) {

                Text(
                    "This is a reduced-order computational model."
                )

                Text(
                    "The CA represents a 2D slice of the proposed battery structure."
                )

                Text(
                    "Lithium transport, electrochemistry, thermal behavior, mechanics, and resonator behavior are modeled using simplified equations."
                )

                Text(
                    "A PASS result is a model result and is not experimental validation of a physical battery."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // ============================================================
    // ROW HELPERS
    // ============================================================

    private func targetRow(
        name: String,
        value: String
    ) -> some View {

        HStack {

            Text(name)

            Spacer()

            Text(value)
                .bold()
                .monospacedDigit()
        }
    }

    private func resultRow(
        _ name: String,
        _ value: String
    ) -> some View {

        HStack {

            Text(name)

            Spacer()

            Text(value)
                .bold()
                .monospacedDigit()
        }
    }
}
