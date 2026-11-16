/// 不依赖 libm 的数学函数（评审 S3）。
///
/// glibc 与 Darwin 的 libm `cbrt` 可能相差 1 ulp。这里的 `cbrt` 只用 IEEE 754 基本运算
/// （加减乘除，Swift 默认不做 FMA 收缩），**这一个函数**在各平台上结果相同。
/// 但整条特征链路**不保证**跨平台逐位一致：sRGB 8 位 → 线性光的查找表（`SRGB.linearLUT`）仍在运行时用
/// libm `pow` 生成，glibc / Darwin 可能差 1 ulp。按评审 ca6a4ca 拍板 (6)：只要求**同平台**逐位确定，
/// 跨平台用容差比较（分配差异率 ≤ 2%、平均匹配距离相对差 ≤ 1e‑3、颜色转换 1e‑4）。
public enum PortableMath {
    /// 立方根（Double）：指数/尾数初值 + 3 次 Halley 迭代（三阶收敛），相对误差 < 1e-15。
    @inlinable
    public static func cbrt(_ x: Double) -> Double {
        if x == 0 || !x.isFinite { return x }
        let a = Swift.abs(x)
        // a = s · 2^e，s ∈ [1, 2)。取 e = 3q + r（r ∈ {0,1,2}），初值 2^q · c_r · (1 + (s − 1)/3)，相对误差 < 6%。
        let e = Int(a.exponent)
        let s = a.significand
        var q = e / 3
        var r = e - 3 * q
        if r < 0 { r += 3; q -= 1 }
        let cr: Double = r == 0 ? 1 : (r == 1 ? 1.2599210498948732 : 1.5874010519681994)
        var y = Double(sign: .plus, exponent: q, significand: 1) * cr * (1 + (s - 1) / 3)
        for _ in 0..<3 {
            let y3 = y * y * y
            y = y * (y3 + 2 * a) / (2 * y3 + a)
        }
        // 最后一步 Newton 修正舍入。
        y = y - (y * y * y - a) / (3 * y * y)
        return x < 0 ? -y : y
    }

    /// 立方根（Float，内部用 Double 计算后舍入）。
    @inlinable
    public static func cbrt(_ x: Float) -> Float { Float(cbrt(Double(x))) }
}
