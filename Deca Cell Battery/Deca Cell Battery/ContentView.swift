import SwiftUI
import Foundation
import Combine

// ============================================================
// QRTL BATTERY — EQUATION-COUPLED REDUCED-ORDER CA (corrected)
// ============================================================
// Reduced-order engineering simulation, not a validated
// electrochemical FEM model. Target quantities are never compared
// with themselves: usable energy comes from integrated SOC, charge
// time from elapsed simulated time, losses from the coupled
// kinetics / ohmic / resonator terms.
//
// Key corrections versus the previous version:
//  * Resonator spring constant/damping derived from m, f0 and Q
//    (the old k gave a 1 kHz resonator driven at 1 MHz -> zero response)
//  * Resonator power is an energy balance (P_abs, E = P*Q/w), not P*Q
//  * Lithium mass uses total pack Ah (all 2,700 cells), not one string
//  * SOC is integrated from current: dSOC = I*dt / (Q*3600)
//  * Pack losses scale by the real cell count (2,700), not CA node count
//  * Thermal update is implicit (unconditionally stable), conduction in W
//  * Nernst-Planck uses the Li+ concentration field, not the SOC field
//  * Overpotential no longer double counted (not inside impedance)
//  * Thermal-limit power uses sqrt scaling (loss ~ I^2) and no longer
//    adds electrical power to heat-rejection capacity
//  * Ionic conductivity 0.006 -> 0.6 S/m (0.006 was S/cm)
//  * Kinetics/ohmic area is the electrode area (capacity / areal loading),
//    not the 0.10 m^2 outer thermal area
//  * 2-D gyroid slice uses a real z-offset (sin x cos y + sin y cos z0 +
//    sin z0 cos x); the old formula collapsed to sin(x+y)
//  * Compile fixes: String(format:), Color ternaries, no Timer in deinit
// ============================================================

// MARK: - Constants

struct QRTLConstants {
    // Targets
    static let targetEnergyKWh = 600.0
    static let targetChargePowerW = 1_000_000.0
    static let maximumPackMassKg = 300.0
    static let targetSpecificEnergyWhKg = 2_000.0
    static let maximumTemperatureC = 60.0
    static let minimumEfficiency = 0.99
    static let maximumChargeTimeHours = 0.60
    static let maximumStressMPa = 900.0

    // Topology
    static let seriesCells = 450
    static let parallelStrings = 6
    static let cellCount = seriesCells * parallelStrings
    static let cellNominalVoltageV = 2.22

    // Physical constants
    static let faraday = 96_485.33212
    static let gasConstant = 8.314462618
    static let sulfurMolarMassKgMol = 0.032065
    static let sulfurElectrons = 2.0
    static let sulfurTheoreticalAhKg =
        sulfurElectrons * faraday / sulfurMolarMassKgMol / 3600.0
    static let lithiumSpecificCapacityAhKg = 3_860.0
    static let sulfurUtilization = 0.95

    // Design variables (cell is sized from material, not from the target)
    static let sulfurMassPerCellKg = 0.0632
    static let arealCapacityAhM2 = 40.0          // 4 mAh/cm^2 loading (model input)

    // Derived design quantities
    static let cellCapacityAh =
        sulfurMassPerCellKg * sulfurTheoreticalAhKg * sulfurUtilization
    static let packVoltageV = Double(seriesCells) * cellNominalVoltageV
    static let packCapacityAh = cellCapacityAh * Double(parallelStrings)
    static let ratedEnergyKWh = packVoltageV * packCapacityAh / 1000.0
    static let activeElectrodeAreaM2PerCell = cellCapacityAh / arealCapacityAhM2
    static let targetPackCurrentA = targetChargePowerW / packVoltageV
    static let targetCellCurrentA = targetPackCurrentA / Double(parallelStrings)

    // Reduced-order material parameters (model inputs, not measurements)
    static let electronicConductivitySm = 5.0e4
    static let ionicConductivitySm = 0.6
    static let lithiumDiffusivityM2s = 2.0e-11
    static let sulfurDiffusivityScale = 1.0
    static let referenceExchangeCurrentAm2 = 25.0
    static let chargeTransferCoefficient = 0.5
    static let exchangeCurrentActivationEnergyJMol = 30_000.0
    static let entropicCoefficientVPerK = -0.0002

    static let electrolyteThicknessM = 25e-6
    static let electrodeThicknessM = 100e-6
    static let effectiveElectrodePorosity = 0.55
    static let tortuosity = 2.0

    static let conductorResistivityOhmM = 2.82e-8
    static let conductorLengthM = 0.10
    static let conductorAreaM2 = 1e-4
    static let interfaceResistanceOhmPerCell = 10e-6

    // Resonator: k and c are derived so f0 = design frequency and Q = qualityFactor
    static let resonanceFrequencyHz = 1_000_000.0        // drive frequency
    static let resonatorDesignFrequencyHz = 1_000_000.0  // sets k
    static let qualityFactor = 2_500.0
    static let resonatorDrivePowerFraction = 0.005
    static let resonatorCouplingEfficiency = 0.95
    static let resonatorMassPerCellKg = 0.002
    static let resonatorDesignOmega = 2.0 * Double.pi * resonatorDesignFrequencyHz
    static let resonatorSpringConstantNpm =
        resonatorMassPerCellKg * resonatorDesignOmega * resonatorDesignOmega
    static let resonatorDampingNsM =
        resonatorMassPerCellKg * resonatorDesignOmega / qualityFactor

    static let piezoCouplingCoefficient = 0.12

