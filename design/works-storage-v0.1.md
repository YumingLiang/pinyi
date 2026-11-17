# 作品保存在 App 内：存储方案 v0.1（架构师，2026-11-16）

## 结论
采用「布局 + 屏幕分辨率预览图 + 目标图副本」，导出时按需条带渲染高清图。**不只存种子**：匹配结果依赖索引版本、特征版本和参数，以后会变，所以每格分配必须显式存下来，重新打开时不再重跑匹配。

## 每个作品存的东西（Application Support/Works/<uuid>/）
- manifest.json：formatVersion、createdAt、网格（列数、行数、格子像素）、叠加强度、featureVersion、TuningDefaults 快照、seed（只用于追溯）
- layout.bin：去重后的照片 ID 表（localIdentifier + PHCloudIdentifier）+ 每格一个 UInt32 下标 + 裁剪参数（归一化裁剪框，当前都是居中正方形，也照样存下来），zlib 压缩。10 万格约 0.5–1 MB
- preview.heic：长边 2732（屏幕分辨率），约 1–2 MB，列表缩略图和查看放大都用它
- target.heic：目标图副本，长边 ≤ 4096，约 1–3 MB。叠加层是低频信息，放大采样够用；原目标图被删也照样能导出
- 单个作品合计约 3–6 MB。写入要原子（先写临时目录再 rename），列表扫描 manifest

## 原照片被删、拿不到时
- 导出前批量 fetch 一次，统计缺失数
- 缺失格子从 preview 裁出对应区域放大补上，不留空白；提示「N 张原照片已删除或不在本机，这些格子清晰度较低」（新 key `export.tiles.missing`）
- 只有 iCloud 版本的照片沿用 `export.fallback`，不下载
- 查看作品不受影响（看的是 preview）

## 重装、换机、过期
- 删除 App 会清空容器，作品跟着没了。删除确认弹窗和作品页都提示「需要长期保留请导出到相册」
- Works 目录**不排除** iCloud 备份（体积小，用户期望保留）；index 目录照旧排除
- 恢复到新手机后 localIdentifier 会变，用 PHCloudIdentifier 映射回来，映射失败的按缺失处理
- 免费签名 7 天过期：重新签名安装、Bundle ID 不变，数据就还在；换了 Bundle ID 数据就丢了

## 删除和空间
- 删除作品就删整个 uuid 目录，在设置页显示作品占用的总空间
- MVP 不设数量上限，以后再看

## 预计工作量
约 2 天：存储层 WorkStore 协议 + 文件实现、列表和查看页、导出时按 layout 渲染、缺失补齐、测试

## QA 用例口径
- 升级后重开旧作品：查看用的是保存的 preview，必须逐像素一致
- 高清导出按 layout 重渲染：缩到 preview 尺寸后和 preview 比较，允许插值和编码误差（建议 PSNR ≥ 35 dB），格子分配必须完全一致

## 后来被隐藏的照片：5d / 5e 增量检查（2026-11-16 23:10 补；23:20 按 AndyL 的选择改为完整版，便宜版作废）
需求见 quick-start-req-v1.0 §4.8 第 5d、5e 条，验收第 3a–3d 条。硬规则：受影响作品的旧缩略图和旧预览**任何时候都不能出现**，包括变更记录过期、走全量重查的时候。

### 共用部件：消失照片记录（GoneLog）
- 数据来源：iOS 16 的 `PHPhotoLibrary.fetchPersistentChanges(since:)`，把上次查到的 `PHPersistentChangeToken` 存进 Application Support/Works/gone-log.json（不放 index 目录，因为 index 不备份）
- 什么时候刷新：App 回到前台、收到 `PHPhotoLibraryChangeObserver` 通知、作品列表或结果页出现时。同一时间只跑一个刷新，后来的请求等这一个结果
- 处理：收集变更里的 deleted 和 updated 资产 ID；updated 的再用 PhotoFetch（`fetchAssets(withLocalIdentifiers:)`）查一遍，查不到的才算消失。把消失的 ID 作为新的一批追加进去，批号 `generation += 1`，再保存新 token
- 状态：`ready(generation)` 或 `refreshing`。启动后第一次刷新完成之前是 `refreshing`
- token 过期（`PHPhotosError.persistentChangeTokenExpired`）或第一次使用（没有 token）：进入 `fullRecheck`，所有作品的「已检查批号」视为无效，按下文全量重查，查完拿一个新 token
- 体积：只追加，超过 5000 条或 30 天时，把所有作品都已检查过的旧批次删掉

### 每个作品新增
- assets.ids：去重、排好序的 localIdentifier 列表（一行一个，zlib 压缩）。写 layout.bin 时一起原子写入，`applyRematch` 替换格子后也重写。旧作品没有这个文件的，第一次检查时从 layout.bin 生成
- manifest.json 新增 `checkedGoneGeneration: Int?`（旧作品没有就是 nil，按「未检查」处理）
- manifest.json 新增 `needsHiddenRefill: Bool`：已确认用到消失照片、但还没替换

### 缩略图显示规则（只有一条判断，放在 MosaicAppCore 里写纯函数和测试）
`canShowStoredThumbnail(work, log) = log 状态是 ready(g)，且 work.checkedGoneGeneration == g，且 !work.needsHiddenRefill`
- 满足：显示 preview 生成的缩略图
- 不满足：显示占位图（灰底加作品图标），**不读也不解码 preview.heic**，避免旧图进内存后被误画出来
- 所以 `refreshing`、`fullRecheck`、尚未检查的作品，都先显示占位图

