# 拼忆 T14 中文文案 v1.1

> 语气：温暖、简洁、口语化，不夸大。全部处理均在设备本地完成。  
> 界面正文不出现「云端」「上传分析」「智能上云」；也不出现「iCloud」。唯一例外：引导用户去系统设置时，引用系统里的原话（如 设置 > 照片 >「下载并保留原件」）。  
> 适用：MVP / 首个 TestFlight，仅简体中文，中国区。  
> 依据：产品决定 v0.3 定稿（2026-11-16，已与架构师对齐）、文案 v1、技术方案 v0.1。  
> 每条用户可见文案附稳定 key，供开发与 QA 引用。占位符用 `{name}`。

---

## v1 → v1.1 变更记录（对应 QA 测试计划 §7）

1. **受限访问入口**：主按钮由「去设置」改为 App 内「选择更多照片」（`presentLimitedLibraryPicker`）；次按钮仍为「用已选的照片继续」；新增文字链接「改为允许访问全部照片」跳系统设置。素材来源页在受限状态下常驻「增加可用照片」。保留 `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES`。
2. **素材不足**：取消「少于 100 张」独立提示。统一阈值 200 张、只保留一条：生成前「照片比较少，会重复使用一些，效果可能不理想」（不阻止生成）；可用照片少于 200 张且算法实际放宽约束时，结果页用短句「有些照片重复用了几次」（素材充足仅因颜色集中而放宽时不显示）。可用为 0 走空状态（见第 16 条）。
3. **相簿**：MVP 改为单选，文案改为「只用一个相簿」；不做多选。
4. **「换一个」进入 MVP**：预览页新增按钮「换一种拼法」（只换随机种子），与「再调一调」并列。
5. **切后台与被杀**：补齐扫描/生成/导出文案。扫描被杀后下次打开显示「接着上次继续扫描」；生成自动重跑失败显示「刚才没拼完，再试一次」；导出被打断显示「导出被打断了，导出时请停留在这个页面」+「重新导出」。回到前台自动续扫或自动重生成时不提示；被杀后的导出临时文件静默清理、不提示。
6. **导出降级**：新增「有些照片还没下载到这台手机，导出后这些小块会稍模糊」。正文不再使用「iCloud」「云端」。
7. **`.restricted`**：与「已拒绝」共用同一套文案，不单列。
8. **来源列表标题**：完全访问为「全部照片」，受限访问为「已允许访问的照片」，后面都跟「N 张」。
9. **非 4:3 目标图**：按决定做正方形格子、短边向下取整后居中裁切、不拉伸、不补边、不对用户开放裁切。无新增用户可见文案。
10. **使用上限 / 邻域半径**：MVP 不向用户开放控件，删除相关界面文案。
11. **TF1 增量策略**：按结果可见性验收，无新增用户可见文案。
12. **导出尺寸**：用户可选仅 4000（默认）和 6000 两档，补齐叫法；8000 不对用户开放。
13. **「生成测试相簿」**：仍待 AndyL 拍板。TestFlight 说明改为：拍板前用真实相册按实际张数换算吞吐；「5 万张不闪退」可标未验证、不阻塞 TF1。
14. **颜色空间**：默认 OKLab，无用户可见文案。
15. **选目标图**：实现定为 SwiftUI `PhotosPicker`，沿用选图文案，无新交互句。
16. **空状态拆分**：资产数为 0 →「相册里还没有照片」；资产数 > 0 但本地可解码缩略图为 0 →「照片都还没下载到这台手机」。部分未下载但仍有可用照片不是空状态，扫描完成时提示「有些照片还没下载到这台手机，已跳过」。删除 v1 中带「iCloud」的跳过正文。
17. **保存失败**：拆成四个分支（预检空间不足、写入中空间不足、添加权限被拒、编码/其他），并明确优先级：权限 > 空间 > 其他。
18. **性能测试入口**：内部 TestFlight 默认在设置页显示「性能测试」；正式版隐藏，只保留「关于」页连点版本号 5 次进入。

另外（非 §7，但已按 v0.3 性能口径改）：渐进可用（扫到 2,000 张可开始拼，后台继续扫描）补进度文案；TestFlight 测试说明改为 iPhone 11、1 万张首次扫描 ≤ 90 秒。

---

## 1. 首启说明页

共 3 屏，可左右滑动；最后一屏为主操作。

### 第 1 屏：它能做什么

| key | 用途 | 文案 |
|---|---|---|
| `onboarding.1.title` | 标题 | 用你的照片，拼出一张新的回忆 |
| `onboarding.1.body` | 正文 | 选一张想拼出来的照片，拼忆会用相册里的照片当作小方块，在这台 iPhone 上拼成一幅马赛克图。 |
| `onboarding.1.next` | 按钮 | 下一步 |

### 第 2 屏：隐私承诺（核心信息）