    // Mass model
    static let collectorAreaM2 = 0.025
    static let collectorThicknessM = 10e-6
    static let collectorDensityKgM3 = 2_700.0
    static let collectorsPerCell = 2.0
    static let tpmsCellVolumeM3 = 1.0e-5
    static let tpmsRelativeDensity = 0.05
    static let tpmsMaterialDensityKgM3 = 4_420.0
    static let tpmsThermalAreaM2PerCell = 0.10
    static let carbonToSulfurMassRatio = 0.05
    static let electrolyteToSulfurMassRatio = 0.06
    static let packagingMassKgPerCell = 0.003
    static let packOverheadFraction = 0.05

    // Thermal
    static let heatTransferCoefficientWm2K = 250.0
    static let cellHeatCapacityJPerK = 1_000.0
    static let ambientTemperatureC = 25.0
    static let thermalConductivityWmK = 4.0
    static let caSliceDepthM = 0.01

    // Mechanics
    static let youngsModulusPa = 110e9

    // Degradation (per full-SOC charge throughput)
    static let degradationCoefficientPerCycle = 0.000002

    // CA
    static let caWidth = 31
    static let caHeight = 31
    static let caIterations = 240
    static let simSecondsPerStep = 15.0        // simulated seconds per CA generation
    static let caTransportCoefficient = 0.18   // numerical lateral SOC mixing
    static let caAcceptanceModulation = 0.25   // TPMS-driven spread in charge acceptance
    static let caCellLengthM = 0.001
    static let tabReservoirConcentration = 0.90
    static let tpmsSliceZ = 0.6
    static let chargeCompleteSOC = 0.999
}

// MARK: - Math Helpers

@inline(__always)
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}

@inline(__always)
func safeExp(_ x: Double) -> Double {
    exp(clamp(x, -50.0, 50.0))
}

@inline(__always)
func safeLog(_ x: Double) -> Double {
    log(max(x, 1e-12))
}

// MARK: - CA Cell

struct QRTLCAChargeCell: Identifiable {
    let id = UUID()
    var x: Int
    var y: Int

    var phiTPMS: Double = 0
    var solidFraction: Double = 0
    var tortuosity: Double = QRTLConstants.tortuosity
    var porosity: Double = QRTLConstants.effectiveElectrodePorosity

    var soc: Double = 0
    var lithiumConcentration: Double = 0.5
    var sulfurFraction: Double = 0.001
    var lithiumIonFlux: Double = 0
    var electronicCurrentDensity: Double = 0
    var reactionRate: Double = 0
    var exchangeCurrentDensity: Double = QRTLConstants.referenceExchangeCurrentAm2
    var overpotentialV: Double = 0
    var equilibriumVoltageV: Double = QRTLConstants.cellNominalVoltageV
    var localVoltageV: Double = QRTLConstants.cellNominalVoltageV
    var impedanceOhm: Double = 0

    var temperatureC: Double = QRTLConstants.ambientTemperatureC
    var heatGenerationW: Double = 0
    var heatFluxWm2: Double = 0

    var strain: Double = 0
    var stressPa: Double = 0
    var resonanceAmplitudeM: Double = 0
    var resonancePhaseRad: Double = 0
    var resonatorEnergyJ: Double = 0
    var resonatorLossW: Double = 0
    var piezoPowerW: Double = 0

    var degradation: Double = 0
    var chargeEnergyJ: Double = 0
    var state: CellState = .empty

    enum CellState {
        case empty
        case receiving
        case reacting
        case charged
        case thermal
        case damaged
    }
}

@inline(__always)
func transportFactor(_ c: QRTLCAChargeCell) -> Double {
    max(c.porosity, 0.05) / max(c.tortuosity, 1.0)
}

@inline(__always)
func effectiveDiffusivity(_ c: QRTLCAChargeCell) -> Double {
    QRTLConstants.lithiumDiffusivityM2s / max(c.tortuosity, 1.0) *
    c.porosity * QRTLConstants.sulfurDiffusivityScale
}

// MARK: - Design Result

struct QRTLDesignResult {
    var cellCapacityAh = 0.0
    var sulfurMassKg = 0.0
    var lithiumMassKg = 0.0
    var carbonMassKg = 0.0
    var electrolyteMassKg = 0.0
    var collectorMassKg = 0.0
    var tpmsMassKg = 0.0
    var resonatorMassKg = 0.0
    var packagingMassKg = 0.0
    var packMassKg = 0.0

    var ratedEnergyKWh = 0.0
    var usableEnergyKWh = 0.0
    var specificEnergyWhKg = 0.0
    var packVoltageV = 0.0
    var packCapacityAh = 0.0

    var totalResistanceOhm = 0.0
    var ohmicLossW = 0.0
    var reactionLossW = 0.0
    var entropicHeatW = 0.0      // signed reversible heat (negative = endothermic on charge)
    var resonatorLossW = 0.0
    var thermalLossW = 0.0       // heat actually rejected to coolant
    var totalLossW = 0.0         // irreversible: ohmic + reaction + resonator
    var efficiency = 0.0

    var modeledChargePowerW = 0.0
    var powerCapabilityW = 0.0
    var chargeTimeHours = 0.0
    var maxTemperatureC = 0.0

    var tpmsSurfaceAreaM2 = 0.0
    var tpmsPorosity = 0.0
    var tpmsRelativeDensity = 0.0

    var averageSOC = 0.0
    var sulfurUtilization = 0.0
    var averageOverpotentialV = 0.0
    var averageImpedanceOhm = 0.0
    var averageResonanceAmplitudeM = 0.0
    var maximumStressMPa = 0.0
    var degradationFraction = 0.0