### 5e 作品列表（完整版：检查、后台替换、完成后换图）
**检查**
- 每行出现时，如果不满足显示规则，就把这个作品交给后台检查（utility 优先级）：读 assets.ids，和 `checkedGoneGeneration` 之后各批的消失 ID 取交集
  - 没有交集：写回 `checkedGoneGeneration = g`，这一行换成真缩略图
  - 有交集：写 `needsHiddenRefill = true`，继续显示占位图，并放进替换队列
- 列表出现时，还要把所有 `needsHiddenRefill` 的作品放进队列，不只是可见的行，因为上次可能没处理完就退到后台了
- 全量重查（升级后首次，或变更记录过期）：对每个作品读 assets.ids，用 PhotoFetch 批量 fetch 一次，缺的 ID 就算消失，先查屏幕上可见的行。查完才把这个作品的批号更新成新的 g。估算每个作品 50–200 ms，100 个作品 5–20 秒，全程后台，期间没查完的作品都显示占位图
- 估算耗时：没有消失照片时只比批号，每行小于 1 ms；有消失照片时每个作品 2–5 ms（读约 400 KB、做一次集合交集）

**后台替换队列（HiddenRefillQueue，一个 actor）**
- 一次只处理一个作品（替换要取图、重画，比较占内存；串行就够，不用并行）。可见行的作品排在前面，其余按列表顺序
- 每个作品走现有的 5a 流程：`worksRematchSnapshot`，然后 `applyRematch`（替换格子、重写 layout.bin 和 assets.ids），再重画 preview.heic 和缩略图
- 重画 preview 只重画被替换的格子：用旧 preview 做底，把新照片画到对应格子的位置，再编码。这样不用为整张图重新取一万张缩略图，估算每个作品几百毫秒
- 全部写完后，原子地把 `needsHiddenRefill = false` 和 `checkedGoneGeneration = g` 写进 manifest，然后通知列表，这一行换成新缩略图（淡入，不要闪）
- App 进入后台：停止取新的任务；正在处理的作品用 `beginBackgroundTask` 争取做完，做不完就丢弃临时文件，标记不变，下次回到前台重新排队
- 失败（例如取不到替代照片）：其他原因缺图的格子沿用 4b 的规则；但**被隐藏照片的格子不能用旧 preview 兜底**（旧 preview 里就是隐藏照片的像素），也不留白，改为填纯色块，颜色取目标图在这一格的平均色（产品 23:25 定，需求 4.8 第 5e 条）。目标色来源：manifest 或 layout 里已存每格目标色就直接用；没有就从 target.heic 副本（5c 保留）按这一格的区域求平均。这些格子按格计数，提示 `works.missing`。高清导出遇到同样的格子也填同一个纯色，和 preview 一致
- 替换之后又有新的照片消失：处理完这一轮后检查 GoneLog 批号，变了就重新检查这个作品，必要时再排一次队

**并发保护**
- 所有写入经过 `FileWorksStore` 现有的按作品串行（`serialized(id:)`），替换队列、打开作品时的替换和 5d 保存都走同一个入口，同一个作品不会被两边同时改
- 写入用版本号做乐观检查：manifest 新增 `revision: Int`，每次写入加 1。队列开始处理时记下 revision，写回前发现 revision 变了（用户在此期间打开并替换了，或者删除、重新保存了），就放弃这次结果
- 用户打开一个正在队列里处理的作品：查看页等这个作品的替换完成（显示占位图和进度），不另起一次替换；不在处理中的就当场替换，并把它从队列里拿掉
- 用户删除一个正在处理的作品：队列发现目录没了，就丢弃结果，不报错
- 写文件仍然先写临时目录再 rename，中途被杀进程也不会留下半个作品；`removeIncomplete()` 启动时清理

### 5d 结果页
- 当前结果用到的照片 ID 集合已经在内存里。GoneLog 每产生新的一批，就和它取交集
- 有交集：按 5a 替换这些格子，作废底图和清晰层缓存（`PreviewDetailLayer` 清掉）并重画，显示一次 `works.replaced`
- 这个结果已经保存成作品的话，同时把那个作品标记 `needsHiddenRefill`；替换后再保存时清掉
- 导出照旧按 ID 经过 PhotoFetch 重新取图，不依赖 GoneLog

### 工作量（含单测）
共用 GoneLog、assets.ids 和显示规则 1.5 天；5d 0.5 天；5e 检查和标记 0.5 天；后台替换队列、只重画变化格子、完成后换图和并发保护 1.5 天。合计约 4 天，另加 QA 真机 0.5 天。依赖：#11（feat/works-hidden，含 5a 替换）先合进 feat/app-layer（开发都合进 feat/app-layer，不进 main；合不合由 AndyL 定）。注：5d 结果页的"保存时清掉标记"依赖 #17 的作品指纹，口径为格子分配 + cols/rows + targetCrop + seed，不含叠加强度，本方案不另定指纹

### QA 补充口径
- 杀掉 App，到「照片」里隐藏一张已存作品用到的照片，再冷启动打开列表：这一张从头到尾都不出现旧缩略图
- 模拟 token 过期（测试开关：清掉 gone-log.json 里的 token）：全量重查期间所有未查完的作品都显示占位图，查完后没受影响的作品恢复真缩略图
- 取消隐藏后：已替换的格子不改回去（5b）
- 隐藏照片后打开列表：受影响作品先占位，后台处理完自动换成新缩略图，新图里没有这张照片；其他作品不变；滚动不卡
- 后台处理中打开那个作品：不会出现旧预览，不会替换两次；处理中删除那个作品：不报错、不残留文件
- 处理中把 App 切到后台再回来：不留下半个作品，回来后继续处理完
