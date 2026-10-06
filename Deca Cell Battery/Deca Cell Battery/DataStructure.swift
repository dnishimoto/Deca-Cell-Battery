
//
//  DataStructure.swift
//  Deca Cell Battery
//
//  Created by David Nishimoto on 10/6/26.
//

import Foundation

// ============================================================
// MARK: - QRTL Constants
// ============================================================

struct QRTLConstants {

    // ========================================================
    // Targets
    // ========================================================

    static let targetEnergyKWh = 600.0
    static let targetChargePowerW = 1_000_000.0

    static let maximumPackMassKg = 300.0
    static let targetSpecificEnergyWhKg = 2_000.0

    static let maximumTemperatureC = 60.0
    static let minimumEfficiency = 0.99
    static let maximumChargeTimeHours = 0.60
    static let maximumStressMPa = 900.0

    // ========================================================
    // Topology
    // ========================================================

    static let seriesCells = 450
    static let parallelStrings = 6

    static let cellCount =
        seriesCells * parallelStrings

    static let cellNominalVoltageV = 2.22

    // ========================================================
    // Physical Constants
    // ========================================================

    static let faraday = 96_485.33212

    // Compatibility alias used internally by the engine.
    static let faradayConstant = faraday

    static let gasConstant = 8.314462618

    static let sulfurMolarMassKgMol = 0.032065
    static let sulfurElectrons = 2.0

    static let sulfurTheoreticalAhKg =
        sulfurElectrons *
        faraday /
        sulfurMolarMassKgMol /
        3600.0

    static let lithiumSpecificCapacityAhKg = 3_860.0

    static let sulfurUtilization = 0.95

    // ========================================================
    // Cell Material Design
    // ========================================================

    static let sulfurMassPerCellKg = 0.0632

    // 4 mAh/cm² loading.
    static let arealCapacityAhM2 = 40.0

    // ========================================================
    // Derived Cell / Pack Quantities
    // ========================================================

    static let cellCapacityAh =
        sulfurMassPerCellKg *
        sulfurTheoreticalAhKg *
        sulfurUtilization

    static let packVoltageV =
        Double(seriesCells) *
        cellNominalVoltageV

    static let packCapacityAh =
        cellCapacityAh *
        Double(parallelStrings)

    static let ratedEnergyKWh =
        packVoltageV *
        packCapacityAh /
        1000.0

    static let activeElectrodeAreaM2PerCell =
        cellCapacityAh /
        arealCapacityAhM2

    static let targetPackCurrentA =
        targetChargePowerW /
        packVoltageV

    static let targetCellCurrentA =
        targetPackCurrentA /
        Double(parallelStrings)

    // ========================================================
    // Reduced-Order Electrochemical Parameters
    // ========================================================

    static let electronicConductivitySm = 5.0e4

    static let ionicConductivitySm = 0.6

    static let lithiumDiffusivityM2s = 2.0e-11

    static let sulfurDiffusivityScale = 1.0

    static let referenceExchangeCurrentAm2 = 25.0

    static let chargeTransferCoefficient = 0.5

    static let exchangeCurrentActivationEnergyJMol =
        30_000.0

    static let entropicCoefficientVPerK = -0.0002

    static let electrolyteThicknessM = 25e-6

    static let electrodeThicknessM = 100e-6

    static let effectiveElectrodePorosity = 0.55

    static let tortuosity = 2.0

    static let conductorResistivityOhmM = 2.82e-8

    static let conductorLengthM = 0.10

    static let conductorAreaM2 = 1e-4

    static let interfaceResistanceOhmPerCell = 10e-6

    // ========================================================
    // Resonator
    // ========================================================

    static let resonanceFrequencyHz = 1_000_000.0

    static let resonatorDesignFrequencyHz = 1_000_000.0

    static let qualityFactor = 2_500.0

    static let resonatorDrivePowerFraction = 0.005

    static let resonatorCouplingEfficiency = 0.95

    static let resonatorMassPerCellKg = 0.002

    static let resonatorDesignOmega =
        2.0 *
        Double.pi *
        resonatorDesignFrequencyHz

    static let resonatorSpringConstantNpm =
        resonatorMassPerCellKg *
        resonatorDesignOmega *
        resonatorDesignOmega

    static let resonatorDampingNsM =
        resonatorMassPerCellKg *
        resonatorDesignOmega /
        qualityFactor

    static let piezoCouplingCoefficient = 0.12

    // ========================================================
    // Mass Model
    // ========================================================

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

    // ========================================================
    // Thermal
    // ========================================================

    static let heatTransferCoefficientWm2K = 250.0

    // Compatibility name used by the engine.
    static let thermalConvectionCoefficientWm2K =
        heatTransferCoefficientWm2K

    static let cellHeatCapacityJPerK = 1_000.0

    static let ambientTemperatureC = 25.0

    static let thermalConductivityWmK = 4.0

    static let caSliceDepthM = 0.01

    // ========================================================
    // Mechanics
    // ========================================================

    static let youngsModulusPa = 110e9

    // Compatibility name used by the engine.
    static let mechanicalModulusPa =
        youngsModulusPa

    // ========================================================
    // Thermal Expansion
    // ========================================================

    static let thermalExpansionCoefficientPerK =
        23.1e-6

    // ========================================================
    // Degradation
    // ========================================================

    static let degradationCoefficientPerCycle =
        0.000002

    // ========================================================
    // Cellular Automaton
    // ========================================================

