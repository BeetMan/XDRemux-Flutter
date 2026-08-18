import Foundation

/// Portable IEEE-754 binary16 conversion for SDKs where Swift's Float16
/// overlay is unavailable to Swift 5 package targets.
public enum XDRemuxHalf {
    public static func encode(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xff)
        var mantissa = bits & 0x7f_ff_ff

        if exponent == 0xff {
            return sign | (mantissa == 0 ? 0x7c00 : 0x7e00)
        }

        var halfExponent = exponent - 127 + 15
        if halfExponent >= 31 {
            return sign | 0x7c00
        }
        if halfExponent <= 0 {
            if halfExponent < -10 { return sign }
            mantissa |= 0x80_00_00
            let shift = UInt32(14 - halfExponent)
            var halfMantissa = mantissa >> shift
            let remainder = mantissa & ((UInt32(1) << shift) - 1)
            let halfway = UInt32(1) << (shift - 1)
            if remainder > halfway ||
                (remainder == halfway && (halfMantissa & 1) != 0) {
                halfMantissa += 1
            }
            return sign | UInt16(halfMantissa)
        }

        var halfMantissa = mantissa >> 13
        if (mantissa & 0x1_000) != 0 {
            halfMantissa += 1
            if halfMantissa == 0x400 {
                halfMantissa = 0
                halfExponent += 1
                if halfExponent >= 31 { return sign | 0x7c00 }
            }
        }
        return sign | UInt16(halfExponent << 10) | UInt16(halfMantissa)
    }

    public static func decode(_ bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) == 0 ? 1 : -1
        let exponent = Int((bits >> 10) & 0x1f)
        let mantissa = Int(bits & 0x03ff)
        if exponent == 0x1f {
            return mantissa == 0 ? sign * Float.infinity : Float.nan
        }
        if exponent == 0 {
            return mantissa == 0
                ? sign * 0
                : sign * Float(mantissa) * powf(2, -24)
        }
        return sign * (1 + Float(mantissa) / 1024) * powf(2, Float(exponent - 15))
    }
}
