import Foundation
import Accelerate

/// 楼上蹦跳、敲墙等撞击声检测：20–250 Hz 带通 → Fast(125 ms) 时间计权 → 扣除自适应背景噪声底。
/// 只作为附加通道，不改动 A/C/Z 读数。所有量都是均方值（dBFS 域），由调用方加校准偏移。
final class ImpactDetector {
    static let band: (low: Double, high: Double) = (20, 250)
    /// IEC 61672-1 Fast 时间常数。
    static let fastTau = 0.125
    /// 背景噪声底向上跟随的速度（dB/s）：足够慢，持续蹦跳不会被当成背景吃掉；
    /// 环境整体变吵（如空调开启 +10 dB）约 20 秒后跟上。
    static let floorRiseDBPerSecond = 0.5
    /// 低于 -120 dBFS 视为数字静音，防止除零。
    private static let minMS = 1e-12

    struct Second {
        /// 本秒 Fast 最大值扣除背景后的残余均方值。
        let residualMS: Double
        /// 当前背景噪声底均方值。
        let floorMS: Double
        /// 本秒 Fast 最大值高出背景的 dB 数。
        let excessDB: Double
    }

    private let setup: vDSP_biquad_SetupD
    private var delay: [Double]
    private var filtered: [Double] = []
    private let k: Double
    private let warmupSamples: Int

    private var fastMS = 0.0
    private var processed = 0
    private var maxMS = 0.0
    private var minMS = Double.greatestFiniteMagnitude
    private var floorMS: Double?

    init(sampleRate fs: Double) {
        // 4 阶 Butterworth 高通 + 4 阶 Butterworth 低通，各由两节二阶段级联（Q = 0.5412 / 1.3066）。
        // 20 Hz / 48 kHz 的极点很贴近单位圆，用双精度避免 Float 滤波器的量化噪声。
        let qs = [0.5412, 1.3066]
        var coeffs: [Double] = []
        for q in qs { coeffs += Self.section(highPass: true, f0: Self.band.low, q: q, fs: fs) }
        for q in qs { coeffs += Self.section(highPass: false, f0: Self.band.high, q: q, fs: fs) }
        let sections = coeffs.count / 5
        setup = vDSP_biquad_CreateSetupD(coeffs, vDSP_Length(sections))!
        delay = [Double](repeating: 0, count: 2 * sections + 2)
        k = 1 - exp(-1 / (Self.fastTau * fs))
        // 滤波器与 Fast 积分器从零启动，前 0.5 秒（4τ）不计入最大/最小，避免首秒背景被估成静音。
        warmupSamples = Int(0.5 * fs)
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }

    /// RBJ Audio EQ Cookbook 二阶段，返回 vDSP 需要的 [b0, b1, b2, a1, a2]（已按 a0 归一）。
    private static func section(highPass: Bool, f0: Double, q: Double, fs: Double) -> [Double] {
        let w0 = 2 * Double.pi * f0 / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = (highPass ? (1 + cosw) : (1 - cosw)) / 2
        let b1 = highPass ? -(1 + cosw) : (1 - cosw)
        return [b0 / a0, b1 / a0, b0 / a0, -2 * cosw / a0, (1 - alpha) / a0]
    }

    func process(_ samples: [Float]) {
        let n = samples.count
        guard n > 0 else { return }
        var input = [Double](repeating: 0, count: n)
        vDSP_vspdp(samples, 1, &input, 1, vDSP_Length(n))
        if filtered.count < n { filtered = [Double](repeating: 0, count: n) }
        vDSP_biquadD(setup, &delay, input, 1, &filtered, 1, vDSP_Length(n))

        for i in 0..<n {
            let y = filtered[i]
            fastMS += k * (y * y - fastMS)
            processed += 1
            guard processed > warmupSamples else { continue }
            if fastMS > maxMS { maxMS = fastMS }
            if fastMS < minMS { minMS = fastMS }
        }
    }

    /// 结束一秒：用本秒最安静的 125 ms 更新背景噪声底，返回本秒结果；预热期内返回 nil。
    /// 背景只升不快：低于原底立即下调，高于原底每秒最多上调 floorRiseDBPerSecond。
    func finishSecond() -> Second? {
        defer {
            maxMS = 0
            minMS = .greatestFiniteMagnitude
        }
        guard maxMS > 0 else { return nil }
        let quietest = max(minMS, Self.minMS)
        let floor: Double
        if let prev = floorMS {
            floor = quietest < prev ? quietest : min(quietest, prev * pow(10, Self.floorRiseDBPerSecond / 10))
        } else {
            floor = quietest
        }
        floorMS = floor
        let peak = max(maxMS, floor)
        return Second(residualMS: peak - floor, floorMS: floor, excessDB: 10 * log10(peak / floor))
    }
}