    static let caWidth = 31

    static let caHeight = 31

    static let caIterations = 240

    static let simSecondsPerStep = 1.0

    static let caTransportCoefficient = 0.18

    static let caAcceptanceModulation = 0.25

    static let caCellLengthM = 0.001

    static let tabReservoirConcentration = 0.90

    static let tpmsSliceZ = 0.6

    static let chargeCompleteSOC = 0.999
}


// ============================================================
// MARK: - Math Helpers
// ============================================================

@inline(__always)
func clamp(
    _ x: Double,
    _ lo: Double,
    _ hi: Double
) -> Double {

    min(
        max(x, lo),
        hi
    )
}


@inline(__always)
func safeExp(
    _ x: Double
) -> Double {

    exp(
        clamp(
            x,
            -50.0,
            50.0
        )
    )
}


@inline(__always)
func safeLog(
    _ x: Double
) -> Double {

    log(
        max(
            x,
            1e-12
        )
    )
}


// ============================================================
// MARK: - CA Cell
// ============================================================

struct QRTLCAChargeCell: Identifiable {

    let id = UUID()

    var x: Int = 0
    var y: Int = 0

    // ========================================================
    // TPMS Geometry
    // ========================================================

    var phiTPMS: Double = 0.0

    var solidFraction: Double = 0.0

    var tortuosity: Double =
        QRTLConstants.tortuosity

    var porosity: Double =
        QRTLConstants.effectiveElectrodePorosity

    // ========================================================
    // Electrochemical State
    // ========================================================

    var soc: Double = 0.0

    var lithiumConcentration: Double = 0.5

    var sulfurFraction: Double = 0.001

    var lithiumIonFlux: Double = 0.0

    var electronicCurrentDensity: Double = 0.0

    var reactionRate: Double = 0.0

    var exchangeCurrentDensity: Double =
        QRTLConstants.referenceExchangeCurrentAm2

    var overpotentialV: Double = 0.0

    var equilibriumVoltageV =
        QRTLConstants.cellNominalVoltageV

    var localVoltageV =
        QRTLConstants.cellNominalVoltageV

    var impedanceOhm: Double = 0.0

    // ========================================================
    // NEW:
    // Electrolyte electric potential.
    //
    // This is deliberately separate from
    // equilibriumVoltageV.
    // ========================================================

    var electrolytePotentialV: Double = 0.0

    // ========================================================
    // Thermal State
    // ========================================================

    var temperatureC =
        QRTLConstants.ambientTemperatureC

    var heatGenerationW: Double = 0.0

    var heatFluxWm2: Double = 0.0

    // ========================================================
    // Mechanical State
    // ========================================================

    var strain: Double = 0.0

    var stressPa: Double = 0.0

    // ========================================================
    // Resonator State
    // ========================================================

    var resonanceAmplitudeM: Double = 0.0

    var resonancePhaseRad: Double = 0.0

    var resonatorEnergyJ: Double = 0.0

    var resonatorLossW: Double = 0.0

    var piezoPowerW: Double = 0.0

    // ========================================================
    // Aging / Energy
    // ========================================================

    var degradation: Double = 0.0

    var chargeEnergyJ: Double = 0.0

    // ========================================================
    // State
    // ========================================================

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


// ============================================================
// MARK: - Transport Helpers
// ============================================================

@inline(__always)
func transportFactor(
    _ c: QRTLCAChargeCell
) -> Double {

    max(
        c.porosity,
        0.05
    ) /
    max(
        c.tortuosity,
        1.0
    )
}


@inline(__always)
func effectiveDiffusivity(
    _ c: QRTLCAChargeCell
) -> Double {

    QRTLConstants.lithiumDiffusivityM2s /
    max(
        c.tortuosity,
        1.0
    ) *
    c.porosity *
    QRTLConstants.sulfurDiffusivityScale
}


// ============================================================
// MARK: - Design Result
// ============================================================

struct QRTLDesignResult {

    // ========================================================
    // Cell / Pack Capacity
    // ========================================================

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

    // ========================================================
    // Electrical
    // ========================================================

    var totalResistanceOhm = 0.0

    var ohmicLossW = 0.0

    var reactionLossW = 0.0

    // Signed reversible heat.
    // Negative = endothermic during charging.

    var entropicHeatW = 0.0

    var resonatorLossW = 0.0

    // Heat rejected to coolant.

    var thermalLossW = 0.0

    // Irreversible losses only.

    var totalLossW = 0.0

    var efficiency = 0.0

    var modeledChargePowerW = 0.0

    var powerCapabilityW = 0.0

    var chargeTimeHours = 0.0

    // ========================================================
    // Thermal / Geometry
    // ========================================================

    var maxTemperatureC = 0.0

    var tpmsSurfaceAreaM2 = 0.0

    var tpmsPorosity = 0.0
    var  tpmsSolidFraction = 0.25

    var tpmsRelativeDensity = 0.0

    // ========================================================
    // Electrochemical Metrics
    // ========================================================

    var averageSOC = 0.0

    var sulfurUtilization = 0.0

    var averageOverpotentialV = 0.0

    var averageImpedanceOhm = 0.0

    // ========================================================
    // Resonator / Mechanics
    // ========================================================

    var averageResonanceAmplitudeM = 0.0

    var maximumStressMPa = 0.0

    // ========================================================
    // Aging
    // ========================================================

    var degradationFraction = 0.0

    // ========================================================
    // Constraint Results
    // ========================================================

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
