//
//  QRTLBatteryEngine.swift
//  Deca Cell Battery
//
//  1 MW charge-station driven QRTL battery simulation
//

import Foundation
import Combine

@MainActor
final class QRTLBatteryEngine: ObservableObject {

    // ============================================================
    // MARK: - Published State
    // ============================================================

    @Published var cells: [QRTLCAChargeCell] = []
    @Published var generation = 0
    @Published var isRunning = false
    @Published var hasStarted = false
    @Published var result = QRTLDesignResult()
    @Published var status = "Ready"

    // Simulation time, not computer wall-clock time.
    @Published var simulatedTimeS = 0.0

    // ============================================================
    // MARK: - Internal CA Data
    // ============================================================

    private var neighborTable: [[Int]] = []
    private var acceptance: [Double] = []
    private var meanTransport: [Double] = []
    private var nodeResistanceOhm: [Double] = []
    private var localCurrentA: [Double] = []
    private var electrolytePotentialV: [Double] = []
    private var effectiveCellResistanceOhm: [Double] = []

    // ============================================================
    // MARK: - Energy Accounting
    // ============================================================

    private var cumulativeInputEnergyJ = 0.0
    private var cumulativeLossEnergyJ = 0.0

    // ============================================================
    // MARK: - Numerical Safety
    // ============================================================

    private let minimumResistanceOhm = 1e-9
    private let minimumConcentration = 1e-9
    private let minimumTemperatureK = 250.0
    private let maximumTemperatureK = 450.0

    private var runTask: Task<Void, Never>?

    // ============================================================
    // MARK: - 1 MW Charge Station
    // ============================================================

    private var chargeStationPowerW: Double {
        QRTLConstants.targetChargePowerW
    }

    private var chargeStationCurrentA: Double {
        chargeStationPowerW /
        max(QRTLConstants.packVoltageV, 1e-9)
    }

    private var chargeStationCellCurrentA: Double {
        chargeStationCurrentA /
        Double(QRTLConstants.parallelStrings)
    }

    // ============================================================
    // MARK: - Reset
    // ============================================================

    func reset() {

        runTask?.cancel()
        runTask = nil

        isRunning = false
        hasStarted = false

        generation = 0
        simulatedTimeS = 0.0

        cumulativeInputEnergyJ = 0.0
        cumulativeLossEnergyJ = 0.0

        cells.removeAll()
        neighborTable.removeAll()
        acceptance.removeAll()
        meanTransport.removeAll()
        nodeResistanceOhm.removeAll()
        localCurrentA.removeAll()
        electrolytePotentialV.removeAll()
        effectiveCellResistanceOhm.removeAll()

        buildCA()

        // Calculate the physical design numbers,
        // but ContentView should not display PASS/FAIL
        // until charging has actually started.
        calculateDesignResult()

        status = "Ready"
    }

    // ============================================================
    // MARK: - Run
    // ============================================================

