import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum AppConstants {
    static let projectRoot: URL = {
        if let configured = ProcessInfo.processInfo.environment["AD_REPORT_AGENT_ROOT"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()
    static let pythonPath: String = {
        if let configured = ProcessInfo.processInfo.environment["AD_REPORT_PYTHON"],
           !configured.isEmpty {
            return configured
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
            .path
    }()
    static let lmEndpoint = "http://127.0.0.1:1234/v1"
    static let lmModel = "prism-ml/bonsai-27b"
    static let lmDisplayName = "Bonsai 27B"
    static let stages = [
        BilingualText(zh: "检查素材", en: "Check inputs"),
        BilingualText(zh: "识别与审核", en: "Recognize & review"),
        BilingualText(zh: "生成演示文稿", en: "Build presentation"),
        BilingualText(zh: "保存结果", en: "Save results"),
    ]
}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }
    var selectorTitle: String { self == .chinese ? "中文" : "EN" }
}

private enum InputSourceKind: String {
    case folder
    case legacyZip
}

private enum InputDiscoveryState: Equatable {
    case empty
    case scanning(candidates: Int)
    case ready(candidates: Int, selected: Int, required: Int)
    case incomplete(candidates: Int, selected: Int, required: Int, missing: [String], duplicates: [String], message: BilingualText)
    case legacyZip

    var allowsGeneration: Bool {
        switch self {
        case .ready, .legacyZip: return true
        default: return false
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .empty:
            return BilingualText(zh: "等待选择文件夹", en: "Waiting for a folder").value(for: language)
        case .scanning:
            return BilingualText(zh: "正在识别文件", en: "Discovering files").value(for: language)
        case .ready:
            return BilingualText(zh: "文件完整，可以生成", en: "Complete and ready").value(for: language)
        case .incomplete:
            return BilingualText(zh: "文件不完整", en: "Files are incomplete").value(for: language)
        case .legacyZip:
            return BilingualText(zh: "已选择旧版 ZIP", en: "Legacy ZIP selected").value(for: language)
        }
    }

    func detail(for language: AppLanguage) -> String {
        switch self {
        case .empty:
            return BilingualText(
                zh: "应用会递归扫描文件夹中的数据表",
                en: "The app will scan spreadsheets recursively"
            ).value(for: language)
        case let .scanning(candidates):
            return BilingualText(
                zh: "发现 \(candidates) 个候选文件，正在确认内容…",
                en: "Found \(candidates) candidates; checking contents…"
            ).value(for: language)
        case let .ready(candidates, selected, required):
            return BilingualText(
                zh: "已识别 \(selected)/\(required) 类必需素材（扫描 \(candidates) 个候选文件）",
                en: "Recognized \(selected)/\(required) required inputs (\(candidates) candidates scanned)"
            ).value(for: language)
        case let .incomplete(candidates, selected, required, missing, duplicates, message):
            let recognized = BilingualText(
                zh: "已识别 \(selected)/\(required) 类（扫描 \(candidates) 个候选文件）。",
                en: "Recognized \(selected)/\(required) types (\(candidates) candidates scanned). "
            ).value(for: language)
            let missingNames = missing.map { localizedSourceKind($0, language: language) }
            let duplicateNames = duplicates.map { localizedSourceKind($0, language: language) }
            let missingDetail = missing.isEmpty ? "" : BilingualText(
                zh: "缺少：\(missingNames.joined(separator: "、"))。",
                en: "Missing: \(missingNames.joined(separator: ", ")). "
            ).value(for: language)
            let duplicateDetail = duplicates.isEmpty ? "" : BilingualText(
                zh: "重复：\(duplicateNames.joined(separator: "、"))。",
                en: "Duplicates: \(duplicateNames.joined(separator: ", ")). "
            ).value(for: language)
            return recognized + missingDetail + duplicateDetail + message.value(for: language)
        case .legacyZip:
            return BilingualText(
                zh: "兼容 0.1 输入；建议后续直接选择原始文件夹",
                en: "0.1 compatibility mode; folders are recommended"
            ).value(for: language)
        }
    }

    var isProblem: Bool {
        if case .incomplete = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .scanning = self { return true }
        return false
    }
}

private struct BilingualText: Equatable {
    let zh: String
    let en: String

    func value(for language: AppLanguage) -> String {
        language == .chinese ? zh : en
    }

    static func raw(_ value: String) -> BilingualText {
        BilingualText(zh: value, en: value)
    }
}

private struct DiagnosticStep: Equatable {
    let zh: String
    let en: String

    func value(for language: AppLanguage) -> String {
        language == .chinese ? zh : en
    }
}

private struct DiagnosticPresentation: Equatable {
    let title: BilingualText
    let summary: BilingualText
    let steps: [DiagnosticStep]
    let category: String
    let affectedItems: [String]
    let aiParticipated: Bool
    let technicalMessage: BilingualText?

    func title(for language: AppLanguage) -> String {
        title.value(for: language)
    }

    func summary(for language: AppLanguage) -> String {
        summary.value(for: language)
    }
}

private struct WeeklyInsight: Identifiable, Equatable {
    let id: String
    let priority: String
    let title: BilingualText
    let summary: BilingualText
    let evidenceZh: [String]
    let evidenceEn: [String]
    let factIDs: [String]

    func title(for language: AppLanguage) -> String {
        title.value(for: language)
    }

    func summary(for language: AppLanguage) -> String {
        summary.value(for: language)
    }

    func evidence(for language: AppLanguage) -> [String] {
        language == .chinese ? evidenceZh : evidenceEn
    }
}

private enum WeeklyInsightsState: Equatable {
    case hidden
    case unavailable
    case ready
    case quiet
    case failed
}

private func localizedSourceKind(_ kind: String, language: AppLanguage) -> String {
    let labels: [String: BilingualText] = [
        "overall": BilingualText(zh: "总览", en: "Overall"),
        "by_day": BilingualText(zh: "每日表现", en: "By day"),
        "by_product": BilingualText(zh: "产品表现", en: "By product"),
        "traffic_campaign": BilingualText(zh: "流量广告", en: "Traffic campaigns"),
        "audience": BilingualText(zh: "受众", en: "Audience"),
        "campaign": BilingualText(zh: "转化广告", en: "Conversion campaigns"),
        "creative": BilingualText(zh: "创意素材", en: "Creative"),
        "keyword": BilingualText(zh: "关键词", en: "Keywords"),
    ]
    return labels[kind]?.value(for: language)
        ?? kind.replacingOccurrences(of: "_", with: " ")
}

private struct AppLogEntry: Equatable {
    let timestamp: Date
    let message: BilingualText
}

private extension Color {
    static let canvas = Color(red: 0.965, green: 0.969, blue: 0.972)
    static let surface = Color(red: 0.994, green: 0.995, blue: 0.996)
    static let sidebar = Color(red: 0.935, green: 0.949, blue: 0.960)
    static let graphite = Color(red: 0.105, green: 0.122, blue: 0.135)
    static let secondaryInk = Color(red: 0.37, green: 0.405, blue: 0.425)
    static let quietLine = Color.black.opacity(0.085)
    static let actionGreen = Color(red: 0.055, green: 0.455, blue: 0.285)
    static let softGreen = Color(red: 0.880, green: 0.947, blue: 0.910)
    static let softBlue = Color(red: 0.902, green: 0.932, blue: 0.952)
    static let errorInk = Color(red: 0.62, green: 0.16, blue: 0.13)
}

private enum LocalModelState: Equatable {
    case checking
    case ready
    case offline
    case starting
    case failed(BilingualText)

    func title(for language: AppLanguage) -> String {
        switch self {
        case .checking: return BilingualText(zh: "正在检查", en: "Checking").value(for: language)
        case .ready: return BilingualText(zh: "本地模型已就绪", en: "Local model ready").value(for: language)
        case .offline: return BilingualText(zh: "LM Studio 未连接", en: "LM Studio not connected").value(for: language)
        case .starting: return BilingualText(zh: "正在启动本地模型", en: "Starting local model").value(for: language)
        case .failed: return BilingualText(zh: "模型检查失败", en: "Model check failed").value(for: language)
        }
    }

    func detail(for language: AppLanguage) -> String {
        switch self {
        case .checking:
            return BilingualText(
                zh: "正在检查 \(AppConstants.lmDisplayName)",
                en: "Checking \(AppConstants.lmDisplayName)"
            ).value(for: language)
        case .ready:
            return BilingualText(
                zh: "\(AppConstants.lmDisplayName) · 本机",
                en: "\(AppConstants.lmDisplayName) · On this Mac"
            ).value(for: language)
        case .offline:
            return BilingualText(
                zh: "启动 LM Studio 并加载 \(AppConstants.lmDisplayName)",
                en: "Open LM Studio and load \(AppConstants.lmDisplayName)"
            ).value(for: language)
        case .starting:
            return BilingualText(
                zh: "正在打开服务并请求加载 \(AppConstants.lmDisplayName)",
                en: "Opening the service and loading \(AppConstants.lmDisplayName)"
            ).value(for: language)
        case let .failed(message):
            return BilingualText(
                zh: "详情：\(message.zh)",
                en: "Details: \(message.en)"
            ).value(for: language)
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checking, .starting: return true
        default: return false
        }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

@MainActor
private final class AppModel: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published private(set) var inputURL: URL?
    @Published private(set) var inputKind: InputSourceKind?
    @Published private(set) var inputDiscoveryState: InputDiscoveryState = .empty
    @Published var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: Keys.outputPath) }
    }
    @Published var aiReviewEnabled: Bool {
        didSet {
            defaults.set(aiReviewEnabled, forKey: Keys.aiReview)
            if !aiReviewEnabled {
                cancelDiagnosticExplanation(resetFingerprint: false)
            }
        }
    }
    @Published var modelState: LocalModelState = .checking
    @Published var isDropTargeted = false
    @Published private(set) var isPreparingGeneration = false
    @Published var isGenerating = false
    @Published var completedStageCount = 0
    @Published var activeStage: Int?
    @Published private var logEntries: [AppLogEntry] = []
    @Published var generatedPowerPoint: URL?
    @Published private(set) var previewImages: [URL] = []
    @Published var selectedPreviewIndex = 0
    @Published private var aiReviewVerdictMessage: BilingualText?
    @Published private var aiReviewSummaryMessage: BilingualText?
    @Published private(set) var aiReviewPassed = false
    @Published var aiReviewSidecarURL: URL?
    @Published private var userFacingErrorMessage: BilingualText?
    @Published private(set) var diagnosticPresentation: DiagnosticPresentation?
    @Published private(set) var isDiagnosticExplanationLoading = false
    @Published var technicalDetailsExpanded = false
    @Published var isErrorPresented = false
    @Published var isDetailsPresented = false
    @Published private(set) var weeklyInsights: [WeeklyInsight] = []
    @Published private(set) var weeklyInsightsState: WeeklyInsightsState = .hidden
    @Published var selectedWeeklyInsight: WeeklyInsight?
    @Published private(set) var runHasStarted = false

    private enum Keys {
        static let language = "appLanguage"
        static let inputPath = "recentInputPath"
        static let inputKind = "recentInputKind"
        static let inputBookmark = "recentInputBookmark"
        static let bundlePath = "recentBundlePath"
        static let outputPath = "recentOutputPath"
        static let outputBookmark = "recentOutputBookmark"
        static let aiReview = "aiReviewEnabled"
    }

    private let defaults = UserDefaults.standard
    private var generationProcess: Process?
    private var discoveryProcess: Process?
    private var modelProcess: Process?
    private var diagnosticProcess: Process?
    private var modelCheckInFlight = false
    private var generationOutput = ""
    private var generationStartedAt: Date?
    private var generationResultURL: URL?
    private var generationPreviewDirectory: URL?
    private var generationUsedAIReview = false
    private var discoveryRequestID: UUID?
    private var diagnosticRequestID: UUID?
    private var diagnosticFingerprint: Data?
    private var diagnosticTemporaryURL: URL?
    private var scopedInputURL: URL?
    private var scopedOutputURL: URL?

    private func clearOwnedPreviewDirectory() {
        guard let directory = generationPreviewDirectory else { return }
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let candidate = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == temporaryRoot,
              candidate.lastPathComponent.hasPrefix("ad-report-agent-"),
              candidate.lastPathComponent.hasSuffix("-previews") else { return }
        try? FileManager.default.removeItem(at: candidate)
        generationPreviewDirectory = nil
    }

    init() {
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .chinese

        let restoredInput = Self.restoreURL(
            bookmark: defaults.data(forKey: Keys.inputBookmark),
            fallbackPath: defaults.string(forKey: Keys.inputPath)
                ?? defaults.string(forKey: Keys.bundlePath)
        )
        inputURL = restoredInput
        if let restoredInput {
            let restoredKind = InputSourceKind(rawValue: defaults.string(forKey: Keys.inputKind) ?? "")
                ?? (restoredInput.pathExtension.lowercased() == "zip" ? .legacyZip : .folder)
            inputKind = restoredKind
            if restoredKind == .legacyZip {
                inputDiscoveryState = .legacyZip
            }
        } else {
            inputKind = nil
        }

        if let restoredOutput = Self.restoreURL(
            bookmark: defaults.data(forKey: Keys.outputBookmark),
            fallbackPath: defaults.string(forKey: Keys.outputPath)
        ) {
            outputDirectory = restoredOutput
        } else {
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Ad Report Agent", isDirectory: true)
        }

        if defaults.object(forKey: Keys.aiReview) == nil {
            aiReviewEnabled = true
        } else {
            aiReviewEnabled = defaults.bool(forKey: Keys.aiReview)
        }

        if let restoredInput, restoredInput.startAccessingSecurityScopedResource() {
            scopedInputURL = restoredInput
        }
        if outputDirectory.startAccessingSecurityScopedResource() {
            scopedOutputURL = outputDirectory
        }
    }

    func text(_ zh: String, _ en: String) -> String {
        BilingualText(zh: zh, en: en).value(for: language)
    }

    var userFacingError: String? {
        diagnosticPresentation?.summary(for: language)
            ?? userFacingErrorMessage?.value(for: language)
    }

    var userFacingErrorTitle: String {
        diagnosticPresentation?.title(for: language)
            ?? text("没有完成报告", "Report not completed")
    }

    var userFacingErrorSteps: [String] {
        diagnosticPresentation?.steps.map { $0.value(for: language) } ?? []
    }

    var userFacingAlertMessage: String {
        let summary = userFacingError ?? text("请检查素材后重试。", "Check the inputs and try again.")
        let affected = diagnosticAffectedItemLabels.isEmpty
            ? nil
            : text(
                "需处理：\(diagnosticAffectedItemLabels.joined(separator: "、"))",
                "Needs attention: \(diagnosticAffectedItemLabels.joined(separator: ", "))"
            )
        let heading = [summary, affected].compactMap { $0 }.joined(separator: "\n")
        guard !userFacingErrorSteps.isEmpty else { return heading }
        let steps = userFacingErrorSteps.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return "\(heading)\n\n\(steps)"
    }

    var diagnosticCategory: String? {
        diagnosticPresentation?.category
    }

    var diagnosticCategoryLabel: String? {
        guard let category = diagnosticCategory else { return nil }
        let labels: [String: BilingualText] = [
            "missing_sources": BilingualText(zh: "缺少素材", en: "Missing inputs"),
            "duplicate_sources": BilingualText(zh: "重复素材", en: "Duplicate inputs"),
            "period_conflict": BilingualText(zh: "日期范围不一致", en: "Date range conflict"),
            "product_alias": BilingualText(zh: "产品名称未匹配", en: "Product name mismatch"),
            "creative_pin": BilingualText(zh: "创意素材定位异常", en: "Creative placement issue"),
            "validation": BilingualText(zh: "报告校验未通过", en: "Report validation issue"),
            "generation": BilingualText(zh: "报告生成中断", en: "Report generation issue"),
            "application": BilingualText(zh: "应用设置", en: "App setting"),
            "unknown": BilingualText(zh: "素材识别未完成", en: "Input discovery incomplete"),
        ]
        return (labels[category] ?? BilingualText(zh: "处理异常", en: "Processing issue"))
            .value(for: language)
    }

    var diagnosticAffectedItems: [String] {
        diagnosticPresentation?.affectedItems ?? []
    }

    var diagnosticAffectedItemLabels: [String] {
        diagnosticAffectedItems.map { localizedSourceKind($0, language: language) }
    }

    var diagnosticTechnicalMessage: String? {
        diagnosticPresentation?.technicalMessage?.value(for: language)
    }

    var diagnosticWasAIExplained: Bool {
        diagnosticPresentation?.aiParticipated == true
    }

    var weeklyInsightsAvailabilityMessage: String? {
        switch weeklyInsightsState {
        case .unavailable:
            return text("完成两周后可用", "Available after two completed weeks")
        case .quiet:
            return text(
                "本周没有需要特别关注的变化",
                "No notable week-over-week changes"
            )
        default:
            return nil
        }
    }

    var selectedPreviewURL: URL? {
        guard previewImages.indices.contains(selectedPreviewIndex) else { return nil }
        return previewImages[selectedPreviewIndex]
    }

    var hasGeneratedWorkspace: Bool {
        generatedPowerPoint != nil
    }

    var showsWorkspace: Bool {
        runHasStarted || isPreparingGeneration || isGenerating || generatedPowerPoint != nil
    }

    var aiReviewVerdict: String? {
        aiReviewVerdictMessage?.value(for: language)
    }

    var aiReviewSummary: String? {
        aiReviewSummaryMessage?.value(for: language)
    }

    var logLines: [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return logEntries.map { entry in
            "\(formatter.string(from: entry.timestamp))  \(entry.message.value(for: language))"
        }
    }

    var canGenerate: Bool {
        inputURL != nil
            && inputDiscoveryState.allowsGeneration
            && !outputDirectory.path.isEmpty
            && !isPreparingGeneration
            && !isGenerating
            && (!aiReviewEnabled || modelState.isReady)
    }

    var overallStatusTitle: String {
        if isPreparingGeneration {
            return text("生成前检查", "Preflight check")
        }
        if isGenerating {
            return text("正在生成", "Generating")
        }
        if generatedPowerPoint != nil {
            return text("报告已生成", "Report generated")
        }
        return text("等待素材", "Waiting for inputs")
    }

    var overallStatusDetail: String {
        if isPreparingGeneration {
            return text("正在重新识别文件夹内容", "Rechecking folder contents")
        }
        if isGenerating, let activeStage, AppConstants.stages.indices.contains(activeStage) {
            return AppConstants.stages[activeStage].value(for: language)
        }
        if let generatedPowerPoint {
            return generatedPowerPoint.lastPathComponent
        }
        return text("所有文件只在这台 Mac 上处理", "All files stay on this Mac")
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.title = text("选择每周素材文件夹", "Choose weekly input folder")
        panel.prompt = text("使用此文件夹", "Use This Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            acceptInput(url)
        }
    }

    func selectLegacyBundle() {
        let panel = NSOpenPanel()
        panel.title = text("选择旧版每周素材 ZIP", "Choose a legacy weekly input ZIP")
        panel.prompt = text("选择 ZIP", "Choose ZIP")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url {
            acceptInput(url)
        }
    }

    func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = text("选择报告输出目录", "Choose report output folder")
        panel.prompt = text("使用此目录", "Use This Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            if let scopedOutputURL {
                scopedOutputURL.stopAccessingSecurityScopedResource()
            }
            scopedOutputURL = url.startAccessingSecurityScopedResource() ? url : nil
            outputDirectory = url
            persistBookmark(url, key: Keys.outputBookmark)
            userFacingErrorMessage = nil
        }
    }

    func acceptInput(_ url: URL) {
        guard url.isFileURL else {
            setError(
                zh: "无法读取这个位置，请重新选择素材文件夹。",
                en: "This location cannot be read. Choose the input folder again."
            )
            return
        }
        let isDirectory = url.hasDirectoryPath
            || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let isLegacyZip = !isDirectory && url.pathExtension.lowercased() == "zip"
        guard isDirectory || isLegacyZip else {
            setError(
                zh: "请拖入一个文件夹；旧版兼容入口也接受 .zip 素材包。",
                en: "Drop a folder. The legacy compatibility option also accepts a .zip bundle."
            )
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            setError(
                zh: "无法读取所选素材，请检查文件权限。",
                en: "The selected inputs cannot be read. Check their file permissions."
            )
            return
        }

        discoveryProcess?.terminate()
        discoveryProcess = nil
        discoveryRequestID = nil
        isPreparingGeneration = false
        if let scopedInputURL {
            scopedInputURL.stopAccessingSecurityScopedResource()
        }
        scopedInputURL = url.startAccessingSecurityScopedResource() ? url : nil
        inputURL = url
        inputKind = isDirectory ? .folder : .legacyZip
        persistInput(url)
        generatedPowerPoint = nil
        clearOwnedPreviewDirectory()
        previewImages = []
        selectedPreviewIndex = 0
        runHasStarted = false
        clearAIReviewResult()
        aiReviewSidecarURL = nil
        completedStageCount = 0
        activeStage = nil
        userFacingErrorMessage = nil
        clearDiagnosticPresentation()
        clearWeeklyInsights()
        appendLog(
            zh: "已选择素材：\(url.lastPathComponent)",
            en: "Inputs selected: \(url.lastPathComponent)"
        )
        if isDirectory {
            discoverInputFolder()
        } else {
            inputDiscoveryState = .legacyZip
            appendLog(
                zh: "正在使用旧版 ZIP 兼容模式。",
                en: "Using legacy ZIP compatibility mode."
            )
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            setError(
                zh: "未识别到文件夹。请将本周素材文件夹拖到这里。",
                en: "No folder was recognized. Drop this week's input folder here."
            )
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            var candidate: URL?
            if let url = item as? URL {
                candidate = url
            } else if let data = item as? Data {
                candidate = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? String {
                candidate = URL(string: value)
            }
            guard let candidate else { return }
            DispatchQueue.main.async {
                self?.acceptInput(candidate)
            }
        }
        return true
    }

    func discoverInputFolder(thenGenerate: Bool = false) {
        guard inputKind == .folder, let inputURL else { return }
        guard !isGenerating else { return }
        let found = Self.spreadsheetCount(in: inputURL)

        discoveryProcess?.terminate()
        clearDiagnosticPresentation()
        let requestID = UUID()
        discoveryRequestID = requestID
        isPreparingGeneration = thenGenerate
        if thenGenerate {
            userFacingErrorMessage = nil
            appendLog(
                zh: "生成前正在重新检查文件夹内容…",
                en: "Rechecking the folder contents before generation…"
            )
        }
        inputDiscoveryState = .scanning(candidates: found)
        discoveryProcess = launchPython(
            arguments: [
                "-m", "ad_report_mvp.gui_bridge", "inspect-folder",
                "--input-folder", inputURL.path,
                "--profile", "auto",
            ],
            timeoutSeconds: 45,
            onText: { _ in },
            completion: { [weak self] code, output in
                guard let self, self.discoveryRequestID == requestID else { return }
                self.discoveryProcess = nil
                self.discoveryRequestID = nil
                self.isPreparingGeneration = false
                let payload = Self.decodeJSONObject(from: output)
                let discovery = payload?["discovery"] as? [String: Any]
                let candidates = discovery?["candidate_count"] as? Int ?? found
                let required = discovery?["required_count"] as? Int ?? 8
                let selected = discovery?["selected_count"] as? Int
                    ?? (discovery?["selected_files"] as? [String: Any])?.count
                    ?? 0
                let missing = discovery?["missing_kinds"] as? [String] ?? []
                let duplicates = Array((discovery?["duplicate_kinds"] as? [String: Any] ?? [:]).keys).sorted()
                if code == 0 {
                    guard selected == required,
                          (payload?["ready"] as? Bool) == true,
                          (discovery?["ready"] as? Bool) == true else {
                        let technical = BilingualText(
                            zh: "预检没有确认完整素材集。",
                            en: "Preflight did not confirm a complete input set."
                        )
                        self.inputDiscoveryState = .incomplete(
                            candidates: candidates,
                            selected: selected,
                            required: required,
                            missing: missing,
                            duplicates: duplicates,
                            message: technical
                        )
                        self.presentDiagnostic(
                            category: Self.discoveryDiagnosticCategory(
                                missing: missing,
                                duplicates: duplicates
                            ),
                            missing: missing,
                            duplicates: duplicates,
                            errorType: "incomplete_inputs",
                            message: technical
                        )
                        return
                    }
                    self.inputDiscoveryState = .ready(
                        candidates: candidates,
                        selected: selected,
                        required: required
                    )
                    self.userFacingErrorMessage = nil
                    self.appendLog(
                        zh: "文件夹预检通过：已识别 \(selected)/\(required) 类必需素材。",
                        en: "Folder check passed: recognized \(selected)/\(required) required inputs."
                    )
                    if thenGenerate {
                        self.startGeneration(inputURL: inputURL, inputKind: .folder)
                    }
                } else {
                    let structuredError = payload?["error"] as? [String: Any]
                    let structured = structuredError?["message"] as? String
                    let message: BilingualText
                    if !missing.isEmpty || !duplicates.isEmpty {
                        message = BilingualText(
                            zh: "请补齐缺失项并移除重复素材后重新识别。",
                            en: "Add missing inputs and remove duplicates, then scan again."
                        )
                    } else {
                        let rawMessage = structured ?? self.conciseError(
                            from: output,
                            fallback: BilingualText(
                                zh: "请检查文件夹内容后重试。",
                                en: "Check the folder contents and try again."
                            )
                        ).value(for: self.language)
                        message = BilingualText.raw(rawMessage)
                    }
                    self.inputDiscoveryState = .incomplete(
                        candidates: candidates,
                        selected: selected,
                        required: required,
                        missing: missing,
                        duplicates: duplicates,
                        message: message
                    )
                    self.appendLog(
                        zh: "文件夹预检未通过：\(message.zh)",
                        en: "Folder check did not pass: \(message.en)"
                    )
                    self.presentDiagnostic(
                        category: Self.discoveryDiagnosticCategory(
                            missing: missing,
                            duplicates: duplicates
                        ),
                        missing: missing,
                        duplicates: duplicates,
                        errorType: structuredError?["type"] as? String ?? "input_discovery_failed",
                        message: structured.map(BilingualText.raw) ?? message
                    )
                }
            }
        )
        if discoveryProcess == nil {
            discoveryRequestID = nil
            isPreparingGeneration = false
            inputDiscoveryState = .incomplete(
                candidates: found,
                selected: 0,
                required: 8,
                missing: [],
                duplicates: [],
                message: BilingualText(
                    zh: "无法启动文件识别，请重试。",
                    en: "File discovery could not start. Try again."
                )
            )
            presentDiagnostic(
                category: Self.discoveryDiagnosticCategory(missing: [], duplicates: []),
                missing: [],
                duplicates: [],
                errorType: "input_discovery_launch_failed",
                message: BilingualText(
                    zh: "无法启动文件识别，请重试。",
                    en: "File discovery could not start. Try again."
                )
            )
        }
    }

    func checkModelStatus() {
        guard !modelCheckInFlight,
              !isPreparingGeneration,
              !isGenerating,
              !isDiagnosticExplanationLoading else { return }
        if case .starting = modelState { return }
        modelCheckInFlight = true
        if !modelState.isReady { modelState = .checking }

        let launched = launchPython(
            arguments: [
                "-m", "ad_report_mvp.gui_bridge", "status",
                "--endpoint", AppConstants.lmEndpoint,
                "--model", AppConstants.lmModel,
                "--request-timeout", "3",
            ],
            timeoutSeconds: 12,
            onText: { _ in },
            completion: { [weak self] code, output in
                guard let self else { return }
                self.modelCheckInFlight = false
                self.modelProcess = nil
                self.applyModelStatus(exitCode: code, output: output)
            }
        )
        modelProcess = launched
        if launched == nil {
            modelCheckInFlight = false
            modelState = .failed(BilingualText(
                zh: "无法运行本地模型状态检查。",
                en: "The local model status check could not be run."
            ))
        }
    }

    func startLocalModel() {
        guard !modelState.isBusy, !isPreparingGeneration, !isGenerating else { return }
        modelState = .starting
        appendLog(
            zh: "正在启动 LM Studio，并准备模型 \(AppConstants.lmDisplayName)…",
            en: "Starting LM Studio and preparing \(AppConstants.lmDisplayName)…"
        )
        let launched = launchPython(
            arguments: [
                "-m", "ad_report_mvp.gui_bridge", "start-model",
                "--endpoint", AppConstants.lmEndpoint,
                "--model", AppConstants.lmModel,
                "--request-timeout", "5",
                "--startup-timeout", "120",
            ],
            timeoutSeconds: 240,
            onText: { [weak self] text in
                self?.consumeLogChunk(
                    text,
                    source: BilingualText(zh: "模型", en: "Model")
                )
            },
            completion: { [weak self] code, output in
                guard let self else { return }
                self.modelProcess = nil
                if code != 0 {
                    let message = self.conciseError(
                        from: output,
                        fallback: BilingualText(
                            zh: "请手动打开 LM Studio 后重试。",
                            en: "Open LM Studio manually and try again."
                        )
                    )
                    self.modelState = .failed(message)
                    self.setError(
                        message,
                        contextZh: "无法启动本地模型",
                        contextEn: "Could not start the local model"
                    )
                    self.appendLog(
                        zh: "错误：无法启动本地模型：\(message.zh)",
                        en: "Error: could not start the local model: \(message.en)"
                    )
                    return
                }
                self.appendLog(
                    zh: "启动命令已完成，正在确认模型状态…",
                    en: "Startup command completed. Confirming model status…"
                )
                self.modelState = .checking
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.checkModelStatus()
                }
            }
        )
        modelProcess = launched
        if launched == nil {
            modelState = .failed(BilingualText(
                zh: "无法运行本地模型启动命令。",
                en: "The local model startup command could not be run."
            ))
        }
    }

    func generate() {
        guard !isGenerating, !isPreparingGeneration else { return }
        runHasStarted = true
        guard let inputURL, let inputKind else {
            setError(zh: "请先选择每周素材文件夹。", en: "Choose the weekly input folder first.")
            return
        }
        guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
            setError(
                zh: "素材位置不存在或无法读取，请重新选择。",
                en: "The input location is missing or unreadable. Choose it again."
            )
            return
        }
        guard inputDiscoveryState.allowsGeneration else {
            setError(
                zh: "素材文件夹尚未通过完整性检查，请补齐缺失文件后重新识别。",
                en: "The input folder has not passed its completeness check. Add missing files and scan again."
            )
            return
        }
        if aiReviewEnabled && !modelState.isReady {
            setError(
                zh: "AI 审核已开启，但本地模型尚未就绪。请先启动模型，或暂时关闭 AI 审核。",
                en: "AI review is on, but the local model is not ready. Start it or turn off AI review."
            )
            return
        }

        if inputKind == .folder {
            discoverInputFolder(thenGenerate: true)
            return
        }
        startGeneration(inputURL: inputURL, inputKind: inputKind)
    }

    private func startGeneration(inputURL: URL, inputKind: InputSourceKind) {
        guard !isGenerating, !isPreparingGeneration else { return }

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            setError(
                zh: "无法创建输出目录：\(error.localizedDescription)",
                en: "Could not create the output folder: \(error.localizedDescription)"
            )
            return
        }

        isGenerating = true
        generatedPowerPoint = nil
        clearOwnedPreviewDirectory()
        previewImages = []
        selectedPreviewIndex = 0
        clearAIReviewResult()
        aiReviewSidecarURL = nil
        userFacingErrorMessage = nil
        clearDiagnosticPresentation()
        clearWeeklyInsights()
        logEntries.removeAll(keepingCapacity: true)
        generationOutput = ""
        generationStartedAt = Date()
        generationUsedAIReview = aiReviewEnabled
        generationResultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ad-report-agent-\(UUID().uuidString).result.json")
        generationPreviewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ad-report-agent-\(UUID().uuidString)-previews", isDirectory: true)
        completedStageCount = 1
        activeStage = 1
        appendLog(
            zh: "使用最新扫描结果：\(inputURL.lastPathComponent)",
            en: "Using the latest scan: \(inputURL.lastPathComponent)"
        )
        if aiReviewEnabled {
            appendLog(
                zh: "开始识别数据，并由 \(AppConstants.lmDisplayName) 复核歧义项。",
                en: "Recognizing data; \(AppConstants.lmDisplayName) will review ambiguous items."
            )
        } else {
            appendLog(
                zh: "开始识别数据；本次未启用 AI 审核。",
                en: "Recognizing data; AI review is off for this run."
            )
        }

        var arguments = [
            "-m", "ad_report_mvp",
        ]
        switch inputKind {
        case .folder:
            arguments += ["--input-folder", inputURL.path]
        case .legacyZip:
            arguments += ["--bundle", inputURL.path]
        }
        arguments += [
            "--profile", "auto",
            "--output-dir", outputDirectory.path,
            "--result-json", generationResultURL!.path,
            "--preview-dir", generationPreviewDirectory!.path,
        ]
        if aiReviewEnabled {
            arguments += [
                "--ai-review",
                "--ai-endpoint", AppConstants.lmEndpoint,
                "--ai-model", AppConstants.lmModel,
                "--ai-timeout", "300",
            ]
        }

        generationProcess = launchPython(
            arguments: arguments,
            onText: { [weak self] text in
                guard let self else { return }
                self.generationOutput += text
                self.consumeGenerationChunk(text)
            },
            completion: { [weak self] code, output in
                guard let self else { return }
                self.generationProcess = nil
                self.finishGeneration(exitCode: code, output: output)
            }
        )

        if generationProcess == nil {
            isGenerating = false
            activeStage = nil
            presentDiagnostic(
                category: "generation",
                missing: [],
                duplicates: [],
                errorType: "generation_launch_failed",
                message: BilingualText(
                    zh: "无法启动报告生成程序。",
                    en: "The report generator could not be started."
                )
            )
        }
    }

    private func persistInput(_ url: URL) {
        defaults.set(url.path, forKey: Keys.inputPath)
        defaults.set(inputKind?.rawValue, forKey: Keys.inputKind)
        persistBookmark(url, key: Keys.inputBookmark)
    }

    private func persistBookmark(_ url: URL, key: String) {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func restoreURL(bookmark: Data?, fallbackPath: String?) -> URL? {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        guard let fallbackPath, !fallbackPath.isEmpty,
              FileManager.default.fileExists(atPath: fallbackPath) else { return nil }
        return URL(fileURLWithPath: fallbackPath)
    }

    private static func spreadsheetCount(in folder: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        let supported = Set(["xlsx", "csv", "tsv"])
        var count = 0
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            if name.hasPrefix("~$") || name.hasPrefix("._") { continue }
            guard supported.contains(file.pathExtension.lowercased()) else { continue }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, values?.isHidden != true { count += 1 }
        }
        return count
    }

    private static func decodeJSONObject(from output: String) -> [String: Any]? {
        let candidates = [output.trimmingCharacters(in: .whitespacesAndNewlines)]
            + output.components(separatedBy: .newlines).reversed()
        for candidate in candidates where !candidate.isEmpty {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return payload
        }
        return nil
    }

    func openPowerPoint() {
        guard let generatedPowerPoint else { return }
        NSWorkspace.shared.open(generatedPowerPoint)
    }

    func revealPowerPoint() {
        guard let generatedPowerPoint else { return }
        NSWorkspace.shared.activateFileViewerSelecting([generatedPowerPoint])
    }

    private func applyModelStatus(exitCode: Int32, output: String) {
        guard exitCode == 0 else {
            modelState = .offline
            return
        }

        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ready = json["ready"] as? Bool
                ?? json["model_ready"] as? Bool
                ?? ((json["status"] as? String)?.lowercased() == "ready")
            if ready {
                modelState = .ready
                return
            }
            if let message = json["message"] as? String, !message.isEmpty {
                modelState = .failed(.raw(message))
                return
            }
        }

        let normalized = output.lowercased()
        if normalized.contains("\"ready\": true")
            || normalized.contains("\"model_ready\": true")
            || normalized.contains("\"status\": \"ready\"") {
            modelState = .ready
        } else {
            modelState = .offline
        }
    }

    private func consumeGenerationChunk(_ text: String) {
        let normalized = text.lowercased()
        if normalized.contains("final-deck")
            || normalized.contains("building powerpoint")
            || normalized.contains("生成演示文稿") {
            completedStageCount = max(completedStageCount, 2)
            activeStage = 2
        }
        if normalized.contains("validation") || normalized.contains("validated") {
            completedStageCount = max(completedStageCount, 2)
            activeStage = max(activeStage ?? 1, 2)
        }
        consumeLogChunk(text, source: nil)
    }

    private func consumeLogChunk(_ text: String, source: BilingualText?) {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .forEach { line in
                if let source {
                    appendLog(
                        zh: "[\(source.zh)] \(line)",
                        en: "[\(source.en)] \(line)"
                    )
                } else {
                    appendRawLog(line)
                }
            }
    }

    private func finishGeneration(exitCode: Int32, output: String) {
        isGenerating = false
        let combined = generationOutput + output
        let resultPayload = readGenerationResult()
        reflectGenerationDiscovery(resultPayload)
        guard exitCode == 0 else {
            activeStage = nil
            let structuredError = resultPayload?["error"] as? [String: Any]
            let structuredMessage = structuredError?["message"] as? String
            let message = structuredMessage.map(BilingualText.raw)
                ?? conciseError(
                    from: combined,
                    fallback: BilingualText(
                        zh: "请查看运行记录后重试。",
                        en: "Check the run log and try again."
                    )
                )
            setError(message, contextZh: "生成失败", contextEn: "Generation failed")
            appendLog(
                zh: "错误：生成失败：\(message.zh)",
                en: "Error: generation failed: \(message.en)"
            )
            let discovery = resultPayload?["discovery"] as? [String: Any]
            let missing = discovery?["missing_kinds"] as? [String] ?? []
            let duplicates = Array(
                (discovery?["duplicate_kinds"] as? [String: Any] ?? [:]).keys
            ).sorted()
            let errorType = structuredError?["type"] as? String ?? "generation_failed"
            let diagnosticCategory = (!missing.isEmpty || !duplicates.isEmpty)
                ? Self.discoveryDiagnosticCategory(missing: missing, duplicates: duplicates)
                : Self.generationDiagnosticCategory(errorType: errorType, message: message)
            presentDiagnostic(
                category: diagnosticCategory,
                missing: missing,
                duplicates: duplicates,
                errorType: errorType,
                message: message
            )
            return
        }

        completedStageCount = 3
        activeStage = 3
        if let inputProfile = resultPayload?["input_profile"] as? String {
            switch inputProfile.lowercased() {
            case "demo":
                appendLog(zh: "已识别：脱敏演示素材", en: "Detected: anonymized demo inputs")
            case "production":
                appendLog(zh: "已识别：正式周报素材", en: "Detected: production weekly inputs")
            default:
                appendLog(
                    zh: "已识别素材模式：\(inputProfile)",
                    en: "Detected input profile: \(inputProfile)"
                )
            }
        }
        if (resultPayload?["nested_bundle"] as? Bool) == true {
            appendLog(
                zh: "已从整合包中自动找到可运行的周报输入包",
                en: "Found a valid weekly input bundle inside the package"
            )
        }
        if (resultPayload?["input_mode"] as? String) == "folder" {
            appendLog(
                zh: "本次报告直接从文件夹生成，生成前已再次扫描素材。",
                en: "This report was generated directly from the folder after a fresh scan."
            )
        }
        let reportedPowerPoint = absoluteFileURL(
            from: resultPayload?["powerpoint"],
            suffix: ".pptx"
        )
        if reportedPowerPoint == nil {
            appendLog(
                zh: "警告：result-json 未返回有效的 powerpoint 绝对路径，尝试从命令输出恢复。",
                en: "Warning: result-json did not return a valid absolute PowerPoint path; trying the command output."
            )
        }
        guard let powerPoint = reportedPowerPoint
            ?? extractPowerPointURL(from: combined)
            ?? newestPowerPoint(createdAfter: generationStartedAt) else {
            activeStage = nil
            let message = BilingualText(
                zh: "流程已结束，但没有找到生成的 PPT 文件。请检查输出目录。",
                en: "The process finished, but no generated PPT was found. Check the output folder."
            )
            setError(message, contextZh: "生成失败", contextEn: "Generation failed")
            appendLog(zh: "错误：未找到输出 PPT。", en: "Error: output PPT not found.")
            presentDiagnostic(
                category: "generation",
                missing: [],
                duplicates: [],
                errorType: "powerpoint_not_found",
                message: message
            )
            return
        }

        generatedPowerPoint = powerPoint
        loadPreviewImages(resultPayload: resultPayload)
        loadAIReviewResult(resultPayload: resultPayload, rawOutput: combined)
        loadWeeklyInsights(resultPayload: resultPayload)
        completedStageCount = AppConstants.stages.count
        activeStage = nil
        appendLog(
            zh: "完成：\(powerPoint.lastPathComponent)",
            en: "Completed: \(powerPoint.lastPathComponent)"
        )
    }

    private func extractPowerPointURL(from output: String) -> URL? {
        extractAbsoluteFileURL(key: "powerpoint", suffix: ".pptx", from: output)
    }

    private func reflectGenerationDiscovery(_ payload: [String: Any]?) {
        guard (payload?["input_mode"] as? String) == "folder",
              let discovery = payload?["discovery"] as? [String: Any] else { return }
        let candidates = discovery["candidate_count"] as? Int ?? 0
        let required = discovery["required_count"] as? Int ?? 8
        let selected = discovery["selected_count"] as? Int
            ?? (discovery["selected_files"] as? [String: Any])?.count
            ?? 0
        let missing = discovery["missing_kinds"] as? [String] ?? []
        let duplicates = Array((discovery["duplicate_kinds"] as? [String: Any] ?? [:]).keys).sorted()
        if selected == required, (discovery["ready"] as? Bool) == true {
            inputDiscoveryState = .ready(
                candidates: candidates,
                selected: selected,
                required: required
            )
        } else {
            let raw = (payload?["error"] as? [String: Any])?["message"] as? String
            inputDiscoveryState = .incomplete(
                candidates: candidates,
                selected: selected,
                required: required,
                missing: missing,
                duplicates: duplicates,
                message: raw.map(BilingualText.raw) ?? BilingualText(
                    zh: "生成前复检未通过。",
                    en: "The final preflight check did not pass."
                )
            )
        }
    }

    private func extractAbsoluteFileURL(key: String, suffix: String, from output: String) -> URL? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
        let pattern = "\\\"\(escapedKey)\\\"\\s*:\\s*\\\"([^\\\"]+\(escapedSuffix))\\\""
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ).last,
              let pathRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        let encodedPath = String(output[pathRange])
        let decodedPath = encodedPath
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\\", with: "\\")
        let url = URL(fileURLWithPath: decodedPath)
        guard decodedPath.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func absoluteFileURL(from value: Any?, suffix: String) -> URL? {
        guard let path = value as? String,
              path.hasPrefix("/"),
              path.lowercased().hasSuffix(suffix.lowercased()) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func readGenerationResult() -> [String: Any]? {
        guard let generationResultURL,
              let data = try? Data(contentsOf: generationResultURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            appendLog(
                zh: "警告：无法读取本次 result-json。",
                en: "Warning: result-json for this run could not be read."
            )
            return nil
        }
        return payload
    }

    private func loadPreviewImages(resultPayload: [String: Any]?) {
        let paths = resultPayload?["preview_images"] as? [String] ?? []
        let expectedDirectory = generationPreviewDirectory?.resolvingSymlinksInPath()
        let loaded = paths.compactMap { path -> URL? in
            guard path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else { return nil }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == expectedDirectory,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        let expectedNames = (1...8).map { String(format: "slide-%02d.png", $0) }
        let receivedCount = loaded.count
        previewImages = loaded.map(\.lastPathComponent) == expectedNames ? loaded : []
        selectedPreviewIndex = 0
        if previewImages.count != 8 {
            appendLog(
                zh: "警告：只收到 \(receivedCount)/8 张幻灯片预览。",
                en: "Warning: received only \(receivedCount)/8 slide previews."
            )
        }
    }

    private func loadAIReviewResult(resultPayload: [String: Any]?, rawOutput: String) {
        guard generationUsedAIReview else {
            aiReviewPassed = false
            aiReviewVerdictMessage = BilingualText(zh: "本次未启用 AI", en: "AI not used for this run")
            aiReviewSummaryMessage = BilingualText(
                zh: "报告由确定性规则完成，未调用本地模型复核。",
                en: "The report was completed with deterministic rules; the local model was not called."
            )
            return
        }

        let reportedSidecar = absoluteFileURL(
            from: resultPayload?["ai_review_json"],
            suffix: ".json"
        )
        if reportedSidecar == nil {
            appendLog(
                zh: "警告：result-json 未返回有效的 ai_review_json 绝对路径，尝试从命令输出恢复。",
                en: "Warning: result-json did not return a valid absolute AI review path; trying the command output."
            )
        }
        guard let sidecar = reportedSidecar ?? extractAbsoluteFileURL(
            key: "ai_review_json",
            suffix: ".json",
            from: rawOutput
        ) else {
            aiReviewPassed = false
            aiReviewVerdictMessage = BilingualText(zh: "未找到审核结论", en: "Review result not found")
            aiReviewSummaryMessage = BilingualText(
                zh: "PPT 已生成，但处理程序没有返回 AI 审核结果文件。",
                en: "The PPT was generated, but the processor did not return an AI review file."
            )
            appendLog(
                zh: "警告：未收到 ai_review_json 绝对路径。",
                en: "Warning: no absolute ai_review_json path was returned."
            )
            return
        }
        aiReviewSidecarURL = sidecar

        guard let data = try? Data(contentsOf: sidecar),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            aiReviewPassed = false
            aiReviewVerdictMessage = BilingualText(zh: "审核结果不可读", en: "Review result unreadable")
            aiReviewSummaryMessage = .raw(sidecar.lastPathComponent)
            appendLog(
                zh: "警告：无法读取 \(sidecar.lastPathComponent)。",
                en: "Warning: could not read \(sidecar.lastPathComponent)."
            )
            return
        }

        let nested = root["review"] as? [String: Any]
        let verdict = root["verdict"] as? String
            ?? root["status"] as? String
            ?? nested?["verdict"] as? String
            ?? "completed"
        let summary = root["summary"] as? String
            ?? root["message"] as? String
            ?? nested?["summary"] as? String
            ?? sidecar.lastPathComponent
        let presentation = localizedVerdict(verdict)
        aiReviewPassed = presentation.isPass
        aiReviewVerdictMessage = presentation.text
        // The model-authored summary is intentionally preserved verbatim.
        aiReviewSummaryMessage = .raw(summary)
        appendLog(
            zh: "AI 审核：\(presentation.text.zh)",
            en: "AI review: \(presentation.text.en)"
        )
    }

    private func localizedVerdict(_ verdict: String) -> (text: BilingualText, isPass: Bool) {
        switch verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pass", "passed", "ok", "approve", "approved":
            return (BilingualText(zh: "通过", en: "Pass"), true)
        case "warn", "warning", "review":
            return (BilingualText(zh: "建议复核", en: "Review recommended"), false)
        case "fail", "failed", "reject", "rejected":
            return (BilingualText(zh: "未通过", en: "Failed"), false)
        case "complete", "completed", "done":
            return (BilingualText(zh: "审核已完成", en: "Review complete"), false)
        default:
            return (.raw(verdict), false)
        }
    }

    private func loadWeeklyInsights(resultPayload: [String: Any]?) {
        clearWeeklyInsights()
        let reportedStatus = (resultPayload?["weekly_insights_status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch reportedStatus {
        case "unavailable":
            weeklyInsightsState = .unavailable
            return
        case "failed":
            weeklyInsightsState = .failed
            return
        case "disabled", "":
            weeklyInsightsState = .hidden
            return
        case "available":
            break
        default:
            weeklyInsightsState = .failed
            return
        }

        guard let sidecar = absoluteFileURL(
            from: resultPayload?["weekly_insights_json"],
            suffix: ".json"
        ), let data = try? Data(contentsOf: sidecar),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            weeklyInsightsState = .failed
            appendLog(
                zh: "提示：本周关注暂时不可用，PPT 已正常生成。",
                en: "Note: weekly insights are temporarily unavailable; the PPT was generated normally."
            )
            return
        }

        let sidecarStatus = (root["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if sidecarStatus == "unavailable" {
            weeklyInsightsState = .unavailable
            return
        }
        guard sidecarStatus == nil || sidecarStatus == "available",
              let items = root["insights"] as? [[String: Any]] else {
            weeklyInsightsState = .failed
            return
        }

        weeklyInsights = items.prefix(3).enumerated().compactMap { index, item in
            guard let title = Self.bilingualText(
                zh: item["title_zh"],
                en: item["title_en"]
            ), let summary = Self.bilingualText(
                zh: item["summary_zh"],
                en: item["summary_en"]
            ) else { return nil }
            let evidenceZh = Self.stringList(from: item["evidence_zh"])
            let evidenceEn = Self.stringList(from: item["evidence_en"])
            let factIDs = Self.stringList(from: item["fact_ids"])
            guard !factIDs.isEmpty else { return nil }
            let priority = Self.nonEmptyString(item["priority"]) ?? "normal"
            return WeeklyInsight(
                id: "\(index)-\(factIDs.joined(separator: "|"))",
                priority: priority,
                title: title,
                summary: summary,
                evidenceZh: evidenceZh.isEmpty ? evidenceEn : evidenceZh,
                evidenceEn: evidenceEn.isEmpty ? evidenceZh : evidenceEn,
                factIDs: factIDs
            )
        }
        if items.isEmpty {
            weeklyInsightsState = .quiet
        } else {
            weeklyInsightsState = weeklyInsights.isEmpty ? .failed : .ready
        }
    }

    private func clearWeeklyInsights() {
        weeklyInsights = []
        weeklyInsightsState = .hidden
        selectedWeeklyInsight = nil
    }

    private func presentDiagnostic(
        category: String,
        missing: [String],
        duplicates: [String],
        errorType: String,
        message: BilingualText
    ) {
        let fallback = fallbackDiagnostic(
            category: category,
            missing: missing,
            duplicates: duplicates,
            technicalMessage: message
        )
        diagnosticPresentation = fallback
        userFacingErrorMessage = fallback.summary
        technicalDetailsExpanded = false
        isErrorPresented = true
        requestDiagnosticExplanation(
            category: category,
            missing: missing,
            duplicates: duplicates,
            errorType: errorType,
            message: message,
            fallback: fallback
        )
    }

    private func fallbackDiagnostic(
        category: String,
        missing: [String],
        duplicates: [String],
        technicalMessage: BilingualText
    ) -> DiagnosticPresentation {
        let missingZh = missing.map { localizedSourceKind($0, language: .chinese) }
        let missingEn = missing.map { localizedSourceKind($0, language: .english) }
        let duplicatesZh = duplicates.map { localizedSourceKind($0, language: .chinese) }
        let duplicatesEn = duplicates.map { localizedSourceKind($0, language: .english) }
        let hasInputIssue = !missing.isEmpty
            || !duplicates.isEmpty
            || category == "missing_sources"
            || category == "duplicate_sources"
            || category == "unknown"

        if hasInputIssue {
            var summaryZh = "应用还没有确认一套完整且唯一的周报素材。"
            var summaryEn = "The app has not found one complete, unambiguous weekly input set yet."
            var steps: [DiagnosticStep] = []
            if !missing.isEmpty {
                summaryZh = "素材不完整：缺少\(missingZh.joined(separator: "、"))。"
                summaryEn = "The input set is incomplete. Missing: \(missingEn.joined(separator: ", "))."
                steps.append(DiagnosticStep(
                    zh: "补齐以下数据表：\(missingZh.joined(separator: "、"))。",
                    en: "Add the missing tables: \(missingEn.joined(separator: ", "))."
                ))
            }
            if !duplicates.isEmpty {
                let duplicateZh = "发现重复素材：\(duplicatesZh.joined(separator: "、"))。"
                let duplicateEn = "Duplicate inputs were found: \(duplicatesEn.joined(separator: ", "))."
                summaryZh = missing.isEmpty ? duplicateZh : "\(summaryZh) \(duplicateZh)"
                summaryEn = missing.isEmpty ? duplicateEn : "\(summaryEn) \(duplicateEn)"
                steps.append(DiagnosticStep(
                    zh: "每类重复素材只保留正确的一份：\(duplicatesZh.joined(separator: "、"))。",
                    en: "Keep only the correct file for each duplicate type: \(duplicatesEn.joined(separator: ", "))."
                ))
            }
            if steps.isEmpty {
                steps.append(DiagnosticStep(
                    zh: "确认文件夹中包含本周所需的八类数据表。",
                    en: "Confirm that the folder contains all eight required weekly tables."
                ))
            }
            steps.append(DiagnosticStep(
                zh: "整理完成后，回到应用点击“重新识别”。",
                en: "After correcting the folder, return to the app and choose Scan Again."
            ))
            return DiagnosticPresentation(
                title: BilingualText(zh: "素材需要调整", en: "Inputs need attention"),
                summary: BilingualText(zh: summaryZh, en: summaryEn),
                steps: steps,
                category: category,
                affectedItems: Array(Set(missing + duplicates)).sorted(),
                aiParticipated: false,
                technicalMessage: technicalMessage
            )
        }

        return DiagnosticPresentation(
            title: BilingualText(zh: "报告生成未完成", en: "Report generation did not finish"),
            summary: BilingualText(
                zh: "本次报告没有完成，现有文件不会受到影响。请按下面的步骤检查后重试。",
                en: "This run did not finish, and existing files were not changed. Check the items below and try again."
            ),
            steps: [
                DiagnosticStep(
                    zh: "确认素材文件夹和输出目录仍可访问。",
                    en: "Confirm that the input and output folders are still accessible."
                ),
                DiagnosticStep(
                    zh: "再次点击“生成 PPT”；如果问题重复出现，再展开技术详情。",
                    en: "Choose Generate PPT again. If the problem repeats, expand Technical Details."
                ),
            ],
            category: category,
            affectedItems: [],
            aiParticipated: false,
            technicalMessage: technicalMessage
        )
    }

    private func requestDiagnosticExplanation(
        category: String,
        missing: [String],
        duplicates: [String],
        errorType: String,
        message: BilingualText,
        fallback: DiagnosticPresentation
    ) {
        guard aiReviewEnabled, modelState.isReady else { return }
        let boundedMissing = missing.prefix(20).map { String($0.prefix(160)) }
        let boundedDuplicates = duplicates.prefix(20).map { String($0.prefix(160)) }
        let duplicateKinds = Dictionary(uniqueKeysWithValues: boundedDuplicates.map {
            ($0, ["candidate", "alternate_candidate"])
        })
        let payload: [String: Any] = [
            "category": category,
            "missing": boundedMissing,
            "duplicates": duplicateKinds,
            "error_type": String(errorType.prefix(80)),
            "message": String(message.en.prefix(1200)),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return }
        guard diagnosticFingerprint != data else { return }

        cancelDiagnosticExplanation(resetFingerprint: false)
        diagnosticFingerprint = data
        let requestID = UUID()
        diagnosticRequestID = requestID
        isDiagnosticExplanationLoading = true
        let diagnosticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ad-report-agent-\(requestID.uuidString).diagnostic.json")
        diagnosticTemporaryURL = diagnosticURL
        do {
            try data.write(to: diagnosticURL, options: .atomic)
        } catch {
            isDiagnosticExplanationLoading = false
            diagnosticRequestID = nil
            diagnosticTemporaryURL = nil
            return
        }

        diagnosticProcess = launchPython(
            arguments: [
                "-m", "ad_report_mvp.gui_bridge", "explain-diagnostic",
                "--diagnostic-json", diagnosticURL.path,
                "--endpoint", AppConstants.lmEndpoint,
                "--model", AppConstants.lmModel,
                "--request-timeout", "300",
            ],
            timeoutSeconds: 315,
            reportsLaunchFailure: false,
            onText: { _ in },
            completion: { [weak self] code, output in
                guard let self, self.diagnosticRequestID == requestID else { return }
                self.diagnosticProcess = nil
                self.diagnosticRequestID = nil
                self.isDiagnosticExplanationLoading = false
                self.removeDiagnosticTemporaryFile(diagnosticURL)
                guard code == 0,
                      let root = Self.decodeJSONObject(from: output),
                      (root["status"] as? String)?.lowercased() == "explained",
                      let explanation = root["explanation"] as? [String: Any] else {
                    return
                }
                self.diagnosticPresentation = Self.decodeDiagnosticExplanation(
                    explanation,
                    fallback: fallback
                )
            }
        )
        if diagnosticProcess == nil {
            diagnosticRequestID = nil
            isDiagnosticExplanationLoading = false
            removeDiagnosticTemporaryFile(diagnosticURL)
        }
    }

    private static func decodeDiagnosticExplanation(
        _ explanation: [String: Any],
        fallback: DiagnosticPresentation
    ) -> DiagnosticPresentation {
        let title = bilingualText(
            zh: explanation["title_zh"],
            en: explanation["title_en"]
        ) ?? fallback.title
        let summary = bilingualText(
            zh: explanation["summary_zh"],
            en: explanation["summary_en"]
        ) ?? fallback.summary
        let decodedSteps = (explanation["steps"] as? [[String: Any]] ?? [])
            .prefix(5)
            .compactMap { item -> DiagnosticStep? in
                guard let text = bilingualText(zh: item["zh"], en: item["en"]) else { return nil }
                return DiagnosticStep(zh: text.zh, en: text.en)
            }
        return DiagnosticPresentation(
            title: title,
            summary: summary,
            steps: decodedSteps.isEmpty ? fallback.steps : decodedSteps,
            category: nonEmptyString(explanation["category"]) ?? fallback.category,
            affectedItems: stringList(from: explanation["affected_items"]).prefix(16).map { $0 },
            aiParticipated: explanation["ai_participated"] as? Bool ?? false,
            technicalMessage: fallback.technicalMessage
        )
    }

    private static func bilingualText(zh: Any?, en: Any?) -> BilingualText? {
        let zhText = nonEmptyString(zh)
        let enText = nonEmptyString(en)
        guard zhText != nil || enText != nil else { return nil }
        return BilingualText(
            zh: zhText ?? enText!,
            en: enText ?? zhText!
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringList(from value: Any?) -> [String] {
        if let values = value as? [String] {
            return values.compactMap { nonEmptyString($0) }
        }
        if let value = nonEmptyString(value) {
            return [value]
        }
        return []
    }

    private static func discoveryDiagnosticCategory(
        missing: [String],
        duplicates: [String]
    ) -> String {
        if !missing.isEmpty { return "missing_sources" }
        if !duplicates.isEmpty { return "duplicate_sources" }
        return "unknown"
    }

    private static func generationDiagnosticCategory(
        errorType: String,
        message: BilingualText
    ) -> String {
        let normalized = "\(errorType) \(message.zh) \(message.en)".lowercased()
        if normalized.contains("period") || normalized.contains("date") || normalized.contains("日期") {
            return "period_conflict"
        }
        if normalized.contains("alias")
            || normalized.contains("no configured product")
            || normalized.contains("产品别名") {
            return "product_alias"
        }
        if normalized.contains("creative pin")
            || normalized.contains("creative_pin")
            || normalized.contains("pinned")
            || normalized.contains("创意固定") {
            return "creative_pin"
        }
        if normalized.contains("reportvalidation")
            || normalized.contains("validation")
            || normalized.contains("校验") {
            return "validation"
        }
        return "generation"
    }

    private func clearDiagnosticPresentation() {
        cancelDiagnosticExplanation(resetFingerprint: true)
        diagnosticPresentation = nil
        userFacingErrorMessage = nil
        technicalDetailsExpanded = false
        isErrorPresented = false
    }

    private func cancelDiagnosticExplanation(resetFingerprint: Bool) {
        diagnosticRequestID = nil
        if diagnosticProcess?.isRunning == true {
            diagnosticProcess?.terminate()
        }
        diagnosticProcess = nil
        isDiagnosticExplanationLoading = false
        if let diagnosticTemporaryURL {
            removeDiagnosticTemporaryFile(diagnosticTemporaryURL)
        }
        if resetFingerprint {
            diagnosticFingerprint = nil
        }
    }

    private func removeDiagnosticTemporaryFile(_ url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        if candidate.deletingLastPathComponent() == temporaryRoot,
           candidate.lastPathComponent.hasPrefix("ad-report-agent-"),
           candidate.lastPathComponent.hasSuffix(".diagnostic.json") {
            try? FileManager.default.removeItem(at: candidate)
        }
        if diagnosticTemporaryURL?.standardizedFileURL == candidate {
            diagnosticTemporaryURL = nil
        }
    }

    private func newestPowerPoint(createdAfter startDate: Date?) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files
            .filter { $0.pathExtension.lowercased() == "pptx" }
            .filter { file in
                guard let startDate else { return false }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return date.map { $0 >= startDate.addingTimeInterval(-1) } ?? false
            }
            .max { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate < rightDate
            }
    }

    private func conciseError(from output: String, fallback: BilingualText) -> BilingualText {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let timeout = lines.last(where: { $0.hasPrefix("ERROR: LOCAL_PROCESS_TIMEOUT:") }),
           let seconds = timeout.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
           !seconds.isEmpty {
            return BilingualText(
                zh: "本地命令等待超过 \(seconds) 秒，已停止。",
                en: "The local command exceeded \(seconds) seconds and was stopped."
            )
        }
        if let explicit = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return .raw(
                explicit.replacingOccurrences(of: "ERROR:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        if let last = lines.last, last.count < 280 {
            return .raw(last)
        }
        return fallback
    }

    private func setError(zh: String, en: String) {
        let message = BilingualText(zh: zh, en: en)
        cancelDiagnosticExplanation(resetFingerprint: true)
        userFacingErrorMessage = message
        diagnosticPresentation = DiagnosticPresentation(
            title: BilingualText(zh: "需要处理一个问题", en: "Something needs attention"),
            summary: message,
            steps: [DiagnosticStep(
                zh: "检查相关设置后重试。",
                en: "Check the related settings and try again."
            )],
            category: "application",
            affectedItems: [],
            aiParticipated: false,
            technicalMessage: message
        )
        technicalDetailsExpanded = false
        isErrorPresented = true
    }

    private func setError(_ message: BilingualText, contextZh: String, contextEn: String) {
        let contextualMessage = BilingualText(
            zh: "\(contextZh)：\(message.zh)",
            en: "\(contextEn): \(message.en)"
        )
        cancelDiagnosticExplanation(resetFingerprint: true)
        userFacingErrorMessage = contextualMessage
        diagnosticPresentation = DiagnosticPresentation(
            title: BilingualText(zh: contextZh, en: contextEn),
            summary: contextualMessage,
            steps: [DiagnosticStep(
                zh: "检查相关设置后重试。",
                en: "Check the related settings and try again."
            )],
            category: "application",
            affectedItems: [],
            aiParticipated: false,
            technicalMessage: message
        )
        technicalDetailsExpanded = false
        isErrorPresented = true
    }

    private func clearAIReviewResult() {
        aiReviewPassed = false
        aiReviewVerdictMessage = nil
        aiReviewSummaryMessage = nil
    }

    private func appendLog(zh: String, en: String) {
        appendLogEntry(BilingualText(zh: zh, en: en))
    }

    private func appendRawLog(_ line: String) {
        // Python/Node output stays byte-for-byte intact in both interface languages.
        appendLogEntry(.raw(line))
    }

    private func appendLogEntry(_ message: BilingualText) {
        logEntries.append(AppLogEntry(timestamp: Date(), message: message))
        if logEntries.count > 240 {
            logEntries.removeFirst(logEntries.count - 240)
        }
    }

    @discardableResult
    private func launchPython(
        arguments: [String],
        timeoutSeconds: TimeInterval? = nil,
        reportsLaunchFailure: Bool = true,
        onText: @escaping (String) -> Void,
        completion: @escaping (Int32, String) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AppConstants.pythonPath)
        process.arguments = arguments
        process.currentDirectoryURL = AppConstants.projectRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = AppConstants.projectRoot.appendingPathComponent("src").path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let capture = ProcessCapture()

        let stream: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capture.append(data)
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { onText(text) }
        }
        standardOutput.fileHandleForReading.readabilityHandler = stream
        standardError.fileHandleForReading.readabilityHandler = stream

        process.terminationHandler = { finished in
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            capture.append(standardOutput.fileHandleForReading.readDataToEndOfFile())
            capture.append(standardError.fileHandleForReading.readDataToEndOfFile())
            let output = capture.text()
            DispatchQueue.main.async {
                completion(finished.terminationStatus, output)
            }
        }

        do {
            try process.run()
            if let timeoutSeconds {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    guard process.isRunning else { return }
                    let timeoutMessage = "\nERROR: LOCAL_PROCESS_TIMEOUT:\(Int(timeoutSeconds))\n"
                    capture.append(Data(timeoutMessage.utf8))
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
            return process
        } catch {
            if reportsLaunchFailure {
                setError(
                    zh: "无法启动本地处理程序：\(error.localizedDescription)",
                    en: "Could not start the local processor: \(error.localizedDescription)"
                )
                appendLog(
                    zh: "错误：无法启动本地处理程序：\(error.localizedDescription)",
                    en: "Error: could not start the local processor: \(error.localizedDescription)"
                )
            }
            return nil
        }
    }
}

@main
struct AdReportAgentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Ad Report Agent") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 960, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.quietLine)
            ZStack {
                if model.showsWorkspace {
                    workspace
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    setupCanvas
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .animation(.easeInOut(duration: 0.28), value: model.showsWorkspace)
        }
        .background(Color.canvas)
        .alert(model.userFacingErrorTitle, isPresented: $model.isErrorPresented) {
            Button(t("查看详情", "View Details")) { model.isDetailsPresented = true }
            Button(t("知道了", "OK"), role: .cancel) {}
        } message: {
            Text(model.userFacingAlertMessage)
        }
        .sheet(isPresented: $model.isDetailsPresented) {
            DiagnosticDetailsView()
                .environmentObject(model)
        }
        .sheet(item: $model.selectedWeeklyInsight) { insight in
            WeeklyInsightDetailsView(insight: insight)
                .environmentObject(model)
        }
        .onAppear {
            model.checkModelStatus()
            if model.inputKind == .folder, model.inputDiscoveryState == .empty {
                model.discoverInputFolder()
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            model.checkModelStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.actionGreen)
                    .frame(width: 27, height: 27)
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Ad Report Agent")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.graphite)
                Text(t("自动生成每周广告报告", "Automated weekly ad reports"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondaryInk)
            }
            Spacer()
            if model.isPreparingGeneration || model.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.overallStatusTitle)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.secondaryInk)
            } else if model.hasGeneratedWorkspace {
                Label(t("报告已生成", "Report ready"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.actionGreen)
            }
            Picker(t("界面语言", "Interface language"), selection: $model.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.selectorTitle).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 102)
            .accessibilityLabel(t("界面语言", "Interface language"))
            .accessibilityValue(model.language == .chinese ? "中文" : "English")
            .accessibilityHint(t("在中文和英文界面之间切换", "Switch between Chinese and English"))
        }
        .padding(.horizontal, 27)
        .frame(height: 70)
        .background(Color.surface)
    }

    private var setupCanvas: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text(t("把本周数据变成一份报告", "Turn this week's data into a report"))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.graphite)
                        .multilineTextAlignment(.center)
                    Text(t(
                        "选择素材文件夹，确认完整后即可生成可编辑的 PowerPoint。",
                        "Choose the input folder. Once it is complete, generate an editable PowerPoint."
                    ))
                        .font(.system(size: 14.5))
                        .foregroundStyle(Color.secondaryInk)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    compactInputSection
                    Divider().overlay(Color.quietLine).padding(.vertical, 22)
                    compactOptionsSection
                    Divider().overlay(Color.quietLine).padding(.vertical, 22)
                    setupAction
                }
                .padding(28)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.quietLine))
                .shadow(color: .black.opacity(0.045), radius: 24, y: 10)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 34)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    private var workspace: some View {
        HSplitView {
            workspaceSidebar
                .frame(minWidth: 285, idealWidth: 310, maxWidth: 345)
            if model.hasGeneratedWorkspace {
                PresentationWorkspace()
                    .environmentObject(model)
                    .frame(minWidth: 610)
            } else {
                GeneratingWorkspace()
                    .environmentObject(model)
                    .frame(minWidth: 610)
            }
        }
        .background(Color.canvas)
    }

    private var compactInputSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(t("本周素材", "This week's inputs"))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.graphite)
            DropZone().environmentObject(model)
            HStack(alignment: .top, spacing: 11) {
                Group {
                    if model.inputDiscoveryState.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.inputDiscoveryState.isProblem
                            ? "exclamationmark.circle.fill"
                            : (model.inputDiscoveryState.allowsGeneration ? "checkmark.circle.fill" : "circle.dotted"))
                            .foregroundStyle(model.inputDiscoveryState.isProblem ? Color.errorInk : Color.actionGreen)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.inputDiscoveryState.title(for: model.language))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(model.inputDiscoveryState.isProblem ? Color.errorInk : Color.graphite)
                    Text(model.inputDiscoveryState.detail(for: model.language))
                        .font(.system(size: 11))
                        .foregroundStyle(model.inputDiscoveryState.isProblem ? Color.errorInk : Color.secondaryInk)
                        .lineLimit(model.inputDiscoveryState.isProblem ? 5 : 2)
                }
                Spacer()
                if model.inputKind == .folder {
                    HStack(spacing: 12) {
                        if model.inputDiscoveryState.isProblem {
                            Button(t("查看建议", "View Guidance")) {
                                model.isDetailsPresented = true
                            }
                            .buttonStyle(TextButtonStyle())
                            .accessibilityHint(t(
                                "查看问题说明和修复步骤",
                                "View the issue summary and recovery steps"
                            ))
                        }
                        Button(t("重新识别", "Scan Again")) { model.discoverInputFolder() }
                            .buttonStyle(TextButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating || model.inputDiscoveryState.isBusy)
                    }
                } else if model.inputKind == .legacyZip {
                    Button(t("改用文件夹", "Use Folder")) { model.selectInputFolder() }
                        .buttonStyle(TextButtonStyle())
                        .disabled(model.isPreparingGeneration || model.isGenerating)
                } else {
                    Button(t("旧版 ZIP", "Legacy ZIP")) { model.selectLegacyBundle() }
                        .buttonStyle(TextButtonStyle())
                        .disabled(model.isPreparingGeneration || model.isGenerating)
                }
            }
        }
    }

    private var compactOptionsSection: some View {
        VStack(spacing: 17) {
            HStack(spacing: 14) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.secondaryInk)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("保存到", "Save to"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(abbreviated(model.outputDirectory.path))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(t("更改", "Change")) { model.selectOutputDirectory() }
                    .buttonStyle(TextButtonStyle())
                    .disabled(model.isPreparingGeneration || model.isGenerating)
            }
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .foregroundStyle(model.modelState.isReady ? Color.actionGreen : Color.secondaryInk)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("本地 AI 复核", "Local AI review"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(model.modelState.isReady
                        ? t("已就绪，仅检查语义歧义", "Ready; checks semantic ambiguity only")
                        : t("未连接，可关闭后直接生成", "Not connected; turn it off to generate"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer()
                if model.aiReviewEnabled && !model.modelState.isReady {
                    Button(t("启动", "Start")) { model.startLocalModel() }
                        .buttonStyle(TextButtonStyle())
                        .disabled(model.modelState.isBusy || model.isPreparingGeneration || model.isGenerating)
                }
                Toggle("", isOn: $model.aiReviewEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Color.actionGreen)
                    .disabled(model.isPreparingGeneration || model.isGenerating)
                    .accessibilityLabel(t("本地 AI 复核", "Local AI review"))
                    .accessibilityValue(model.aiReviewEnabled
                        ? t("已开启", "On")
                        : t("已关闭", "Off"))
                    .accessibilityHint(t(
                        "开启后使用本地模型复核并生成本周关注",
                        "Use the local model for review and weekly insights"
                    ))
            }
        }
    }

    private var setupAction: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("准备生成", "Ready to generate"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(actionHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                model.generate()
            } label: {
                HStack(spacing: 8) {
                    if model.isPreparingGeneration || model.isGenerating {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    }
                    Text(model.isPreparingGeneration
                        ? t("正在检查…", "Checking…")
                        : (model.isGenerating ? t("正在生成…", "Generating…") : t("生成 PPT", "Generate PPT")))
                }
            }
            .buttonStyle(PrimaryButtonStyle(compact: false))
            .disabled(!model.canGenerate)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var workspaceSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(
                            model.hasGeneratedWorkspace
                                ? t("报告已准备好", "Report ready")
                                : (model.userFacingError == nil
                                    ? t("正在制作报告", "Creating report")
                                    : t("需要处理一个问题", "Something needs attention")),
                            systemImage: model.hasGeneratedWorkspace
                                ? "checkmark.circle.fill"
                                : (model.userFacingError == nil ? "hourglass" : "exclamationmark.circle.fill")
                        )
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(model.userFacingError == nil ? Color.actionGreen : Color.errorInk)
                        Text(model.generatedPowerPoint?.lastPathComponent ?? model.overallStatusDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryInk)
                            .lineLimit(2)
                    }

                    SidebarSection(title: t("素材", "Inputs")) {
                        SidebarValueRow(icon: "folder.fill", title: model.inputURL?.lastPathComponent ?? "—", detail: t("8 类数据已确认", "8 input types confirmed"))
                        Button(t("更换素材文件夹", "Change input folder")) { model.selectInputFolder() }
                            .buttonStyle(TextButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating)
                    }

                    SidebarSection(title: t("本地复核", "Local review")) {
                        HStack {
                            Circle().fill(model.aiReviewPassed ? Color.actionGreen : Color.secondaryInk.opacity(0.45)).frame(width: 7, height: 7)
                            Text(model.aiReviewVerdict ?? t("已完成", "Complete"))
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                        }
                        if let summary = model.aiReviewSummary {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryInk)
                                .lineLimit(5)
                        }
                    }

                    if model.hasGeneratedWorkspace, model.weeklyInsightsState == .ready {
                        SidebarSection(title: t("本周关注", "This week")) {
                            ForEach(Array(model.weeklyInsights.prefix(3).enumerated()), id: \.offset) { index, insight in
                                Button {
                                    model.selectedWeeklyInsight = insight
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.actionGreen)
                                            .frame(width: 17, height: 17)
                                            .background(Color.softGreen)
                                            .clipShape(Circle())
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(insight.title(for: model.language))
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(Color.graphite)
                                                .lineLimit(2)
                                            Text(insight.summary(for: model.language))
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(Color.secondaryInk)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Color.secondaryInk.opacity(0.58))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(insight.title(for: model.language))
                                .accessibilityValue(insight.summary(for: model.language))
                                .accessibilityHint(t("打开关注详情", "Open insight details"))
                                if index < min(model.weeklyInsights.count, 3) - 1 {
                                    Divider().overlay(Color.quietLine)
                                }
                            }
                        }
                    } else if model.hasGeneratedWorkspace,
                              let availability = model.weeklyInsightsAvailabilityMessage {
                        SidebarSection(title: t("本周关注", "This week")) {
                            Text(availability)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryInk)
                        }
                    }

                    SidebarSection(title: t("进度", "Progress")) {
                        ForEach(Array(AppConstants.stages.enumerated()), id: \.offset) { index, title in
                            StageRow(title: title.value(for: model.language), isComplete: index < model.completedStageCount, isActive: index == model.activeStage, language: model.language)
                        }
                    }
                }
                .padding(24)
            }
            Divider().overlay(Color.quietLine)
            VStack(spacing: 10) {
                if model.hasGeneratedWorkspace {
                    Button(t("打开 PPT", "Open PPT")) { model.openPowerPoint() }
                        .buttonStyle(PrimaryButtonStyle(compact: false))
                        .frame(maxWidth: .infinity)
                    HStack {
                        Button(t("在 Finder 显示", "Show in Finder")) { model.revealPowerPoint() }
                            .buttonStyle(TextButtonStyle())
                        Spacer()
                        Button(t("查看详情", "View Details")) { model.isDetailsPresented = true }
                            .buttonStyle(TextButtonStyle())
                    }
                } else if model.userFacingError != nil {
                    Button(t("重试", "Try Again")) { model.generate() }
                        .buttonStyle(PrimaryButtonStyle(compact: false))
                        .frame(maxWidth: .infinity)
                        .disabled(!model.canGenerate)
                    Button(t("查看详情", "View Details")) { model.isDetailsPresented = true }
                        .buttonStyle(TextButtonStyle())
                }
            }
            .padding(20)
        }
        .background(Color.sidebar)
    }

    private var actionHint: String {
        if model.isPreparingGeneration {
            return t("正在确认素材完整性。", "Confirming that the inputs are complete.")
        }
        if model.isGenerating {
            return t("报告正在本机生成。", "The report is being generated locally.")
        }
        if model.aiReviewEnabled && !model.modelState.isReady {
            return t("启动本地 AI，或关闭复核后继续。", "Start local AI, or turn review off to continue.")
        }
        if model.inputURL == nil {
            return t("先选择本周素材文件夹。", "Choose this week's input folder first.")
        }
        if !model.inputDiscoveryState.allowsGeneration {
            return t("补齐素材后即可生成。", "Complete the input set to continue.")
        }
        return t("素材完整，所有处理都在这台 Mac 上完成。", "Inputs are complete. Everything runs on this Mac.")
    }

    private func t(_ zh: String, _ en: String) -> String {
        model.text(zh, en)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

#if false
    // 0.2 legacy layout is intentionally retained only as a source reference.
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionTitle(
                index: "01",
                title: t("准备素材", "Prepare inputs"),
                detail: t(
                    "选择本周素材文件夹，应用会自动识别其中的完整数据。",
                    "Choose this week's input folder; the app will recognize its complete dataset."
                )
            )

            HStack(alignment: .top, spacing: 25) {
                FormLabel(
                    title: t("素材文件夹", "Input folder"),
                    detail: t("自动递归识别", "Scanned recursively")
                )
                DropZone()
                    .environmentObject(model)
            }

            HStack(alignment: .center, spacing: 25) {
                FormLabel(
                    title: t("识别状态", "Discovery status"),
                    detail: model.inputKind == .legacyZip
                        ? t("兼容模式", "Compatibility mode")
                        : t("生成前完整性检查", "Preflight check")
                )
                HStack(spacing: 10) {
                    if model.inputDiscoveryState.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: model.inputDiscoveryState.isProblem
                            ? "exclamationmark.circle"
                            : (model.inputDiscoveryState.allowsGeneration ? "checkmark.circle.fill" : "circle.dotted"))
                            .foregroundStyle(model.inputDiscoveryState.isProblem
                                ? Color.errorInk
                                : (model.inputDiscoveryState.allowsGeneration ? Color.actionGreen : Color.secondaryInk))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.inputDiscoveryState.title(for: model.language))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(model.inputDiscoveryState.isProblem ? Color.errorInk : Color.graphite)
                        Text(model.inputDiscoveryState.detail(for: model.language))
                            .font(.system(size: 10.5))
                            .foregroundStyle(model.inputDiscoveryState.isProblem ? Color.errorInk : Color.secondaryInk)
                            .lineLimit(model.inputDiscoveryState.isProblem ? 5 : 2)
                            .fixedSize(horizontal: false, vertical: model.inputDiscoveryState.isProblem)
                    }
                    Spacer(minLength: 12)
                    if model.inputKind == .folder {
                        Button(t("重新识别", "Scan Again")) { model.discoverInputFolder() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating || model.inputDiscoveryState.isBusy)
                        Button(t("改用旧版 ZIP…", "Use Legacy ZIP…")) { model.selectLegacyBundle() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating || model.inputDiscoveryState.isBusy)
                    } else if model.inputKind == .legacyZip {
                        Button(t("改用文件夹…", "Use Folder…")) { model.selectInputFolder() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating)
                    } else {
                        Button(t("选择旧版 ZIP…", "Choose Legacy ZIP…")) { model.selectLegacyBundle() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.isPreparingGeneration || model.isGenerating)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .center, spacing: 25) {
                FormLabel(
                    title: t("输出目录", "Output folder"),
                    detail: t("保存 PPT 和校验结果", "PPT and validation results")
                )
                HStack(spacing: 12) {
                    Text(abbreviated(model.outputDirectory.path))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.graphite)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(t("更改…", "Change…")) { model.selectOutputDirectory() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(model.isPreparingGeneration || model.isGenerating)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionTitle(
                index: "02",
                title: t("本地 AI", "Local AI"),
                detail: t(
                    "Bonsai 27B 复核语义与异常；计算和版式仍由确定性规则完成。",
                    "Bonsai 27B reviews semantics and anomalies; deterministic rules handle calculations and layout."
                )
            )

            HStack(alignment: .center, spacing: 25) {
                FormLabel(title: "LM Studio", detail: AppConstants.lmDisplayName)
                HStack(spacing: 12) {
                    ModelStateIndicator(state: model.modelState, language: model.language)
                    Spacer(minLength: 12)
                    Button {
                        model.checkModelStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(IconButtonStyle())
                    .disabled(model.modelState.isBusy || model.isPreparingGeneration || model.isGenerating)
                    .help(t("重新检查模型状态", "Check model status again"))
                    .accessibilityLabel(t("刷新模型状态", "Refresh model status"))
                    .accessibilityHint(t("重新连接 LM Studio 并检查模型", "Reconnect to LM Studio and check the model"))

                    if !model.modelState.isReady {
                        Button(t("启动本地模型", "Start local model")) { model.startLocalModel() }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.modelState.isBusy || model.isPreparingGeneration || model.isGenerating)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .center, spacing: 25) {
                FormLabel(
                    title: t("AI 审核", "AI review"),
                    detail: t("建议保持开启", "Recommended")
                )
                Toggle(isOn: $model.aiReviewEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t(
                            "识别后由本地模型检查列名与语义歧义",
                            "Use the local model to check column names and semantic ambiguity"
                        ))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.graphite)
                        Text(t(
                            "原始素材和报告内容不会上传到云端。",
                            "Source files and report content are never uploaded to the cloud."
                        ))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondaryInk)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.actionGreen)
                .disabled(model.isPreparingGeneration || model.isGenerating)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.generatedPowerPoint == nil
                        ? t("生成本周报告", "Generate this week's report")
                        : t("报告已准备好", "Report ready"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.graphite)
                    Text(actionHint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(model.userFacingError == nil ? Color.secondaryInk : Color.errorInk)
                        .lineLimit(2)
                }
                Spacer()

                if model.generatedPowerPoint != nil {
                    Button(t("在 Finder 显示", "Show in Finder")) { model.revealPowerPoint() }
                        .buttonStyle(QuietButtonStyle())
                    Button(t("打开 PPT", "Open PPT")) { model.openPowerPoint() }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                } else {
                    Button {
                        model.generate()
                    } label: {
                        HStack(spacing: 8) {
                            if model.isPreparingGeneration || model.isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(model.isPreparingGeneration
                                ? t("正在复检…", "Rechecking…")
                                : (model.isGenerating
                                ? t("正在生成…", "Generating…")
                                : t("生成 PPT", "Generate PPT"))
                            )
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: false))
                    .disabled(!model.canGenerate)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityHint(actionHint)
                }
            }
            if model.generatedPowerPoint != nil, let verdict = model.aiReviewVerdict {
                Divider().overlay(Color.quietLine)
                HStack(alignment: .top, spacing: 25) {
                    FormLabel(
                        title: t("AI 审核结论", "AI review result"),
                        detail: model.aiReviewSidecarURL?.lastPathComponent ?? t("本地审核", "Local review")
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verdict)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(model.aiReviewPassed ? Color.actionGreen : Color.graphite)
                        if let summary = model.aiReviewSummary {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryInk)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var progressAndLogs: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionTitle(
                index: "03",
                title: t("运行记录", "Run log"),
                detail: t(
                    "进度和错误会实时显示在这里。",
                    "Progress and errors appear here in real time."
                )
            )
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(AppConstants.stages.enumerated()), id: \.offset) { index, title in
                        StageRow(
                            title: title.value(for: model.language),
                            isComplete: index < model.completedStageCount,
                            isActive: index == model.activeStage,
                            language: model.language
                        )
                    }
                }
                .frame(width: 150, alignment: .leading)

                Divider().overlay(Color.quietLine)

                LogView(lines: model.logLines)
                    .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 150)
            }
        }
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(Color.quietLine)
            .padding(.vertical, 23)
    }

    private var actionHint: String {
        if let error = model.userFacingError { return error }
        if let output = model.generatedPowerPoint { return output.path }
        if model.isPreparingGeneration {
            return t("正在生成前重新识别文件夹…", "Rechecking the folder before generation…")
        }
        if model.isGenerating {
            return t("正在生成报告…", "Report generation is in progress…")
        }
        if model.aiReviewEnabled && !model.modelState.isReady {
            return t(
                "请先启动本地模型，或关闭 AI 审核。",
                "Start the local model, or turn off AI review."
            )
        }
        if model.inputURL == nil {
            return t(
                "选择素材文件夹后即可开始，通常需要一到两分钟。",
                "Choose the input folder to begin. Generation usually takes one or two minutes."
            )
        }
        if !model.inputDiscoveryState.allowsGeneration {
            return model.inputDiscoveryState.detail(for: model.language)
        }
        return t("素材和输出位置已就绪。", "Inputs and output folder are ready.")
    }

    private func t(_ zh: String, _ en: String) -> String {
        model.text(zh, en)
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
#endif
}

