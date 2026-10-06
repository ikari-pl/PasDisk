import Foundation
let f = ByteCountFormatter()
f.countStyle = .file
f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
let d = ByteCountFormatter()
d.countStyle = .decimal
d.allowsNonnumericFormatting = false
d.zeroPadsFractionDigits = false
d.allowedUnits = [.useGB, .useTB]
var vals: [Int64] = [1_100_000_000, 1_200_000_000_000, 10_000_000_000, 100_000_000_000, 120_000_000, 1_150_000, 100_000, 199_999_999, 1_995_000_000, 2_000_000_000_000_000, 9_223_372_036_854_775_807, -5, 0,1,2,999,1000,1001,1499,1500,1501,2500,9_999,10_000,99_499,99_500,999_499,999_500,999_999,1_000_000,1_049_999,1_050_000,1_250_000,9_950_000,12_900_000,40_000_000,99_950_000,999_949_999,999_950_000,1_000_000_000,1_004_999_999,1_005_000_000,1_234_567_890,12_345_678_901,999_994_999_999,999_995_000_000,1_000_000_000_000,2_550_000_000_000,999_999_999_999_999,1_500_000_000_000_000, 63_340_000_000, 863_020_000_000]
var g = SystemRandomNumberGenerator()
for e in 0..<16 { for _ in 0..<8 { let base = Int64(pow(10.0, Double(e))); vals.append(base + Int64.random(in: 0..<(base*9), using: &g)) } }
for v in vals { print("\(v)\t\(f.string(fromByteCount: v))\t\(d.string(fromByteCount: v))") }