    var energyPass = false
    var powerPass = false
    var massPass = false
    var specificEnergyPass = false
    var efficiencyPass = false
    var thermalPass = false
    var timePass = false
    var mechanicalPass = false
    var overallPass = false

    var failureReasons: [String] = []
}

// MARK: - Engine

@MainActor
final class QRTLBatteryEngine: ObservableObject {
    @Published var cells: [QRTLCAChargeCell] = []
    @Published var generation = 0
    @Published var isRunning = false
    @Published var result = QRTLDesignResult()
    @Published var status = "Ready"
    @Published var simulatedTimeS = 0.0

    private var runTask: Task<Void, Never>?

    // Static-geometry caches (rebuilt in buildCA)
    private var neighborTable: [[Int]] = []
    private var acceptance: [Double] = []
    private var meanTransport = 1.0
    private var nodeResistanceOhm: [Double] = []
    private var effectiveCellResistanceOhm = 0.0

    // Energy bookkeeping
    private var cumulativeInputEnergyJ = 0.0
    private var cumulativeLossEnergyJ = 0.0

    init() {
        reset()
    }

    deinit {
        runTask?.cancel()
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        resetState()
        buildCA()
        result = calculateDesignResult()
        status = "Ready — equation-coupled model"
    }

    func run() {
        runTask?.cancel()
        resetState()
        buildCA()
        result = calculateDesignResult()
        isRunning = true
        status = "Running coupled electrochemical / thermal / mechanical CA"

        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self else { return }
                if engine.advance() { return }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    private func resetState() {
        generation = 0
        simulatedTimeS = 0
        cumulativeInputEnergyJ = 0
        cumulativeLossEnergyJ = 0
    }

    /// One CA generation. Returns true when the run is finished.
    private func advance() -> Bool {
        step()
        let finished = meanValue(\.soc) >= QRTLConstants.chargeCompleteSOC ||
                       generation >= QRTLConstants.caIterations
        if finished {
            isRunning = false
            runTask = nil
            result = calculateDesignResult()
            status = result.overallPass
                ? "TARGET PASS — all modeled constraints satisfied"
                : "TARGET FAIL — CA identified limiting constraints"
        }
        return finished
    }

    // MARK: CA Initialization

    private func buildCA() {
        let w = QRTLConstants.caWidth
        let h = QRTLConstants.caHeight
        var newCells: [QRTLCAChargeCell] = []
        newCells.reserveCapacity(w * h)

        let z0 = QRTLConstants.tpmsSliceZ

        for y in 0..<h {
            for x in 0..<w {
                var c = QRTLCAChargeCell(x: x, y: y)

                // Gyroid slice at z = z0:
                // sin x cos y + sin y cos z + sin z cos x
                let xx = Double(x) * 0.45
                let yy = Double(y) * 0.45
                let phi = sin(xx) * cos(yy) + sin(yy) * cos(z0) + sin(z0) * cos(xx)

                c.phiTPMS = phi
                c.solidFraction = clamp(1.0 - abs(phi) / 1.5, 0.05, 1.0)
                c.porosity = clamp(1.0 - c.solidFraction, 0.05, 0.95)
                c.tortuosity = 1.0 + 1.5 * (1.0 - c.porosity)
                c.soc = 0
                c.lithiumConcentration = 0.50
                c.sulfurFraction = 0.001
                c.temperatureC = QRTLConstants.ambientTemperatureC
                c.state = .empty
                newCells.append(c)
            }
        }

        let n = newCells.count

        // Neighbour table (4-connected)
        var table = [[Int]](repeating: [], count: n)
        for y in 0..<h {
            for x in 0..<w {
                var list: [Int] = []
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    if nx >= 0 && nx < w && ny >= 0 && ny < h {
                        list.append(ny * w + nx)
                    }
                }
                table[y * w + x] = list
            }
        }
        neighborTable = table

        // Charge-acceptance weights with mean exactly 1 (conserves total current)
        let transports = newCells.map { transportFactor($0) }
        meanTransport = max(transports.reduce(0.0, +) / Double(n), 1e-9)
        acceptance = transports.map {
            max(1.0 + QRTLConstants.caAcceptanceModulation * ($0 / meanTransport - 1.0), 0.05)
        }
        let accMean = acceptance.reduce(0.0, +) / Double(n)
        acceptance = acceptance.map { $0 / accMean }

        // Per-node ohmic resistance (full-area equivalent) and the parallel-combined cell value
        nodeResistanceOhm = newCells.map { nodeOhmicResistance($0) }
        let meanConductance = nodeResistanceOhm.reduce(0.0) { $0 + 1.0 / max($1, 1e-12) } / Double(n)
        effectiveCellResistanceOhm = 1.0 / max(meanConductance, 1e-12)
        for i in 0..<n { newCells[i].impedanceOhm = nodeResistanceOhm[i] }

        cells = newCells
    }

    /// Z = Z_collector + Z_electrolyte + Z_electrode(pore ionic) + Z_interface
    /// Effective conductivity in the porous electrode: sigma * eps / tau.
    private func nodeOhmicResistance(_ c: QRTLCAChargeCell) -> Double {
        let area = max(QRTLConstants.activeElectrodeAreaM2PerCell, 1e-6)
        let sigma = QRTLConstants.ionicConductivitySm

        let collectorR =
            QRTLConstants.conductorResistivityOhmM *
            QRTLConstants.conductorLengthM /
            max(QRTLConstants.conductorAreaM2, 1e-12)
        let electrolyteR =
            QRTLConstants.electrolyteThicknessM / (sigma * area)
        let electrodeR =
            QRTLConstants.electrodeThicknessM * max(c.tortuosity, 1.0) /
            (sigma * max(c.porosity, 0.05) * area)

        return collectorR + electrolyteR + electrodeR +
               QRTLConstants.interfaceResistanceOhmPerCell
    }