private struct SectionTitle: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.actionGreen)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.graphite)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryInk)
            Spacer()
        }
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.secondaryInk)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarValueRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.graphite)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondaryInk)
            }
        }
    }
}

private struct PresentationWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text("报告预览", "Report preview"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.graphite)
                    Text(model.generatedPowerPoint?.lastPathComponent ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                }
                Spacer()
                if !model.previewImages.isEmpty {
                    Text("\(model.selectedPreviewIndex + 1) / \(model.previewImages.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 62)
            .background(Color.surface)

            Divider().overlay(Color.quietLine)

            VStack(spacing: 20) {
                Group {
                    if let preview = model.selectedPreviewURL,
                       let image = NSImage(contentsOf: preview) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .id(preview)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.on.rectangle.slash")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(Color.secondaryInk.opacity(0.6))
                            Text(model.text("预览暂不可用", "Preview unavailable"))
                                .font(.system(size: 15, weight: .semibold))
                            Text(model.text("PPT 已生成，可以直接打开查看。", "The PPT is ready and can be opened directly."))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondaryInk)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.surface)
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.13), radius: 24, y: 9)
                .animation(.easeOut(duration: 0.18), value: model.selectedPreviewIndex)

                if !model.previewImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(model.previewImages.enumerated()), id: \.offset) { index, url in
                                Button { model.selectedPreviewIndex = index } label: {
                                    if let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .frame(width: 108)
                                            .background(Color.white)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                    .stroke(index == model.selectedPreviewIndex ? Color.actionGreen : Color.quietLine, lineWidth: index == model.selectedPreviewIndex ? 2 : 1)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(model.text("第 \(index + 1) 页", "Slide \(index + 1)"))
                            }
                        }
                    }
                    .frame(height: 74)
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        }
    }
}