| key | 用途 | 文案 |
|---|---|---|
| `onboarding.2.title` | 标题 | 照片不会离开这台手机 |
| `onboarding.2.body` | 正文 | 所有处理都在手机本地完成，照片不会上传。不需要账号，也不连接网络。 |
| `onboarding.2.next` | 按钮 | 下一步 |

### 第 3 屏：怎么开始

| key | 用途 | 文案 |
|---|---|---|
| `onboarding.3.title` | 标题 | 选一张目标图，再选用哪些照片来拼 |
| `onboarding.3.body` | 正文 | 可以用全部照片，也可以选几个相簿。宝宝相簿、旅行相簿都很适合。拼好后能放大，看清每一块都是哪张照片。 |
| `onboarding.3.start` | 按钮 | 开始使用 |
| `onboarding.3.allow` | 按钮（若即将弹出系统权限） | 允许访问照片 |

---

## 2. Info.plist 权限说明

请如实、简短，与产品行为一致。

| key | 用途 | 文案 |
|---|---|---|
| `plist.nsPhotoLibraryUsageDescription` | `NSPhotoLibraryUsageDescription` | 拼忆需要访问你的照片，才能用相册或相簿里的图片来拼马赛克。所有处理都在这台 iPhone 上完成，照片不会上传。 |
| `plist.nsPhotoLibraryAddUsageDescription` | `NSPhotoLibraryAddUsageDescription` | 拼忆需要把做好的马赛克图保存到你的相册。图片只保存在这台 iPhone 上，不会上传。 |

`PHPhotoLibraryPreventAutomaticLimitedAccessAlert` 设为 `YES`（无用户文案）。

---

## 3. 相册权限状态

`.restricted`（家长控制 / MDM）与「已拒绝」共用第 3.3 节全套文案，不单列、不作为退出项。

### 3.1 尚未请求（`.notDetermined`，可与首启第 3 屏衔接）

| key | 用途 | 文案 |
|---|---|---|
| `permission.undetermined.title` | 标题 | 需要访问照片才能开始 |
| `permission.undetermined.body` | 正文 | 拼忆要用你相册里的照片来拼图。我们只会在这台手机上处理，照片不会上传。 |
| `permission.undetermined.primary` | 主按钮 | 继续 |
| `permission.undetermined.secondary` | 次按钮 | 先看看说明 |

### 3.2 受限访问（`.limited`）

App 内为主：主按钮调用 `presentLimitedLibraryPicker`；文字链接跳转系统设置。

| key | 用途 | 文案 |
|---|---|---|
| `limited.title` | 标题 | 目前只能使用部分照片 |
| `limited.body` | 正文 | 现在只能用你选中的那些照片来拼图。想用某个相簿（比如宝宝相册），请先增加可用的照片。 |
| `limited.primary` | 主按钮 | 选择更多照片 |
| `limited.secondary` | 次按钮 | 用已选的照片继续 |
| `limited.allow_all_link` | 文字链接（跳系统设置） | 改为允许访问全部照片 |

若已选照片为 0，不走「用已选的照片继续」，改走空状态（见第 5 节）。可用照片不足 200 张时仍可继续，之后在生成前给出素材不足提示。

### 3.3 已拒绝或无法访问（`.denied` / `.restricted`）

| key | 用途 | 文案 |
|---|---|---|
| `permission.denied.title` | 标题 | 没有相册权限，没法开始拼图 |
| `permission.denied.body` | 正文 | 请到系统设置里打开「拼忆」的照片权限。我们只会在这台手机上使用这些照片，不会上传。 |
| `permission.denied.primary` | 主按钮 | 去设置 |
| `permission.denied.secondary` | 次按钮 | 以后再说 |

---

## 4. 主流程界面文案

### 4.1 选择目标图

实现：SwiftUI `PhotosPicker`（iOS 16+）。选目标图不单独再要一次相册权限。

| key | 用途 | 文案 |
|---|---|---|
| `home.nav_title` | 首页两个入口的导航标题 | 开始拼图 |
| `home.photo_entry` | 首页，拼成一张照片 | 拼成一张照片 |
| `target.nav_title` | 导航标题，只在照片模式 | 目标照片 |
| `target.prompt` | 引导语，只在照片模式 | 想把哪张目标照片拼出来？ |
| `target.choose` | 按钮，只在照片模式 | 选择目标照片 |
| `target.replace` | 已选后的操作，只在照片模式 | 更换目标照片 |
| `target.next` | 下一步 | 下一步 |
| `target.unreadable` | 无法读取 | 这张照片打不开，请换一张再试。 |

### 4.2 选择素材来源

MVP 相簿为**单选**。列表只展示含至少 1 张已授权照片的相簿，空相簿隐藏。

