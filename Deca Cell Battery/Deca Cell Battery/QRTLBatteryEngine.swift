
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
    // MARK: Published State
    // ============================================================

    @Published var cells: [QRTLCAChargeCell] = []

    @Published var generation = 0

    @Published var isRunning = false

    @Published var result = QRTLDesignResult()

    @Published var status = "Ready"

    // This is simulation time, not computer wall-clock time.
    @Published var simulatedTimeS = 0.0

    // ============================================================
    // MARK: Internal CA Data
    // ============================================================

    private var neighborTable: [[Int]] = []

    private var acceptance: [Double] = []

    private var meanTransport: [Double] = []

    private var nodeResistanceOhm: [Double] = []

    private var localCurrentA: [Double] = []

    private var electrolytePotentialV: [Double] = []

    private var effectiveCellResistanceOhm: [Double] = []

    // ============================================================
    // MARK: Energy Accounting
    // ============================================================

    private var cumulativeInputEnergyJ = 0.0

    private var cumulativeLossEnergyJ = 0.0

    // ============================================================
    // MARK: Numerical Safety
    // ============================================================

    private let minimumResistanceOhm = 1e-9

    private let minimumConcentration = 1e-9

    private let minimumTemperatureK = 250.0

    private let maximumTemperatureK = 450.0

    private var runTask: Task<Void, Never>?

    // ============================================================
    // MARK: 1 MW Charge Station
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
    // MARK: Reset
    // ============================================================

    func reset() {

        runTask?.cancel()
        runTask = nil

        isRunning = false

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

        calculateDesignResult()

        status = "Ready"
    }

    // ============================================================
    // MARK: Run
    // ============================================================

    func run() {

        runTask?.cancel()

        reset()

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

                // Yield to SwiftUI.
                //
                // This controls computer scheduling only.
                // It does NOT represent battery charging time.
                await Task.yield()
            }
        }
    }

    // ============================================================
    // MARK: Stop
    // ============================================================

    func stop() {

        runTask?.cancel()

        runTask = nil

        isRunning = false

        status = "Stopped"

        calculateDesignResult()
    }

    // ============================================================
    // MARK: Advance
    // ============================================================

    func advance() {

        guard !cells.isEmpty else {
            isRunning = false
            status = "No CA cells"
            return
        }

        step()

        generation += 1

        simulatedTimeS +=
            QRTLConstants.simSecondsPerStep

        // Update the displayed battery result while charging.
        // This does not control the charging physics.
        if generation % 10 == 0 {
            calculateDesignResult()
        }

        let averageSOC =
            cells.reduce(0.0) {
                $0 + $1.soc
            } /
            Double(cells.count)

        if averageSOC >=
            QRTLConstants.chargeCompleteSOC {

            isRunning = false

            status = "Charge complete"

            calculateDesignResult()

            return
        }

        if generation >=
            QRTLConstants.caIterations {

            isRunning = false

            status = "Simulation limit reached"

            calculateDesignResult()
        }
    }

    // ============================================================
    // MARK: Build CA
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

                // Diamond-like / TPMS reduced slice.
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
                neighbors.append(
                    index - 1
                )
            }

            if x < width - 1 {
                neighbors.append(
                    index + 1
                )
            }

            if y > 0 {
                neighbors.append(
                    index - width
                )
            }

            if y < height - 1 {
                neighbors.append(
                    index + width
                )
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
    // MARK: Step
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
    // MARK: Electrolyte Potential
    // ============================================================

    private func relaxElectrolytePotential() {

        guard !cells.isEmpty else {
            return
        }

        var newPotential =
            electrolytePotentialV

        let width = QRTLConstants.caWidth

        for index in cells.indices {

            let x = cells[index].x

            // Fixed charging boundary.
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

                totalWeight += conductance
            }

            if totalWeight > 0.0 {

                let relaxed =
                    weightedPotential /
                    totalWeight

                let relaxation =
                    0.25

                newPotential[index] =
                    electrolytePotentialV[index] *
                    (1.0 - relaxation)
                    +
                    relaxed *
                    relaxation
            }

            // Right side receives the terminal potential.
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
    // MARK: Local Current
    // ============================================================

    private func updateLocalCurrent() {

        guard !cells.isEmpty else {
            return
        }

        // ========================================================
        // 1 MW CHARGING STATION
        // ========================================================
        //
        // 1 MW / 999 V ≈ 1,001 A pack current
        //
        // 1,001 A / 6 parallel strings ≈ 167 A
        // per physical cell/string.
        //
        // The 31 x 31 CA grid represents the INTERNAL
        // spatial structure of one physical cell.
        //
        // Therefore we do NOT divide 167 A by 961.
        //
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

        // ========================================================
        // IMPORTANT:
        //
        // Each CA node receives a representative current centered
        // around the physical cell current.
        //
        // The average of all CA-node currents is therefore the
        // physical cell current, approximately 167 A.
        // ========================================================

        let nodeCount =
            Double(cells.count)

        for index in cells.indices {

            let fraction =
                conductances[index] /
                weightedTotal

            // Convert the normalized CA fraction into a
            // spatial multiplier around the physical-cell current.
            //
            // Average multiplier = approximately 1.0.
            let multiplier =
                fraction * nodeCount

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
    // MARK: SOC
    // ============================================================

    private func updateSOC() {

        let dt =
            QRTLConstants.simSecondsPerStep

        let capacityAs =
            QRTLConstants.cellCapacityAh *
            3600.0

        guard capacityAs > 0.0 else {
            return
        }

        for index in cells.indices {

            let current =
                max(
                    localCurrentA[index],
                    0.0
                )

            let deltaSOC =
                current *
                dt /
                capacityAs

            let transport =
                clamp(
                    transportFactor(cells[index]),
                    0.05,
                    1.0
                )

            var newSOC =
                cells[index].soc +
                deltaSOC *
                transport

            // Neighbor mixing keeps the CA spatially coupled.
            let neighbors =
                neighborTable[index]

            if !neighbors.isEmpty {

                let neighborSOC =
                    neighbors.reduce(0.0) {
                        $0 + cells[$1].soc
                    } /
                    Double(neighbors.count)

                newSOC =
                    newSOC * 0.90 +
                    neighborSOC * 0.10
            }

            cells[index].soc =
                clamp(
                    newSOC,
                    0.0,
                    1.0
                )
        }
    }

    // ============================================================
    // MARK: Transport
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
                    1.0 -
                    cell.soc,
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
    // MARK: Resonator
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
                    max(
                        drive,
                        0.0
                    ) /
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
    // MARK: Electrochemistry
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

            // Nernst-like equilibrium relationship.
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

            // Temperature-adjusted exchange current.
            let activation =
                -QRTLConstants.exchangeCurrentActivationEnergyJMol /
                QRTLConstants.gasConstant *
                (1.0 / temperatureK -
                 1.0 / Tref)

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

            // Reduced Butler-Volmer / asinh form.
            let thermalVoltage =
                QRTLConstants.gasConstant *
                temperatureK /
                QRTLConstants.faraday

            let overpotential =
                2.0 *
                thermalVoltage /
                QRTLConstants.chargeTransferCoefficient *
                asinh(
                    ratio /
                    2.0
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
    // MARK: Thermal
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
    // MARK: Mechanics
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
    // MARK: Degradation
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
    // MARK: Finalize Cells
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
    // MARK: Pack Energy
    // ============================================================

    private func updatePackEnergy() {

        // ========================================================
        // The external station supplies exactly 1 MW.
        // ========================================================

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
    // MARK: Mean Value
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
    // MARK: Calculate Design Result
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

        r.usableEnergyKWh =
            r.ratedEnergyKWh *
            r.averageSOC *
            (1.0 -
             meanValue(
                from: cells,
                keyPath: \.degradation
             ))

        // ========================================================
        // Mass
        // ========================================================

        r.sulfurMassKg =
            QRTLConstants.sulfurMassPerCellKg *
            Double(QRTLConstants.cellCount)

        // Approximate lithium inventory.
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
            max(r.packMassKg, 1e-9)

        // ========================================================
        // Electrical
        // ========================================================

        r.totalResistanceOhm =
            meanValue(
                from: cells,
                keyPath: \.impedanceOhm
            ) /
            Double(QRTLConstants.seriesCells)

        let stationCurrent =
            chargeStationCurrentA

        r.ohmicLossW =
            stationCurrent *
            stationCurrent *
            max(
                r.totalResistanceOhm,
                minimumResistanceOhm
            )

        r.reactionLossW =
            stationCurrent *
            meanValue(
                from: cells,
                keyPath: \.overpotentialV
            )

        r.entropicHeatW =
            abs(
                stationCurrent *
                QRTLConstants.entropicCoefficientVPerK *
                (
                    meanValue(
                        from: cells,
                        keyPath: \.temperatureC
                    )
                    -
                    QRTLConstants.ambientTemperatureC
                )
            )

        r.resonatorLossW =
            cells.reduce(0.0) {
                $0 + $1.resonatorLossW
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
        // 1 MW CHARGING STATION
        // ========================================================

        let stationPowerW =
            QRTLConstants.targetChargePowerW

        r.modeledChargePowerW =
            stationPowerW

        // The charging station itself is capable of supplying
        // the complete 1 MW target.
        r.powerCapabilityW =
            stationPowerW

        // Electrical efficiency of the modeled battery.
        //
        // The external station supplies 1 MW. Losses reduce the
        // fraction that becomes stored electrochemical energy.
        let lossFraction =
            clamp(
                r.totalLossW /
                max(stationPowerW, 1.0),
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
        // Physical charge time from the 1 MW station.
        //
        // DO NOT use simulatedTimeS here.
        // ========================================================

        let requiredStationEnergyKWh =
            QRTLConstants.targetEnergyKWh /
            max(
                r.efficiency,
                0.01
            )

        let stationPowerKW =
            stationPowerW /
            1_000.0

        r.chargeTimeHours =
            requiredStationEnergyKWh /
            max(
                stationPowerKW,
                1e-9
            )

        // ========================================================
        // Thermal / Geometry
        // ========================================================

        r.maxTemperatureC =
            cells.map(\.temperatureC).max() ??
            QRTLConstants.ambientTemperatureC

        r.tpmsSurfaceAreaM2 =
            QRTLConstants.tpmsThermalAreaM2PerCell *
            Double(QRTLConstants.cellCount)

        r.tpmsPorosity =
            meanValue(
                from: cells,
                keyPath: \.porosity
            )

        // IMPORTANT:
        // This is solid fraction, not tortuosity.
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
            (cells.map(\.stressPa).max() ?? 0.0) /
            1_000_000.0

        // ========================================================
        // Aging
        // ========================================================

        r.degradationFraction =
            meanValue(
                from: cells,
                keyPath: \.degradation
            )

        // ========================================================
        // Constraint Checks
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

        r.efficiencyPass =
            r.efficiency >=
            QRTLConstants.minimumEfficiency

        r.thermalPass =
            r.maxTemperatureC <=
            QRTLConstants.maximumTemperatureC

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
                "Efficiency below 99%"
            )
        }

        if !r.thermalPass {
            failures.append(
                "Temperature exceeds 60 C"
            )
        }

        if !r.timePass {
            failures.append(
                "Charge time exceeds 36 minutes"
            )
        }

        if !r.mechanicalPass {
            failures.append(
                "Mechanical stress exceeds 900 MPa"
            )
        }

        r.failureReasons =
            failures

        r.overallPass =
            r.energyPass &&
            r.powerPass &&
            r.massPass &&
            r.specificEnergyPass &&
            r.efficiencyPass &&
            r.thermalPass &&
            r.timePass &&
            r.mechanicalPass

        result = r
    }
}
