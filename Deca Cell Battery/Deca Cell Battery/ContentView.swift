

import SwiftUI

struct ContentView: View {

    @StateObject private var engine = QRTLBatteryEngine()

    // ============================================================
    // MARK: - LIVE CHARGE PERCENT
    // ============================================================

    private var chargePercent: Double {

        guard !engine.cells.isEmpty else {
            return 0.0
        }

        let averageSOC = engine.cells.reduce(0.0) {
            $0 + $1.soc
        } / Double(engine.cells.count)

        return min(
            max(averageSOC * 100.0, 0.0),
            100.0
        )
    }

    // ============================================================
    // MARK: - LIVE ENERGY
    // ============================================================

    private var liveEnergyKWh: Double {

        let targetEnergy =
            QRTLConstants.targetEnergyKWh

        return targetEnergy *
            (chargePercent / 100.0)
    }

    // ============================================================
    // MARK: - ENERGY TARGET PERCENT
    // ============================================================

    private var energyTargetPercent: Double {

        guard QRTLConstants.targetEnergyKWh > 0 else {
            return 0.0
        }

        return min(
            max(
                liveEnergyKWh /
                QRTLConstants.targetEnergyKWh *
                100.0,
                0.0
            ),
            100.0
        )
    }

    // ============================================================
    // MARK: - POWER TARGET PERCENT
    // ============================================================

    private var powerTargetPercent: Double {

        guard QRTLConstants.targetChargePowerW > 0 else {
            return 0.0
        }

        let power =
            engine.result.powerCapabilityW

        return min(
            max(
                power /
                QRTLConstants.targetChargePowerW *
                100.0,
                0.0
            ),
            100.0
        )
    }

    // ============================================================
    // MARK: - HAS CHARGING STARTED?
    // ============================================================

    private var chargingHasStarted: Bool {

        engine.generation > 0 ||
        engine.simulatedTimeS > 0.0 ||
        chargePercent > 0.0 ||
        engine.isRunning ||
        engine.status == "Charge complete"
    }

    // ============================================================
    // MARK: - SIMULATION COMPLETE
    // ============================================================

    private var simulationComplete: Bool {

        chargePercent >= 99.9 ||
        engine.status == "Charge complete"
    }