| key | 用途 | 文案 |
|---|---|---|
| `source.nav_title` | 导航标题 | 用哪些素材照片来拼 |
| `source.list.all` | 完全访问时的来源标题 | 全部照片 |
| `source.list.allowed` | 受限访问时的来源标题 | 已允许访问的照片 |
| `source.list.count` | 张数（跟在标题后面；扫描完成后显示可用张数） | {count} 张 |
| `source.list.count_pending` | 张数（扫描未完成时显示资产总数，不随扫描跳动） | 约 {count} 张 |
| `source.list.title_format` | 组合格式（标题与张数同一行） | {title}  {count} 张 |
| `source.album.option` | 选项 | 选择相簿 |
| `source.album.option_desc` | 说明 | 可以选一个或几个相簿，比如宝宝和旅行。 |
| `source.album.list_title` | 相簿列表标题 | 选择相簿（可多选） |
| `source.album.item_count` | 相簿项副文案（规则同 `source.list.count` / `count_pending`） | {count} 张 |
| `source.album.unreadable` | 相簿列表里打不开的相簿：这一行置灰、不能勾时的副文案（§2f；00:15 起相簿不见了一律静默去掉，不再作为提示弹出） | 打不开这个相簿，请换一个，或改用全部照片。 |
| `source.add_photos` | 受限状态下常驻入口（同样调用系统选择器） | 增加可用照片 |
| `source.next` | 下一步 | 下一步 |
| `source.excluded_low_res` | 来源页 / 生成后提示：生成时剔除了手机上版本不够清楚的照片（copy v1.2 补充，hd-export-req-v0.2 F5） | 有 {count} 张照片手机上的版本不够清楚，没有用上 |

「全部照片 / 已允许访问的照片」选项下，可用张数用 `source.list.count` 显示，例如「全部照片  1,234 张」「已允许访问的照片  180 张」。  
`source.list.all` 的说明不必再写「已下载到这台手机」：未下载的照片按第 5 节处理，不在标题里暗示。

### 4.3 密度（三档）

格子为正方形。长边按档位分成 40 / 80 / 120 格；短边格数向下取整，余量居中裁掉，不拉伸、不补边。不对用户开放裁切。界面只保留密度三档。

| key | 用途 | 文案 |
|---|---|---|
| `density.section` | 区域标题 | 拼图密度 |
| `density.coarse` | 粗 | 粗 |
| `density.coarse.desc` | 说明 | 方块更大，更容易看清每一张照片。 |
| `density.medium` | 中（默认） | 中 |
| `density.medium.desc` | 说明 | 在细节和每张照片的清晰度之间比较平衡。 |
| `density.fine` | 细 | 细 |
| `density.fine.desc` | 说明 | 更接近原图，单张照片会更小。 |

使用上限、邻域半径不向用户开放，无控件文案。

### 4.3b 预设形状（首版）

首页仍是「拼成一张照片」和「拼成一个图形」两个入口。图形配置里可以在预设和文字之间切换，不另做文字入口，也不另做向导。文字固定细档，没有密度和叠加，也不能存到我的作品。10 个形状 ID 与设计锁定表一致。

| key | 用途 | 文案 |
|---|---|---|
| `shape.entry` | 首页，拼成一个图形。不提未开放的文字 | 拼成一个图形 |
| `shape.summary` | 确认页和预览页的图形摘要 | 图形：{preset} · {palette} · {background} |
| `shape.stale_result` | 改了形状、文字、配色或密度但还没重新生成 | 这仍是按上次参数生成的结果。改了形状、文字、配色或密度后，要重新生成才能导出。 |
| `shape.export_note` | 图形预览，导出和存作品不是一件事 | 导出会写进系统相册，不会存到我的作品。 |
| `shape.section` | 确认页形状 | 形状 |
| `shape.palette.section` | 配色 | 颜色 |
| `shape.palette.auto` | 按相册 | 按相册 |
| `shape.palette.warmRed` | 暖红 | 暖红 |
| `shape.palette.pink` | 粉 | 粉 |
| `shape.palette.blue` | 蓝 | 蓝 |
| `shape.palette.gold` | 金 | 金 |
| `shape.background.section` | 背景 | 背景 |
| `shape.background.white` | 白 | 白 |
| `shape.background.black` | 黑 | 黑 |
| `shape.kind.preset` | 图形配置里选预设 | 预设 |
| `shape.kind.text` | 图形配置里选文字 | 文字 |
| `shape.text.line1` | 第一行 | 第一行 |
| `shape.text.line2` | 第二行 | 第二行 |
| `shape.text.unsupported` | 输入了汉字、字母、数字以外的字符 | 只能输入汉字、英文字母和数字。 |
| `shape.text.too_long` | 一行超过 4 个汉字的量 | 这一行太长了。汉字最多 4 个，英文和数字大约 8 个。 |
| `shape.text.too_many_lines` | 超过两行 | 最多两行。 |
| `shape.text.second_kept` | 第一行换行粘贴会盖掉第二行已有正文，整次不改 | 第二行已经有文字，没有改掉它。 |
| `shape.text.empty` | 空正文不能开始拼图 | 先输入文字，才能开始拼图。 |
| `shape.text.unreadable` | 合法文字排不开或不达 24 格 | 这组文字没法按当前大小排开，请换一组文字。 |
| `shape.text.summary` | 确认页和预览页的文字摘要 | 文字：{text} · {palette} · {background} |
| `shape.preset.heart` | 爱心 | 爱心 |
| `shape.preset.star` | 星星 | 星星 |
| `shape.preset.circle` | 圆形 | 圆形 |
| `shape.preset.birthdayCake` | 生日蛋糕 | 生日蛋糕 |
| `shape.preset.flower` | 花朵 | 花朵 |
| `shape.preset.moon` | 月亮 | 月亮 |
| `shape.preset.fourLeafClover` | 四叶草 | 四叶草 |
| `shape.preset.house` | 小房子 | 小房子 |
| `shape.preset.speechBubble` | 对话框 | 对话框 |
| `shape.preset.roundedSquare` | 圆角方块 | 圆角方块 |

