import Foundation

// MARK: - PRNG (Mulberry32, matches nuggets TypeScript for compatibility)

public struct Mulberry32: Sendable {
    private var state: Int32

    public init(seed: UInt32) {
        self.state = Int32(bitPattern: seed)
    }

    public mutating func next() -> Double {
        state = state &+ Int32(bitPattern: 0x6D2B_79F5)
        let u1 = UInt32(bitPattern: state) >> 15
        let xor1 = state ^ Int32(bitPattern: u1)
        var t = xor1 &* (1 | state)
        let u2 = UInt32(bitPattern: t) >> 7
        let xor2 = t ^ Int32(bitPattern: u2)
        t = (t &+ (xor2 &* (61 | t))) ^ t
        let u3 = UInt32(bitPattern: t) >> 14
        let final32 = UInt32(bitPattern: t ^ Int32(bitPattern: u3))
        return Double(final32) / 4_294_967_296.0
    }

    /// FNV-1a hash — uses all bytes of the string for better distribution
    public static func seed(from string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

// MARK: - Complex Vector

/// A complex vector stored as separate real and imaginary arrays.
/// Core data structure for Holographic Reduced Representations.
public struct ComplexVector: Sendable, Codable {
    public var re: [Double]
    public var im: [Double]

    public var dimension: Int { re.count }

    public init(dimension: Int) {
        re = [Double](repeating: 0, count: dimension)
        im = [Double](repeating: 0, count: dimension)
    }

    public init(re: [Double], im: [Double]) {
        precondition(re.count == im.count, "Real and imaginary arrays must have equal length")
        self.re = re
        self.im = im
    }

    /// Unit-phase vector from angles: each element is e^(iφ)
    public init(phases: [Double]) {
        re = phases.map { cos($0) }
        im = phases.map { sin($0) }
    }

    /// Generate a deterministic unit-phase vector from a string seed
    public static func random(for string: String, dimension: Int) -> ComplexVector {
        var rng = Mulberry32(seed: Mulberry32.seed(from: string))
        let twoPi = 2.0 * Double.pi
        let phases = (0..<dimension).map { _ in rng.next() * twoPi }
        return ComplexVector(phases: phases)
    }

    // MARK: - HRR Operations

    /// Binding: element-wise complex multiply (circular convolution in frequency domain)
    /// Fuses a key-value pair into one vector
    public func bind(with other: ComplexVector) -> ComplexVector {
        let d = dimension
        var result = ComplexVector(dimension: d)
        for i in 0..<d {
            result.re[i] = re[i] * other.re[i] - im[i] * other.im[i]
            result.im[i] = re[i] * other.im[i] + im[i] * other.re[i]
        }
        return result
    }

    /// Unbinding: multiply by conjugate (reverses binding)
    /// Given memory M and key K: unbind(M, K) recovers the bound value
    public func unbind(with key: ComplexVector) -> ComplexVector {
        let d = dimension
        var result = ComplexVector(dimension: d)
        for i in 0..<d {
            // conj(key) = (key.re, -key.im)
            result.re[i] = re[i] * key.re[i] + im[i] * key.im[i]
            result.im[i] = im[i] * key.re[i] - re[i] * key.im[i]
        }
        return result
    }

    /// Superposition: element-wise addition
    public func add(_ other: ComplexVector) -> ComplexVector {
        let d = dimension
        var result = ComplexVector(dimension: d)
        for i in 0..<d {
            result.re[i] = re[i] + other.re[i]
            result.im[i] = im[i] + other.im[i]
        }
        return result
    }

    /// Element-wise subtraction
    public func subtract(_ other: ComplexVector) -> ComplexVector {
        let d = dimension
        var result = ComplexVector(dimension: d)
        for i in 0..<d {
            result.re[i] = re[i] - other.re[i]
            result.im[i] = im[i] - other.im[i]
        }
        return result
    }

    /// Scalar multiply
    public func scale(by scalar: Double) -> ComplexVector {
        ComplexVector(re: re.map { $0 * scalar }, im: im.map { $0 * scalar })
    }

    /// L2 magnitude
    public func magnitude() -> Double {
        var sum = 0.0
        for i in 0..<dimension {
            sum += re[i] * re[i] + im[i] * im[i]
        }
        return sqrt(sum)
    }

    /// Normalize to unit length
    public func normalized() -> ComplexVector {
        let mag = magnitude()
        guard mag > 1e-12 else { return self }
        let inv = 1.0 / mag
        return scale(by: inv)
    }

    /// Cosine similarity between two complex vectors (treated as 2D real vectors)
    public func cosineSimilarity(with other: ComplexVector) -> Double {
        let d = dimension
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<d {
            dot += re[i] * other.re[i] + im[i] * other.im[i]
            normA += re[i] * re[i] + im[i] * im[i]
            normB += other.re[i] * other.re[i] + other.im[i] * other.im[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-12 else { return 0 }
        return dot / denom
    }

    /// Sharpening: contrast enhancement via magnitude-dependent scaling
    /// p > 1 increases contrast, p < 1 softens, p = 1 is identity
    public func sharpen(power p: Double) -> ComplexVector {
        guard p != 1.0 else { return self }
        let d = dimension
        var result = ComplexVector(dimension: d)
        let exp = p - 1.0
        for i in 0..<d {
            let mag = sqrt(re[i] * re[i] + im[i] * im[i])
            let scale = pow(mag + 1e-12, exp)
            result.re[i] = re[i] * scale
            result.im[i] = im[i] * scale
        }
        return result
    }

    /// Project back to unit-phase (each element → e^(iφ))
    public func toUnitPhase() -> ComplexVector {
        let d = dimension
        var result = ComplexVector(dimension: d)
        for i in 0..<d {
            let phase = atan2(im[i], re[i])
            result.re[i] = cos(phase)
            result.im[i] = sin(phase)
        }
        return result
    }
}
