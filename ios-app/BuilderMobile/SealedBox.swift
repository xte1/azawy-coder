import Foundation
import CryptoKit

/// libsodium-compatible `crypto_box_seal`, required by the GitHub Actions secrets API.
/// (X25519 + HSalsa20 + XSalsa20-Poly1305, nonce = BLAKE2b-192(ephemeralPK || recipientPK)).
/// The algorithm was verified against libsodium for message sizes from 0 to 20 KB.
enum SealedBox {
    enum SealError: LocalizedError {
        case invalidKey
        var errorDescription: String? { "مفتاح GitHub العام غير صالح." }
    }

    static func seal(_ message: Data, recipientPublicKey: Data) throws -> Data {
        guard recipientPublicKey.count == 32 else { throw SealError.invalidKey }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPK = [UInt8](ephemeral.publicKey.rawRepresentation)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let shared: [UInt8] = secret.withUnsafeBytes { Array($0) }

        let key = hsalsa20(key: shared, nonce16: [UInt8](repeating: 0, count: 16))
        let nonce = blake2b(ephemeralPK + [UInt8](recipientPublicKey), outLength: 24)
        let box = secretBox(message: [UInt8](message), nonce24: nonce, key: key)
        return Data(ephemeralPK + box)
    }

    // MARK: Salsa20 family

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func putLE32(_ v: UInt32, into out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: v))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    private static func salsaState(key: [UInt8], nonce16: [UInt8]) -> [UInt32] {
        let c: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] // "expand 32-byte k"
        return [
            c[0], le32(key, 0), le32(key, 4), le32(key, 8),
            le32(key, 12), c[1], le32(nonce16, 0), le32(nonce16, 4),
            le32(nonce16, 8), le32(nonce16, 12), c[2], le32(key, 16),
            le32(key, 20), le32(key, 24), le32(key, 28), c[3]
        ]
    }

    private static func salsaRounds(_ x: inout [UInt32]) {
        for _ in 0..<10 {
            x[4] ^= rotl(x[0] &+ x[12], 7);  x[8] ^= rotl(x[4] &+ x[0], 9)
            x[12] ^= rotl(x[8] &+ x[4], 13); x[0] ^= rotl(x[12] &+ x[8], 18)
            x[9] ^= rotl(x[5] &+ x[1], 7);   x[13] ^= rotl(x[9] &+ x[5], 9)
            x[1] ^= rotl(x[13] &+ x[9], 13); x[5] ^= rotl(x[1] &+ x[13], 18)
            x[14] ^= rotl(x[10] &+ x[6], 7); x[2] ^= rotl(x[14] &+ x[10], 9)
            x[6] ^= rotl(x[2] &+ x[14], 13); x[10] ^= rotl(x[6] &+ x[2], 18)
            x[3] ^= rotl(x[15] &+ x[11], 7); x[7] ^= rotl(x[3] &+ x[15], 9)
            x[11] ^= rotl(x[7] &+ x[3], 13); x[15] ^= rotl(x[11] &+ x[7], 18)

            x[1] ^= rotl(x[0] &+ x[3], 7);   x[2] ^= rotl(x[1] &+ x[0], 9)
            x[3] ^= rotl(x[2] &+ x[1], 13);  x[0] ^= rotl(x[3] &+ x[2], 18)
            x[6] ^= rotl(x[5] &+ x[4], 7);   x[7] ^= rotl(x[6] &+ x[5], 9)
            x[4] ^= rotl(x[7] &+ x[6], 13);  x[5] ^= rotl(x[4] &+ x[7], 18)
            x[11] ^= rotl(x[10] &+ x[9], 7); x[8] ^= rotl(x[11] &+ x[10], 9)
            x[9] ^= rotl(x[8] &+ x[11], 13); x[10] ^= rotl(x[9] &+ x[8], 18)
            x[12] ^= rotl(x[15] &+ x[14], 7); x[13] ^= rotl(x[12] &+ x[15], 9)
            x[14] ^= rotl(x[13] &+ x[12], 13); x[15] ^= rotl(x[14] &+ x[13], 18)
        }
    }

    private static func hsalsa20(key: [UInt8], nonce16: [UInt8]) -> [UInt8] {
        var x = salsaState(key: key, nonce16: nonce16)
        salsaRounds(&x)
        var out: [UInt8] = []
        for i in [0, 5, 10, 15, 6, 7, 8, 9] { putLE32(x[i], into: &out) }
        return out
    }

    private static func salsa20Block(key: [UInt8], nonce8: [UInt8], counter: UInt64) -> [UInt8] {
        var n16 = nonce8
        for i in 0..<8 { n16.append(UInt8(truncatingIfNeeded: counter >> (8 * UInt64(i)))) }
        let start = salsaState(key: key, nonce16: n16)
        var x = start
        salsaRounds(&x)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for i in 0..<16 { putLE32(x[i] &+ start[i], into: &out) }
        return out
    }

    private static func secretBox(message: [UInt8], nonce24: [UInt8], key: [UInt8]) -> [UInt8] {
        let subKey = hsalsa20(key: key, nonce16: Array(nonce24[0..<16]))
        let nonce8 = Array(nonce24[16..<24])

        let block0 = salsa20Block(key: subKey, nonce8: nonce8, counter: 0)
        let polyKey = Array(block0[0..<32])
        var stream = Array(block0[32..<64])
        var counter: UInt64 = 1
        while stream.count < message.count {
            stream += salsa20Block(key: subKey, nonce8: nonce8, counter: counter)
            counter += 1
        }

        var cipher = [UInt8](repeating: 0, count: message.count)
        for i in 0..<message.count { cipher[i] = message[i] ^ stream[i] }
        return poly1305(key: polyKey, message: cipher) + cipher
    }

    // MARK: Poly1305 (26-bit limbs)

    private static func poly1305(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let r0 = UInt64(le32(key, 0)) & 0x3ffffff
        let r1 = (UInt64(le32(key, 3)) >> 2) & 0x3ffff03
        let r2 = (UInt64(le32(key, 6)) >> 4) & 0x3ffc0ff
        let r3 = (UInt64(le32(key, 9)) >> 6) & 0x3f03fff
        let r4 = (UInt64(le32(key, 12)) >> 8) & 0x00fffff
        let s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5

        var h0: UInt64 = 0, h1: UInt64 = 0, h2: UInt64 = 0, h3: UInt64 = 0, h4: UInt64 = 0
        var pos = 0
        while pos < message.count {
            var block = Array(message[pos..<min(pos + 16, message.count)])
            var hibit: UInt64 = 1 << 24
            if block.count < 16 {
                block.append(1)
                while block.count < 16 { block.append(0) }
                hibit = 0
            }
            pos += 16

            h0 += UInt64(le32(block, 0)) & 0x3ffffff
            h1 += (UInt64(le32(block, 3)) >> 2) & 0x3ffffff
            h2 += (UInt64(le32(block, 6)) >> 4) & 0x3ffffff
            h3 += (UInt64(le32(block, 9)) >> 6) & 0x3ffffff
            h4 += (UInt64(le32(block, 12)) >> 8) | hibit

            var d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0

            var c = d0 >> 26; h0 = d0 & 0x3ffffff
            d1 += c; c = d1 >> 26; h1 = d1 & 0x3ffffff
            d2 += c; c = d2 >> 26; h2 = d2 & 0x3ffffff
            d3 += c; c = d3 >> 26; h3 = d3 & 0x3ffffff
            d4 += c; c = d4 >> 26; h4 = d4 & 0x3ffffff
            h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff
            h1 += c
        }

        var c = h1 >> 26; h1 &= 0x3ffffff
        h2 += c; c = h2 >> 26; h2 &= 0x3ffffff
        h3 += c; c = h3 >> 26; h3 &= 0x3ffffff
        h4 += c; c = h4 >> 26; h4 &= 0x3ffffff
        h0 += c * 5; c = h0 >> 26; h0 &= 0x3ffffff
        h1 += c

        var g0 = h0 + 5; c = g0 >> 26; g0 &= 0x3ffffff
        var g1 = h1 + c; c = g1 >> 26; g1 &= 0x3ffffff
        var g2 = h2 + c; c = g2 >> 26; g2 &= 0x3ffffff
        var g3 = h3 + c; c = g3 >> 26; g3 &= 0x3ffffff
        var g4 = (h4 &+ c &- (UInt64(1) << 26)) & 0xffffffff

        let mask = ((g4 >> 31) &- 1) & 0xffffffff
        g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask
        let nmask = (~mask) & 0xffffffff
        h0 = (h0 & nmask) | g0
        h1 = (h1 & nmask) | g1
        h2 = (h2 & nmask) | g2
        h3 = (h3 & nmask) | g3
        h4 = (h4 & nmask) | g4

        let w0 = (h0 | (h1 << 26)) & 0xffffffff
        let w1 = ((h1 >> 6) | (h2 << 20)) & 0xffffffff
        let w2 = ((h2 >> 12) | (h3 << 14)) & 0xffffffff
        let w3 = ((h3 >> 18) | (h4 << 8)) & 0xffffffff

        var f = w0 + UInt64(le32(key, 16))
        var out: [UInt8] = []
        putLE32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w1 + UInt64(le32(key, 20)) + (f >> 32)
        putLE32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w2 + UInt64(le32(key, 24)) + (f >> 32)
        putLE32(UInt32(truncatingIfNeeded: f), into: &out)
        f = w3 + UInt64(le32(key, 28)) + (f >> 32)
        putLE32(UInt32(truncatingIfNeeded: f), into: &out)
        return out
    }

    // MARK: BLAKE2b (unkeyed)

    private static let blakeIV: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]

    private static let blakeSigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    private static func blakeCompress(_ h: [UInt64], block: [UInt8], t: UInt64, last: Bool) -> [UInt64] {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in 0..<8 { word |= UInt64(block[i * 8 + j]) << (8 * UInt64(j)) }
            m[i] = word
        }
        var v = h + blakeIV
        v[12] ^= t
        if last { v[14] = ~v[14] }

        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr64(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d];      v[b] = rotr64(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr64(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d];      v[b] = rotr64(v[b] ^ v[c], 63)
        }

        for round in 0..<12 {
            let s = blakeSigma[round % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        return (0..<8).map { h[$0] ^ v[$0] ^ v[$0 + 8] }
    }

    private static func blake2b(_ data: [UInt8], outLength: Int) -> [UInt8] {
        var h = blakeIV
        h[0] ^= 0x01010000 ^ UInt64(outLength)

        if data.isEmpty {
            h = blakeCompress(h, block: [UInt8](repeating: 0, count: 128), t: 0, last: true)
        } else {
            var pos = 0
            var t: UInt64 = 0
            while pos < data.count {
                let end = min(pos + 128, data.count)
                var block = Array(data[pos..<end])
                t += UInt64(block.count)
                let isLast = end >= data.count
                while block.count < 128 { block.append(0) }
                h = blakeCompress(h, block: block, t: t, last: isLast)
                pos = end
            }
        }

        var out: [UInt8] = []
        for word in h {
            for j in 0..<8 { out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt64(j)))) }
        }
        return Array(out[0..<outLength])
    }
}