### 4.4 原图叠加强度

| key | 用途 | 文案 |
|---|---|---|
| `overlay.section` | 区域标题 | 原图叠加 |
| `overlay.left` | 滑杆左侧 | 更能看清照片 |
| `overlay.right` | 滑杆右侧 | 更像原图 |
| `overlay.hint` | 辅助说明 | 往右拖，会更像目标图；往左拖，更容易认出每一块是哪张照片。 |

### 4.5 生成前

所选来源可用照片 ≥ 1 且 < 200 时，先弹出素材不足提示，不阻止生成。可用为 0 走空状态，不走这条。

| key | 用途 | 文案 |
|---|---|---|
| `generate.cta` | 主按钮 | 开始拼图 |
| `generate.privacy_hint` | 生成前一行小字（可选） | 处理都在本地完成，照片不会上传。 |
| `shortage.pregenerate` | 生成前提示（唯一长句） | 照片比较少，会重复使用一些，效果可能不理想 |
| `shortage.pregenerate.continue` | 主按钮 | 继续拼图 |
| `shortage.pregenerate.back` | 次按钮 | 返回调整 |

### 4.6 扫描进度（可取消；渐进可用）

扫描到 2,000 张即可开始拼图，其余继续在后台整理。来源总数不足 2,000 时，不显示渐进可用句，等本次扫描结束后再开始。

回到前台自动续扫时不提示。被系统杀掉后，下次打开自动从断点继续，进度页用 `scan.resume`。

| key | 用途 | 文案 |
|---|---|---|
| `scan.title` | 标题 | 正在整理照片 |
| `scan.resume` | 被杀后再次打开的进度页标题/状态 | 接着上次继续扫描 |
| `scan.progress` | 进度 | 已处理 {done} / {total} 张 |
| `scan.first_time_hint` | 状态补充（可选，首次） | 第一次可能会久一点，之后会快很多。 |
| `scan.progressive.ready` | 达到 2,000 张后的状态 | 已就绪 {ready} 张，可以开始拼图 |
| `scan.progressive.hint` | 补充 | 其余照片还在继续整理。 |
| `scan.progressive.cta` | 此时的主按钮 | 开始拼图 |
| `scan.cancel` | 按钮 | 取消 |
| `scan.cancel_confirm.title` | 取消确认标题 | 要停止整理吗？ |
| `scan.cancel_confirm.body` | 取消确认正文 | 已经处理过的部分会保留，下次可以接着用。 |
| `scan.cancel_confirm.stop` | 确认 | 停止 |
| `scan.cancel_confirm.continue` | 返回 | 继续整理 |
| `scan.skipped_undownloaded` | 扫描完成且部分未下载、但仍有可用照片 | 有些照片还没下载到这台手机，已跳过 |

`scan.skipped_undownloaded` 不是空状态，用轻提示即可（如扫描结束或进入设置页时显示一次）。不要写「iCloud」或「云端」。

### 4.7 生成中

切到后台被挂起时取消当前生成，回到前台用同一种子自动重跑，用户无感、不提示。若自动重跑也失败，回到生成前的设置页，使用下面这句。

| key | 用途 | 文案 |
|---|---|---|
| `generate.progress.title` | 标题 | 正在拼图 |
| `generate.progress.body` | 正文 | 请稍等，马上就好。手机可能会有些发热，这是正常的。 |
| `generate.progress.cancel` | 按钮 | 取消 |
| `generate.progress.checking` | 生成进度：检查照片清晰度期间的正文（copy v1.2 补充） | 正在挑选清楚的照片… |
| `generate.cancel_confirm.title` | 取消确认标题 | 要取消这次拼图吗？ |
| `generate.cancel_confirm.confirm` | 确认 | 取消拼图 |
| `generate.cancel_confirm.continue` | 返回 | 继续等待 |
| `generate.auto_retry_failed` | 自动重跑失败后的提示 | 刚才没拼完，再试一次 |
| `generate.auto_retry_failed.retry` | 主按钮 | 再试一次 |
| `generate.failed.title` | 其他生成失败标题 | 这次没能完成 |
| `generate.failed.body` | 正文 | 拼图没有成功，可能是照片读取出了问题，或这台手机暂时内存不足。可以稍后再试，或先改成「粗」密度。 |
| `generate.failed.retry` | 主按钮 | 再试一次 |
| `generate.failed.back` | 次按钮 | 返回调整 |