private struct GeneratingWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text("报告预览", "Report preview"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(model.overallStatusTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 62)
            .background(Color.surface)
            Divider().overlay(Color.quietLine)

            VStack(spacing: 18) {
                if model.userFacingError == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.actionGreen)
                    Text(model.overallStatusDetail)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.graphite)
                    Text(model.text("数据和演示文稿都只在这台 Mac 上处理。", "Data and presentation files stay on this Mac."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondaryInk)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.errorInk)
                    Text(model.text("报告还没有完成", "The report is not complete yet"))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(model.userFacingError ?? "")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondaryInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        }
    }
}

private struct DiagnosticDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.userFacingErrorTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(model.isDiagnosticExplanationLoading
                        ? model.text("正在整理更清晰的处理建议…", "Preparing clearer recovery guidance…")
                        : (model.diagnosticWasAIExplained
                            ? model.text("本地 AI 已根据错误类型整理建议", "Local AI organized guidance from the error type")
                            : model.text("下面的步骤不会改动现有文件", "The steps below will not change existing files")))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer()
                if model.isDiagnosticExplanationLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(model.text("正在解释问题", "Explaining the issue"))
                }
                Button(model.text("完成", "Done")) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
            }

            if let summary = model.userFacingError {
                Text(summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(model.text("问题说明", "Issue summary"))
                    .accessibilityValue(summary)
            } else {
                Label(
                    model.text("报告和校验结果已保存。", "The report and validation results were saved."),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.actionGreen)
            }

            if !model.diagnosticAffectedItemLabels.isEmpty {
                Label(
                    model.text(
                        "需处理：\(model.diagnosticAffectedItemLabels.joined(separator: "、"))",
                        "Needs attention: \(model.diagnosticAffectedItemLabels.joined(separator: ", "))"
                    ),
                    systemImage: "doc.badge.ellipsis"
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.graphite)
                .accessibilityLabel(model.text("需要处理的素材", "Inputs needing attention"))
                .accessibilityValue(model.diagnosticAffectedItemLabels.joined(separator: ", "))
            }

            if !model.userFacingErrorSteps.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    Text(model.text("建议这样处理", "What to do next"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                    ForEach(Array(model.userFacingErrorSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.actionGreen)
                                .frame(width: 20, height: 20)
                                .background(Color.softGreen)
                                .clipShape(Circle())
                            Text(step)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.graphite)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(model.text("步骤 \(index + 1)", "Step \(index + 1)"))
                        .accessibilityValue(step)
                    }
                }
            }

            Spacer(minLength: 8)

            if model.diagnosticTechnicalMessage != nil || model.diagnosticCategory != nil {
                DisclosureGroup(
                    isExpanded: $model.technicalDetailsExpanded,
                    content: {
                        VStack(alignment: .leading, spacing: 9) {
                            if let category = model.diagnosticCategoryLabel {
                                Text(model.text("问题类型：\(category)", "Issue type: \(category)"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            if !model.diagnosticAffectedItemLabels.isEmpty {
                                Text(model.text(
                                    "涉及：\(model.diagnosticAffectedItemLabels.joined(separator: "、"))",
                                    "Affected: \(model.diagnosticAffectedItemLabels.joined(separator: ", "))"
                                ))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            if let technical = model.diagnosticTechnicalMessage {
                                Text(technical)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.secondaryInk)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 8)
                    },
                    label: {
                        Text(model.text("技术详情", "Technical Details"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                )
                .tint(Color.secondaryInk)
                .accessibilityHint(model.text(
                    "展开后显示错误类型和原始错误信息",
                    "Expand to show the error type and original error message"
                ))
            }

            HStack {
                Spacer()
                Button(model.text("复制诊断", "Copy diagnostics")) {
                    let lines = [model.userFacingErrorTitle, model.userFacingError ?? ""]
                        + model.userFacingErrorSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }
                        + [model.diagnosticTechnicalMessage ?? ""]
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        lines.filter { !$0.isEmpty }.joined(separator: "\n"),
                        forType: .string
                    )
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.userFacingError == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 440)
        .background(Color.surface)
    }
}

private struct WeeklyInsightDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let insight: WeeklyInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.text("本周关注", "This week"))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.actionGreen)
                    Text(insight.title(for: model.language))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button(model.text("完成", "Done")) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
            }

            Text(insight.summary(for: model.language))
                .font(.system(size: 14))
                .foregroundStyle(Color.graphite)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Color.quietLine)

            if !insight.evidence(for: model.language).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.text("判断依据", "Evidence"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                    ForEach(Array(insight.evidence(for: model.language).enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(Color.actionGreen)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(evidence)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.graphite)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(minWidth: 600, minHeight: 430)
        .background(Color.surface)
        .accessibilityElement(children: .contain)
    }
}