    // MARK: CA Step

    private func step() {
        guard !cells.isEmpty else { return }

        let previous = cells
        let n = previous.count
        let dtS = QRTLConstants.simSecondsPerStep
        let dtH = dtS / 3600.0
        let dx = QRTLConstants.caCellLengthM
        let F = QRTLConstants.faraday
        let R = QRTLConstants.gasConstant

        let iCell = QRTLConstants.targetCellCurrentA        // current through every cell of a string
        let area = max(QRTLConstants.activeElectrodeAreaM2PerCell, 1e-6)
        let qEffAh = QRTLConstants.cellCapacityAh * max(1.0 - averageDegradation(), 1e-6)

        // --------------------------------------------------------
        // A) SOC from Coulomb counting: dSOC = I dt / (3600 Q)
        //    + conservative lateral mixing + redistribution of
        //    current away from nodes that are already full.
        // --------------------------------------------------------
        let socStep = iCell * dtH / qEffAh
        var newSOC = [Double](repeating: 0, count: n)
        var surplus = 0.0

        for i in 0..<n {
            var mix = 0.0
            for j in neighborTable[i] {
                let face = min(transportFactor(previous[i]), transportFactor(previous[j])) / meanTransport
                mix += QRTLConstants.caTransportCoefficient * 0.25 * face *
                       (previous[j].soc - previous[i].soc)
            }
            let raw = previous[i].soc + mix + socStep * acceptance[i]
            surplus += max(raw - 1.0, 0.0)
            newSOC[i] = clamp(raw, 0.0, 1.0)
        }

        if surplus > 0 {
            let headroom = newSOC.map { 1.0 - $0 }
            let totalHeadroom = headroom.reduce(0.0, +)
            if totalHeadroom > 1e-12 {
                let share = min(surplus / totalHeadroom, 1.0)
                for i in 0..<n { newSOC[i] += headroom[i] * share }
            }
        }

        // --------------------------------------------------------
        // B) NERNST-PLANCK Li+ TRANSPORT (finite-volume, conservative)
        //    N_ij = -D dc/dx - (z F D c / R T) dphi/dx ,  z = +1
        //    dc/dt = -div(N)  (+ tab reservoir boundary at x = 0)
        // --------------------------------------------------------
        var newC = [Double](repeating: 0, count: n)
        var netFlux = [Double](repeating: 0, count: n)

        for i in 0..<n {
            let ci = previous[i]
            let tK = max(ci.temperatureC + 273.15, 1.0)
            var dcdt = 0.0
            var outFlux = 0.0

            for j in neighborTable[i] {
                let cj = previous[j]
                let dFace = 0.5 * (effectiveDiffusivity(ci) + effectiveDiffusivity(cj))
                let cFace = 0.5 * (ci.lithiumConcentration + cj.lithiumConcentration)
                let dC = cj.lithiumConcentration - ci.lithiumConcentration
                let dPhi = cj.equilibriumVoltageV - ci.equilibriumVoltageV

                let nFlux = -dFace * dC / dx - (F * dFace * cFace / (R * tK)) * dPhi / dx
                outFlux += nFlux
                dcdt -= nFlux / dx
            }

            newC[i] = clamp(ci.lithiumConcentration + dcdt * dtS, 0.001, 0.999)
            netFlux[i] = outFlux
            if ci.x == 0 { newC[i] = QRTLConstants.tabReservoirConcentration }
        }

        // --------------------------------------------------------
        // C) RESONATOR (identical for every cell, computed once)
        //    m x'' + c x' + k x = F0 cos(wt)
        //    Absorbed power:  P_abs = P_drive * eta_c / (1 + (2 Q delta)^2)
        //    Stored energy:   E = P_abs Q / w        Loss: P = w E / Q
        // --------------------------------------------------------
        let omegaDrive = 2.0 * Double.pi * QRTLConstants.resonanceFrequencyHz
        let springK = QRTLConstants.resonatorSpringConstantNpm
        let naturalOmega = sqrt(springK / max(QRTLConstants.resonatorMassPerCellKg, 1e-12))
        let detuning = (omegaDrive - naturalOmega) / max(naturalOmega, 1.0)
        let lorentzian = 1.0 / (1.0 + pow(2.0 * QRTLConstants.qualityFactor * detuning, 2.0))

        let drivePowerPerCell =
            QRTLConstants.targetChargePowerW *
            QRTLConstants.resonatorDrivePowerFraction /
            Double(QRTLConstants.cellCount)

        let absorbedPowerW =
            drivePowerPerCell * QRTLConstants.resonatorCouplingEfficiency * lorentzian
        let storedEnergyJ = absorbedPowerW * QRTLConstants.qualityFactor / max(omegaDrive, 1.0)
        let resonatorLossW = omegaDrive * storedEnergyJ / QRTLConstants.qualityFactor
        let amplitudeM = sqrt(max(2.0 * storedEnergyJ / max(springK, 1e-12), 0.0))
        let phaseRad = atan2(
            (omegaDrive / naturalOmega) / QRTLConstants.qualityFactor,
            1.0 - pow(omegaDrive / naturalOmega, 2.0)
        )

        // Piezo surrogate: reactive electromechanical power  k^2 * w * E
        let piezoPower =
            QRTLConstants.piezoCouplingCoefficient * QRTLConstants.piezoCouplingCoefficient *
            omegaDrive * storedEnergyJ

        // --------------------------------------------------------
        // D) Per-node electrochemistry, heat, mechanics
        // --------------------------------------------------------
        let vDrop = iCell * effectiveCellResistanceOhm
        let gCool = QRTLConstants.heatTransferCoefficientWm2K * QRTLConstants.tpmsThermalAreaM2PerCell
        let gCond = QRTLConstants.thermalConductivityWmK * QRTLConstants.caSliceDepthM
        let heatCap = QRTLConstants.cellHeatCapacityJPerK
        let ambient = QRTLConstants.ambientTemperatureC

        var next = previous

        for i in 0..<n {
            var c = previous[i]
            let tK = max(c.temperatureC + 273.15, 1.0)

            c.soc = newSOC[i]
            c.lithiumConcentration = newC[i]
            c.lithiumIonFlux = netFlux[i]
            c.sulfurFraction = clamp(c.soc, 0.001, 1.0)    // charged (S8) fraction

            // Nernst: Eeq = E0 + RT/(nF) ln(Q)
            let reactionQuotient =
                max(c.sulfurFraction, 0.01) / max(c.lithiumConcentration, 0.01)
            c.equilibriumVoltageV =
                QRTLConstants.cellNominalVoltageV +
                (R * tK / (QRTLConstants.sulfurElectrons * F)) * safeLog(reactionQuotient)

            // Butler-Volmer (symmetric inversion): eta = RT/(alpha F) asinh(j / 2 j0)
            let arrhenius = safeExp(
                QRTLConstants.exchangeCurrentActivationEnergyJMol / R * (1.0 / 298.15 - 1.0 / tK)
            )
            let speciesFactor = sqrt(max(c.soc, 0.05) * max(1.0 - c.soc, 0.05))
            c.exchangeCurrentDensity =
                QRTLConstants.referenceExchangeCurrentAm2 * arrhenius * speciesFactor

            let j = iCell / area
            c.overpotentialV =
                (R * tK / (QRTLConstants.chargeTransferCoefficient * F)) *
                asinh(j / max(2.0 * c.exchangeCurrentDensity, 1e-9))
            c.reactionRate = j / F
            c.electronicCurrentDensity = j     // J_e = sigma_e * |grad phi_e|

            // Ohmic part only; overpotential is accounted separately (no double count)
            c.impedanceOhm = nodeResistanceOhm[i]
            c.localVoltageV = c.equilibriumVoltageV + c.overpotentialV + vDrop

            // Resonator / mechanics
            c.resonatorEnergyJ = storedEnergyJ
            c.resonatorLossW = resonatorLossW
            c.resonanceAmplitudeM = amplitudeM
            c.resonancePhaseRad = phaseRad
            c.piezoPowerW = piezoPower
            c.strain = amplitudeM / max(dx, 1e-9)
            c.stressPa = QRTLConstants.youngsModulusPa * max(c.solidFraction, 0.05) * c.strain

            // Heat: parallel-slice ohmic share + reaction + resonator + reversible
            let ohmicW = vDrop * vDrop / max(nodeResistanceOhm[i], 1e-12)
            let reactionW = iCell * c.overpotentialV
            let reversibleW = iCell * tK * QRTLConstants.entropicCoefficientVPerK  // < 0 on charge
            c.heatGenerationW = ohmicW + reactionW + resonatorLossW + reversibleW

            // Transient heat equation, implicit cooling (unconditionally stable)
            // C dT/dt = q + sum G (Tn - T) - h A (T - Tamb)
            var conduction = 0.0
            for k in neighborTable[i] {
                conduction += gCond * (previous[k].temperatureC - c.temperatureC)
            }
            let tNew =
                (c.temperatureC + dtS / heatCap * (c.heatGenerationW + conduction + gCool * ambient)) /
                (1.0 + dtS * gCool / heatCap)
            c.temperatureC = clamp(tNew, ambient - 20.0, 150.0)
            c.heatFluxWm2 = QRTLConstants.heatTransferCoefficientWm2K * (c.temperatureC - ambient)

            // Degradation per unit charge throughput, accelerated by heat and stress
            let overTemp = max(c.temperatureC - QRTLConstants.maximumTemperatureC, 0.0)
            let stressRatio = c.stressPa / (QRTLConstants.maximumStressMPa * 1e6)
            let deltaSOC = max(c.soc - previous[i].soc, 0.0)
            c.degradation = clamp(
                c.degradation +
                QRTLConstants.degradationCoefficientPerCycle * deltaSOC *
                (1.0 + overTemp / 20.0 + stressRatio),
                0.0, 1.0
            )

            c.chargeEnergyJ += max(iCell * c.localVoltageV, 0.0) * dtS

            if c.degradation > 0.20 {
                c.state = .damaged
            } else if c.temperatureC > QRTLConstants.maximumTemperatureC {
                c.state = .thermal
            } else if c.soc >= 0.98 {
                c.state = .charged
            } else if c.soc >= 0.25 {
                c.state = .reacting
            } else if c.soc > 0.0 {
                c.state = .receiving
            } else {
                c.state = .empty
            }

            next[i] = c
        }

        cells = next
        generation += 1
        simulatedTimeS += dtS

        // --------------------------------------------------------
        // E) Pack-level energy bookkeeping (all 2,700 cells carry I_cell)
        // --------------------------------------------------------
        let nCells = Double(QRTLConstants.cellCount)
        let inputPowerW = nCells * iCell * meanValue(\.localVoltageV)
        let lossPowerW = nCells * (iCell * vDrop +
                                   iCell * meanValue(\.overpotentialV) +
                                   resonatorLossW)
        cumulativeInputEnergyJ += inputPowerW * dtS
        cumulativeLossEnergyJ += lossPowerW * dtS

        result = calculateDesignResult()
    }