失败文案不归因为网络，不出现「连接网络重试」。

### 4.8 预览 / 结果页

「换一种拼法」只换随机种子，密度、叠加、目标图和素材来源不变，然后重新生成。「再调一调」返回密度和叠加设置，不重新选图。

结果页显示短句 `shortage.result` 必须**同时**满足两个条件：① 可用照片少于 200 张；② 匹配器实际放宽了约束（relaxedConstraints 为真）。只满足 ② 时（素材充足但颜色集中，如整张蓝天）**不显示**。满足条件时，即使生成前已经提示过，也再显示一次。

| key | 用途 | 文案 |
|---|---|---|
| `preview.nav_title` | 导航标题 | 预览 |
| `preview.hint` | 提示 | 双指放大，看看每一块都是哪张照片。 |
| `preview.save` | 按钮 | 保存到相册 |
| `preview.share` | 按钮 | 分享 |
| `preview.export` | 结果页导出按钮（hd-export-req v0.2 §B2，key 待产品确认） | 导出 |
| `preview.adjust` | 按钮 | 再调一调 |
| `preview.reshuffle` | 按钮 | 换一种拼法 |
| `shortage.result` | 结果页短提示（仅当可用照片 < 200 张且匹配器实际放宽了约束时显示） | 有些照片重复用了几次 |

### 4.9 导出尺寸（用户仅两档）

8000 不对用户开放，只出现在内部性能测试的导出基准里。

| key | 用途 | 文案 |
|---|---|---|
| `export.size.section` | 区域标题 | 导出尺寸 |
| `export.size.share` | 分享档名称（hd-export-req v0.2 §A3；原 4000 / 6000 作废） | 分享 |
| `export.size.share.desc` | 说明 | 长边约 4000 像素，适合发微信。 |
| `export.size.hd` | 高清档名称 | 高清 |
| `export.size.hd.desc` | 说明（v0.2 原文带「（默认）」，§F 默认改为超清，已移到超清，待产品确认） | 放大能看清每张小照片。 |
| `export.size.uhd` | 超清档名称（默认） | 超清 |
| `export.size.uhd.desc` | 说明（copy v1.2 补充） | 放大看得最清楚。（默认） |
| `export.size.large_hint` | 档位下方固定提示（v0.2 §F1-2 只给文字，key 待产品确认） | 文件较大，导出需要一会儿 |
| `export.degraded` | 部分原图未在本地、导出时块被降级 | 有些照片还没下载到这台手机，导出后这些小块会稍模糊 |
| `export.progress.title` | 导出中标题 | 正在导出 |
| `export.progress.hint` | 导出中提示 | 导出时请停留在这个页面。 |
| `export.interrupted` | 导出被后台宽限打断、回到前台 | 导出被打断了，导出时请停留在这个页面 |
| `export.retry` | 按钮 | 重新导出 |

被系统杀掉后，下次启动静默清理临时文件，不提示。

### 4.10 保存成功与分享

| key | 用途 | 文案 |
|---|---|---|
| `save.success.title` | 标题 | 已保存到相册 |
| `save.success.body` | 正文 | 可以在系统相册里找到这张图，也可以再分享给家人。 |
| `save.success.done` | 主按钮 | 完成 |
| `save.success.share` | 次按钮 | 分享 |
| `share.sheet_title` | 系统分享面板标题（如需） | 分享这张拼图 |
| `share.suggest_save` | 尚未保存、分享完成后的轻提示 | 也可以再保存到相册 |

---

## 5. 空状态和错误提示

### 5.1 相册里还没有照片

仅当当前来源**资产数为 0** 时使用（相册或所选范围为真的没有照片）。

| key | 用途 | 文案 |
|---|---|---|
| `empty.no_photos.title` | 标题 | 相册里还没有照片 |
| `empty.no_photos.body` | 正文 | 先去拍几张，拍好了再回来。 |
| `empty.no_photos.ok` | 按钮 | 我知道了 |

### 5.2 照片都还没下载到这台手机

资产数 > 0，但本地可解码缩略图为 0（全部尚未下载到这台手机）。这是独立空状态，不是 5.1，也不是扫描完成时的跳过提示。

正文中的「设置 > 照片」「下载并保留原件」是在引用系统设置里的原话，属于用词例外。不要再自行加上「iCloud」或「云端」。

