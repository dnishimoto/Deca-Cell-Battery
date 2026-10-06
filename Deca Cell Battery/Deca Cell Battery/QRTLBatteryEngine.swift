
import Foundation
import Combine

@MainActor
final class QRTLBatteryEngine: ObservableObject {

    // ============================================================
    // CONTENTVIEW-FACING INTERFACE — UNCHANGED
    // ============================================================

    @Published var cells: [QRTLCAChargeCell] = []
    @Published var generation = 0
    @Published var isRunning = false
    @Published var result = QRTLDesignResult()
    @Published var status = "Ready"
    @Published var simulatedTimeS = 0.0

    private var runTask: Task<Void, Never>?

    // ============================================================
    // INTERNAL MODEL STATE
    // ============================================================

    private var neighborTable: [[Int]] = []
    private var acceptance: [Double] = []
    private var meanTransport = 1.0

    private var nodeResistanceOhm: [Double] = []
    private var localCurrentA: [Double] = []

    private var electrolytePotentialV: [Double] = []

    private var effectiveCellResistanceOhm = 0.0

    private var cumulativeInputEnergyJ = 0.0
    private var cumulativeLossEnergyJ = 0.0

    // ============================================================
    // NUMERICAL SAFETY
    // ============================================================

    private let minimumResistanceOhm = 1e-9
    private let minimumConcentration = 1e-9
    private let minimumTemperatureK = 250.0
    private let maximumTemperatureK = 450.0

    // ============================================================
    // INITIALIZATION
    // ============================================================

    init() {
        reset()
    }

    deinit {
        runTask?.cancel()
    }

    // ============================================================
    // CONTENTVIEW INTERFACE
    // ============================================================

    var chargePercent: Double {
        guard !cells.isEmpty else {
            return 0.0
        }

        let averageSOC =
            cells.reduce(0.0) { $0 + $1.soc } /
            Double(cells.count)

        return clamp(averageSOC * 100.0, 0.0, 100.0)
    }

    // ============================================================
    // RESET
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
        nodeResistanceOhm.removeAll()
        localCurrentA.removeAll()
        electrolytePotentialV.removeAll()

        effectiveCellResistanceOhm = 0.0
        meanTransport = 1.0

        buildCA()
        calculateDesignResult()