    // ============================================================
    // MARK: - BODY
    // ============================================================

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(spacing: 16) {

                    header

                    // =================================================
                    // PRIMARY MISSION DASHBOARD
                    // =================================================

                    keyIndicatorsPanel

                    // =================================================
                    // DETAILED INFORMATION
                    // =================================================

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

                ToolbarItemGroup(
                    placement: .topBarTrailing
                ) {

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
    // MARK: - HEADER
    // ============================================================

    private var header: some View {

        VStack(
            alignment: .leading,
            spacing: 8
        ) {

            Text("QRTL Battery")
                .font(.largeTitle)
                .bold()

            Text(engine.status)
                .font(.headline)

            HStack {

                Text(
                    "Generation: \(engine.generation)"
                )

                Spacer()

                Text(
                    "Time: \(engine.simulatedTimeS / 60.0, specifier: "%.1f") min"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    // ============================================================
    // MARK: - KEY INDICATORS
    // ============================================================

    private var keyIndicatorsPanel: some View {

        VStack(spacing: 12) {

            // ========================================================
            // DASHBOARD HEADER
            // ========================================================

            HStack {

                Text("MISSION CONTROL")
                    .font(.headline)

                Spacer()

                statusIndicator
            }

            // ========================================================
            // PRIMARY CHARGE INDICATOR
            // ========================================================

            primaryChargeCard

            // ========================================================
            // TIME / GENERATION
            // ========================================================

            HStack(spacing: 10) {

                indicatorCard(
                    title: "ELAPSED TIME",
                    value: String(
                        format: "%.1f min",
                        engine.simulatedTimeS / 60.0
                    ),
                    systemImage: "clock"
                )

                indicatorCard(
                    title: "GENERATION",
                    value: "\(engine.generation)",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }

            // ========================================================
            // POWER / ENERGY
            // ========================================================

            HStack(spacing: 10) {

                indicatorCard(
                    title: "CHARGE POWER",
                    value: String(
                        format: "%.2f MW",
                        engine.result.powerCapabilityW /
                        1_000_000.0
                    ),
                    systemImage: "bolt.fill"
                )

                indicatorCard(
                    title: "USABLE ENERGY",
                    value: String(
                        format: "%.1f kWh",
                        liveEnergyKWh
                    ),
                    systemImage: "battery.100.bolt"
                )
            }

            // ========================================================
            // ENERGY TARGET
            // ========================================================

            progressTargetCard(
                title: "600 kWh ENERGY TARGET",
                progress: energyTargetPercent
            )

            // ========================================================
            // POWER TARGET
            // ========================================================

            progressTargetCard(
                title: "1 MW CHARGE TARGET",
                progress: powerTargetPercent
            )

          
        }
        .padding(14)
        .background(
            RoundedRectangle(
                cornerRadius: 16
            )
            .fill(
                Color.gray.opacity(0.08)
            )
        )
    }

    // ============================================================
    // MARK: - STATUS INDICATOR
    // ============================================================

    private var statusIndicator: some View {

        HStack(spacing: 6) {

            Circle()
                .fill(statusColor)
                .frame(
                    width: 9,
                    height: 9
                )

            Text(statusText)
                .font(.caption)
                .bold()
        }
    }

    // ============================================================
    // MARK: - STATUS COLOR
    // ============================================================

    private var statusColor: Color {

        if engine.isRunning {
            return .orange
        }

        if simulationComplete {
            return .green
        }

        if chargingHasStarted {
            return .blue
        }

        return .gray
    }

    // ============================================================
    // MARK: - STATUS TEXT
    // ============================================================

    private var statusText: String {

        if engine.isRunning {
            return "RUNNING"
        }

        if simulationComplete {
            return "COMPLETE"
        }

        if chargingHasStarted {
            return "ACTIVE"
        }

        return "READY"
    }

    // ============================================================
    // MARK: - PRIMARY CHARGE CARD
    // ============================================================

    private var primaryChargeCard: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                HStack(spacing: 7) {

                    Image(
                        systemName: "battery.100"
                    )
                    .foregroundStyle(.blue)

                    Text("BATTERY CHARGE")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(
                    String(
                        format: "%.1f%%",
                        chargePercent
                    )
                )
                .font(.title)
                .bold()
                .monospacedDigit()
            }

            GeometryReader { geometry in

                ZStack(alignment: .leading) {

                    RoundedRectangle(
                        cornerRadius: 8
                    )
                    .fill(
                        Color.gray.opacity(0.20)
                    )

                    RoundedRectangle(
                        cornerRadius: 8
                    )
                    .fill(
                        simulationComplete
                        ? Color.green
                        : Color.blue
                    )
                    .frame(
                        width:
                            geometry.size.width *
                            CGFloat(
                                chargePercent / 100.0
                            )
                    )
                }
            }
            .frame(height: 18)

            HStack {

                Text("0%")

                Spacer()

                Text("50%")

                Spacer()

                Text("100%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(
                cornerRadius: 12
            )
            .fill(
                Color.gray.opacity(0.10)
            )
        )
    }

    // ============================================================
    // MARK: - INDICATOR CARD
    // ============================================================

    private func indicatorCard(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 6
        ) {

            HStack(spacing: 5) {

                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3)
                .bold()
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: 10
            )
            .fill(
                Color.gray.opacity(0.10)
            )
        )
    }

    // ============================================================
    // MARK: - PROGRESS TARGET CARD
    // ============================================================

    private func progressTargetCard(
        title: String,
        progress: Double
    ) -> some View {

        let clampedProgress =
            min(
                max(progress, 0.0),
                100.0
            )

        let reached =
            clampedProgress >= 100.0

        return VStack(
            alignment: .leading,
            spacing: 7
        ) {

            HStack {

                Text(title)
                    .font(.caption)
                    .bold()

                Spacer()

                Text(
                    String(
                        format: "%.1f%%",
                        clampedProgress
                    )
                )
                .font(.caption)
                .bold()
                .monospacedDigit()
            }

            GeometryReader { geometry in

                ZStack(alignment: .leading) {

                    RoundedRectangle(
                        cornerRadius: 6
                    )
                    .fill(
                        Color.gray.opacity(0.20)
                    )

                    RoundedRectangle(
                        cornerRadius: 6
                    )
                    .fill(
                        reached
                        ? Color.green
                        : Color.blue
                    )
                    .frame(
                        width:
                            geometry.size.width *
                            CGFloat(
                                clampedProgress / 100.0
                            )
                    )
                }
            }
            .frame(height: 10)
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: 10
            )
            .fill(
                Color.gray.opacity(0.10)
            )
        )
    }

    // ============================================================
    // MARK: - MODEL RESULT CARD
    // ============================================================



  

    // ============================================================
    // MARK: - MODEL RESULT SYMBOL
    // ============================================================

    private var modelResultSymbol: String {

        if !chargingHasStarted {
            return "questionmark.circle"
        }

        if engine.isRunning {
            return "arrow.triangle.2.circlepath"
        }

        return engine.result.overallPass
            ? "checkmark.circle.fill"
            : "xmark.circle.fill"
    }

    // ============================================================
    // MARK: - MODEL RESULT COLOR
    // ============================================================

    private var modelResultColor: Color {

        if !chargingHasStarted {
            return .secondary
        }

        if engine.isRunning {
            return .orange
        }

        return engine.result.overallPass
            ? .green
            : .red
    }

    // ============================================================
    // MARK: - TARGET PANEL
    // ============================================================

    private var targetPanel: some View {

        GroupBox("BATTERY TARGETS") {

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                targetRow(
                    name: "Target Energy",
                    value:
                        "\(QRTLConstants.targetEnergyKWh) kWh"
                )

                targetRow(
                    name: "Target Charge Power",
                    value: String(
                        format: "%.1f MW",
                        QRTLConstants.targetChargePowerW /
                        1_000_000.0
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
    // MARK: - BATTERY CHARGE PANEL
    // ============================================================

    private var chargePanel: some View {

        GroupBox("BATTERY CHARGE") {

            VStack(
                alignment: .leading,
                spacing: 12
            ) {

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

                        RoundedRectangle(
                            cornerRadius: 10
                        )
                        .fill(
                            Color.gray.opacity(0.20)
                        )

                        RoundedRectangle(
                            cornerRadius: 10
                        )
                        .fill(
                            simulationComplete
                            ? Color.green
                            : Color.blue
                        )
                        .frame(
                            width:
                                geometry.size.width *
                                CGFloat(
                                    chargePercent / 100.0
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
                        .fill(statusColor)
                        .frame(
                            width: 8,
                            height: 8
                        )

                    Text(statusText)

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
    // MARK: - CA GRID
    // ============================================================

    private var caPanel: some View {

        GroupBox("CELLULAR AUTOMATON") {

            let width =
                QRTLConstants.caWidth

            let height =
                QRTLConstants.caHeight

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
                            .fill(
                                color(
                                    for: cell
                                )
                            )
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
    // MARK: - CELL COLOR
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
    // MARK: - RESULT PANEL
    // ============================================================

    private var resultPanel: some View {

        GroupBox("SIMULATION RESULT") {

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                if !chargingHasStarted {

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {

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
                            engine.result.maximumStressMPa /
                            1_000_000.0
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

                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {

                            Text("Failure Reasons")
                                .font(.headline)

                            ForEach(
                                engine.result.failureReasons,
                                id: \.self
                            ) { reason in

                                Text(
                                    "• \(reason)"
                                )
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
    // MARK: - EQUATIONS
    // ============================================================

    private var equationPanel: some View {

        GroupBox("MODEL EQUATIONS") {

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

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
    // MARK: - ASSUMPTIONS
    // ============================================================

    private var assumptionsPanel: some View {

        GroupBox("ASSUMPTIONS") {

            VStack(
                alignment: .leading,
                spacing: 6
            ) {

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
    // MARK: - ROW HELPERS
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