| key | 用途 | 文案 |
|---|---|---|
| `empty.not_downloaded.title` | 标题 | 照片都还没下载到这台手机 |
| `empty.not_downloaded.body` | 正文 | 可以在 设置 > 照片 里打开「下载并保留原件」，或先打开系统「照片」App 浏览一下。 |
| `empty.not_downloaded.retry` | 按钮 | 重新检查 |

### 5.3 保存失败（四个分支，判断优先级：权限 > 空间 > 其他）

写入前用可用磁盘空间 API 预检，需 ≥ 预计文件大小 × 3（含临时文件）；写入过程中磁盘写满与预检不足走同一条。PrivacyInfo 声明 E174.1。

| key | 用途 | 文案 |
|---|---|---|
| `save.disk_full.title` | 预检不足，或写入中磁盘写满 | 手机存储空间不足 |
| `save.disk_full.body` | 正文 | 这张拼图比较大，目前没有足够的空间来完成或保存。清理一些空间后再试试。 |
| `save.disk_full.ok` | 按钮 | 我知道了 |
| `save.add_denied.title` | 「添加照片」权限被拒 | 需要允许添加照片才能保存 |
| `save.add_denied.body` | 正文 | 也可以先用「分享」把这张图发出去。 |
| `save.add_denied.settings` | 主按钮 | 去设置 |
| `save.add_denied.share` | 次按钮 | 分享 |
| `save.failed` | 编码失败或其他错误 | 没能保存到相册，再试一次 |
| `save.failed.retry` | 主按钮 | 再试一次 |

### 5.4 其他简短提示

| key | 用途 | 文案 |
|---|---|---|
| `misc.scan_stopped` | 用户主动停止扫描 | 整理已停止。可以重新开始，或先用已经整理好的照片。 |

不提供「连接网络重试」。本 App 零网络，失败不归因为网络。

### 5.5 我的作品（⚠️ 待文案确认：取自 product/hd-export-req-v0.2 B 节，全栈先行补齐，正式文案以文案表更新为准）

| key | 用途 | 文案 |
|---|---|---|
| `works.entry` | 首页右上角入口 | 我的作品 |
| `works.nav_title` | 作品列表页标题 | 我的作品 |
| `works.empty` | 作品列表空状态 | 还没有作品，拼好的图可以存在这里 |
| `works.keep_hint` | 作品列表底部常驻提示 | 删除 App 后作品会一起删除，想长期保留请导出到相册 |
| `preview.save_to_works` | 结果页次按钮 | 存到我的作品 |
| `preview.saved_to_works` | 预览页「存到我的作品」按钮：当前结果已存且没有改动时，不可点（B10-5/6，22:45 统一用这个 key） | 已存到我的作品 |
| `works.save_failed` | 存作品失败（结果页） | 没能存到我的作品，请再试一次 |
| `works.export` | 作品查看页按钮 | 导出 |
| `works.delete` | 作品查看页按钮 | 删除 |
| `works.delete.confirm` | 删除二次确认 | 删除这张作品？相册里的照片不会受影响。 |
| `works.delete.confirm.ok` | 删除确认按钮 | 删除 |
| `works.missing` | 查看页：本次原照片用不了、又找不到合格相近照片、改填目标图这一格平均色的格数（按格计；只在本次发生时出一次；v1.8，取消 4b） | 有 {count} 格原来的照片现在用不了，这几格先用相近的颜色填上 |
| `works.replaced` | 查看页：本次原照片用不了、已换成本机相近照片的格数（4b；按格计；只在本次发生时出一次） | 有 {count} 格原来的照片现在用不了，已换成相近的照片 |
| `works.open_failed` | 作品读不出来 | 这张作品打不开了 |
| `works.delete_failed` | 删除失败 | 没能删除，请再试一次 |
| `works.update` | 存过的作品只改了叠加强度时的按钮（v1.5，不弹确认） | 更新这张作品 |
| `works.updated` | 更新成功轻提示，约 2 秒自动消失（v1.5） | 已更新这张作品 |
| `works.limited_placeholder` | 作品查看页：受限访问（不是「允许访问全部照片」）时不显示保存的预览，改显示占位和这句话（v1.7a，04:00） | 这张作品里有些照片拼忆现在看不到，允许访问全部照片后就能查看 |
| `works.limited_note.settings` | 作品查看页占位下的按钮，打开系统设置里拼忆的页面（v1.7 / v1.7a） | 去设置 |

