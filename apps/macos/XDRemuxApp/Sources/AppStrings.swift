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
    static let inputProcessingHybrid = "混合模式"
    static let inputProcessingHybridHelp = "先让系统重建，再只取系统重新编码为 HEVC Rext 的 gain map，写回原始容器结构。"
    static let inputProcessingPassthrough = "保留原始增益图"
    static let inputProcessingPassthroughHelp = "不让系统重编码 gain map；直接重建符合 ISO 标准的 ISOBMFF box 来保留原始增益图数据。"

    static let oppoCompatLabel = "[实验性] OPPO 相册 HDR 兼容层"
    static let oppoCompatHelp = "控制 OPPO 相册识别信号。关闭时保持默认 Apple/ImageIO 输出；自动使用无私有尾部的 ISO 诊断路径；开启也不追加任何私有 tail。LHDR 在兼容模式下固定使用 RGB-copy gain map。"
    static let oppoCompatAuto = "自动"
    static let oppoCompatOn = "开启"
    static let oppoCompatTail = "兼容开启"
    static let oppoCompatOff = "关闭"
    static let oppoCompatAutoHelp = "写入 142B ImageIO-native tmap 和 PQ tmap 颜色，并清理会触发私有 OUHDR 路径的 tagflags；不追加任何私有 tail。"
    static let oppoCompatOnHelp = "保留 source primary，写入标准 HEIC tmap/gain map 结构并设置 OPPO UHDR tagflags；LHDR 固定输出 RGB-copy gain map；不追加任何私有 tail。"
    static let oppoCompatTailHelp = "兼容旧命令名；行为等同于开启，不追加任何私有 tail。"
    static let oppoCompatOffHelp = "不写 OPPO 兼容 tmap 扩展，保持默认元数据行为。"
    static let skipExisting = "跳过已有有效输出"
    static let skipExistingHelp = "目标文件已经包含可识别的 ISO gain map 时不重复转换。"
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
        case .on: return AppStrings.oppoCompatOn
        case .tail: return AppStrings.oppoCompatTail
        case .off: return AppStrings.oppoCompatOff
        }
    }

    var appHelp: String {
        switch self {
        case .auto: return AppStrings.oppoCompatAutoHelp
        case .on: return AppStrings.oppoCompatOnHelp
        case .tail: return AppStrings.oppoCompatTailHelp
        case .off: return AppStrings.oppoCompatOffHelp
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
        case .hybrid: return AppStrings.inputProcessingHybrid
        case .passthrough: return AppStrings.inputProcessingPassthrough
        }
    }

    var appHelp: String {
        switch self {
        case .system: return AppStrings.inputProcessingSystemHelp
        case .hybrid: return AppStrings.inputProcessingHybridHelp
        case .passthrough: return AppStrings.inputProcessingPassthroughHelp
        }
    }
}