    // MARK: Helpers

    private func meanValue(_ keyPath: KeyPath<QRTLCAChargeCell, Double>) -> Double {
        guard !cells.isEmpty else { return 0 }
        return cells.reduce(0.0) { $0 + $1[keyPath: keyPath] } / Double(cells.count)
    }

    private func averageDegradation() -> Double {
        meanValue(\.degradation)
    }

    // MARK: Design / Pack Equations

    private func calculateDesignResult() -> QRTLDesignResult {
        var r = QRTLDesignResult()
        let nCells = Double(QRTLConstants.cellCount)
        let iCell = QRTLConstants.targetCellCurrentA

        r.cellCapacityAh = QRTLConstants.cellCapacityAh
        r.packVoltageV = QRTLConstants.packVoltageV
        r.packCapacityAh = QRTLConstants.packCapacityAh
        r.ratedEnergyKWh = QRTLConstants.ratedEnergyKWh

        // ---- Mass (per-cell Ah x total cell count) ----
        let totalCellAh = r.cellCapacityAh * nCells
        let sulfurCapacityAhKg =
            QRTLConstants.sulfurTheoreticalAhKg * QRTLConstants.sulfurUtilization

        r.sulfurMassKg = QRTLConstants.sulfurMassPerCellKg * nCells
        r.lithiumMassKg = totalCellAh / QRTLConstants.lithiumSpecificCapacityAhKg
        r.carbonMassKg = r.sulfurMassKg * QRTLConstants.carbonToSulfurMassRatio
        r.electrolyteMassKg = r.sulfurMassKg * QRTLConstants.electrolyteToSulfurMassRatio

        let collectorMassPerCell =
            QRTLConstants.collectorAreaM2 *
            QRTLConstants.collectorThicknessM *
            QRTLConstants.collectorDensityKgM3 *
            QRTLConstants.collectorsPerCell
        r.collectorMassKg = collectorMassPerCell * nCells

        let tpmsMassPerCell =
            QRTLConstants.tpmsCellVolumeM3 *
            QRTLConstants.tpmsMaterialDensityKgM3 *
            QRTLConstants.tpmsRelativeDensity
        r.tpmsMassKg = tpmsMassPerCell * nCells
        r.resonatorMassKg = QRTLConstants.resonatorMassPerCellKg * nCells
        r.packagingMassKg = QRTLConstants.packagingMassKgPerCell * nCells

        let activeMass =
            r.sulfurMassKg + r.lithiumMassKg + r.carbonMassKg + r.electrolyteMassKg +
            r.collectorMassKg + r.tpmsMassKg + r.resonatorMassKg + r.packagingMassKg
        r.packMassKg = activeMass * (1.0 + QRTLConstants.packOverheadFraction)

        // Sanity: sulfur capacity check (material-limited cell Ah)
        _ = sulfurCapacityAhKg

        // ---- Energy from integrated SOC ----
        let degradation = averageDegradation()
        r.degradationFraction = degradation
        r.averageSOC = meanValue(\.soc)
        r.usableEnergyKWh = r.ratedEnergyKWh * r.averageSOC * max(1.0 - degradation, 0.0)
        r.specificEnergyWhKg = r.packMassKg > 0 ? r.usableEnergyKWh * 1000.0 / r.packMassKg : 0

        // ---- Losses (pack = 2,700 cells, each carrying I_cell) ----
        let vDrop = iCell * effectiveCellResistanceOhm
        let meanEta = meanValue(\.overpotentialV)
        let meanTempK = meanValue(\.temperatureC) + 273.15

        r.totalResistanceOhm =
            effectiveCellResistanceOhm * Double(QRTLConstants.seriesCells) /
            Double(QRTLConstants.parallelStrings)
        r.ohmicLossW = nCells * iCell * vDrop
        r.reactionLossW = nCells * iCell * meanEta
        r.resonatorLossW = nCells * meanValue(\.resonatorLossW)
        r.entropicHeatW = nCells * iCell * meanTempK * QRTLConstants.entropicCoefficientVPerK
        r.thermalLossW = nCells * meanValue(\.heatFluxWm2) * QRTLConstants.tpmsThermalAreaM2PerCell
        r.totalLossW = r.ohmicLossW + r.reactionLossW + r.resonatorLossW

        let inputPowerW = nCells * iCell * meanValue(\.localVoltageV)
        if cumulativeInputEnergyJ > 0 {
            r.efficiency = clamp(1.0 - cumulativeLossEnergyJ / cumulativeInputEnergyJ, 0.0, 1.0)
        } else {
            r.efficiency = clamp(1.0 - r.totalLossW / max(inputPowerW, 1.0), 0.0, 1.0)
        }

        // ---- Power capability: minimum of three independent limits ----
        let lossFraction = max(1.0 - r.efficiency, 1e-9)

        // 1) 2C cell-current limit
        let currentLimitedPower =
            2.0 * r.cellCapacityAh * Double(QRTLConstants.parallelStrings) * r.packVoltageV

        // 2) Thermal: heat ~ I^2 => P_max = P0 * sqrt(Q_allow / Q_loss0)
        let thermalArea = QRTLConstants.tpmsThermalAreaM2PerCell * nCells
        let allowableHeatW =
            max(QRTLConstants.maximumTemperatureC - QRTLConstants.ambientTemperatureC, 0.0) *
            QRTLConstants.heatTransferCoefficientWm2K * thermalArea
        let thermalLimitedPower =
            inputPowerW * sqrt(allowableHeatW / max(r.totalLossW, 1e-9))

        // 3) Efficiency: loss fraction ~ I => P_max = P0 * (1 - eta_min) / lossFraction
        let efficiencyLimitedPower =
            inputPowerW * (1.0 - QRTLConstants.minimumEfficiency) / lossFraction

        r.powerCapabilityW = min(currentLimitedPower, thermalLimitedPower, efficiencyLimitedPower)
        r.modeledChargePowerW = min(QRTLConstants.targetChargePowerW, r.powerCapabilityW)

        // ---- Charge time: elapsed + remaining Coulombs at the applied current ----
        let qEffAh = r.cellCapacityAh * max(1.0 - degradation, 1e-6)
        r.chargeTimeHours =
            simulatedTimeS / 3600.0 + max(1.0 - r.averageSOC, 0.0) * qEffAh / max(iCell, 1e-9)

        r.maxTemperatureC = cells.map(\.temperatureC).max() ?? QRTLConstants.ambientTemperatureC
        r.tpmsRelativeDensity = QRTLConstants.tpmsRelativeDensity
        r.tpmsPorosity = 1.0 - QRTLConstants.tpmsRelativeDensity
        r.tpmsSurfaceAreaM2 = thermalArea

        if !cells.isEmpty {
            r.sulfurUtilization = meanValue(\.sulfurFraction)
            r.averageOverpotentialV = meanEta
            r.averageImpedanceOhm = effectiveCellResistanceOhm
            r.averageResonanceAmplitudeM = meanValue(\.resonanceAmplitudeM)
            r.maximumStressMPa = (cells.map(\.stressPa).max() ?? 0) / 1e6
        }

        // ---- Constraints ----
        r.energyPass = r.usableEnergyKWh >= QRTLConstants.targetEnergyKWh
        r.powerPass = r.powerCapabilityW >= QRTLConstants.targetChargePowerW
        r.massPass = r.packMassKg <= QRTLConstants.maximumPackMassKg
        r.specificEnergyPass = r.specificEnergyWhKg >= QRTLConstants.targetSpecificEnergyWhKg
        r.efficiencyPass = r.efficiency >= QRTLConstants.minimumEfficiency
        r.thermalPass = r.maxTemperatureC <= QRTLConstants.maximumTemperatureC
        r.timePass = r.chargeTimeHours <= QRTLConstants.maximumChargeTimeHours
        r.mechanicalPass = r.maximumStressMPa < QRTLConstants.maximumStressMPa

        r.failureReasons.removeAll()
        if !r.energyPass { r.failureReasons.append("usable energy below \(Int(QRTLConstants.targetEnergyKWh)) kWh") }
        if !r.powerPass { r.failureReasons.append("power capability below 1 MW") }
        if !r.massPass { r.failureReasons.append("pack mass above \(Int(QRTLConstants.maximumPackMassKg)) kg") }
        if !r.specificEnergyPass { r.failureReasons.append("specific energy below 2,000 Wh/kg") }
        if !r.efficiencyPass { r.failureReasons.append("efficiency below 99%") }
        if !r.thermalPass { r.failureReasons.append("temperature above 60 °C") }
        if !r.timePass { r.failureReasons.append("charge time above 36 minutes") }
        if !r.mechanicalPass { r.failureReasons.append("mechanical stress limit exceeded") }

        r.overallPass =
            r.energyPass && r.powerPass && r.massPass && r.specificEnergyPass &&
            r.efficiencyPass && r.thermalPass && r.timePass && r.mechanicalPass

        return r
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var engine = QRTLBatteryEngine()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    targetPanel
                    caPanel
                    resultPanel
                    equationPanel
                    assumptionsPanel
                }
                .padding()
            }
            .navigationTitle("QRTL Battery CA")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("RESET") { engine.reset() }
                    Button(engine.isRunning ? "RUNNING" : "RUN CA") {
                        if !engine.isRunning { engine.run() }
                    }
                    .disabled(engine.isRunning)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Equation-Coupled QRTL Battery")
                .font(.title2.bold())
            Text(engine.status)
                .font(.caption)
                .foregroundStyle(engine.result.overallPass ? Color.green : Color.secondary)
            Text("Generation \(engine.generation) / \(QRTLConstants.caIterations)  ·  simulated \(fmt(engine.simulatedTimeS / 60.0, 1)) min")
                .font(.caption.monospaced())
            Text("Rated \(fmt(engine.result.ratedEnergyKWh, 1)) kWh · cell \(fmt(engine.result.cellCapacityAh, 1)) Ah")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var targetPanel: some View {
        GroupBox("TARGETS") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metric("Energy", "600 kWh")
                metric("Charge", "1 MW")
                metric("Time", "36 min")
                metric("Mass", "≤300 kg")
                metric("Specific", "2,000 Wh/kg")
                metric("Efficiency", "≥99%")
                metric("Temperature", "≤60 °C")
                metric("Topology", "TPMS + resonator")
            }
        }
    }

    private var caPanel: some View {
        GroupBox("CHARGE PROPAGATION / TPMS CA") {
            VStack(spacing: 2) {
                ForEach(0..<QRTLConstants.caHeight, id: \.self) { y in
                    HStack(spacing: 2) {
                        ForEach(0..<QRTLConstants.caWidth, id: \.self) { x in
                            let index = y * QRTLConstants.caWidth + x
                            let cell: QRTLCAChargeCell? =
                                index < engine.cells.count ? engine.cells[index] : nil
                            RoundedRectangle(cornerRadius: 1)
                                .fill(cellColor(cell))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            HStack(spacing: 12) {
                legend(Color.gray.opacity(0.4), "empty")
                legend(Color.blue, "receiving")
                legend(Color.orange, "reacting")
                legend(Color.green, "charged")
                legend(Color.red, "thermal")
            }
            .font(.caption2)
        }
    }

    private func cellColor(_ cell: QRTLCAChargeCell?) -> Color {
        guard let cell else { return Color.gray.opacity(0.15) }
        switch cell.state {
        case .empty: return Color.gray.opacity(0.18)
        case .receiving: return Color.blue
        case .reacting: return Color.orange
        case .charged: return Color.green
        case .thermal: return Color.red
        case .damaged: return Color.black
        }
    }

    private var resultPanel: some View {
        GroupBox("MODELED RESULT") {
            VStack(alignment: .leading, spacing: 7) {
                resultRow("Usable energy", "\(fmt(engine.result.usableEnergyKWh, 2)) kWh", engine.result.energyPass)
                resultRow("Power capability", "\(fmt(engine.result.powerCapabilityW / 1e6, 3)) MW", engine.result.powerPass)
                resultRow("Charge time", "\(fmt(engine.result.chargeTimeHours * 60.0, 1)) min", engine.result.timePass)
                resultRow("Pack mass", "\(fmt(engine.result.packMassKg, 1)) kg", engine.result.massPass)
                resultRow("Specific energy", "\(fmt(engine.result.specificEnergyWhKg, 0)) Wh/kg", engine.result.specificEnergyPass)
                resultRow("Efficiency", "\(fmt(engine.result.efficiency * 100.0, 3)) %", engine.result.efficiencyPass)
                resultRow("Max temperature", "\(fmt(engine.result.maxTemperatureC, 1)) °C", engine.result.thermalPass)
                resultRow("Maximum stress", "\(fmt(engine.result.maximumStressMPa, 1)) MPa", engine.result.mechanicalPass)

                Divider()

                Text(engine.result.overallPass ? "PASS — all targets met" : "FAIL — limiting constraints")
                    .font(.headline)
                    .foregroundStyle(engine.result.overallPass ? Color.green : Color.red)

                if !engine.result.failureReasons.isEmpty {
                    ForEach(engine.result.failureReasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var equationPanel: some View {
        GroupBox("EQUATIONS USED BY THE SIMULATION") {
            VStack(alignment: .leading, spacing: 7) {
                equation("TPMS", "φ = sin x cos y + sin y cos z₀ + sin z₀ cos x")
                equation("Li+ flux", "N = −D∇c − zFDc/(RT)∇φ")
                equation("Conservation", "∂c/∂t = −∇·N + S")
                equation("Electron current", "Jₑ = −σₑ∇φₑ")
                equation("Butler–Volmer", "j = j₀[exp(αFη/RT) − exp(−αFη/RT)]")
                equation("Nernst", "Eeq = E⁰ + RT/(nF) ln(Q)")
                equation("SOC", "dSOC/dt = I / (3600·Q)")
                equation("Impedance", "Z = Zcollector + Zelectrolyte + Zelectrode + Zinterface")
                equation("Resonator", "mẍ + cẋ + kx = F₀cos(ωt)")
                equation("Resonator Q", "Q = mω₀/c ; k = mω₀²")
                equation("Resonator loss", "Pres = ωEres/Q ; E = P·Q/ω")
                equation("Piezoelectric", "S = sᴱT + dᵀE ; D = dT + εᵀE")
                equation("Heat", "ρCp ∂T/∂t = ∇·(k∇T) + q̇")
                equation("Heat generation", "q̇ = I²R + Iη + Qres + I T ∂U/∂T")
                equation("Mechanics", "∇·σ + f = ρü ; σ = C:ε")
                equation("Charge time", "t = t_elapsed + (1 − SOC)·Q/I")
                equation("Degradation", "dQ/Q = k·ΔSOC·(1 + ΔT/20 + σ/σmax)")
            }
        }
    }

    private var assumptionsPanel: some View {
        GroupBox("MODEL NOTES") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• 450S6P, 2.22 V/cell, 2,700 cells; every cell carries the string current.")
                Text("• Cell capacity is set by sulfur mass per cell, not by the 600 kWh target.")
                Text("• Resonator stores a small oscillatory energy; it does not create battery energy.")
                Text("• The CA is a 2-D reduced-order slice of a TPMS-inspired 3-D architecture.")
                Text("• Lateral SOC mixing is numerical; Li+ lateral diffusion over 1 mm is negligible on this timescale.")
                Text("• Polysulfide shuttle and coulombic losses are not modeled.")
                Text("• Charge time assumes the 1 MW target is applied; power capability is checked separately.")
                Text("• Parameters are model inputs and must be calibrated against measured cells/materials.")
                Text("• A PASS means the programmed equations and parameters satisfy the constraints; it is not experimental validation.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultRow(_ name: String, _ value: String, _ pass: Bool) -> some View {
        HStack {
            Image(systemName: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(pass ? Color.green : Color.red)
            Text(name)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func equation(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name)
                .frame(width: 125, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }

    private func fmt(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

#Preview {
    ContentView()
}