- 作品列表长按菜单唯一一项复用 `works.delete`「删除」，红色破坏性样式，不新增 key（v1.5 22:40 改，原先的 works.menu.delete 作废）。点了沿用 `works.delete.confirm` 确认框，按钮用「删除」（红色）和「取消」。
- `works.missing` / `works.replaced` 都按「格」计数（同一张照片可能用在好几格），统一用「现在用不了」，不写「删掉」「隐藏」（v1.3）。`works.replaced` 是一次性提示，作品查看页、导出前、结果页共用这一条。
- 导出不再自动存（AndyL 22:20 定），不需要「已自动存到我的作品」一类的提示（v1.5）。
- 已存状态统一用已有的 `preview.saved_to_works`；v1.5 写过的 `works.saved` 作废，不新增（产品 22:45）。
- `works.missing` v1.8（16:10）：原「这几格会稍模糊」作废——取消 4b 后找不到相近照片的格子一律填目标色。计数（按格）和只提示一次的规则不变。
- 受限访问时列表缩略图和查看页都不读保存的预览，列表显示灰色占位、查看页显示 `works.limited_placeholder` 和「去设置」（v1.7a，产品 04:00）。`works.limited_note`（v1.7「先用相近的颜色代替」）暂不使用，等现场渲染那版再启用，这里不收。

### 5.6 相簿多选（v1.4，20:55，同步自产品文案表）

| key | 用途 | 文案 |
|---|---|---|
| `source.selection.summary` | 相簿列表底部栏 | 已选 {n} 个相簿 · 共 {count} 张 |
| `source.selection.none` | 底部栏，未勾选 | 还没选相簿 |
| `source.selection.dedup_note` | 底部栏小字 | 同一张照片在几个相簿里只算一次 |
| `source.selection.summary_pending` | 底部栏，扫描未完成时 | 已选 {n} 个相簿 · 约 {count} 张 |
| `source.album.done` | 底部主按钮 | 完成 |
| `albums.limited_note` | 相簿列表顶部，只在受限访问时显示（00:15） | 只显示你允许拼忆访问的照片 |
| `source.counting` | 素材标签里的张数位置，相簿列表加载完之前（00:35） | 正在统计… |
| `quick.source.summary_two` | 确认页，2 个相簿 | 素材照片：{name1}、{name2} · {count} 张 |
| `quick.source.summary_many` | 确认页，3 个及以上 | 素材照片：{name1} 等 {n} 个相簿 · {count} 张 |

### 5.7 「再拼一张」（v1.4，21:20 定稿；quick-start-req-v1.0.md 22:58 定稿沿用，同步自产品文案表）

未保存提示的弹出规则以 hd-export-req-v0.2 B10-4 为准：当前结果没存进作品，或存过的作品改了叠加强度还没存，就弹；导出过不算存过。

| key | 用途 | 文案 |
|---|---|---|
| `quick.again` | 预览页、作品查看页的文字按钮 | 再拼一张 |
| `quick.source.summary` | 确认页，1 个相簿或全部照片 | 素材照片：{name} · {count} 张 |
| `quick.source.change` | 确认页 | 换素材照片 |
| `quick.unsaved.title` | 未保存确认弹窗 | 这张还没保存，要先存到我的作品吗？ |
| `quick.unsaved.save` | 弹窗按钮 | 保存 |
| `quick.unsaved.discard` | 弹窗按钮 | 不保存 |
| `quick.unsaved.cancel` | 弹窗按钮 | 取消 |
| `quick.unsaved.update_title` | 存过但叠加强度改了没存时的未保存提示标题（v1.5，B10-11；「保存」等于更新） | 叠加强度改了还没保存，要更新这张作品吗？ |

### 5.8 选图后读不出照片（v1.6，23:55，#18）

| key | 用途 | 文案 |
|---|---|---|
| `picker.unavailable` | 用系统选择器选了一张照片，经过共用过滤入口却取不到（隐藏、未授权、已删除、本机读不出来，这几种情况一律用这一句） | 这张照片现在用不了，换一张试试 |
| `picker.unavailable.change` | 按钮：重新打开选择器 | 换一张 |
| `picker.unavailable.add_access` | 按钮，只在受限访问（.limited）时显示，点了调用系统的「增加可用照片」 | 增加可用照片 |

- 另一个按钮复用 `common.cancel`「取消」：回到发起页，当前结果保留。
- 不区分原因，也不出现「隐藏」「授权」「删除」这些字眼。是否显示「增加可用照片」只看整个 App 的权限状态，不看这张照片的情况，所以用户无法从提示里推断某张照片是隐藏的。

---

## 6. 其他通用界面文案

