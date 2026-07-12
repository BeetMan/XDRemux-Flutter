import Foundation

enum AppStrings {
    static let addHEIC = "添加 HEIC"
    static let addHEICHelp = "添加 HEIC 文件或文件夹"
    static let startConversion = "开始转换"
    static let cancel = "取消"
    static let conversionSettings = "转换设置"
    static let clearQueue = "清空队列"
    static let emptyQueueTitle = "拖入或添加 ProXDR HEIC 文件"
    static let queueNotImported = "未导入文件"
    static let retryFailed = "重试失败"
    static let removeCompleted = "移除已完成"
    static let revealOutputsInFinder = "在访达中显示输出"
    static let revealInputInFinder = "在访达中显示源文件"
    static let revealInFinder = "在访达中显示"
    static let remove = "移除"
    static let noSelection = "选择队列中的文件查看预览与输出计划"
    static let preview = "预览"
    static let previewLoading = "正在生成预览..."
    static let previewUnavailable = "预览不可用"
    static let inputPath = "源文件"
    static let outputPath = "输出文件"
    static let fileStatus = "文件状态"
    static let outputPlan = "输出计划"
    static let outputPlanReady = "准备写入"
    static let outputPlanOverwriteExisting = "将覆盖已有文件"
    static let outputPlanSkipExisting = "已有有效输出，将跳过"
    static let outputPlanDuplicate = "输出路径冲突"
    static let outputPlanInputMissing = "源文件不存在"
    static let outputPlanParentIsFile = "输出目录位置是文件"

    static let statConverted = "成功"
    static let statSkipped = "已跳过"
    static let statFailed = "失败"
    static let statCancelled = "已取消"
    static let statTotal = "总计"

    static let concurrentJobsSummary = "并发"
    static let pending = "待处理"
    static let running = "运行中"
    static let ready = "准备就绪"
    static let queueReady = "队列就绪"
    static let scanning = "正在扫描"
    static let converting = "正在转换"
    static let conversionFinished = "转换完成"
    static let conversionFinishedWithFailures = "转换完成，存在失败"
    static let waitingForInput = "等待输入"

    static let selectHEICPanelMessage = "选择要加入队列的 ProXDR HEIC 文件或文件夹"
    static let select = "选择"

    static let statusPending = "待处理"
    static let statusRunning = "运行中"
    static let statusConverted = "成功"
    static let statusSkippedExisting = "已跳过"
    static let statusFailed = "失败"
    static let statusCancelled = "已取消"

    static let inputHDRType = "输入 HDR 类型"
    static let inputHDRTypeHelp = "选择源文件的 HDR 数据布局。自动模式会根据文件内容选择 X6 或 X7 / UHDR 路径。"
    static let familyAuto = "自动识别"
    static let familyX6 = "X6 / LHDR"
    static let familyX7 = "X7 / UHDR"

    static let inputProcessing = "输入处理"
    static let inputProcessingHelp = "控制 base image 和 gain map 在转换过程中由系统重建、混合写回，还是尽量保留原始增益图。"
    static let inputProcessingSystem = "系统重建"
    static let inputProcessingSystemHelp = "让 ImageIO 接管 base image 和 gain map 的重打包过程；系统可能会重新编码图像数据。"
    static let inputProcessingSystemDecoded = "系统解码重建"
    static let inputProcessingSystemDecodedHelp = "先解码主图再由 ImageIO 重编码；仅用于 10-bit 主图兼容性诊断。"
    static let inputProcessingHybrid = "混合模式"
    static let inputProcessingHybridHelp = "先让系统重建，再只取系统重新编码为 HEVC Rext 的 gain map，写回原始容器结构。"
    static let inputProcessingPassthrough = "保留原始增益图"
    static let inputProcessingPassthroughHelp = "不让系统重编码 gain map；直接重建符合 ISO 标准的 ISOBMFF box 来保留原始增益图数据。"

    static let tmapFormatLabel = "ISO tmap 格式"
    static let tmapFormatStrict = "严格 ISO 145B"
    static let tmapFormatImageIO = "ImageIO 142B"
    static let tmapFormatStrictHelp = "实验性写入 ISO 21496-1 三通道 145-byte GainMapMetadata。Find X9 Ultra 实测会导致相册 Exif 解析和编辑组件异常，不建议正式输出。"
    static let tmapFormatImageIOHelp = "默认保留 Apple ImageIO 生成的 142-byte 兼容形式；Find X9 Ultra 相册 Exif、编辑和 HDR 兼容性更好。"

