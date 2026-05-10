// SPDX-License-Identifier: GPL-3.0+

import Foundation
import UIKit

enum PresentationColor {
    static let uniformSliderMin: Float = -2
    static let uniformSliderMax: Float = 2
    static let uniformSliderDefault: Float = 0
    static let uniformSliderStep: Double = 0.05

    static func clampUniform(_ u: Float) -> Float {
        min(uniformSliderMax, max(uniformSliderMin, u))
    }

    private static func clampIni(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(hi, max(lo, v))
    }

    static func iniDisplayColorSaturation(fromUniform u: Float) -> Float {
        let t = clampUniform(u)
        return clampIni(1 + 0.5 * t, 0, 2)
    }

    static func uniformDisplayColorSaturation(fromIni ini: Float) -> Float {
        let b = clampIni(ini, 0, 2)
        return clampUniform(2 * (b - 1))
    }

    static func iniBrightness(fromUniform u: Float) -> Float {
        clampIni(clampUniform(u) * 0.25, -0.5, 0.5)
    }

    static func uniformBrightness(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, -0.5, 0.5) * 4)
    }

    static func iniContrast(fromUniform u: Float) -> Float {
        clampIni(1 + 0.25 * clampUniform(u), 0.5, 2)
    }

    static func uniformContrast(fromIni ini: Float) -> Float {
        clampUniform((clampIni(ini, 0.5, 2) - 1) / 0.25)
    }

    static func iniVibrance(fromUniform u: Float) -> Float {
        clampIni(clampUniform(u) * 0.5, -1, 1)
    }

    static func uniformVibrance(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, -1, 1) * 2)
    }

    static func iniExposure(fromUniform u: Float) -> Float {
        clampIni(clampUniform(u), -2, 2)
    }

    static func uniformExposure(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, -2, 2))
    }

    static func iniGamma(fromUniform u: Float) -> Float {
        let t = clampUniform(u)
        let g = t >= 0 ? 1 + 0.75 * t : 1 + 0.25 * t
        return clampIni(g, 0.5, 2.5)
    }

    static func uniformGamma(fromIni ini: Float) -> Float {
        let b = clampIni(ini, 0.5, 2.5)
        let u = b >= 1 ? (b - 1) / 0.75 : (b - 1) / 0.25
        return clampUniform(u)
    }

    static func iniColorTemperature(fromUniform u: Float) -> Float {
        clampIni(clampUniform(u) * 0.5, -1, 1)
    }

    static func uniformColorTemperature(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, -1, 1) * 2)
    }

    static func iniSharpness(fromUniform u: Float) -> Float {
        clampIni(max(0, clampUniform(u)), 0, 2)
    }

    static func uniformSharpness(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, 0, 2))
    }

    static func iniBloomIntensity(fromUniform u: Float) -> Float {
        clampIni(max(0, min(1, clampUniform(u) * 0.5)), 0, 1)
    }

    static func uniformBloomIntensity(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, 0, 1) * 2)
    }

    static func iniBloomRadius(fromUniform u: Float) -> Float {
        let t = clampUniform(u)
        let b: Float
        if t >= 0 {
            b = 3 + 2.5 * t
        } else {
            b = 3 + 1.375 * t
        }
        return clampIni(b, 0.25, 8)
    }

    static func uniformBloomRadius(fromIni ini: Float) -> Float {
        let b = clampIni(ini, 0.25, 8)
        let u = b >= 3 ? (b - 3) / 2.5 : (b - 3) / 1.375
        return clampUniform(u)
    }

    static func iniVignetteIntensity(fromUniform u: Float) -> Float {
        clampIni(max(0, min(1, clampUniform(u) * 0.5)), 0, 1)
    }

    static func uniformVignetteIntensity(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, 0, 1) * 2)
    }

    static func iniVignetteRadius(fromUniform u: Float) -> Float {
        let t = clampUniform(u)
        let b: Float
        if t >= 0 {
            b = 1 + 0.75 * t
        } else {
            b = 1 + 0.375 * t
        }
        return clampIni(b, 0.25, 2.5)
    }

    static func uniformVignetteRadius(fromIni ini: Float) -> Float {
        let b = clampIni(ini, 0.25, 2.5)
        let u = b >= 1 ? (b - 1) / 0.75 : (b - 1) / 0.375
        return clampUniform(u)
    }

    static func iniHdrExposure(fromUniform u: Float) -> Float {
        iniExposure(fromUniform: u)
    }

    static func uniformHdrExposure(fromIni ini: Float) -> Float {
        uniformExposure(fromIni: ini)
    }

    static func iniHdrSaturation(fromUniform u: Float) -> Float {
        clampIni(1 + 0.5 * clampUniform(u), 0, 2)
    }

    static func uniformHdrSaturation(fromIni ini: Float) -> Float {
        let b = clampIni(ini, 0, 2)
        return clampUniform(2 * (b - 1))
    }

    static func iniHdrContrast(fromUniform u: Float) -> Float {
        iniContrast(fromUniform: u)
    }

    static func uniformHdrContrast(fromIni ini: Float) -> Float {
        uniformContrast(fromIni: ini)
    }

    static func iniHdrBloom(fromUniform u: Float) -> Float {
        iniBloomIntensity(fromUniform: u)
    }

    static func uniformHdrBloom(fromIni ini: Float) -> Float {
        uniformBloomIntensity(fromIni: ini)
    }

    static func iniHdrShadowLift(fromUniform u: Float) -> Float {
        clampIni(max(0, min(0.5, clampUniform(u) * 0.25)), 0, 0.5)
    }

    static func uniformHdrShadowLift(fromIni ini: Float) -> Float {
        clampUniform(clampIni(ini, 0, 0.5) * 4)
    }

    static func iniHdrHighlightCompress(fromUniform u: Float) -> Float {
        iniBloomIntensity(fromUniform: u)
    }

    static func uniformHdrHighlightCompress(fromIni ini: Float) -> Float {
        uniformBloomIntensity(fromIni: ini)
    }

    static var extendedBrightnessHeadroomApprox: CGFloat {
        CGFloat(SakuraBridge.screenPotentialEDRHeadroomApprox())
    }

    static var extendedBrightnessAvailable: Bool {
        SakuraBridge.presentationHDRHeadroomLikelyAvailable()
    }
}