private struct FormLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.graphite)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondaryInk)
        }
        .frame(width: 125, alignment: .leading)
    }
}

private struct DropZone: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.selectInputFolder() } label: {
            HStack(spacing: 13) {
                Image(systemName: model.inputURL == nil ? "folder.badge.plus" : (model.inputKind == .folder ? "folder.fill" : "doc.zipper"))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(model.isDropTargeted ? Color.actionGreen : Color.secondaryInk)
                    .frame(width: 27)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.inputURL?.lastPathComponent ?? model.text(
                        "拖入文件夹，或点此选择",
                        "Drop a folder, or click to choose"
                    ))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.graphite)
                        .lineLimit(1)
                    Text(model.inputURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? model.text("文件不会离开本机", "Files stay on this Mac"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(model.inputURL == nil
                    ? model.text("选择文件夹", "Choose Folder")
                    : model.text("重新选择", "Choose Again"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.actionGreen)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(model.isDropTargeted ? Color.softGreen : Color.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        model.isDropTargeted ? Color.actionGreen : Color.quietLine,
                        style: StrokeStyle(lineWidth: model.isDropTargeted ? 1.5 : 1, dash: model.inputURL == nil ? [5, 4] : [])
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingGeneration || model.isGenerating)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
        }
        .accessibilityLabel(model.text("每周素材文件夹", "Weekly input folder"))
        .accessibilityHint(model.text(
            "点击选择，或将素材文件夹拖到这里",
            "Click to choose, or drop an input folder here"
        ))
    }
}