        status = "Ready — equation-coupled model"
    }

    // ============================================================
    // RUN
    // ============================================================

    func run() {
        runTask?.cancel()

        reset()

        isRunning = true
        status = "Running equation-coupled charge simulation"

        runTask = Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            while !Task.isCancelled && self.isRunning {

                self.advance()

                if !self.isRunning {
                    break
                }

                try? await Task.sleep(
                    nanoseconds: 1000
                )
            }
        }
    }

    // ============================================================
    // STOP
    // ============================================================

    func stop() {
        runTask?.cancel()
        runTask = nil

        isRunning = false
        calculateDesignResult()

        status = "Stopped"
    }

    // ============================================================
    // ADVANCE
    // ============================================================

    func advance() {

        guard !cells.isEmpty else {
            isRunning = false
            status = "No CA cells"
            return
        }

        step()

        generation += 1

        simulatedTimeS += QRTLConstants.simSecondsPerStep

        let averageSOC =
            cells.reduce(0.0) { $0 + $1.soc } /
            Double(cells.count)

        if averageSOC >= QRTLConstants.chargeCompleteSOC {

            isRunning = false
            runTask?.cancel()
            runTask = nil

            calculateDesignResult()

            status = result.overallPass
                ? "PASS — charge target reached"
                : "Charge target reached — design constraints not all satisfied"

            return
        }

        if generation >= QRTLConstants.caIterations {

            isRunning = false
            runTask?.cancel()
            runTask = nil

            calculateDesignResult()

            status = result.overallPass
                ? "PASS — simulation complete"
                : "Simulation complete — design constraints not all satisfied"
        }
    }

    // ============================================================
    // CA CONSTRUCTION
    // ============================================================

    private func buildCA() {

        let width = QRTLConstants.caWidth
        let height = QRTLConstants.caHeight

        let count = width * height

        cells = Array(
            repeating: QRTLCAChargeCell(),
            count: count
        )

        neighborTable = Array(
            repeating: [],
            count: count
        )

        acceptance = Array(
            repeating: 1.0,
            count: count
        )

        nodeResistanceOhm = Array(
            repeating: 0.0,
            count: count
        )

        localCurrentA = Array(
            repeating: 0.0,
            count: count
        )

        electrolytePotentialV = Array(
            repeating: 0.0,
            count: count
        )

        // --------------------------------------------------------
        // CREATE TPMS COMPUTATIONAL DOMAIN
        // --------------------------------------------------------

        for y in 0..<height {
            for x in 0..<width {

                let i = y * width + x

                let fx =
                    Double(x) /
                    Double(max(width - 1, 1))

                let fy =
                    Double(y) /
                    Double(max(height - 1, 1))

                let z = QRTLConstants.tpmsSliceZ

                let phi =
                    sin(2.0 * Double.pi * fx) *
                    cos(2.0 * Double.pi * fy)
                    +
                    sin(2.0 * Double.pi * fy) *
                    cos(2.0 * Double.pi * z)
                    +
                    sin(2.0 * Double.pi * z) *
                    cos(2.0 * Double.pi * fx)

                let solid =
                    clamp(
                        0.5 +
                        0.5 * phi,
                        0.05,
                        0.95
                    )

                let porosity =
                    clamp(
                        1.0 - solid,
                        0.05,
                        0.95
                    )

                let tortuosity =
                    clamp(
                        1.0 +
                        1.5 * solid,
                        1.0,
                        4.0
                    )

                var cell = QRTLCAChargeCell()

                cell.x = x
                cell.y = y

                cell.phiTPMS = phi
                cell.solidFraction = solid
                cell.porosity = porosity
                cell.tortuosity = tortuosity

                cell.soc = 0.0
                cell.lithiumConcentration =
                    QRTLConstants.tabReservoirConcentration

                cell.temperatureC = 25.0
                cell.degradation = 0.0
                cell.sulfurFraction = 1.0

                cells[i] = cell
            }
        }

        // --------------------------------------------------------
        // 4-CONNECTED CA NEIGHBORHOOD
        // --------------------------------------------------------

        for y in 0..<height {
            for x in 0..<width {

                let i = y * width + x

                var neighbors: [Int] = []

                if x > 0 {
                    neighbors.append(i - 1)
                }

                if x < width - 1 {
                    neighbors.append(i + 1)
                }

                if y > 0 {
                    neighbors.append(i - width)
                }

                if y < height - 1 {
                    neighbors.append(i + width)
                }

                neighborTable[i] = neighbors
            }
        }

        // --------------------------------------------------------
        // TRANSPORT ACCEPTANCE
        // --------------------------------------------------------

        var transportValues: [Double] =
            Array(repeating: 1.0, count: count)

        for i in 0..<count {

            let c = cells[i]

            let transport =
                c.porosity /
                max(c.tortuosity, 1.0)

            transportValues[i] =
                max(transport, 1e-6)
        }

        let transportMean =
            transportValues.reduce(0.0, +) /
            Double(max(transportValues.count, 1))

        meanTransport = max(transportMean, 1e-9)

        for i in 0..<count {

            let normalized =
                transportValues[i] /
                meanTransport

            acceptance[i] =
                clamp(
                    1.0 +
                    QRTLConstants.caAcceptanceModulation *
                    (normalized - 1.0),
                    0.10,
                    2.0
                )
        }

        // --------------------------------------------------------
        // NODE RESISTANCE
        // --------------------------------------------------------

        for i in 0..<count {

            let c = cells[i]

            let conductivity =
                max(
                    QRTLConstants.ionicConductivitySm *
                    c.porosity /
                    max(c.tortuosity, 1.0),
                    1e-8
                )

            let length =
                max(
                    QRTLConstants.caCellLengthM,
                    1e-6
                )

            let area =
                max(
                    c.porosity *
                    QRTLConstants.caCellLengthM *
                    QRTLConstants.caCellLengthM,
                    1e-12
                )

            let resistance =
                length /
                max(conductivity * area, 1e-12)

            nodeResistanceOhm[i] =
                clamp(
                    resistance,
                    minimumResistanceOhm,
                    1e6
                )
        }

        // --------------------------------------------------------
        // PARALLEL EQUIVALENT RESISTANCE
        // --------------------------------------------------------

        let conductance =
            nodeResistanceOhm.reduce(0.0) {
                $0 + 1.0 /
                max($1, minimumResistanceOhm)
            }

        effectiveCellResistanceOhm =
            conductance > 0.0
            ? 1.0 / conductance
            : 1e6

        effectiveCellResistanceOhm =
            clamp(
                effectiveCellResistanceOhm,
                minimumResistanceOhm,
                1e6
            )

        // --------------------------------------------------------
        // INITIAL ELECTROLYTE POTENTIAL
        // --------------------------------------------------------

        initializeElectrolytePotential()

        // Establish a valid initial current distribution.
        updateLocalCurrentDistribution()
    }

    // ============================================================
    // ELECTROLYTE POTENTIAL
    // ============================================================

    private func initializeElectrolytePotential() {

        guard !cells.isEmpty else {
            return
        }

        let width = QRTLConstants.caWidth

        for i in cells.indices {

            let x = i % width

            let normalizedX =
                Double(x) /
                Double(max(width - 1, 1))

            electrolytePotentialV[i] =
                -normalizedX *
                QRTLConstants.cellNominalVoltageV

            cells[i].electrolytePotentialV =
                electrolytePotentialV[i]
        }
    }

    // ============================================================
    // ELECTROLYTE POTENTIAL RELAXATION
    // ============================================================

    private func relaxElectrolytePotential(
        previous: [QRTLCAChargeCell]
    ) {

        guard !cells.isEmpty else {
            return
        }

        let width = QRTLConstants.caWidth

        var newPotential =
            electrolytePotentialV

        for i in cells.indices {

            let neighbors = neighborTable[i]

            guard !neighbors.isEmpty else {
                continue
            }

            var weightedPotential = 0.0
            var weightSum = 0.0

            for j in neighbors {

                let conductance =
                    1.0 /
                    max(
                        nodeResistanceOhm[j],
                        minimumResistanceOhm
                    )

                weightedPotential +=
                    electrolytePotentialV[j] *
                    conductance

                weightSum += conductance
            }

            if weightSum > 0.0 {

                let average =
                    weightedPotential /
                    weightSum

                let relaxation =
                    clamp(
                        QRTLConstants.caTransportCoefficient,
                        0.01,
                        0.5
                    )

                newPotential[i] =
                    electrolytePotentialV[i] +
                    relaxation *
                    (average - electrolytePotentialV[i])
            }
        }

        // Fixed reservoir boundary.
        for y in 0..<QRTLConstants.caHeight {

            let i = y * width

            if i < newPotential.count {
                newPotential[i] = 0.0
            }
        }

        electrolytePotentialV = newPotential

        for i in cells.indices {

            cells[i].electrolytePotentialV =
                clamp(
                    electrolytePotentialV[i],
                    -10.0,
                    10.0
                )
        }
    }

    // ============================================================
    // CONSERVED LOCAL CURRENT DISTRIBUTION
    // ============================================================

    private func updateLocalCurrentDistribution() {

        guard !nodeResistanceOhm.isEmpty else {
            return
        }

        let targetCurrent =
            max(
                QRTLConstants.targetCellCurrentA,
                0.0
            )

        var conductances =
            Array(
                repeating: 0.0,
                count: nodeResistanceOhm.count
            )

        var totalConductance = 0.0

        for i in nodeResistanceOhm.indices {

            let g =
                1.0 /
                max(
                    nodeResistanceOhm[i],
                    minimumResistanceOhm
                )

            conductances[i] = g
            totalConductance += g
        }

        guard totalConductance > 0.0 else {
            localCurrentA =
                Array(
                    repeating: 0.0,
                    count: nodeResistanceOhm.count
                )
            return
        }

        for i in conductances.indices {

            localCurrentA[i] =
                targetCurrent *
                conductances[i] /
                totalConductance

            localCurrentA[i] =
                clamp(
                    localCurrentA[i],
                    0.0,
                    targetCurrent
                )
        }

        // --------------------------------------------------------
        // FINAL NORMALIZATION
        //
        // Ensures numerical rounding cannot violate:
        //
        // Σ I_i = I_cell
        // --------------------------------------------------------

        let sumCurrent =
            localCurrentA.reduce(0.0, +)

        if sumCurrent > 0.0 {

            let scale =
                targetCurrent /
                sumCurrent

            for i in localCurrentA.indices {
                localCurrentA[i] *= scale
            }
        }
    }

    // ============================================================
    // MAIN SIMULATION STEP
    // ============================================================

    private func step() {

        guard !cells.isEmpty else {
            return
        }

        let previous = cells

        let dtS =
            max(
                QRTLConstants.simSecondsPerStep,
                1e-6
            )

        let dtH =
            dtS / 3600.0

        let ambientC = 25.0

        // --------------------------------------------------------
        // 1. UPDATE ELECTROLYTE POTENTIAL
        // --------------------------------------------------------

        relaxElectrolytePotential(
            previous: previous
        )

        // --------------------------------------------------------
        // 2. UPDATE LOCAL CURRENT DISTRIBUTION
        // --------------------------------------------------------

        updateLocalCurrentDistribution()

        // --------------------------------------------------------
        // 3. SOC / COULOMB COUNTING
        // --------------------------------------------------------

        let cellCurrent =
            max(
                QRTLConstants.targetCellCurrentA,
                0.0
            )

        let qEffAh =
            max(
                QRTLConstants.cellCapacityAh *
                max(
                    1.0 - averageDegradation(
                        from: previous
                    ),
                    1e-6
                ),
                1e-9
            )

        var newSOC =
            Array(
                repeating: 0.0,
                count: cells.count
            )

        for i in cells.indices {

            var mixing = 0.0

            for j in neighborTable[i] {

                let face =
                    0.5 *
                    (
                        acceptance[i] +
                        acceptance[j]
                    )

                mixing +=
                    QRTLConstants.caTransportCoefficient *
                    0.25 *
                    face *
                    (
                        previous[j].soc -
                        previous[i].soc
                    )
            }

            let localCurrent =
                localCurrentA[i]

            let localSOCStep =
                localCurrent *
                dtH /
                qEffAh

            let raw =
                previous[i].soc +
                mixing +
                localSOCStep

            newSOC[i] =
                clamp(
                    raw,
                    0.0,
                    1.0
                )
        }

        // --------------------------------------------------------
        // 4. NERNST–PLANCK TRANSPORT
        //
        // IMPORTANT:
        // dPhi is now the electrolyte potential gradient.
        // Equilibrium voltage is NOT used as electric potential.
        // --------------------------------------------------------

        let dx =
            max(
                QRTLConstants.caCellLengthM,
                1e-6
            )

        let temperatureReferenceK =
            298.15

        for i in cells.indices {

            var lithiumFlux = 0.0

            let ci =
                max(
                    previous[i].lithiumConcentration,
                    minimumConcentration
                )

            for j in neighborTable[i] {

                let cj =
                    max(
                        previous[j].lithiumConcentration,
                        minimumConcentration
                    )

                let dFace =
                    0.5 *
                    (
                        effectiveDiffusivity(
                            previous[i]
                        ) +
                        effectiveDiffusivity(
                            previous[j]
                        )
                    )

                let cFace =
                    0.5 *
                    (ci + cj)

                let dC =
                    cj - ci

                let dPhi =
                    electrolytePotentialV[j] -
                    electrolytePotentialV[i]

                let migration =
                    (
                        QRTLConstants.faradayConstant *
                        dFace *
                        cFace /
                        (
                            QRTLConstants.gasConstant *
                            temperatureReferenceK
                        )
                    ) *
                    dPhi /
                    dx

                let diffusion =
                    dFace *
                    dC /
                    dx

                let faceFlux =
                    -diffusion -
                    migration

                lithiumFlux +=
                    faceFlux *
                    0.25
            }

            cells[i].lithiumIonFlux =
                clamp(
                    lithiumFlux,
                    -1e12,
                    1e12
                )

            let concentrationChange =
                -lithiumFlux *
                dtS /
                max(dx, 1e-9)

            cells[i].lithiumConcentration =
                clamp(
                    previous[i].lithiumConcentration +
                    concentrationChange,
                    minimumConcentration,
                    10.0
                )
        }

        // Reservoir boundary.
        let width = QRTLConstants.caWidth

        for y in 0..<QRTLConstants.caHeight {

            let i = y * width

            if i < cells.count {

                cells[i].lithiumConcentration =
                    QRTLConstants.tabReservoirConcentration
            }
        }

        // --------------------------------------------------------
        // 5. RESONATOR STEADY-STATE MODEL
        // --------------------------------------------------------

        let omegaDrive =
            2.0 *
            Double.pi *
            QRTLConstants.resonanceFrequencyHz

        let springK =
            max(
                QRTLConstants.resonatorSpringConstantNpm,
                1e-12
            )

        let resonatorMass =
            max(
                QRTLConstants.resonatorMassPerCellKg,
                1e-12
            )

        let naturalOmega =
            sqrt(
                springK /
                resonatorMass
            )

        let detuning =
            (
                omegaDrive -
                naturalOmega
            ) /
            max(
                naturalOmega,
                1.0
            )

        let qualityFactor =
            max(
                QRTLConstants.qualityFactor,
                1.0
            )

        let lorentzian =
            1.0 /
            (
                1.0 +
                pow(
                    2.0 *
                    qualityFactor *
                    detuning,
                    2.0
                )
            )

        let drivePowerPerCell =
            max(
                QRTLConstants.targetChargePowerW *
                QRTLConstants.resonatorDrivePowerFraction /
                Double(
                    max(
                        QRTLConstants.cellCount,
                        1
                    )
                ),
                0.0
            )

        let absorbedPower =
            drivePowerPerCell *
            QRTLConstants.resonatorCouplingEfficiency *
            lorentzian

        let storedEnergy =
            absorbedPower *
            qualityFactor /
            max(
                omegaDrive,
                1.0
            )

        let resonatorLoss =
            omegaDrive *
            storedEnergy /
            qualityFactor

        let amplitude =
            sqrt(
                max(
                    2.0 *
                    storedEnergy /
                    springK,
                    0.0
                )
            )

        let piezoPower =
            QRTLConstants.piezoCouplingCoefficient *
            QRTLConstants.piezoCouplingCoefficient *
            omegaDrive *
            storedEnergy

        // --------------------------------------------------------
        // 6. LOCAL ELECTROCHEMISTRY
        // --------------------------------------------------------

        let gasConstant =
            QRTLConstants.gasConstant

        let faraday =
            QRTLConstants.faradayConstant

        let chargeTransferCoefficient =
            max(
                QRTLConstants.chargeTransferCoefficient,
                1e-6
            )

        for i in cells.indices {

            var c = cells[i]

            let temperatureC =
                clamp(
                    previous[i].temperatureC,
                    ambientC - 20.0,
                    150.0
                )

            let temperatureK =
                clamp(
                    temperatureC + 273.15,
                    minimumTemperatureK,
                    maximumTemperatureK
                )

            // ----------------------------------------------------
            // LOCAL CURRENT
            //
            // This is the conserved branch current rather than
            // incorrectly applying the full cell current to every
            // CA node.
            // ----------------------------------------------------

            let localCurrent =
                localCurrentA[i]

            let area =
                max(
                    c.porosity *
                    QRTLConstants.caCellLengthM *
                    QRTLConstants.caCellLengthM,
                    1e-12
                )

            let currentDensity =
                localCurrent /
                area

            // ----------------------------------------------------
            // EQUILIBRIUM VOLTAGE
            // ----------------------------------------------------

            c.sulfurFraction =
                clamp(
                    newSOC[i],
                    0.001,
                    1.0
                )

            let reactionQuotient =
                max(
                    c.sulfurFraction,
                    0.01
                ) /
                max(
                    c.lithiumConcentration,
                    0.01
                )

            let equilibriumCorrection =
                (
                    gasConstant *
                    temperatureK /
                    (
                        Double(
                            QRTLConstants.sulfurElectrons
                        ) *
                        faraday
                    )
                ) *
                safeLog(
                    reactionQuotient
                )

            c.equilibriumVoltageV =
                clamp(
                    QRTLConstants.cellNominalVoltageV +
                    equilibriumCorrection,
                    0.1,
                    5.0
                )

            // ----------------------------------------------------
            // EXCHANGE CURRENT
            // ----------------------------------------------------

            let concentrationFactor =
                sqrt(
                    max(
                        c.lithiumConcentration,
                        minimumConcentration
                    )
                )

            c.exchangeCurrentDensity =
                max(
                    QRTLConstants.arealCapacityAhM2 /
                    3600.0 *
                    concentrationFactor,
                    1e-9
                )

            // ----------------------------------------------------
            // BUTLER–VOLMER REDUCED FORM
            // ----------------------------------------------------

            let argument =
                currentDensity /
                max(
                    2.0 *
                    c.exchangeCurrentDensity,
                    1e-9
                )

            c.overpotentialV =
                (
                    gasConstant *
                    temperatureK /
                    (
                        chargeTransferCoefficient *
                        faraday
                    )
                ) *
                asinh(
                    clamp(
                        argument,
                        -1e12,
                        1e12
                    )
                )

            c.reactionRate =
                currentDensity /
                faraday

            c.electronicCurrentDensity =
                currentDensity

            c.impedanceOhm =
                max(
                    nodeResistanceOhm[i],
                    minimumResistanceOhm
                )

            // ----------------------------------------------------
            // LOCAL OHMIC DROP
            // ----------------------------------------------------

            let localVoltageDrop =
                localCurrent *
                c.impedanceOhm

            c.localVoltageV =
                clamp(
                    c.equilibriumVoltageV +
                    c.overpotentialV +
                    localVoltageDrop,
                    0.0,
                    10.0
                )

            // ----------------------------------------------------
            // RESONATOR
            // ----------------------------------------------------

            c.resonatorEnergyJ =
                clamp(
                    storedEnergy,
                    0.0,
                    1e6
                )

            c.resonatorLossW =
                clamp(
                    resonatorLoss,
                    0.0,
                    1e6
                )

            c.resonanceAmplitudeM =
                clamp(
                    amplitude,
                    0.0,
                    1.0
                )

            c.resonancePhaseRad =
                atan2(
                    2.0 *
                    qualityFactor *
                    detuning,
                    1.0
                )

            c.piezoPowerW =
                clamp(
                    piezoPower,
                    0.0,
                    1e6
                )

            // ----------------------------------------------------
            // HEAT GENERATION
            // ----------------------------------------------------

            let ohmicW =
                localCurrent *
                localCurrent *
                c.impedanceOhm

            let reactionW =
                abs(
                    localCurrent *
                    c.overpotentialV
                )

            let reversibleW =
                abs(
                    localCurrent *
                    temperatureK *
                    QRTLConstants.entropicCoefficientVPerK
                )

            c.heatGenerationW =
                clamp(
                    ohmicW +
                    reactionW +
                    c.resonatorLossW +
                    reversibleW,
                    0.0,
                    1e6
                )

            // ----------------------------------------------------
            // THERMAL UPDATE
            //
            // Neighbor conduction is explicitly bounded while
            // ambient cooling is treated implicitly.
            // ----------------------------------------------------

            let heatCapacity =
                max(
                    localHeatCapacity(for: c),
                    1e-9
                )

            let ambientConductance =
                max(
                    localCoolingConductance(for: c),
                    0.0
                )

            var neighborConduction = 0.0

            for j in neighborTable[i] {

                let deltaT =
                    previous[j].temperatureC -
                    previous[i].temperatureC

                let conductance =
                    boundedThermalConductance(
                        from: previous[i],
                        to: previous[j]
                    )

                neighborConduction +=
                    conductance *
                    clamp(
                        deltaT,
                        -100.0,
                        100.0
                    )
            }

            // Explicit neighbor contribution is bounded by the
            // available thermal time scale.
            let maxConduction =
                0.25 *
                heatCapacity /
                dtS *
                100.0

            neighborConduction =
                clamp(
                    neighborConduction,
                    -maxConduction,
                    maxConduction
                )

            let numerator =
                previous[i].temperatureC +
                (
                    dtS /
                    heatCapacity
                ) *
                (
                    c.heatGenerationW +
                    neighborConduction
                ) +
                (
                    dtS *
                    ambientConductance /
                    heatCapacity
                ) *
                ambientC

            let denominator =
                1.0 +
                dtS *
                ambientConductance /
                heatCapacity

            let newTemperature =
                numerator /
                max(
                    denominator,
                    1.0
                )

            c.temperatureC =
                clamp(
                    newTemperature,
                    ambientC - 20.0,
                    150.0
                )

            // ----------------------------------------------------
            // MECHANICAL STATE
            // ----------------------------------------------------

            let thermalStrain =
                (
                    c.temperatureC -
                    ambientC
                ) *
                QRTLConstants.thermalExpansionCoefficientPerK

            c.strain =
                clamp(
                    thermalStrain,
                    -0.1,
                    0.1
                )

            c.stressPa =
                clamp(
                    abs(
                        c.strain *
                        QRTLConstants.mechanicalModulusPa
                    ),
                    0.0,
                    1e12
                )

            // ----------------------------------------------------
            // DEGRADATION
            // ----------------------------------------------------

            let overTemperature =
                max(
                    c.temperatureC -
                    QRTLConstants.maximumTemperatureC,
                    0.0
                )

            let stressRatio =
                c.stressPa /
                max(
                    QRTLConstants.maximumStressMPa *
                    1e6,
                    1.0
                )

            let deltaSOC =
                max(
                    newSOC[i] -
                    previous[i].soc,
                    0.0
                )

            let degradationIncrement =
                QRTLConstants.degradationCoefficientPerCycle *
                deltaSOC *
                (
                    1.0 +
                    overTemperature / 20.0 +
                    stressRatio
                )

            c.degradation =
                clamp(
                    previous[i].degradation +
                    degradationIncrement,
                    0.0,
                    1.0
                )

            // ----------------------------------------------------
            // FINAL SOC
            // ----------------------------------------------------

            c.soc =
                clamp(
                    newSOC[i],
                    0.0,
                    1.0
                )

            // ----------------------------------------------------
            // CHARGE ENERGY
            // ----------------------------------------------------

            c.chargeEnergyJ +=
                max(
                    localCurrent *
                    max(
                        c.localVoltageV,
                        0.0
                    ) *
                    dtS,
                    0.0
                )

            // ----------------------------------------------------
            // STATE
            // ----------------------------------------------------

            if c.degradation > 0.20 {

                c.state = .damaged

            } else if c.temperatureC >
                        QRTLConstants.maximumTemperatureC {

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

            cells[i] = c
        }

        // ========================================================
        // PACK-LEVEL BOOKKEEPING
        //
        // CA node quantities are representative-cell quantities.
        // Only after averaging do we scale to 2,700 physical cells.
        // ========================================================

        let nPhysicalCells =
            Double(
                max(
                    QRTLConstants.cellCount,
                    1
                )
            )

        let averageLocalVoltage =
            meanValue(
                from: cells,
                keyPath: \.localVoltageV
            )

        let averageLocalCurrent =
            localCurrentA.reduce(0.0, +) /
            Double(
                max(
                    localCurrentA.count,
                    1
                )
            )

        let averageOhmicLoss =
            cells.indices.reduce(0.0) {
                let i = $1

                return $0 +
                    localCurrentA[i] *
                    localCurrentA[i] *
                    nodeResistanceOhm[i]
            }

        let averageReactionLoss =
            cells.indices.reduce(0.0) {
                let i = $1

                return $0 +
                    abs(
                        localCurrentA[i] *
                        cells[i].overpotentialV
                    )
            }

        let averageResonatorLoss =
            meanValue(
                from: cells,
                keyPath: \.resonatorLossW
            )

        let inputPowerW =
            nPhysicalCells *
            averageLocalCurrent *
            max(
                averageLocalVoltage,
                0.0
            )

        let lossPowerW =
            nPhysicalCells *
            (
                averageOhmicLoss /
                Double(
                    max(
                        cells.count,
                        1
                    )
                )
                +
                averageReactionLoss /
                Double(
                    max(
                        cells.count,
                        1
                    )
                )
                +
                averageResonatorLoss
            )

        cumulativeInputEnergyJ +=
            max(
                inputPowerW,
                0.0
            ) *
            dtS

        cumulativeLossEnergyJ +=
            max(
                lossPowerW,
                0.0
            ) *
            dtS
    }

    // ============================================================
    // DESIGN RESULT
    // ============================================================

    private func calculateDesignResult() {

        guard !cells.isEmpty else {
            result = QRTLDesignResult()
            return
        }

        var r = QRTLDesignResult()

        let nPhysicalCells =
            Double(
                max(
                    QRTLConstants.cellCount,
                    1
                )
            )

        // --------------------------------------------------------
        // SOC / DEGRADATION
        // --------------------------------------------------------

        r.averageSOC =
            meanValue(
                from: cells,
                keyPath: \.soc
            )

        let degradation =
            averageDegradation()

        // --------------------------------------------------------
        // PACK MASS
        // --------------------------------------------------------

        r.packMassKg =
            nPhysicalCells *
            (
                QRTLConstants.sulfurMassPerCellKg +
                QRTLConstants.resonatorMassPerCellKg
            )

        // --------------------------------------------------------
        // RATED ENERGY
        // --------------------------------------------------------

        r.ratedEnergyKWh =
            Double(
                QRTLConstants.seriesCells
            ) *
            QRTLConstants.cellNominalVoltageV *
            QRTLConstants.cellCapacityAh *
            Double(
                QRTLConstants.parallelStrings
            ) /
            1000.0

        r.usableEnergyKWh =
            r.ratedEnergyKWh *
            r.averageSOC *
            max(
                1.0 - degradation,
                0.0
            )

        // --------------------------------------------------------
        // SPECIFIC ENERGY
        // --------------------------------------------------------

        r.specificEnergyWhKg =
            r.packMassKg > 0.0
            ? r.usableEnergyKWh *
              1000.0 /
              r.packMassKg
            : 0.0

        // --------------------------------------------------------
        // RESISTANCE
        // --------------------------------------------------------

        r.totalResistanceOhm =
            effectiveCellResistanceOhm *
            Double(
                QRTLConstants.seriesCells
            ) /
            Double(
                max(
                    QRTLConstants.parallelStrings,
                    1
                )
            )

        // --------------------------------------------------------
        // ELECTRICAL LOSSES
        // --------------------------------------------------------

        let averageOhmicLossPerNode =
            cells.indices.reduce(0.0) {
                let i = $1

                return $0 +
                    localCurrentA[i] *
                    localCurrentA[i] *
                    nodeResistanceOhm[i]
            } /
            Double(
                max(
                    cells.count,
                    1
                )
            )

        r.ohmicLossW =
            nPhysicalCells *
            averageOhmicLossPerNode

        r.reactionLossW =
            nPhysicalCells *
            cells.indices.reduce(0.0) {
                let i = $1

                return $0 +
                    abs(
                        localCurrentA[i] *
                        cells[i].overpotentialV
                    )
            } /
            Double(
                max(
                    cells.count,
                    1
                )
            )

        r.resonatorLossW =
            nPhysicalCells *
            meanValue(
                from: cells,
                keyPath: \.resonatorLossW
            )

        let averageTemperatureK =
            meanValue(
                from: cells,
                keyPath: \.temperatureC
            ) +
            273.15

        r.entropicHeatW =
            nPhysicalCells *
            QRTLConstants.targetCellCurrentA *
            averageTemperatureK *
            QRTLConstants.entropicCoefficientVPerK

        r.thermalLossW =
            nPhysicalCells *
            meanValue(
                from: cells,
                keyPath: \.heatFluxWm2
            ) *
            QRTLConstants.tpmsThermalAreaM2PerCell

        r.totalLossW =
            max(
                r.ohmicLossW,
                0.0
            ) +
            max(
                r.reactionLossW,
                0.0
            ) +
            max(
                r.resonatorLossW,
                0.0
            )

        // --------------------------------------------------------
        // EFFICIENCY
        // --------------------------------------------------------

        if cumulativeInputEnergyJ > 1e-12 {

            r.efficiency =
                clamp(
                    1.0 -
                    cumulativeLossEnergyJ /
                    cumulativeInputEnergyJ,
                    0.0,
                    1.0
                )

        } else {

            r.efficiency = 1.0
        }

        // --------------------------------------------------------
        // THERMAL / MECHANICAL
        // --------------------------------------------------------

        r.maxTemperatureC =
            cells.map(\.temperatureC).max() ?? 25.0

        r.maximumStressMPa =
            cells.map(\.stressPa).max() ?? 0.0

        // --------------------------------------------------------
        // POWER CAPABILITY
        // --------------------------------------------------------

        let currentLimitedPower =
            QRTLConstants.targetCellCurrentA *
            Double(
                QRTLConstants.seriesCells
            ) *
            QRTLConstants.cellNominalVoltageV

        let thermalMargin =
            max(
                QRTLConstants.maximumTemperatureC -
                r.maxTemperatureC,
                0.0
            )

        let thermalFactor =
            clamp(
                thermalMargin /
                max(
                    QRTLConstants.maximumTemperatureC,
                    1.0
                ),
                0.05,
                1.0
            )

        let thermalLimitedPower =
            currentLimitedPower *
            thermalFactor

        let efficiencyLimitedPower =
            currentLimitedPower *
            clamp(
                r.efficiency,
                0.05,
                1.0
            )

        r.powerCapabilityW =
            max(
                0.0,
                min(
                    currentLimitedPower,
                    thermalLimitedPower,
                    efficiencyLimitedPower
                )
            )

        // --------------------------------------------------------
        // CHARGE POWER
        // --------------------------------------------------------

        let modeledChargePower =
            min(
                QRTLConstants.targetChargePowerW,
                r.powerCapabilityW
            )

        // --------------------------------------------------------
        // CHARGE TIME
        // --------------------------------------------------------

        let remainingSOC =
            max(
                1.0 -
                r.averageSOC,
                0.0
            )

        let qEffAh =
            max(
                QRTLConstants.cellCapacityAh *
                max(
                    1.0 -
                    degradation,
                    1e-6
                ),
                1e-9
            )

        let current =
            max(
                QRTLConstants.targetCellCurrentA,
                1e-9
            )

        let currentLimitedHours =
            remainingSOC *
            qEffAh /
            current

        let powerLimitedHours =
            modeledChargePower > 0.0
            ? (
                remainingSOC *
                r.ratedEnergyKWh /
                (
                    modeledChargePower /
                    1000.0
                )
            )
            : Double.infinity

        r.chargeTimeHours =
            max(
                simulatedTimeS / 3600.0 +
                currentLimitedHours,
                powerLimitedHours
            )

        // --------------------------------------------------------
        // TPMS METRICS
        // --------------------------------------------------------

        r.tpmsSolidFraction =
            meanValue(
                from: cells,
                keyPath: \.solidFraction
            )

        r.tpmsPorosity =
            meanValue(
                from: cells,
                keyPath: \.porosity
            )

        r.tpmsPorosity =
            meanValue(
                from: cells,
                keyPath: \.tortuosity
            )

        // --------------------------------------------------------
        // CONSTRAINT CHECKS
        // --------------------------------------------------------

        r.energyPass =
            r.usableEnergyKWh >=
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
            QRTLConstants.maximumStressMPa *
            1e6

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

    // ============================================================
    // EFFECTIVE DIFFUSIVITY
    // ============================================================

    private func effectiveDiffusivity(
        _ cell: QRTLCAChargeCell
    ) -> Double {

        let base =
            max(
                QRTLConstants.lithiumDiffusivityM2s,
                1e-12
            )

        return clamp(
            base *
            cell.porosity /
            max(
                cell.tortuosity,
                1.0
            ),
            1e-14,
            1e-4
        )
    }

    // ============================================================
    // THERMAL HELPERS
    // ============================================================

    private func localHeatCapacity(
        for cell: QRTLCAChargeCell
    ) -> Double {

        let aluminumFraction =
            clamp(
                cell.solidFraction,
                0.0,
                1.0
            )

        let effectiveSpecificHeat =
            aluminumFraction *
            900.0 +
            (
                1.0 -
                aluminumFraction
            ) *
            1800.0

        let volume =
            max(
                QRTLConstants.caCellLengthM *
                QRTLConstants.caCellLengthM *
                QRTLConstants.caCellLengthM,
                1e-15
            )

        let density =
            aluminumFraction *
            2700.0 +
            (
                1.0 -
                aluminumFraction
            ) *
            1200.0

        return max(
            density *
            volume *
            effectiveSpecificHeat,
            1e-9
        )
    }

    private func localCoolingConductance(
        for cell: QRTLCAChargeCell
    ) -> Double {

        let area =
            max(
                QRTLConstants.tpmsThermalAreaM2PerCell,
                1e-8
            )

        let coefficient =
            max(
                QRTLConstants.thermalConvectionCoefficientWm2K,
                0.0
            )

        return coefficient * area
    }

    private func boundedThermalConductance(
        from a: QRTLCAChargeCell,
        to b: QRTLCAChargeCell
    ) -> Double {

        let conductivity =
            max(
                QRTLConstants.thermalConductivityWmK,
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
                QRTLConstants.caCellLengthM,
                1e-6
            )

        let porosity =
            0.5 *
            (
                clamp(a.porosity, 0.01, 1.0) +
                clamp(b.porosity, 0.01, 1.0)
            )

        return clamp(
            conductivity *
            area *
            porosity /
            length,
            0.0,
            1e6
        )
    }

    // ============================================================
    // DEGRADATION
    // ============================================================

    private func averageDegradation() -> Double {

        averageDegradation(
            from: cells
        )
    }

    private func averageDegradation(
        from source: [QRTLCAChargeCell]
    ) -> Double {

        guard !source.isEmpty else {
            return 0.0
        }

        return source.reduce(0.0) {
            $0 + $1.degradation
        } /
        Double(source.count)
    }

    // ============================================================
    // MEAN VALUE
    // ============================================================

    private func meanValue<T>(
        from source: [QRTLCAChargeCell],
        keyPath: KeyPath<QRTLCAChargeCell, T>
    ) -> Double where T: BinaryFloatingPoint {

        guard !source.isEmpty else {
            return 0.0
        }

        return source.reduce(0.0) {
            $0 + Double($1[keyPath: keyPath])
        } /
        Double(source.count)
    }

    // ============================================================
    // SAFE LOG
    // ============================================================

    private func safeLog(
        _ value: Double
    ) -> Double {

        log(
            max(
                value,
                1e-12
            )
        )
    }

    // ============================================================
    // CLAMP
    // ============================================================

    private func clamp(
        _ value: Double,
        _ minimum: Double,
        _ maximum: Double
    ) -> Double {

        if !value.isFinite {
            return minimum
        }

        return min(
            max(
                value,
                minimum
            ),
            maximum
        )
    }
}