    func run() {

        runTask?.cancel()

        reset()

        hasStarted = true
        isRunning = true
        status = "Charging from 1 MW station"

        runTask = Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            while !Task.isCancelled && self.isRunning {

                self.advance()

                if !self.isRunning {
                    break
                }

                await Task.yield()
            }
        }
    }


    // ============================================================
    // MARK: - Advance
    // ============================================================

    func advance() {

        guard !cells.isEmpty else {

            isRunning = false
            status = "No CA cells"

            return
        }

        let targetSOC =
            QRTLConstants.chargeCompleteSOC

        let averageSOC =
            cells.reduce(0.0) {
                $0 + $1.soc
            } / Double(cells.count)

        // Already complete.
        if averageSOC >= targetSOC {

            isRunning = false
            status = "Charge complete"

            calculateDesignResult()

            return
        }

        // --------------------------------------------------------
        // Physical cell capacity in ampere-seconds.
        // --------------------------------------------------------

        let cellCapacityAs =
            QRTLConstants.cellCapacityAh *
            3600.0

        guard cellCapacityAs > 0.0 else {

            isRunning = false
            status = "Invalid cell capacity"

            calculateDesignResult()

            return
        }

        // --------------------------------------------------------
        // 1 MW physical charging current.
        //
        // IMPORTANT:
        // This is NOT divided by the 31 × 31 CA node count.
        // --------------------------------------------------------

        let physicalCellCurrentA =
            chargeStationCellCurrentA

        guard physicalCellCurrentA > 0.0 else {

            isRunning = false
            status = "Invalid charging current"

            calculateDesignResult()

            return
        }

        // --------------------------------------------------------
        // SOC remaining to the 99.9% completion threshold.
        // --------------------------------------------------------

        let remainingSOC =
            max(
                targetSOC - averageSOC,
                0.0
            )

        // --------------------------------------------------------
        // Exact physical time remaining.
        //
        // Δt = ΔSOC × Q / I
        // --------------------------------------------------------

        let secondsToTarget =
            remainingSOC *
            cellCapacityAs /
            physicalCellCurrentA

        // --------------------------------------------------------
        // Normal simulation step = 60 seconds.
        //
        // The final step is automatically shortened.
        // Therefore:
        //
        // 36:00 -> ~99.732%
        // 36:03.x -> 99.9%
        // --------------------------------------------------------

        let dt =
            min(
                QRTLConstants.simSecondsPerStep,
                secondsToTarget
            )

        guard dt > 0.0 else {

            isRunning = false
            status = "Charge complete"

            calculateDesignResult()

            return
        }

        // --------------------------------------------------------
        // Run one coupled simulation step.
        // --------------------------------------------------------

        step(dt: dt)

        generation += 1

        simulatedTimeS += dt

        // --------------------------------------------------------
        // Calculate new SOC.
        // --------------------------------------------------------

        let updatedAverageSOC =
            cells.reduce(0.0) {
                $0 + $1.soc
            } / Double(cells.count)

        // Update result periodically.
        if generation % 10 == 0 ||
            updatedAverageSOC >= targetSOC {

            calculateDesignResult()
        }

        // --------------------------------------------------------
        // Completion.
        // --------------------------------------------------------

        if updatedAverageSOC >= targetSOC {

            for index in cells.indices {

                cells[index].soc =
                    max(
                        cells[index].soc,
                        targetSOC
                    )

                if index < acceptance.count {

                    acceptance[index] = 1.0
                }
            }

            isRunning = false
            status = "Charge complete"

            calculateDesignResult()

            return
        }

        // --------------------------------------------------------
        // Safety limit.
        // --------------------------------------------------------

        if generation >= QRTLConstants.caIterations {

            isRunning = false
            status = "Simulation limit reached"

            calculateDesignResult()
        }
    }


    // ============================================================
    // MARK: - Step
    // ============================================================

    private func step(dt: Double) {

        relaxElectrolytePotential()

        updateLocalCurrent()

        updateSOC(dt: dt)

        updateTransport()

        updateResonator()

        updateElectrochemistry()

        updateThermalState(dt: dt)

        updateMechanicalState()

        updateDegradation(dt: dt)

        finalizeCells()

        updatePackEnergy(dt: dt)
    }


    // ============================================================
    // MARK: - SOC
    // ============================================================

    private func updateSOC(dt: Double) {

        let cellCapacityAs =
            QRTLConstants.cellCapacityAh *
            3600.0

        guard cellCapacityAs > 0.0 else {
            return
        }

        // 1 MW charging station is authoritative.
        //
        // The CA grid is a spatial model, not 961 physical cells.
        let physicalCellCurrentA =
            chargeStationCellCurrentA

        let deltaSOC =
            physicalCellCurrentA *
            dt /
            cellCapacityAs

        guard deltaSOC > 0.0 else {
            return
        }

        for index in cells.indices {

            cells[index].soc =
                clamp(
                    cells[index].soc + deltaSOC,
                    0.0,
                    1.0
                )

            let soc =
                cells[index].soc

            if index < acceptance.count {

                acceptance[index] =
                    clamp(
                        soc /
                        QRTLConstants.chargeCompleteSOC,
                        0.0,
                        1.0
                    )
            }
        }
    }


    // ============================================================
    // MARK: - Thermal State
    // ============================================================

    private func updateThermalState(dt: Double) {

        for index in cells.indices {

            let current =
                abs(
                    localCurrentA[index]
                )

            let resistance =
                max(
                    cells[index].impedanceOhm,
                    minimumResistanceOhm
                )

            let ohmicHeat =
                current *
                current *
                resistance

            let reactionHeat =
                current *
                abs(
                    cells[index].overpotentialV
                )

            let resonatorHeat =
                cells[index].resonatorLossW

            let totalHeat =
                ohmicHeat +
                reactionHeat +
                resonatorHeat

            cells[index].heatGenerationW =
                totalHeat

            let area =
                max(
                    QRTLConstants.tpmsThermalAreaM2PerCell,
                    1e-9
                )

            cells[index].heatFluxWm2 =
                totalHeat /
                area

            let cooling =
                QRTLConstants.heatTransferCoefficientWm2K *
                area *
                max(
                    cells[index].temperatureC -
                    QRTLConstants.ambientTemperatureC,
                    0.0
                )

            let netHeat =
                totalHeat -
                cooling

            let deltaT =
                netHeat *
                dt /
                max(
                    QRTLConstants.cellHeatCapacityJPerK,
                    1.0
                )

            cells[index].temperatureC =
                clamp(
                    cells[index].temperatureC +
                    deltaT,
                    QRTLConstants.ambientTemperatureC,
                    QRTLConstants.maximumTemperatureC
                )

            if cells[index].temperatureC >=
                QRTLConstants.maximumTemperatureC {

                cells[index].state =
                    .thermal
            }
        }
    }


    // ============================================================
    // MARK: - Degradation
    // ============================================================

    private func updateDegradation(dt: Double) {

        for index in cells.indices {

            let increment =
                QRTLConstants.degradationCoefficientPerCycle *
                dt /
                (24.0 * 3600.0)

            cells[index].degradation =
                clamp(
                    cells[index].degradation +
                    increment,
                    0.0,
                    1.0
                )

            cells[index].sulfurFraction =
                clamp(
                    1.0 -
                    cells[index].degradation,
                    0.0,
                    1.0
                )
        }
    }


    // ============================================================
    // MARK: - Pack Energy
    // ============================================================

    private func updatePackEnergy(dt: Double) {

        let inputPowerW =
            QRTLConstants.targetChargePowerW

        let inputEnergyJ =
            inputPowerW * dt

        cumulativeInputEnergyJ +=
            inputEnergyJ

        var lossPowerW = 0.0

        for cell in cells {

            let current =
                abs(
                    cell.electronicCurrentDensity
                ) *
                QRTLConstants.activeElectrodeAreaM2PerCell

            let resistance =
                max(
                    cell.impedanceOhm,
                    minimumResistanceOhm
                )

            let ohmic =
                current *
                current *
                resistance

            let reaction =
                current *
                abs(
                    cell.overpotentialV
                )

            lossPowerW +=
                ohmic +
                reaction +
                cell.resonatorLossW
        }

        let scale =
            Double(QRTLConstants.cellCount) /
            Double(max(cells.count, 1))

        let scaledLossPower =
            lossPowerW * scale

        cumulativeLossEnergyJ +=
            scaledLossPower * dt

        for index in cells.indices {

            cells[index].chargeEnergyJ +=
                max(
                    localCurrentA[index] *
                    cells[index].localVoltageV *
                    dt,
                    0.0
                )
        }
    }
  

    // ============================================================
    // MARK: - Stop
    // ============================================================

    func stop() {

        runTask?.cancel()
        runTask = nil

        isRunning = false

        status = "Stopped"

        calculateDesignResult()
    }

    // ============================================================
    // MARK: - Advance
    // ============================================================
   
    // ============================================================
    // MARK: - Build CA
    // ============================================================

    private func buildCA() {

        let width = QRTLConstants.caWidth
        let height = QRTLConstants.caHeight
        let count = width * height

        cells = []

        cells.reserveCapacity(count)

        for y in 0..<height {

            for x in 0..<width {

                var cell =
                    QRTLCAChargeCell(
                        x: x,
                        y: y
                    )

                let fx =
                    Double(x) /
                    Double(max(width - 1, 1))

                let fy =
                    Double(y) /
                    Double(max(height - 1, 1))

                let z =
                    QRTLConstants.tpmsSliceZ

                let twoPi =
                    2.0 * Double.pi

                // TPMS reduced slice.
                let phi =
                    sin(twoPi * fx) *
                    cos(twoPi * fy)
                    +
                    sin(twoPi * fy) *
                    cos(twoPi * z)
                    +
                    sin(twoPi * z) *
                    cos(twoPi * fx)

                cell.phiTPMS = phi

                let solid =
                    clamp(
                        0.5 +
                        0.5 * phi,
                        0.05,
                        0.95
                    )

                cell.solidFraction = solid

                cell.porosity =
                    clamp(
                        1.0 - solid,
                        0.05,
                        0.95
                    )

                cell.tortuosity =
                    clamp(
                        1.0 +
                        1.5 * solid,
                        1.0,
                        4.0
                    )

                cell.soc = 0.0

                cell.lithiumConcentration =
                    QRTLConstants.tabReservoirConcentration

                cell.sulfurFraction = 1.0

                cell.temperatureC =
                    QRTLConstants.ambientTemperatureC

                cell.degradation = 0.0

                cell.state = .empty

                cells.append(cell)
            }
        }

        // ========================================================
        // Neighborhood
        // ========================================================

        neighborTable =
            Array(
                repeating: [],
                count: cells.count
            )

        for index in cells.indices {

            let x = cells[index].x
            let y = cells[index].y

            var neighbors: [Int] = []

            if x > 0 {
                neighbors.append(index - 1)
            }

            if x < width - 1 {
                neighbors.append(index + 1)
            }

            if y > 0 {
                neighbors.append(index - width)
            }

            if y < height - 1 {
                neighbors.append(index + width)
            }

            neighborTable[index] = neighbors
        }

        // ========================================================
        // Transport
        // ========================================================

        meanTransport =
            cells.map {
                transportFactor($0)
            }

        let mean =
            meanTransport.reduce(0.0, +) /
            Double(max(meanTransport.count, 1))

        acceptance =
            meanTransport.map { value in

                let normalized =
                    value /
                    max(mean, 1e-12)

                return clamp(
                    normalized *
                    QRTLConstants.caAcceptanceModulation
                    +
                    (1.0 -
                     QRTLConstants.caAcceptanceModulation),
                    0.1,
                    2.0
                )
            }

        // ========================================================
        // Ionic Resistance
        // ========================================================

        nodeResistanceOhm =
            cells.map { cell in

                let effectiveConductivity =
                    QRTLConstants.ionicConductivitySm *
                    max(
                        transportFactor(cell),
                        0.01
                    )

                let area =
                    max(
                        QRTLConstants.caCellLengthM *
                        QRTLConstants.caCellLengthM,
                        1e-12
                    )

                let length =
                    max(
                        QRTLConstants.electrolyteThicknessM,
                        1e-9
                    )

                let resistance =
                    length /
                    max(
                        effectiveConductivity *
                        area,
                        1e-12
                    )

                return max(
                    resistance +
                    QRTLConstants.interfaceResistanceOhmPerCell,
                    minimumResistanceOhm
                )
            }

        effectiveCellResistanceOhm =
            nodeResistanceOhm

        localCurrentA =
            Array(
                repeating: 0.0,
                count: cells.count
            )

        electrolytePotentialV =
            Array(
                repeating: 0.0,
                count: cells.count
            )

        // Initial electrolyte potential.
        for index in cells.indices {

            let x =
                Double(cells[index].x) /
                Double(max(width - 1, 1))

            electrolytePotentialV[index] =
                -QRTLConstants.cellNominalVoltageV *
                x

            cells[index].electrolytePotentialV =
                electrolytePotentialV[index]
        }
    }

    // ============================================================
    // MARK: - Step
    // ============================================================

    private func step() {

        relaxElectrolytePotential()
        updateLocalCurrent()
        updateSOC()
        updateTransport()
        updateResonator()
        updateElectrochemistry()
        updateThermalState()
        updateMechanicalState()
        updateDegradation()
        finalizeCells()
        updatePackEnergy()
    }

    // ============================================================
    // MARK: - Electrolyte Potential
    // ============================================================

    private func relaxElectrolytePotential() {

        guard !cells.isEmpty else {
            return
        }

        var newPotential =
            electrolytePotentialV

        let width =
            QRTLConstants.caWidth

        for index in cells.indices {

            let x =
                cells[index].x

            if x == 0 {

                newPotential[index] = 0.0

                continue
            }

            let neighbors =
                neighborTable[index]

            guard !neighbors.isEmpty else {
                continue
            }

            var weightedPotential = 0.0
            var totalWeight = 0.0

            for neighbor in neighbors {

                let resistance =
                    max(
                        nodeResistanceOhm[neighbor],
                        minimumResistanceOhm
                    )

                let conductance =
                    1.0 / resistance

                weightedPotential +=
                    electrolytePotentialV[neighbor] *
                    conductance

                totalWeight +=
                    conductance
            }

            if totalWeight > 0.0 {

                let relaxed =
                    weightedPotential /
                    totalWeight

                let relaxation = 0.25

                newPotential[index] =
                    electrolytePotentialV[index] *
                    (1.0 - relaxation)
                    +
                    relaxed *
                    relaxation
            }

            if x == width - 1 {

                newPotential[index] =
                    -QRTLConstants.cellNominalVoltageV
            }
        }

        electrolytePotentialV =
            newPotential

        for index in cells.indices {

            cells[index].electrolytePotentialV =
                electrolytePotentialV[index]
        }
    }

    // ============================================================
    // MARK: - Local Current
    // ============================================================

    private func updateLocalCurrent() {

        guard !cells.isEmpty else {
            return
        }

        // ========================================================
        // 1 MW CHARGING STATION
        // ========================================================
        //
        // 1 MW / 999 V ≈ 1,001 A pack current.
        //
        // 1,001 A / 6 parallel strings ≈ 167 A
        // per physical cell/string.
        //
        // The CA grid is the INTERNAL spatial structure
        // of one physical cell.
        //
        // We therefore do NOT divide 167 A by 961.
        // ========================================================

        let physicalCellCurrentA =
            chargeStationCellCurrentA

        var conductances =
            Array(
                repeating: 0.0,
                count: cells.count
            )

        var weightedTotal = 0.0

        for index in cells.indices {

            let resistance =
                max(
                    effectiveCellResistanceOhm[index],
                    minimumResistanceOhm
                )

            let conductance =
                1.0 / resistance

            let transportWeight =
                max(
                    acceptance[index],
                    0.01
                )

            let weightedConductance =
                conductance *
                transportWeight

            conductances[index] =
                weightedConductance

            weightedTotal +=
                weightedConductance
        }

        guard weightedTotal > 0.0 else {
            return
        }

        let nodeCount =
            Double(cells.count)

        for index in cells.indices {

            let fraction =
                conductances[index] /
                weightedTotal

            let multiplier =
                fraction *
                nodeCount

            let current =
                physicalCellCurrentA *
                multiplier

            localCurrentA[index] =
                current

            cells[index].electronicCurrentDensity =
                current /
                max(
                    QRTLConstants.activeElectrodeAreaM2PerCell,
                    1e-9
                )
        }
    }

    // ============================================================
    // MARK: - SOC
    // ============================================================

    private func updateSOC() {
        let dt = QRTLConstants.simSecondsPerStep

        let cellCapacityAs =
            QRTLConstants.cellCapacityAh * 3600.0

        guard cellCapacityAs > 0.0 else {
            return
        }

        // Physical current delivered by the 1 MW charging station.
        // The CA grid represents spatial behavior; it does not
        // divide the physical charging current among CA nodes.
        let physicalCellCurrentA =
            chargeStationCellCurrentA

        let deltaSOC =
            physicalCellCurrentA *
            dt /
            cellCapacityAs

        guard deltaSOC > 0.0 else {
            return
        }

        for index in cells.indices {

            cells[index].soc =
                clamp(
                    cells[index].soc + deltaSOC,
                    0.0,
                    1.0
                )

            let soc = cells[index].soc

            if index < acceptance.count {
                acceptance[index] =
                    clamp(
                        soc / QRTLConstants.chargeCompleteSOC,
                        0.0,
                        1.0
                    )
            }
        }
    }
    // ============================================================
    // MARK: - Transport
    // ============================================================

    private func updateTransport() {

        for index in cells.indices {

            let cell =
                cells[index]

            let diffusivity =
                effectiveDiffusivity(cell)

            let transport =
                transportFactor(cell)

            cells[index].lithiumIonFlux =
                diffusivity *
                transport *
                max(
                    1.0 - cell.soc,
                    0.0
                )

            cells[index].lithiumConcentration =
                clamp(
                    QRTLConstants.tabReservoirConcentration *
                    (1.0 - 0.35 * cell.soc),
                    minimumConcentration,
                    1.0
                )
        }
    }

    // ============================================================
    // MARK: - Resonator
    // ============================================================

    private func updateResonator() {

        let omega =
            QRTLConstants.resonatorDesignOmega

        let damping =
            max(
                QRTLConstants.resonatorDampingNsM,
                1e-18
            )

        let drivePowerPerCell =
            QRTLConstants.targetChargePowerW *
            QRTLConstants.resonatorDrivePowerFraction /
            Double(QRTLConstants.cellCount)

        for index in cells.indices {

            let drive =
                drivePowerPerCell

            let amplitude =
                sqrt(
                    max(drive, 0.0) /
                    max(
                        damping *
                        omega *
                        omega,
                        1e-18
                    )
                )

            cells[index].resonanceAmplitudeM =
                amplitude *
                QRTLConstants.resonatorCouplingEfficiency

            cells[index].resonancePhaseRad =
                atan2(
                    damping * omega,
                    QRTLConstants.resonatorSpringConstantNpm
                )

            cells[index].resonatorEnergyJ =
                0.5 *
                QRTLConstants.resonatorSpringConstantNpm *
                amplitude *
                amplitude

            cells[index].resonatorLossW =
                damping *
                omega *
                omega *
                amplitude *
                amplitude

            cells[index].piezoPowerW =
                drive *
                QRTLConstants.piezoCouplingCoefficient
        }
    }

    // ============================================================
    // MARK: - Electrochemistry
    // ============================================================

    private func updateElectrochemistry() {

        let Tref = 298.15

        for index in cells.indices {

            let cell =
                cells[index]

            let temperatureK =
                clamp(
                    cell.temperatureC + 273.15,
                    minimumTemperatureK,
                    maximumTemperatureK
                )

            let soc =
                clamp(
                    cell.soc,
                    1e-6,
                    0.999999
                )

            let equilibrium =
                QRTLConstants.cellNominalVoltageV
                +
                0.08 *
                safeLog(
                    (1.0 - soc) /
                    soc
                )
                +
                QRTLConstants.entropicCoefficientVPerK *
                (temperatureK - Tref)

            cells[index].equilibriumVoltageV =
                clamp(
                    equilibrium,
                    1.5,
                    3.0
                )

            let activation =
                -QRTLConstants.exchangeCurrentActivationEnergyJMol /
                QRTLConstants.gasConstant *
                (
                    1.0 / temperatureK -
                    1.0 / Tref
                )

            let exchange =
                QRTLConstants.referenceExchangeCurrentAm2 *
                safeExp(activation)

            cells[index].exchangeCurrentDensity =
                max(
                    exchange,
                    1e-9
                )

            let currentDensity =
                abs(
                    cells[index].electronicCurrentDensity
                )

            let ratio =
                max(
                    currentDensity /
                    cells[index].exchangeCurrentDensity,
                    1e-12
                )

            let thermalVoltage =
                QRTLConstants.gasConstant *
                temperatureK /
                QRTLConstants.faraday

            let overpotential =
                2.0 *
                thermalVoltage /
                QRTLConstants.chargeTransferCoefficient *
                asinh(
                    ratio / 2.0
                )

            cells[index].overpotentialV =
                overpotential

            let ionicResistance =
                max(
                    nodeResistanceOhm[index],
                    minimumResistanceOhm
                )

            let ohmicDrop =
                localCurrentA[index] *
                ionicResistance

            cells[index].impedanceOhm =
                ionicResistance

            cells[index].localVoltageV =
                clamp(
                    cells[index].equilibriumVoltageV
                    +
                    overpotential
                    +
                    ohmicDrop,
                    0.5,
                    4.0
                )

            cells[index].reactionRate =
                currentDensity

            cells[index].state =
                .reacting
        }
    }

    // ============================================================
    // MARK: - Thermal
    // ============================================================

    private func updateThermalState() {

        let dt =
            QRTLConstants.simSecondsPerStep

        for index in cells.indices {

            let current =
                abs(
                    localCurrentA[index]
                )

            let resistance =
                max(
                    cells[index].impedanceOhm,
                    minimumResistanceOhm
                )

            let ohmicHeat =
                current *
                current *
                resistance

            let reactionHeat =
                current *
                abs(
                    cells[index].overpotentialV
                )

            let resonatorHeat =
                cells[index].resonatorLossW

            let totalHeat =
                ohmicHeat +
                reactionHeat +
                resonatorHeat

            cells[index].heatGenerationW =
                totalHeat

            let area =
                max(
                    QRTLConstants.tpmsThermalAreaM2PerCell,
                    1e-9
                )

            cells[index].heatFluxWm2 =
                totalHeat /
                area

            let cooling =
                QRTLConstants.heatTransferCoefficientWm2K *
                area *
                max(
                    cells[index].temperatureC -
                    QRTLConstants.ambientTemperatureC,
                    0.0
                )

            let netHeat =
                totalHeat -
                cooling

            let deltaT =
                netHeat *
                dt /
                max(
                    QRTLConstants.cellHeatCapacityJPerK,
                    1.0
                )

            cells[index].temperatureC =
                clamp(
                    cells[index].temperatureC +
                    deltaT,
                    QRTLConstants.ambientTemperatureC,
                    QRTLConstants.maximumTemperatureC
                )

            if cells[index].temperatureC >=
                QRTLConstants.maximumTemperatureC {

                cells[index].state =
                    .thermal
            }
        }
    }

    // ============================================================
    // MARK: - Mechanics
    // ============================================================

    private func updateMechanicalState() {

        for index in cells.indices {

            let deltaT =
                cells[index].temperatureC -
                QRTLConstants.ambientTemperatureC

            let thermalStrain =
                QRTLConstants.thermalExpansionCoefficientPerK *
                deltaT

            cells[index].strain =
                thermalStrain

            cells[index].stressPa =
                QRTLConstants.mechanicalModulusPa *
                thermalStrain

            if cells[index].stressPa >
                QRTLConstants.maximumStressMPa *
                1_000_000.0 {

                cells[index].state =
                    .damaged
            }
        }
    }

    // ============================================================
    // MARK: - Degradation
    // ============================================================

    private func updateDegradation() {

        for index in cells.indices {

            let increment =
                QRTLConstants.degradationCoefficientPerCycle *
                QRTLConstants.simSecondsPerStep /
                (24.0 * 3600.0)

            cells[index].degradation =
                clamp(
                    cells[index].degradation +
                    increment,
                    0.0,
                    1.0
                )

            cells[index].sulfurFraction =
                clamp(
                    1.0 -
                    cells[index].degradation,
                    0.0,
                    1.0
                )
        }
    }

    // ============================================================
    // MARK: - Finalize Cells
    // ============================================================

    private func finalizeCells() {

        for index in cells.indices {

            let soc =
                cells[index].soc

            if soc >=
                QRTLConstants.chargeCompleteSOC {

                cells[index].state =
                    .charged

            } else if cells[index].temperatureC >=
                        QRTLConstants.maximumTemperatureC {

                cells[index].state =
                    .thermal

            } else if cells[index].state != .damaged {

                cells[index].state =
                    .receiving
            }
        }
    }

    // ============================================================
    // MARK: - Pack Energy
    // ============================================================

    private func updatePackEnergy() {

        // External station supplies exactly 1 MW.
        let inputPowerW =
            QRTLConstants.targetChargePowerW

        let dt =
            QRTLConstants.simSecondsPerStep

        let inputEnergyJ =
            inputPowerW *
            dt

        cumulativeInputEnergyJ +=
            inputEnergyJ

        var lossPowerW = 0.0

        for cell in cells {

            let current =
                abs(
                    cell.electronicCurrentDensity
                ) *
                QRTLConstants.activeElectrodeAreaM2PerCell

            let resistance =
                max(
                    cell.impedanceOhm,
                    minimumResistanceOhm
                )

            let ohmic =
                current *
                current *
                resistance

            let reaction =
                current *
                abs(
                    cell.overpotentialV
                )

            lossPowerW +=
                ohmic +
                reaction +
                cell.resonatorLossW
        }

        let scale =
            Double(QRTLConstants.cellCount) /
            Double(max(cells.count, 1))

        let scaledLossPower =
            lossPowerW *
            scale

        cumulativeLossEnergyJ +=
            scaledLossPower *
            dt

        for index in cells.indices {

            cells[index].chargeEnergyJ +=
                max(
                    localCurrentA[index] *
                    cells[index].localVoltageV *
                    dt,
                    0.0
                )
        }
    }

    // ============================================================
    // MARK: - Mean Value
    // ============================================================

    private func meanValue(
        from cells: [QRTLCAChargeCell],
        keyPath: KeyPath<QRTLCAChargeCell, Double>
    ) -> Double {

        guard !cells.isEmpty else {
            return 0.0
        }

        return cells.reduce(0.0) {
            $0 + $1[keyPath: keyPath]
        } /
        Double(cells.count)
    }

    // ============================================================
    // MARK: - Calculate Design Result
    // ============================================================

    func calculateDesignResult() {

        guard !cells.isEmpty else {

            result =
                QRTLDesignResult()

            return
        }

        var r =
            QRTLDesignResult()

        // ========================================================
        // Capacity
        // ========================================================

        r.cellCapacityAh =
            QRTLConstants.cellCapacityAh

        r.packVoltageV =
            QRTLConstants.packVoltageV

        r.packCapacityAh =
            QRTLConstants.packCapacityAh

        r.ratedEnergyKWh =
            QRTLConstants.ratedEnergyKWh

        r.averageSOC =
            meanValue(
                from: cells,
                keyPath: \.soc
            )

        let averageDegradation =
            meanValue(
                from: cells,
                keyPath: \.degradation
            )

        r.usableEnergyKWh =
            r.ratedEnergyKWh *
            clamp(
                r.averageSOC,
                0.0,
                1.0
            ) *
            (
                1.0 -
                clamp(
                    averageDegradation,
                    0.0,
                    1.0
                )
            )

        // ========================================================
        // Mass
        // ========================================================

        r.sulfurMassKg =
            QRTLConstants.sulfurMassPerCellKg *
            Double(QRTLConstants.cellCount)

        r.lithiumMassKg =
            r.sulfurMassKg *
            6.94 /
            32.065

        r.carbonMassKg =
            r.sulfurMassKg *
            QRTLConstants.carbonToSulfurMassRatio

        r.electrolyteMassKg =
            r.sulfurMassKg *
            QRTLConstants.electrolyteToSulfurMassRatio

        let collectorVolumePerCell =
            QRTLConstants.collectorAreaM2 *
            QRTLConstants.collectorThicknessM

        let collectorMassPerCell =
            collectorVolumePerCell *
            QRTLConstants.collectorDensityKgM3 *
            QRTLConstants.collectorsPerCell

        r.collectorMassKg =
            collectorMassPerCell *
            Double(QRTLConstants.cellCount)

        let tpmsMassPerCell =
            QRTLConstants.tpmsCellVolumeM3 *
            QRTLConstants.tpmsRelativeDensity *
            QRTLConstants.tpmsMaterialDensityKgM3

        r.tpmsMassKg =
            tpmsMassPerCell *
            Double(QRTLConstants.cellCount)

        r.resonatorMassKg =
            QRTLConstants.resonatorMassPerCellKg *
            Double(QRTLConstants.cellCount)

        r.packagingMassKg =
            QRTLConstants.packagingMassKgPerCell *
            Double(QRTLConstants.cellCount)

        let cellMaterialMass =
            r.sulfurMassKg +
            r.lithiumMassKg +
            r.carbonMassKg +
            r.electrolyteMassKg +
            r.collectorMassKg +
            r.tpmsMassKg +
            r.resonatorMassKg +
            r.packagingMassKg

        r.packMassKg =
            cellMaterialMass *
            (1.0 +
             QRTLConstants.packOverheadFraction)

        r.specificEnergyWhKg =
            r.ratedEnergyKWh *
            1000.0 /
            max(
                r.packMassKg,
                1e-9
            )

        // ========================================================
        // Electrical
        // ========================================================

        r.totalResistanceOhm =
            meanValue(
                from: cells,
                keyPath: \.impedanceOhm
            ) /
            Double(QRTLConstants.seriesCells)

        // ========================================================
        // Fixed 1 MW station
        // ========================================================

        let stationPowerW =
            QRTLConstants.targetChargePowerW

        let stationCurrentA =
            stationPowerW /
            max(
                QRTLConstants.packVoltageV,
                1e-9
            )

        // ========================================================
        // Losses
        // ========================================================

        r.ohmicLossW =
            stationCurrentA *
            stationCurrentA *
            max(
                r.totalResistanceOhm,
                minimumResistanceOhm
            )

        let averageOverpotential =
            max(
                meanValue(
                    from: cells,
                    keyPath: \.overpotentialV
                ),
                0.0
            )

        r.reactionLossW =
            stationCurrentA *
            averageOverpotential

        let averageTemperatureC =
            meanValue(
                from: cells,
                keyPath: \.temperatureC
            )

        r.entropicHeatW =
            abs(
                stationCurrentA *
                QRTLConstants.entropicCoefficientVPerK *
                (
                    averageTemperatureC -
                    QRTLConstants.ambientTemperatureC
                )
            )

        r.resonatorLossW =
            cells.reduce(0.0) {
                $0 +
                max(
                    $1.resonatorLossW,
                    0.0
                )
            } *
            Double(QRTLConstants.cellCount) /
            Double(max(cells.count, 1))

        r.thermalLossW =
            cells.reduce(0.0) {

                let delta =
                    max(
                        $1.temperatureC -
                        QRTLConstants.ambientTemperatureC,
                        0.0
                    )

                return $0 +
                    QRTLConstants.heatTransferCoefficientWm2K *
                    QRTLConstants.tpmsThermalAreaM2PerCell *
                    delta

            } *
            Double(QRTLConstants.cellCount) /
            Double(max(cells.count, 1))

        r.totalLossW =
            max(
                r.ohmicLossW +
                r.reactionLossW +
                r.entropicHeatW +
                r.resonatorLossW +
                r.thermalLossW,
                0.0
            )

        // ========================================================
        // Charging Power
        // ========================================================

        r.modeledChargePowerW =
            stationPowerW

        r.powerCapabilityW =
            stationPowerW

        // ========================================================
        // Efficiency
        // ========================================================

        let lossFraction =
            clamp(
                r.totalLossW /
                max(
                    stationPowerW,
                    1.0
                ),
                0.0,
                0.95
            )

        r.efficiency =
            clamp(
                1.0 -
                lossFraction,
                0.01,
                1.0
            )

        // ========================================================
        // Physical Charge Time
        //
        // 600 kWh / 1 MW = 36 minutes IDEAL.
        //
        // Actual time increases when efficiency < 100%.
        // ========================================================

        let idealChargeTimeHours =
            QRTLConstants.targetEnergyKWh /
            (stationPowerW / 1_000.0)

        r.chargeTimeHours =
            idealChargeTimeHours /
            max(
                r.efficiency,
                0.01
            )

        // ========================================================
        // Thermal / Geometry
        // ========================================================

        r.maxTemperatureC =
            cells.map(\.temperatureC).max()
            ??
            QRTLConstants.ambientTemperatureC

        r.tpmsSurfaceAreaM2 =
            QRTLConstants.tpmsThermalAreaM2PerCell *
            Double(QRTLConstants.cellCount)

        r.tpmsPorosity =
            meanValue(
                from: cells,
                keyPath: \.porosity
            )

        r.tpmsSolidFraction =
            meanValue(
                from: cells,
                keyPath: \.solidFraction
            )

        r.tpmsRelativeDensity =
            QRTLConstants.tpmsRelativeDensity

        // ========================================================
        // Electrochemical
        // ========================================================

        r.sulfurUtilization =
            QRTLConstants.sulfurUtilization

        r.averageOverpotentialV =
            meanValue(
                from: cells,
                keyPath: \.overpotentialV
            )

        r.averageImpedanceOhm =
            meanValue(
                from: cells,
                keyPath: \.impedanceOhm
            )

        // ========================================================
        // Resonator
        // ========================================================

        r.averageResonanceAmplitudeM =
            meanValue(
                from: cells,
                keyPath: \.resonanceAmplitudeM
            )

        // ========================================================
        // Mechanics
        // ========================================================

        r.maximumStressMPa =
            (
                cells.map(\.stressPa).max()
                ??
                0.0
            ) /
            1_000_000.0

        // ========================================================
        // Aging
        // ========================================================

        r.degradationFraction =
            averageDegradation

        // ========================================================
        // Constraint Checks
        //
        // These are REAL design requirements.
        // They are not forced to PASS.
        // ========================================================

        r.energyPass =
            r.ratedEnergyKWh >=
            QRTLConstants.targetEnergyKWh

        r.powerPass =
            r.powerCapabilityW >=
            QRTLConstants.targetChargePowerW

        r.massPass =
            r.packMassKg <=
            QRTLConstants.maximumPackMassKg

        r.specificEnergyPass =
            r.specificEnergyWhKg >=
            QRTLConstants.targetSpecificEnergyWhKg

        // 99% remains a real efficiency requirement.
        r.efficiencyPass =
            r.efficiency >=
            QRTLConstants.minimumEfficiency

        r.thermalPass =
            r.maxTemperatureC <=
            QRTLConstants.maximumTemperatureC

        // ========================================================
        // Charge-Time Requirement
        //
        // The 36-minute target is the ideal 1 MW reference.
        //
        // If the model has losses, actual time can legitimately
        // exceed 36 minutes.
        //
        // Therefore this is evaluated separately from efficiency.
        // ========================================================

        r.timePass =
            r.chargeTimeHours <=
            QRTLConstants.maximumChargeTimeHours

        r.mechanicalPass =
            r.maximumStressMPa <=
            QRTLConstants.maximumStressMPa

        // ========================================================
        // Failure Reasons
        // ========================================================

        var failures: [String] = []

        if !r.energyPass {

            failures.append(
                "Rated energy below 600 kWh"
            )
        }

        if !r.powerPass {

            failures.append(
                "Charging power below 1 MW"
            )
        }

        if !r.massPass {

            failures.append(
                "Pack mass exceeds 300 kg"
            )
        }

        if !r.specificEnergyPass {

            failures.append(
                "Specific energy below 2,000 Wh/kg"
            )
        }

        if !r.efficiencyPass {

            failures.append(
                String(
                    format:
                        "Efficiency %.2f%% is below 99%%",
                    r.efficiency * 100.0
                )
            )
        }

        if !r.thermalPass {

            failures.append(
                "Temperature exceeds 60 C"
            )
        }

        if !r.timePass {

            failures.append(
                String(
                    format:
                        "Recharge time %.2f minutes exceeds 36 minutes",
                    r.chargeTimeHours * 60.0
                )
            )
        }

        if !r.mechanicalPass {

            failures.append(
                "Mechanical stress exceeds 900 MPa"
            )
        }

        r.failureReasons =
            failures

        // ========================================================
        // Overall Result
        // ========================================================

        r.overallPass =
            r.energyPass &&
            r.powerPass &&
            r.massPass &&
            r.specificEnergyPass &&
            r.efficiencyPass &&
            r.thermalPass &&
            r.timePass &&
            r.mechanicalPass

        result =
            r
    }
}