| key | 用途 | 文案 |
|---|---|---|
| `app.display_name` | App 显示名 | 拼忆 |
| `app.store_subtitle` | 建议 App Store 副标题 | 照片马赛克 |
| `app.store_full_name` | 建议展示名 | 拼忆 - 照片马赛克 |
| `common.cancel` | 取消 | 取消 |
| `common.done` | 完成 | 完成 |
| `common.back` | 返回 | 返回 |
| `common.ok` | 确定 | 确定 |
| `common.close` | 关闭 | 关闭 |
| `common.retry` | 重试 | 再试一次 |
| `settings.title` | 设置页标题 | 设置 |
| `settings.performance` | 内部 TestFlight 设置页入口（编译开关控制；正式版隐藏） | 性能测试 |
| `settings.about` | 关于入口 | 关于拼忆 |
| `about.title` | 关于页标题 | 关于拼忆 |
| `diagnostics.export_note` | 诊断导出说明 | 仅包含技术诊断信息，不含照片。 |
| `about.body` | 关于正文 | 拼忆在这台 iPhone 上，用你自己的照片拼出一张新的马赛克图。所有处理都在本地完成，照片不会上传。 |
| `about.performance_hidden` | 正式版隐藏入口说明（不对用户展示；连点版本号 5 次进入性能测试） | （无文案，手势入口） |
| `privacy.entry` | 隐私说明入口 | 照片如何被使用 |
| `privacy.body` | 隐私说明正文 | 拼忆会读取你允许访问的照片，用于生成马赛克图，也可以在你同意后把成品保存到相册。照片不会上传，也不会用于分析或广告。 |

「性能测试」页的字段（机型、耗时、峰值内存、「复制结果」等）供内部基准使用，不作为给普通用户的产品文案；正式版不对用户露出该入口。

---

## 7. TestFlight 测试说明（给内测用户）

内部构建请从「设置 > 性能测试」进入计时页。正式版不会显示这个入口。

### `tf.welcome.title`：欢迎来测拼忆

`tf.welcome.body`：拼忆可以用相册里的照片，在手机本地拼出一张马赛克图。这次是内部测试版，请直接告诉我哪里不好用、哪里看不懂、哪里太慢。

### `tf.howto.title`：建议你这样测

`tf.howto.body`：

1. 第一次打开时，看看说明是否清楚，再按提示处理相册权限。
2. 选一张你熟悉的目标图（家人合影或宝宝照片都可以）。
3. 分别用「全部照片」（或受限下的「已允许访问的照片」）和「选择相簿」走一遍。相簿是单选。核心场景：只用「宝宝」或某个家庭相簿来拼。
4. 试一下粗、中、细三档，再拖一拖「原图叠加」滑杆，看看预览是否好懂。
5. 在预览里双指放大，确认能看清每一块是哪张照片；再点一次「换一种拼法」，看看是否只是换了一种排列。
6. 导出时试一下「标准」（4000，默认）和「更细」（6000），保存到相册，再用系统分享发出去（例如发给自己）。导出过程中请停留在当前页面。
7. 如果方便，再试：只允许访问部分照片（用「选择更多照片」「增加可用照片」，以及「改为允许访问全部照片」）、关掉权限再打开、选一个照片很少的相簿（不到 200 张）、相册里有还没下载到这台手机的照片、扫描或导出时把 App 切到后台。

### `tf.focus.title`：请重点反馈这些

`tf.focus.body`：

- 验收口径：在 iPhone 11 上，1 万张照片首次扫描是否在 90 秒内完成（清空缓存、完整权限、关闭低电量模式、不充电，以扫描页显示完成计时，建议跑 3 次看中位数；尚未下载到这台手机而被跳过的照片也计入张数）。iPhone 12 上 60 秒只作为参考，不是这次必须过的线。
- 扫到大约 2,000 张时，是否已经可以开始拼图，其余是否还在继续整理。
- 中档（「中」）生成在 iPhone 11 上是否大约 10 秒内完成；过程中会不会卡住、闪退，或明显发热、耗电。
- 文案有没有让人误会“会上传照片”，有没有出现「云端」或「iCloud」等字（引导去 设置 > 照片 时除外）。
- 照片比较少、权限受限、保存失败、导出被打断时，提示够不够清楚。
- 成品是否达到你期望的“远看是目标图，放大能认出自己的照片”。

### `tf.known.title`：已知问题（占位，发 TestFlight 前请替换为当时真实列表）

`tf.known.body`：

- （待补）大相册首次扫描的耗时和内存表现，仍在真机验证中。验收线是 iPhone 11、1 万张 ≤ 90 秒。
- （待补）尚未下载到这台手机的照片被跳过或导出变模糊时，提示是否足够明确，仍在观察。
- （待补）极少数目标图或相簿可能读取失败，请记下当时选的照片和操作步骤。
- 「5 万张不闪退」若当前相册达不到 5 万张，本轮可记为未验证，不阻塞这次发放。请按实际张数记录扫描吞吐（张/秒）。
- 当前为测试版，图标为占位设计，名称和商店文案可能还会微调。
- 本次测试不收费、没有水印；如遇到任何付费或登录提示，请立刻反馈，那不应出现。
- 「生成测试相簿」（在相册里写入「马赛克测试」）是否开放，还等确认；未开放前请用你现有的相册测。

### `tf.feedback.title`：怎么反馈

`tf.feedback.body`：请用 TestFlight 的“发送测试反馈”，或直接把截图和机型、系统版本发给我们。若做了性能测试，把「复制结果」一并发来。谢谢你愿意用自己的照片帮忙试。