private struct ModelStateIndicator: View {
    let state: LocalModelState
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(state.isReady ? Color.actionGreen : Color.secondaryInk.opacity(0.45))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title(for: language))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.graphite)
                Text(state.detail(for: language))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StageRow: View {
    let title: String
    let isComplete: Bool
    let isActive: Bool
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(isComplete || isActive ? Color.actionGreen : Color.quietLine, lineWidth: 1.2)
                    .frame(width: 17, height: 17)
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.actionGreen)
                } else if isActive {
                    Circle()
                        .fill(Color.actionGreen)
                        .frame(width: 5, height: 5)
                }
            }
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isComplete || isActive ? Color.graphite : Color.secondaryInk.opacity(0.72))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(BilingualText(
            zh: isComplete ? "已完成" : (isActive ? "进行中" : "未开始"),
            en: isComplete ? "Completed" : (isActive ? "In progress" : "Not started")
        ).value(for: language))
    }
}

private struct StatusDot: View {
    let active: Bool
    let label: String
    let language: AppLanguage

    var body: some View {
        Circle()
            .fill(active ? Color.actionGreen : Color.secondaryInk.opacity(0.38))
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
            .accessibilityValue(BilingualText(
                zh: active ? "活动" : "空闲",
                en: active ? "Active" : "Idle"
            ).value(for: language))
            .accessibilityHidden(true)
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.graphite.opacity(0.83))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .background(Color.graphite.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onChange(of: lines.count) { count in
                if count > 0 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
            .padding(.horizontal, compact ? 16 : 21)
            .frame(height: compact ? 34 : 38)
            .background(Color.actionGreen.opacity(
                !isEnabled ? 0.42 : (configuration.isPressed ? 0.82 : 1)
            ))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.graphite.opacity(isEnabled ? 1 : 0.46))
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(configuration.isPressed ? Color.black.opacity(0.07) : Color.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.quietLine, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.secondaryInk.opacity(isEnabled ? 1 : 0.38))
            .frame(width: 29, height: 29)
            .background(configuration.isPressed ? Color.black.opacity(0.065) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct TextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.actionGreen.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38))
            .contentShape(Rectangle())
    }
}
