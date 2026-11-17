# 设计 v0.1：形状 / 文字拼图（S1）

> 架构师 · 2026-11-16 · 对应需求 product/shape-mosaic-req-v1.0.md（AndyL 21:05 确认：形状外纯色留白 B）
> 基线：feat/internal-1116（9d1b058）。行号以该提交为准。

## 0. 总体路线
1. 形状或文字 → 归一化矢量路径 `ShapePath`（纯数据）。
2. 纯 Swift 扫描线光栅化，每格 8×8 采样，覆盖 ≥ 32/64 记为形状内 → `CellMask`。
3. 按格子生成合成目标图（形状内每格涂渐变色，形状外随便涂，反正不参与）。
4. 现有 `MosaicPipeline` 多一个 `activeCells` 参数：只给形状内格子配照片，形状外 tile = -1。
5. 预览、导出、作品把 -1 格子画成背景色（白 #FFFFFF / 黑 #000000）。叠加固定 0。

**和需求 §8 的一处出入**：S2 写的是「MosaicCore」。MosaicCore 只放引擎（S3 的 activeCells）；形状路径、光栅化、文字规则、配色放 **MosaicAppCore/Shape/**（纯 Swift，Linux 可测）；CoreText 取字形轮廓放 **App/Adapters**（只有它依赖 Apple 框架）。

## 1. 数据类型（MosaicAppCore/Shape/）
```swift
/// 归一化到 0…1 的路径（y 向下）。非零环绕规则。
public struct ShapePath: Codable, Sendable, Equatable {
    public enum Element: Codable, Sendable, Equatable {
        case move(Point), line(Point), quad(Point, Point), cubic(Point, Point, Point), close
    }
    public var elements: [Element]
    public var aspect: Double          // 外接框 宽/高
}
public enum ShapeSource: Codable, Sendable, Equatable {
    case preset(ShapePresetID)         // 10 个；rawValue 写进 manifest，定稿后不可改
    case text(lines: [String])         // 1–2 行，已过滤
}
public enum ShapePalette: String, Codable, Sendable { case auto, warmRed, pink, blue, gold }
public enum ShapeBackground: String, Codable, Sendable { case white, black }
public struct ShapeSpec: Codable, Sendable, Equatable {
    public var source: ShapeSource
    public var palette: ShapePalette
    public var background: ShapeBackground
}
```
- `PresetShapes.path(for:) -> ShapePath`：10 个形状用代码写贝塞尔，纯数据。设计约束：最细处 ≥ 外接框短边的 7%（粗档 40 格时约 2.8 格），避免断开；内部不留小于 10% 的孔。
- `ShapePresetID` 的 rawValue（v0.1.1 定稿，写进 manifest `source.preset`，也是文案 key `shape.preset.<id>` 的后缀；一旦有作品存盘就不能改，要有测试锁定）：`heart`、`star`、`circle`、`birthdayCake`、`flower`、`moon`、`fourLeafClover`、`house`、`speechBubble`、`roundedSquare`。解码到未登记的 preset 时报错，S5 把这个错误映射成「需要新版本打开」。
- `TextOutlineProviding`（协议，App 层实现 `CoreTextOutline`）：`func outline(lines: [String]) -> TextOutline?`，其中 `TextOutline { path: ShapePath, widthEm, heightEm }`（v0.1.1：多带 em 尺寸，用来校验「每字 ≥ 24 格」；`cellsPerEm` 按实际光栅化的缩放 `min(fitW / widthEm, fitH / heightEm)` 算，已扣掉边距）。
  - 字体：`UIFont.systemFont(ofSize: 100, weight: .heavy)`，中文由系统回退到苹方（最粗 Semibold），不指定字体名。
  - 用 CTLine 排版（自动回退字体），逐 glyph `CTFontCreatePathForGlyph`，转成 `ShapePath`；多行居中，行距 1.15 em。
  - 归一化后的路径就是形状的唯一事实来源；之后全部走同一个光栅化器。

## 2. 光栅化和 50% 判定（`PathRasterizer`）
- 输入 `ShapePath`、`columns × rows`；先把路径等比放进网格，四周留 1 格边距（预设和文字一样；v0.1.1 从 0.5 格改为 1 格，因为 0.5 格时形状最宽处的边格覆盖率正好 32/64 会被点亮，形状会贴到图边）。
- 贝塞尔按 0.05 格容差拆成线段；对 `rows × 8` 条采样扫描线（采样点 y = (j+0.5)/8 格）求与所有边的交点，按非零环绕填充区间；每条扫描线上 x 方向同样 8 个采样点/格，累计到 `coverage[cell]`（0…64）。
- 形状内 ⇔ coverage ≥ 32。复杂度 O(扫描线 × 边数)，120×120 格、几百条边 < 10 ms。
- 输出 `CellMask { columns, rows, bits: BitMask }`。
- 断笔保护：文字掩码生成后检查每个字的连通块数量，比字形轮廓的连通块多就提示（只记日志 + 测试断言，P0 不做自动修补；靠 §3 的格数下限保证）。

## 3. 网格、字数和密度联动（`ShapeLayoutRules`）
- 网格：`Layout.grid(width:height:density:)` 现有规则，长边 = 密度档列数（粗 40 / 中 80 / 细 120），短边按外接框比例（含边距）。合成目标图尺寸 = 列 × 16、行 × 16 px。
- 文字输入过滤：只允许汉字（Unicode Script=Han）、A–Z a–z、0–9；其余（emoji、标点、空格）在输入时丢弃并提示 `shape.text.unsupported`。
- 计数：汉字 1，字母数字 0.5；每行 ≤ 4，最多 2 行；空文字不可下一步。
- **文字模式固定细档（120 列），不显示密度选择**（需求 v1.0 定稿）。「520」「LOVE」也走细档。
  - 排版后校验：`cellsPerEm = 120 × 1em / max(外接框宽, 外接框高)`（含边距，单位 em），验收按 ≥ 24（目标 30）。
  - 预估：1–3 个汉字每行可到 30 左右；每行 4 个汉字约 27–28（宽约 4.3 em，两行时高约 51 格），满足 24。
  - 理论上被字数上限挡住，不会出现 < 24；万一出现（字体异常），提示 `shape.text.too_long`。
- 「再调一调」在文字模式下同样不显示密度。
- 形状（预设）模式三档都可用。

## 4. 合成目标图和配色（`ShapeTarget`、`ShapePaletteBuilder`）
- **按格子涂色，不按路径涂色**：形状内每格整块涂该格中心的渐变色；形状外涂背景色（不参与匹配）。这样边缘格子不会因为一半是背景而去配白色或黑色照片。
- 渐变方向：左上 → 右下，`t = (cx/W + cy/H) / 2`，在 OKLab 里线性插值。
- 固定配色（OKLab 插值，两端色）：
  | key | 起点 | 终点 |
  |---|---|---|
  | warmRed 暖红 | #B8403A | #E0774E |
  | pink 粉 | #D9809A | #F2B6C4 |
  | blue 蓝 | #3C6BAF | #86ACDA |
  | gold 金 | #B98A3A | #E6C478 |
  选值原则：饱和度比纯色低一档，照片的平均色很少能到高饱和；两端拉开明度，渐变看得出来。
- **按相册取色（auto）**：用快照里每张照片特征的 OKLab 均值。
  1. 「有彩照片」的定义：照片特征的 OKLab 均值色度 `sqrt(a² + b²) ≥ 0.03`，否则算近灰。去掉近灰照片后，按色相分 12 桶；
  2. 取照片数最多、且彼此相隔 ≥ 2 桶的 2–3 个桶，按色相排序；每桶取 L、a、b 中位数作为色标。一个桶的照片至少要占有彩照片的 10%，才能当色标（`minStopShare = 0.10`）；
     - 符合条件的桶只有 1 个时（单主色）：用这个桶自己做深浅渐变，a、b 取该桶中位数，两端 L 取该桶照片 L 值的 20% 和 80% 分位；两端明度差不到 0.1 时，以中点为中心往两边各拉开 0.1，并限制在 L 0.05–0.95 之间；
  3. `有彩张数 / 全部张数 < 0.30`（严格小于，30% 整走第 1、2 步）时，改成按明度的渐变：取全部照片 L 的 20% 和 80% 分位，a = b = 0 的中性色；
     - 没有可用颜色（快照为空等）：中性灰 L 0.45 → 0.80，不报错；
  4. 色标同种子无关，「换一种拼法」不变色。
- **素材不足检测（固定配色）**：某张照片均值到渐变上最近点的 OKLab 距离 ≤ 0.10 算「近色」。
  `近色张数 < max(50, ceil(形状内格数 / 单张上限))` 时出 `shape.color.shortage`，不拦截。单张上限用 `AssignmentConfiguration.cap.resolve` 同一套。auto 不做此检测，照常走 200 张门槛。

## 5. 引擎（MosaicCore，S3）
- 现有 `mask` 参数是「可用素材掩码」（Assignment.swift:374），**不要复用这个名字**。新增：
```swift
public struct CellMask: Sendable, Hashable { public let columns: Int; public let rows: Int; public let bits: BitMask }
// MosaicPipeline / GreedyAssigner 新增可选参数 activeCells: CellMask? = nil
```
- 规则：
  - `activeCells == nil` 行为与现在逐位一致（回归测试：同种子结果字节相同）。
  - 尺寸必须等于 pipeline 算出的网格，否则抛 `MosaicError.countMismatch`。调用方先调 `Layout.grid` 拿到网格再建掩码。
  - 取样照旧全格（便宜）；`makeOrder` 只产出形状内格子（seededRandom 先对全格 permutation 再过滤，保证同种子稳定）；TopK 只查形状内格子的特征。
  - 形状外 `tiles[i] = -1`，distance 0。邻域收集已经跳过 -1（Assignment.swift:734），不用改。
  - 单张上限按形状内格数解析：`cap.resolve(cellCount: activeCount, ...)`。
  - `AssignmentStatistics`、`MosaicGeneration.shouldShowShortageNotice`、`MaterialSupply` 都按形状内格数算。
  - `MosaicGeneration` 带上 `activeCells`，下游据此判断。
- `CellRefill`（作品里照片被删或被隐藏后换格子）：跳过 -1 格子；邻域判断同上。

## 6. App 层
- 流程状态：`MainFlow` 加 `mode: .photo | .shape(ShapeSpec)`。确认页、生成、预览、导出沿用；生成时：
  1. `ShapeSpec` → `ShapePath`（预设直接取；文字调 `TextOutlineProviding`）；
  2. `Layout.grid` → `PathRasterizer` → `CellMask`；
  3. `ShapePaletteBuilder` + `ShapeTarget` → PixelBuffer；
  4. `GenerationRunner` 透传 `activeCells`。
  这些步骤在 runner 之前、后台执行，都是毫秒级。
- 生成时把 `CellMask` 和 `ShapePath` 存在 `GenerationProduct` 里；「换一种拼法」复用，不重新排版。
- 「再调一调」改密度要重新排版和光栅化（新网格）；改配色只重做目标图；改背景色不用重新生成，只重画预览。
- 叠加：形状模式 `overlayAlpha` 固定 0，滑杆隐藏；不保存 target.heic。
- 预览 `MosaicPreviewRenderer` 和导出 `LiveMosaicExporter`：tile = -1 的格子填背景色。流式条带导出逐条填色，没有冲突。`ExportFillStats` 的糊格子/白格子只数形状内。
- 门槛：`GenerateGate` 的 200 张照旧（需求 §5-4）。
- 隐藏照片：快照来源不变，4.8 规则自动满足。

## 7. 我的作品和 manifest（S5）
- `MosaicLayout.formatVersion` 1 → 2；新增可选字段：
```json
{
  "formatVersion": 2,
  "mode": "shape",
  "shape": {
    "source": { "preset": "heart" }  /* 或 { "text": ["生日快乐", "宝贝"] } */,
    "color": "auto",   /* auto 或固定配色 key：warmRed / pink / blue / gold */
    "paletteStops": [[0.62, 0.12, 0.05], [0.70, 0.08, 0.10]],
    "background": "white",
    "mask": { "columns": 120, "rows": 104, "encoding": "bits-v1", "data": "<base64>" }
  },
  "cellAssignments": [ /* 长度 cols×rows；形状外为 null */ ]
}
```
- `bits-v1`：行优先，每格 1 bit，低位在前，按字节补齐。120×120 也只有约 1.8 KB。
- **再导出一致**：再导出只读 `cellAssignments` + `mask` + `background`，不重新排版文字，所以系统字体升级不会改变结果。P0 不存轮廓（`outline`）；P1 做平滑裁边时再加这个可选字段，解码对缺失字段兼容。
- 「再调一调」从作品进入时会用当前系统字体重新排版（这是一次新生成，可以接受）。
- **不需要数据迁移**：解码同时接受 1 和 2；缺 `mode` 视为 photo。新作品一律写 2。遇到更高版本：作品列表显示「这个作品需要新版本打开」，不崩溃。
- 作品缩略图：沿用导出缩略图逻辑，留白填背景色。5a/5b 换格子跳过 null。

## 8. 工作量（人天，开发项都含单元测试）
| 编号 | 内容 | 人天 |
|---|---|---|
| S1 | 本设计 | 0.5（已完成） |
| S2 | ShapePath + 光栅化 0.5；10 个预设路径 1；CoreText 轮廓 + 文字规则（固定细档）0.75；配色（auto + 4 固定）+ 合成目标图 + 不足检测 1 | 3.25 |
| S3 | 引擎 activeCells + 回归测试 1.5；预览和导出留白、叠加固定 0、统计 0.5 | 2 |
| S4 | 流程状态 0.75；选形状页、文字输入页（无密度选择）、配色和背景选择、确认页摘要 1.25 | 2 |
| S5 | manifest v2、作品保存和再导出、「再调一调」「再拼一张」 | 1 |
| S6 | 文案并入 copy 源文件 | 0.25 |
| S7 | QA 真机和端到端（单元测试已含在上面） | 1.5 |
| 合计 | | 10.25，**对外按 11**（0.75 作缓冲） |

需求里的 6.5 人天不是这个范围的数：我之前给过 4.5（形状外也铺照片，不改引擎）和 9（留白 + 两种填法、5–6 个形状）。现在是 10 个形状、文字联动、渐变 + 4 个固定配色，所以是约 11。
可砍：形状先做 5 个（省 0.5）；auto 配色先用固定的明度渐变、不做色相分桶（省 0.5）。

## 9. PR 拆分和并行
- PR①（S2 + S3）：MosaicCore 和 MosaicAppCore/Shape 新文件为主，可以现在就开始，和现有 PR 冲突很小（只碰 Assignment.swift、MosaicPipeline.swift）。
- PR②（S4 + S6）：碰 AppCoordinator、MainFlowView，和 PR #11、选图页 T5/T6、性能修复冲突，等它们合入后再开；可以先用假 `CellMask` 联调。
- PR③（S5）：等 PR #11（作品）合入。

## 10. 测试要点
- 光栅化：方块、圆、带孔字形（「口」「回」）的覆盖率和 50% 边界；同输入结果稳定。
- 文字规则：过滤 emoji、计数、四组验收文字在细档（120 列）下的每字格数（文字固定细档，以需求 1c 为准，不测三档）。
- 引擎：activeCells=nil 回归逐字节一致；形状外全 -1；邻域不重复；单张上限按形状内格数。
- 配色：auto 在偏灰相册里退化为明度渐变；不足检测阈值。
- manifest：v1 解码、v2 往返、未知版本不崩溃；再导出像素一致。