    static let oppoCompatLabel = "[实验性] OPPO 相册 HDR 兼容层"
    static let oppoCompatHelp = "控制 Gain Map 的 OPPO 编码兼容性和可选私有激活位；相机私有尾由下方选项独立控制。默认自动输出 Main Still 4:2:0，并保持源 UserComment 不变。"
    static let oppoCompatAuto = "自动"
    static let oppoCompatISO = "标准 HDR 位"
    static let oppoCompatISONoLocal = "标准 HDR（清除 LHDR）"
    static let oppoCompatISOGraph = "仅 ISO 图"
    static let oppoCompatOn = "开启"
    static let oppoCompatTail = "兼容开启"
    static let oppoCompatOff = "关闭"
    static let oppoCompatAutoHelp = "按所选 tmap 格式写入 PQ tmap 颜色，并保持源 OPPO tagflags 不变；私有尾部由下方选项独立控制。"
    static let oppoCompatISOHelp = "清除 OPLUS_UHDR 私有路由位并设置标准 ULTRA_HDR 位；用于验证 Gallery 的标准 ISO HDR 路径。"
    static let oppoCompatISONoLocalHelp = "清除 OPLUS_UHDR 与 LOCAL_HDR，并设置标准 ULTRA_HDR；仅用于 Main10/LHDR 路由诊断。"
    static let oppoCompatISOGraphHelp = "清除 OPLUS_UHDR 和 ULTRA_HDR 两种 HDR 位，仅依赖 ISO tmap/Gain Map 图触发；用于诊断，不建议正式输出。"
    static let oppoCompatOnHelp = "输出 Main Still 4:2:0，并在 Exif UserComment 设置 OPPO 私有 UHDR activation bit；仅用于明确的路由测试。"
    static let oppoCompatTailHelp = "兼容旧命令名；行为等同于开启。相机尾部仍由下方选项控制。"
    static let oppoCompatOffHelp = "从原始高规格源生成 profile 4/4:4:4 Gain Map；已经降采样为 4:2:0 的输入不能反向升级。"
    static let oppoGalleryCompatibility = "输出 OPPO 相册兼容格式"
    static let oppoGalleryCompatibilityHelp = "开启时输出 Main Still Picture 4:2:0 Gain Map；关闭时保留原始单通道，或从未降采样的三通道源输出 4:4:4/RExt。元数据保留策略不受影响。"
    static let preservePortraitEditingData = "保留人像后期数据"
    static let preservePortraitEditingDataHelp = "关闭时删除 depth、src.image、mask、mesh 和 crop 等大体积后期资源；水印、大师模式、HDR 数据和其他厂商元数据继续保留。"
    static let oppoCameraTailLabel = "[实验性] OPPO 相机尾部"
    static let oppoCameraTailHelp = "控制是否复制 OPPO Camera FileExtendedContainer 中的水印、大师模式、人像/景深条目；这和 HDR gain map 兼容层相互独立。"
    static let oppoCameraTailOff = "关闭"
    static let oppoCameraTailWatermark = "水印"
    static let oppoCameraTailCompact = "紧凑景深"
    static let oppoCameraTailPreserve = "完整保留"
    static let oppoCameraTailPreserveWithoutPortrait = "不保留人像后期数据"
    static let oppoCameraTailPreserveWithoutPrivateUHDR = "移除私有 UHDR 数据"
    static let oppoCameraTailPreserveWithoutPrivateHDR = "移除全部私有 HDR 数据"
    static let oppoCameraTailPreserveNoUHDR = "停用私有 UHDR"
    static let oppoCameraTailPreserveNoHDR = "停用 HDR 尾"
    static let oppoCameraTailOffHelp = "不追加 OPPO 相机私有尾部，保持默认 ISO 输出行为。"
    static let oppoCameraTailWatermarkHelp = "只追加水印相关 FileExtendedContainer 条目，保留 watermark.*、大师模式 preset 和拍摄参数，不复制大型景深/source/gainmap 私有块。"
    static let oppoCameraTailCompactHelp = "在水印基础上追加已验证的人像/景深紧凑尾部，并按真实 JSON-to-EOF span 写入 jxrs footer。"
    static let oppoCameraTailPreserveHelp = "强制使用保留源主图与非 HDR item 的混合写入路径；重建 ISO 21496-1 HDR 图后，逐字节复制源文件 mdat 之后的完整 OPPO/QTI/FileExtendedContainer 尾部，保留景深、水印、原图、编辑、实况和未知数据。"
    static let oppoCameraTailPreserveWithoutPortraitHelp = "保留水印、大师模式、HDR、UserComment 和其他厂商数据，仅移除景深、蒙版、网格和恢复原图等大体积人像后期资源。"
    static let oppoCameraTailPreserveWithoutPrivateUHDRHelp = "物理移除 local.uhdr.gainmap.data/info，保留人像、水印和其他非目标条目；仅用于设备验证。"
    static let oppoCameraTailPreserveWithoutPrivateHDRHelp = "物理移除 local.uhdr.*、local.hdr.*、src.local.hdr.* 和 hdr.*，保留非 HDR 厂商数据；仅用于设备验证。"
    static let oppoCameraTailPreserveNoUHDRHelp = "完整保留尾长、payload、offset、大师模式和未知数据，仅把 local.uhdr.gainmap.data/info 在 manifest 中等长改名，停用私有 UHDR reader。"
    static let oppoCameraTailPreserveNoHDRHelp = "在完整保留其他业务数据的前提下，等长停用 local.uhdr.*、hdr.*、local.hdr.* 和 src.local.hdr.* manifest key。"
    static let skipExisting = "跳过已有有效输出"
    static let skipExistingHelp = "目标文件已经满足当前 ISO gain map 与 OPPO 相机尾部设置时不重复转换。"
    static let concurrentJobs = "并发任务"
    static let outputFileSuffix = "输出文件后缀"
    static let outputFileSuffixHelp = "未设置输出目录时，在原目录用这个后缀生成新文件。"
    static let outputDirectory = "输出目录"
    static let debugOutputDirectory = "调试输出目录"
    static let done = "完成"
    static let useOriginalDirectory = "使用原目录"
    static let doNotWriteDebugFiles = "不写调试文件"
    static let chooseDirectory = "选择目录"
    static let clear = "清除"
}
extension OppoCompatibility {
    var appTitle: String {
        switch self {
        case .auto: return AppStrings.oppoCompatAuto
        case .iso: return AppStrings.oppoCompatISO
        case .isoNoLocal: return AppStrings.oppoCompatISONoLocal
        case .isoGraph: return AppStrings.oppoCompatISOGraph
        case .on: return AppStrings.oppoCompatOn
        case .tail: return AppStrings.oppoCompatTail
        case .off: return AppStrings.oppoCompatOff
        }
    }

    var appHelp: String {
        switch self {
        case .auto: return AppStrings.oppoCompatAutoHelp
        case .iso: return AppStrings.oppoCompatISOHelp
        case .isoNoLocal: return AppStrings.oppoCompatISONoLocalHelp
        case .isoGraph: return AppStrings.oppoCompatISOGraphHelp
        case .on: return AppStrings.oppoCompatOnHelp
        case .tail: return AppStrings.oppoCompatTailHelp
        case .off: return AppStrings.oppoCompatOffHelp
        }
    }
}

extension TmapFormat {
    var appTitle: String {
        switch self {
        case .strict: return AppStrings.tmapFormatStrict
        case .imageIO: return AppStrings.tmapFormatImageIO
        }
    }

    var appHelp: String {
        switch self {
        case .strict: return AppStrings.tmapFormatStrictHelp
        case .imageIO: return AppStrings.tmapFormatImageIOHelp
        }
    }
}

extension OppoCameraTail {
    var appTitle: String {
        switch self {
        case .off: return AppStrings.oppoCameraTailOff
        case .watermark: return AppStrings.oppoCameraTailWatermark
        case .compact: return AppStrings.oppoCameraTailCompact
        case .preserve: return AppStrings.oppoCameraTailPreserve
        case .preserveWithoutPortrait: return AppStrings.oppoCameraTailPreserveWithoutPortrait
        case .preserveWithoutPrivateUHDR: return AppStrings.oppoCameraTailPreserveWithoutPrivateUHDR
        case .preserveWithoutPrivateHDR: return AppStrings.oppoCameraTailPreserveWithoutPrivateHDR
        case .preserveNoUHDR: return AppStrings.oppoCameraTailPreserveNoUHDR
        case .preserveNoHDR: return AppStrings.oppoCameraTailPreserveNoHDR
        }
    }

    var appHelp: String {
        switch self {
        case .off: return AppStrings.oppoCameraTailOffHelp
        case .watermark: return AppStrings.oppoCameraTailWatermarkHelp
        case .compact: return AppStrings.oppoCameraTailCompactHelp
        case .preserve: return AppStrings.oppoCameraTailPreserveHelp
        case .preserveWithoutPortrait: return AppStrings.oppoCameraTailPreserveWithoutPortraitHelp
        case .preserveWithoutPrivateUHDR: return AppStrings.oppoCameraTailPreserveWithoutPrivateUHDRHelp
        case .preserveWithoutPrivateHDR: return AppStrings.oppoCameraTailPreserveWithoutPrivateHDRHelp
        case .preserveNoUHDR: return AppStrings.oppoCameraTailPreserveNoUHDRHelp
        case .preserveNoHDR: return AppStrings.oppoCameraTailPreserveNoHDRHelp
        }
    }
}

extension Family {
    var appTitle: String {
        switch self {
        case .auto: return AppStrings.familyAuto
        case .x6: return AppStrings.familyX6
        case .x7: return AppStrings.familyX7
        }
    }
}

extension InputProcessingBranch {
    var appTitle: String {
        switch self {
        case .system: return AppStrings.inputProcessingSystem
        case .systemDecoded: return AppStrings.inputProcessingSystemDecoded
        case .hybrid: return AppStrings.inputProcessingHybrid
        case .passthrough: return AppStrings.inputProcessingPassthrough
        }
    }

    var appHelp: String {
        switch self {
        case .system: return AppStrings.inputProcessingSystemHelp
        case .systemDecoded: return AppStrings.inputProcessingSystemDecodedHelp
        case .hybrid: return AppStrings.inputProcessingHybridHelp
        case .passthrough: return AppStrings.inputProcessingPassthroughHelp
        }
    }
}
