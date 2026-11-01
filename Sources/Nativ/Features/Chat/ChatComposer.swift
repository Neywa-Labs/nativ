import AppKit
import Foundation
import SwiftUI

private struct ChatContextWindowUsage: Equatable {
    let usedTokens: Int
    let capacityTokens: Int
    let apcEnabled: Bool
    let promptTokens: Int?
    let cachedTokens: Int?
    let uncachedPromptTokens: Int?
    let cacheReuseFraction: Double?

    var usedFraction: Double {
        guard capacityTokens > 0 else { return 0 }
        return min(max(Double(usedTokens) / Double(capacityTokens), 0), 1)
    }

    var remainingPercentage: Int {
        Int(((1 - usedFraction) * 100).rounded())
    }
}

@MainActor
private enum ChatContextWindowFormatting {
    static let percentageFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let tokenCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func percentage(_ fraction: Double) -> String {
        percentageFormatter.string(from: NSNumber(value: fraction))
            ?? "\(Int((fraction * 100).rounded()))%"
    }

    static func tokenCount(_ value: Int) -> String {
        tokenCountFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func compactTokenCount(_ value: Int) -> String {
        guard value >= 1_000 else { return tokenCount(value) }
        let thousands = (Double(value) / 1_000).formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(thousands)k"
    }
}

private struct ChatContextWindowRing: View, Equatable {
    let usage: ChatContextWindowUsage
    @State private var showsDetails = false
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usage == rhs.usage
    }

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            ring
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(isHovered || showsDetails ? 0.10 : 0), in: Circle())
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered || showsDetails)
        .help("View context capacity and prompt cache reuse")
        .background {
            NativArrowlessPopoverPresenter(
                isPresented: $showsDetails, gap: 6, alignment: .leading,
                cornerRadius: 12, title: "Context window",
                anchorTogglesPresentation: true
            ) {
                ChatContextWindowDetails(usage: usage)
            }
        }
        .accessibilityLabel("Model context window")
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityHint("Show context and cache details")
        .accessibilityIdentifier("chatContextWindowButton")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(isHovered || showsDetails ? 0.45 : 0.28), lineWidth: 2)

            Circle()
                .trim(from: 0, to: usage.usedFraction)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        let context = "\(usage.remainingPercentage) percent remaining, "
            + "\(ChatContextWindowFormatting.tokenCount(usage.usedTokens)) of "
            + "\(ChatContextWindowFormatting.tokenCount(usage.capacityTokens)) tokens used"
        return usage.apcEnabled
            ? context + ", cached tokens for the last response: "
                + (usage.cachedTokens.map(ChatContextWindowFormatting.tokenCount) ?? "Not reported")
            : context
    }

    private var ringColor: Color {
        switch usage.usedFraction {
        case ..<0.75:
            .primary.opacity(0.9)
        case ..<0.9:
            .orange
        default:
            .red
        }
    }

}

private struct ChatContextWindowDetails: View {
    let usage: ChatContextWindowUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Context capacity", detail: "\(ChatContextWindowFormatting.percentage(1 - usage.usedFraction)) available")
                HStack(alignment: .firstTextBaseline) {
                    percentageLabel(ChatContextWindowFormatting.percentage(usage.usedFraction), label: "used")
                    Spacer(minLength: 8)
                    Text("\(ChatContextWindowFormatting.compactTokenCount(usage.usedTokens)) / \(ChatContextWindowFormatting.compactTokenCount(usage.capacityTokens)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                usageBar(usage.usedFraction, color: .secondary)
            }
            if usage.apcEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Last prompt cache", detail: "APC on")
                    if let fraction = usage.cacheReuseFraction {
                        percentageLabel(fraction.formatted(.percent.precision(.fractionLength(0...1))), label: "reused")
                        usageBar(fraction, color: .green.opacity(0.55))
                    } else {
                        Text("Reuse rate not reported")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let cachedTokens = usage.cachedTokens {
                            if let processedTokens = usage.uncachedPromptTokens {
                                Text("\(tokenCount(cachedTokens)) reused · \(tokenCount(processedTokens)) processed")
                            } else {
                                Text("\(tokenCount(cachedTokens)) reused · processed count unavailable")
                            }
                        }
                        if let promptTokens = usage.promptTokens {
                            Text("\(tokenCount(promptTokens)) prompt tokens in total")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .frame(width: 242)
        .padding(16)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func percentageLabel(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 21, weight: .medium))
            Text(label)
        }
    }

    private func usageBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func tokenCount(_ count: Int) -> String {
        ChatContextWindowFormatting.tokenCount(count)
    }
}

private struct ChatAttachmentThumbnail: View {
    let attachment: ChatImageAttachment
    var width: CGFloat = 120
    var height: CGFloat = 90

    var body: some View {
        Group {
            if attachment.chatAttachmentKind == .image,
               let data = attachment.imageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .background(Color.white)
            } else {
                FileTypeIcon(fileExtension: attachment.fileExtension, size: 26)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help(attachment.filename)
    }
}

private enum ChatReasoningLevel: String, CaseIterable, Identifiable {
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case max = "Max"

    var id: Self { self }

    var tokenBudget: Int? {
        switch self {
        case .off, .max:
            nil
        case .low:
            512
        case .medium:
            2_048
        case .high:
            8_192
        }
    }

    var detail: String {
        switch self {
        case .off:
            ""
        case .low:
            "Max 512 tokens"
        case .medium:
            "Max 2,048 tokens"
        case .high:
            "Max 8,192 tokens"
        case .max:
            "Unlimited"
        }
    }

}

private struct ChatBrowsingAvailability: Sendable {
    let isSearchAvailable: Bool
    let isReadAvailable: Bool
    let searchProviderLabel: String?
    let readProviderLabel: String?

    static func load() -> Self {
        let preferences = WebBrowsingPreferences()
        let isSearchAvailable = ChatWebSearchToolRegistry.isConfigured()
        let isReadAvailable = ChatWebReadToolRegistry.isConfigured()

        return Self(
            isSearchAvailable: isSearchAvailable,
            isReadAvailable: isReadAvailable,
            searchProviderLabel: isSearchAvailable
                ? preferences.searchProvider.metadata.displayName
                : nil,
            readProviderLabel: isReadAvailable
                ? preferences.provider(for: .read)?.metadata.displayName
                : nil
        )
    }
}

struct ChatComposer<ContextHeader: View>: View {
    var model: NativModel
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var extensionManager: NativExtensionManager
    @Environment(\.openExtensionsHubSection) private var openExtensionsHubSection
    @Environment(\.undoManager) private var undoManager
    @StateObject private var localLibrary = LocalModelLibrary()
    let unavailableReason: String?
    let canCompose: Bool
    let canSend: Bool
    let workspaceMode: ChatWorkspaceMode
    let onSelectWorkspaceMode: (ChatWorkspaceMode) -> Void
    let onFindDraftModels: (String) -> Void
    let onAttachmentDropTargetChange: (Bool) -> Void
    let onSend: (Bool, Bool) -> Void
    let onBackdropHeightChange: (CGFloat) -> Void
    let contextHeader: ContextHeader
    @State private var editorContentHeight: CGFloat = 0
    @State private var didApplyInitialReasoningDefault = false
    @State private var showsKits = false
    @State private var showsCapabilities = false
    @State private var showsAddPanel = false
    @State private var isWebSearchAvailable = false
    @State private var isWebReadAvailable = false
    @State private var webSearchProviderLabel: String?
    @State private var webReadProviderLabel: String?
    @State private var browsingConfigurationRevision = 0
    @State private var composerWidth: CGFloat = 410
    @State private var workspacePickerWidth: CGFloat = 120
    @State private var accessPickerWidth: CGFloat = 30
    @State private var modelPickerWidth: CGFloat = 180
    private let textInset = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    private let editorMinimumHeight: CGFloat = 64
    private let editorMaximumHeight: CGFloat = 120
    private let composerVerticalPadding: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.promptEditContext != nil {
                ChatPromptEditBanner(
                    onCancel: viewModel.cancelPromptEditing
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Group {
                if viewModel.isCurrentSessionSending, let sendingStartedAt = viewModel.sendingStartedAt {
                    ChatGenerationStatusRow(
                        startedAt: sendingStartedAt,
                        metrics: viewModel.currentSessionLiveResponseMetrics
                    )
                    .equatable()
                    .padding(.horizontal, textInset.leading + 4)
                    .transition(.opacity)
                } else if let unavailableReason {
                    Text(unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, textInset.leading + 4)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isCurrentSessionSending)

            if !viewModel.currentSessionQueuedPrompts.isEmpty {
                ChatQueueTray(
                    prompts: viewModel.currentSessionQueuedPrompts,
                    onSteer: viewModel.steerQueuedRequest,
                    onPrioritize: viewModel.prioritizeQueuedRequest,
                    onRemove: viewModel.removeQueuedRequest
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                contextHeader.padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 0) {
                    if !viewModel.pendingPastedTexts.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.pendingPastedTexts) { item in
                                    ChatPastedTextCard(pastedText: item, onRemove: {
                                        viewModel.removePendingPastedText(item.id, undoManager: undoManager)
                                    })
                                }
                            }
                            .padding(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    }
                    if !viewModel.pendingAnnotations.isEmpty {
                        ChatAnnotationCards(
                            annotations: viewModel.pendingAnnotations,
                            allowsRemoval: true
                        )
                        .padding(12)
                    }
                    ZStack(alignment: .topLeading) {
                        ChatComposerTextEditor(
                            text: $viewModel.composerText,
                            isEnabled: canCompose,
                            onSubmit: send,
                            onCancel: cancelPromptEditingAction,
                            onRecallPrevious: recallPreviousPrompt,
                            onPasteImage: { viewModel.attachAttachments(from: $0) },
                            onContentHeightChange: { height in
                                editorContentHeight = height
                            },
                            acceptsImageDrops: true,
                            onImageDropTargetChange: onAttachmentDropTargetChange,
                            maximumHeight: editorMaximumHeight,
                            fontScale: model.settings.chatFontScale,
                            focusToken: viewModel.composerFocusToken,
                            focusOnAppearance: !viewModel.pendingAnnotations.isEmpty,
                            forwardsKeysToPendingDecision: viewModel.pendingImageAttachments
                                .isEmpty
                                && viewModel.pendingPastedTexts.isEmpty
                                && viewModel.promptEditContext == nil,
                            onNavigatePendingSelection: viewModel.moveImageModelHighlight,
                            onCancelPendingDecision: viewModel.cancelPendingToolDecision,
                            onPasteText: viewModel.attachPastedText,
                            onTextEdit: viewModel.editComposerText,
                            onTextCommit: viewModel.commitComposerText,
                            resetToken: viewModel.composerResetToken
                        )

                        if viewModel.composerText.isEmpty {
                            HStack(spacing: 8) {
                                Text(viewModel.promptEditContext == nil ? "Message" : "Edit message")
                                if showsRecallHint {
                                    ChatRecallHint()
                                }
                            }
                            .font(ChatFontMetrics.bodyFont(scale: model.settings.chatFontScale))
                            .foregroundStyle(.tertiary)
                            .padding(textInset)
                            .offset(x: 4)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(height: editorHeight)

                    if !viewModel.pendingImageAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.pendingImageAttachments) { attachment in
                                    ChatPendingImageAttachmentView(
                                        attachment: attachment,
                                        validation: viewModel.attachmentValidation(for: attachment.id),
                                        modelRejectsImage: modelLacksVision
                                            && attachment.chatAttachmentKind == .image
                                    ) {
                                        viewModel.removePendingImageAttachment(attachment.id)
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }

                    if !attachmentNotices.isEmpty {
                        ChatAttachmentNoticesView(
                            notices: attachmentNotices,
                            onDismiss: dismissAttachmentNotice
                        )
                    }

                    HStack(spacing: 8) {
                        ChatComposerAddButton(
                            isEnabled: canCompose,
                            isPresented: $showsAddPanel
                        )
                        .frame(width: 30, height: 30)
                        .help("More message options")

                        ChatWorkspacePicker(
                            selection: workspaceMode,
                            onSelect: onSelectWorkspaceMode
                        )
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspacePickerWidth = $0 }

                        ChatAccessPicker(selection: viewModel.currentAccessMode,
                                         onSelect: viewModel.setAccessMode)
                            .fixedSize()
                            .disabled(viewModel.isLoadingSessions || viewModel.isCurrentSessionSending)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { accessPickerWidth = $0 }

                        Spacer(minLength: 12)

                        if let contextWindowUsage {
                            ChatContextWindowRing(usage: contextWindowUsage)
                                .equatable()
                        }

                        modelPicker
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { modelPickerWidth = $0 }

                        Button {
                            if showsStopButton {
                                viewModel.cancel()
                            } else {
                                send()
                            }
                        } label: {
                            Image(systemName: showsStopButton ? "stop.fill" : "arrow.up")
                                .font(.system(size: showsStopButton ? 10 : 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(actionButtonColor, in: Circle())
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!showsStopButton && !effectiveCanSend)
                        .help(actionButtonHelp)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                onBackdropHeightChange(height + (composerVerticalPadding * 2))
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                composerWidth = width
            }
            .background {
                NativArrowlessPopoverPresenter(isPresented: $showsAddPanel) {
                    addPanel
                }
            }
        }
        .padding(.vertical, composerVerticalPadding)
        .preference(key: ChatComposerMinimumWidthKey.self, value: minimumControlsWidth)
        .task(id: modelScanKey) {
            localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        }
        .task(id: browsingConfigurationRevision) {
            await refreshBrowsingAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .webBrowsingConfigurationDidChange)) { _ in
            browsingConfigurationRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            localLibrary.scan(searchPaths: model.settings.localModelSearchPaths)
        }
        .onChange(of: localLibrary.models) { _, models in
            disableThinkingIfUnsupported(modelID: selectedModelID, models: models)
            applyInitialReasoningDefaultIfNeeded(modelID: selectedModelID, models: models)
        }
        .onChange(of: selectedModelID) { oldModelID, newModelID in
            applyModelConfigOnSwitch(from: oldModelID, to: newModelID, models: localLibrary.models)
        }
        .onChange(of: model.settings.currentModelProfile) { _, _ in
            guard let modelID = selectedModelID, !modelID.isEmpty else {
                return
            }
            model.settings.rememberProfile(forModel: modelID)
        }
        .onDisappear {
            localLibrary.cancel()
        }
        .sheet(isPresented: $showsKits) {
            ChatKitsPickerSheet(
                model: model,
                manager: extensionManager
            )
        }
        .sheet(isPresented: $showsCapabilities) {
            ChatCapabilitiesSheet(model: model)
        }
    }

    private var controlsSizing: ChatComposerControlsSizing {
        ChatComposerControlsSizing(workspaceWidth: workspacePickerWidth,
                                  accessWidth: accessPickerWidth, modelWidth: modelPickerWidth,
                                  showsContext: contextWindowUsage != nil)
    }

    private var minimumControlsWidth: CGFloat { controlsSizing.minimumWidth }

    private var addPanel: some View {
        ChatComposerActionPanel(
            canPasteImage: viewModel.canPasteImage,
            showsGlobalTools: true,
            isWebSearchEnabled: globalToolIsEnabled(
                ChatWebSearchToolRegistry.toolName,
                isAvailable: isWebSearchAvailable
            ),
            isWebSearchAvailable: isWebSearchAvailable,
            webSearchProviderLabel: webSearchProviderLabel,
            isWebReadEnabled: globalToolIsEnabled(
                ChatWebReadToolRegistry.toolName,
                isAvailable: isWebReadAvailable
            ),
            isWebReadAvailable: isWebReadAvailable,
            webReadProviderLabel: webReadProviderLabel,
            onAttachImages: { dismissAddPanelAndPerform(viewModel.chooseAttachments) },
            onPasteImage: { dismissAddPanelAndPerform(viewModel.pasteImageFromClipboard) },
            onCaptureScreenshot: { dismissAddPanelAndPerform(viewModel.captureScreenshot) },
            onToggleWebSearch: {
                toggleGlobalBrowsingTool(
                    ChatWebSearchToolRegistry.toolName,
                    isAvailable: isWebSearchAvailable
                )
            },
            onToggleWebRead: {
                toggleGlobalBrowsingTool(
                    ChatWebReadToolRegistry.toolName,
                    isAvailable: isWebReadAvailable
                )
            },
            onOpenKits: { dismissAddPanelAndPerform { showsKits = true } },
            onOpenCapabilities: { dismissAddPanelAndPerform { showsCapabilities = true } }
        )
        .frame(width: max(320, composerWidth))
    }

    private func dismissAddPanelAndPerform(_ action: @escaping () -> Void) {
        showsAddPanel = false
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func globalToolIsEnabled(_ toolName: String, isAvailable: Bool) -> Bool {
        isAvailable && model.settings.isToolEnabled(toolName)
    }

    private func toggleGlobalBrowsingTool(
        _ toolName: String,
        isAvailable: Bool
    ) {
        guard isAvailable else {
            let openExtensionsHubSection = openExtensionsHubSection
            dismissAddPanelAndPerform {
                openExtensionsHubSection(.tools)
            }
            return
        }

        model.settings.setToolEnabled(
            !model.settings.isToolEnabled(toolName),
            toolName: toolName
        )
        showsAddPanel = false
    }

    private func refreshBrowsingAvailability() async {
        let availability = await Task.detached(priority: .userInitiated) {
            ChatBrowsingAvailability.load()
        }.value
        guard !Task.isCancelled else { return }

        isWebSearchAvailable = availability.isSearchAvailable
        isWebReadAvailable = availability.isReadAvailable
        webSearchProviderLabel = availability.searchProviderLabel
        webReadProviderLabel = availability.readProviderLabel
    }

    private var modelScanKey: String {
        model.settings.localModelSearchPaths.cacheKey
    }

    private var modelPicker: some View {
        ComposerModelPicker(
            models: languageModels,
            selectedModelID: selectedModelID,
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            selectedModelDetail: selectedModelSupportsThinking
                ? reasoningLevel.rawValue
                : nil,
            showsFastIndicator: model.settings.speculativeDecodingActive,
            secondarySections: modelPickerSecondarySections,
            isModelLoading: model.isModelLoading,
            modelLoadingPercentage: model.modelLoadingPercentage,
            isDisabled: model.isModelLoading || viewModel.hasPendingRequests
                || model.inferenceActivityInProgress,
            statusLabel: localModelStatusLabel,
            helpText: modelPickerHelp,
            accessibilityValue: modelPickerAccessibilityValue,
            shortcutLabel: "⌃⇧M",
            emptyStateActionTitle: nil,
            onEmptyStateAction: nil,
            onSelectModel: select,
            onSwitchModel: { model.switchLanguageModel(to: $0) }
        )
    }

    private var contextWindowUsage: ChatContextWindowUsage? {
        guard let capacity = effectiveContextWindowCapacity,
              capacity > 0 else {
            return nil
        }

        let usedTokens = viewModel.visibleMessages
            .reversed()
            .lazy
            .compactMap({ $0.responseMetrics?.totalTokens })
            .first ?? 0

        return ChatContextWindowUsage(
            usedTokens: usedTokens,
            capacityTokens: capacity,
            apcEnabled: model.metrics?.server.apc.enabled ?? model.settings.prefixCachingEnabled,
            promptTokens: viewModel.currentSessionLatestResponseMetrics?.promptTokens,
            cachedTokens: viewModel.currentSessionLatestResponseMetrics?.cachedTokens,
            uncachedPromptTokens: viewModel.currentSessionLatestResponseMetrics?.uncachedPromptTokens,
            cacheReuseFraction: viewModel.currentSessionLatestResponseMetrics?.cacheReuseFraction
        )
    }

    private var effectiveContextWindowCapacity: Int? {
        if let runtimeCapacity = model.metrics?.server.effectiveContextLimit
            ?? model.metrics?.server.configuredContextLimit
            ?? model.metrics?.server.loadedContextSize {
            return runtimeCapacity
        }

        let advertisedCapacity = selectedLocalModel?.contextSize
        guard model.settings.maxKVSize > 0 else {
            return advertisedCapacity
        }
        guard let advertisedCapacity else {
            return model.settings.maxKVSize
        }
        return min(advertisedCapacity, model.settings.maxKVSize)
    }

    private var languageModels: [LocalModel] {
        localLibrary.models.filter(\.isEligibleForLanguageModelPicker)
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var selectedModelLabel: String {
        guard let selectedModelID else {
            return "Choose Model"
        }
        return modelMenuLabel(selectedModelID)
    }

    private var modelPickerAccessibilityValue: String {
        var components = [selectedModelLabel]
        if selectedModelSupportsThinking {
            components.append("reasoning \(reasoningLevel.rawValue)")
        }
        if model.settings.speculativeDecodingActive {
            components.append("speed \(modelPickerSecondarySections.first { $0.id == "drafter" }?.selectedLabel ?? "Fast")")
        }
        let value = components.joined(separator: ", ")
        guard model.isModelLoading, let percentage = model.modelLoadingPercentage else {
            return value
        }
        return "\(value), loading \(percentage) percent"
    }

    private var modelLacksVision: Bool {
        guard let model = selectedLocalModel else { return false }
        return !model.capabilities.contains(.vision)
    }

    private var hasVisionRejectedAttachment: Bool {
        modelLacksVision && viewModel.hasPendingImageAttachments
    }

    private var effectiveCanSend: Bool {
        canSend && !hasVisionRejectedAttachment && importedContinuationIsAvailable
    }

    private var attachmentNotices: [ChatAttachmentNotice] {
        var notices: [ChatAttachmentNotice] = []
        if let importedContinuationNotice {
            notices.append(importedContinuationNotice)
        }
        let rejectedImages = modelLacksVision
            ? viewModel.pendingImageAttachments.filter { $0.chatAttachmentKind == .image }
            : []

        if !rejectedImages.isEmpty {
            notices.append(ChatAttachmentNotice(
                id: "vision-model-required",
                severity: .error,
                title: "This model can’t view images",
                message: visionModelWarningMessage(for: rejectedImages),
                systemImage: "eye.slash.fill"
            ))
        }

        for attachment in viewModel.pendingImageAttachments {
            if modelLacksVision, attachment.chatAttachmentKind == .image {
                continue
            }

            guard let validation = viewModel.attachmentValidation(for: attachment.id) else {
                continue
            }
            switch validation {
            case .processing(let message):
                notices.append(ChatAttachmentNotice(
                    id: "attachment-\(attachment.id.uuidString)",
                    severity: .progress,
                    message: message
                ))
            case .blocked(let message):
                notices.append(ChatAttachmentNotice(
                    id: "attachment-\(attachment.id.uuidString)",
                    severity: .error,
                    title: "Attachment can’t be used",
                    message: message
                ))
            case .ready:
                break
            }
        }

        if modelLacksVision,
           !viewModel.hasPendingImageAttachments,
           viewModel.hasImageAttachmentsInCurrentSession {
            notices.append(ChatAttachmentNotice(
                id: "historical-images-unavailable",
                severity: .warning,
                title: "Earlier images are unavailable",
                message: "The selected model can’t access images from earlier messages in this chat.",
                systemImage: "eye.slash.fill"
            ))
        }

        if let attachmentImportError = viewModel.attachmentImportError {
            notices.append(ChatAttachmentNotice(
                id: "attachment-import-error",
                severity: .warning,
                title: "Some files weren’t added",
                message: attachmentImportError,
                isDismissible: true
            ))
        }
        let omittedDocuments = viewModel.currentDocumentContextOmissions
        if !omittedDocuments.isEmpty {
            notices.append(ChatAttachmentNotice(
                id: "document-context-limit",
                severity: .warning,
                title: "Some documents weren’t included",
                message: documentContextWarningMessage(for: omittedDocuments),
                systemImage: "doc.badge.ellipsis",
                isDismissible: true
            ))
        }
        return notices
    }

    private var importedContinuationIsAvailable: Bool {
        viewModel.importedContinuationIsAvailable(contextWindow: selectedLocalModel?.contextSize)
    }

    private var importedContinuationNotice: ChatAttachmentNotice? {
        guard viewModel.importedModelRepositoryID != nil else {
            return nil
        }
        if let tokenCount = viewModel.importedPromptTokenCount,
           let contextWindow = selectedLocalModel?.contextSize,
           tokenCount > contextWindow {
            return ChatAttachmentNotice(
                id: "imported-chat-context-limit",
                severity: .error,
                title: "This chat can’t be continued",
                message: "Its \(tokenCount)-token history exceeds the selected model’s "
                    + "\(contextWindow)-token context window."
            )
        }
        return nil
    }

    private func documentContextWarningMessage(
        for omissions: [ChatDocumentOmission]
    ) -> String {
        if omissions.count == 1, let filename = omissions.first?.filename {
            return "The model’s context is full, so “\(filename)” wasn’t included."
        }
        let filenames = omissions.prefix(3).map { "“\($0.filename)”" }.joined(separator: ", ")
        let suffix = omissions.count > 3 ? ", and \(omissions.count - 3) more" : ""
        return "The model’s context is full, so \(filenames)\(suffix) weren’t included."
    }

    private func visionModelWarningMessage(
        for attachments: [ChatImageAttachment]
    ) -> String {
        if attachments.count == 1, let filename = attachments.first?.filename {
            return "Remove “\(filename)” or choose a vision-capable model to continue."
        }
        return "Remove these \(attachments.count) images or choose a vision-capable model to continue."
    }

    private var selectedLocalModel: LocalModel? {
        guard let selectedModelID else { return nil }
        return localLibrary.models.first { $0.repoID == selectedModelID }
    }

    private var selectedModelProvider: LocalModelProvider? {
        if let provider = selectedLocalModel?.provider {
            return provider
        }
        guard let selectedModelID else { return nil }
        return provider(for: selectedModelID)
    }

    private var selectedModelSupportsThinking: Bool {
        guard let selectedModelID else {
            return model.settings.thinkingEnabled
        }
        return modelSupportsThinking(
            selectedModelID,
            profile: model.settings.currentModelProfile
        )
    }

    private var reasoningLevel: ChatReasoningLevel {
        reasoningLevel(for: model.settings.currentModelProfile)
    }

    private func reasoningLevel(for profile: ModelConfigProfile) -> ChatReasoningLevel {
        guard profile.thinkingEnabled else {
            return .off
        }
        guard profile.thinkingBudgetEnabled,
              !speculativeDecodingActive(in: profile)
        else {
            return .max
        }

        switch profile.thinkingBudget {
        case ...512:
            return .low
        case ...2_048:
            return .medium
        default:
            return .high
        }
    }

    private var localModelStatusLabel: String {
        if localLibrary.isScanning {
            return "Scanning for models…"
        }
        return localLibrary.error ?? "No installed language models"
    }

    private func reasoningPickerSection(
        for modelID: String,
        profile: ModelConfigProfile
    ) -> ComposerModelPickerSecondarySection? {
        guard modelSupportsThinking(modelID, profile: profile) else {
            return nil
        }
        let level = reasoningLevel(for: profile)
        return ComposerModelPickerSecondarySection(
            id: "reasoning",
            title: "Reasoning",
            selectedID: level.rawValue,
            selectedLabel: level.rawValue,
            options: availableReasoningLevels(for: profile).map {
                ComposerModelPickerSecondaryOption(
                    id: $0.rawValue,
                    title: $0.rawValue,
                    detail: $0.detail
                )
            },
            onSelect: { rawValue in
                guard let level = ChatReasoningLevel(rawValue: rawValue) else {
                    return
                }
                applyReasoningLevel(level)
            }
        )
    }

    private var modelPickerSecondarySections: [ComposerModelPickerSecondarySection] {
        guard let selectedModelID else { return [] }
        return modelPickerSecondarySections(
            for: selectedModelID,
            profile: model.settings.currentModelProfile
        )
    }

    private func modelPickerSecondarySections(
        for modelID: String,
        profile: ModelConfigProfile
    ) -> [ComposerModelPickerSecondarySection] {
        [
            drafterPickerSection(for: modelID, profile: profile),
            reasoningPickerSection(for: modelID, profile: profile),
        ].compactMap { $0 }
    }

    private func modelSupportsThinking(
        _ modelID: String,
        profile: ModelConfigProfile
    ) -> Bool {
        profile.thinkingEnabled
            || localLibrary.models.first { $0.repoID == modelID }?
                .capabilities.contains(.reasoning) == true
    }

    private func compatibleDrafters(for modelID: String) -> [LocalModel] {
        guard let targetModel = localLibrary.models.first(where: {
            $0.repoID == modelID
        }) else { return [] }
        return DrafterModelCompatibility.compatibleDrafters(
            in: localLibrary.models,
            with: targetModel
        )
    }

    private func drafterPickerSection(
        for modelID: String,
        profile: ModelConfigProfile
    ) -> ComposerModelPickerSecondarySection {
        let compatibleDrafters = compatibleDrafters(for: modelID)
        let activeDraftModelID = speculativeDecodingActive(in: profile)
            ? profile.draftModelID
            : ""
        let options = ComposerModelPickerSecondaryOption.speedOptions(
            drafters: compatibleDrafters, activeID: activeDraftModelID, activeKind: profile.draftKind,
            target: localLibrary.models.first { $0.repoID == modelID }
        )

        let hasCompatibleDrafters = options.contains { !$0.id.isEmpty && $0.isEnabled }
        let needsDrafters = !hasCompatibleDrafters || options.contains { !$0.isEnabled }
        return ComposerModelPickerSecondarySection(
            id: "drafter",
            title: "Speed",
            selectedID: activeDraftModelID,
            selectedLabel: options.first { $0.id == activeDraftModelID }?.title ?? "Off",
            options: options,
            statusTitle: !hasCompatibleDrafters && localLibrary.isScanning
                ? "Scanning for drafters…"
                : nil,
            actionTitle: needsDrafters && !localLibrary.isScanning
                ? "Find Draft Models"
                : nil,
            onAction: {
                onFindDraftModels(modelID)
            },
            onSelect: selectDrafter
        )
    }

    private func speculativeDecodingActive(in profile: ModelConfigProfile) -> Bool {
        profile.speculativeDecodingEnabled
            && !profile.draftModelID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private var modelPickerHelp: String {
        if viewModel.hasPendingRequests || model.inferenceActivityInProgress {
            return "Models can’t be changed while a response is being generated."
        }
        if model.isModelLoading {
            return model.modelLoadingStatusText ?? "Loading \(selectedModelLabel)"
        }
        return "Change model"
    }

    private func modelMenuLabel(_ modelID: String) -> String {
        NativFormatting.truncateModelName(
            LocalModel.displayTitle(for: modelID),
            maxLength: 28
        )
    }

    private func select(_ localModel: LocalModel) {
        model.requestPreloadedModelSwitch(
            to: localModel,
            for: .language,
            availableModels: localLibrary.models
        ) {}
    }

    private func selectDrafter(_ drafterID: String) {
        var settings = model.settings
        if drafterID.isEmpty {
            guard settings.speculativeDecodingActive else { return }
            settings.speculativeDecodingEnabled = false
        } else {
            guard let drafter = localLibrary.models.first(where: {
                $0.repoID == drafterID
            }) else {
                return
            }
            let kind = drafter.hasBuiltInMTP && drafter.repoID == selectedModelID ? "mtp" : drafter.drafterKind ?? "auto"
            guard !settings.speculativeDecodingActive
                    || settings.draftModelID != drafter.repoID
                    || settings.draftKind != kind
            else {
                return
            }
            settings.draftModelID = drafter.repoID
            settings.draftKind = kind
            settings.speculativeDecodingEnabled = true
            settings.structuredOutputEnabled = false
            settings.thinkingBudgetEnabled = false
        }
        let requiresRestart = !model.settings.hasSameLaunchConfiguration(as: settings)
        model.settings = settings
        if requiresRestart {
            model.restartServer()
        }
    }

    private func availableReasoningLevels(
        for profile: ModelConfigProfile
    ) -> [ChatReasoningLevel] {
        guard speculativeDecodingActive(in: profile) else {
            return ChatReasoningLevel.allCases
        }
        return ChatReasoningLevel.allCases.filter { $0.tokenBudget == nil }
    }

    private func applyReasoningLevel(_ level: ChatReasoningLevel) {
        switch level {
        case .off:
            model.settings.thinkingEnabled = false
        case .max:
            model.settings.thinkingEnabled = true
            model.settings.thinkingBudgetEnabled = false
        case .low, .medium, .high:
            model.settings.thinkingEnabled = true
            if model.settings.speculativeDecodingActive {
                model.settings.thinkingBudgetEnabled = false
            } else {
                model.settings.thinkingBudgetEnabled = true
                model.settings.thinkingBudget = level.tokenBudget ?? model.settings.thinkingBudget
            }
        }
    }

    private func disableThinkingIfUnsupported(modelID: String?, models: [LocalModel]) {
        guard model.settings.thinkingEnabled,
              let modelID,
              let localModel = models.first(where: { $0.repoID == modelID }),
              !localModel.capabilities.contains(.reasoning)
        else {
            return
        }
        model.settings.thinkingEnabled = false
    }

    private func applyInitialReasoningDefaultIfNeeded(
        modelID: String?,
        models: [LocalModel]
    ) {
        guard !didApplyInitialReasoningDefault,
              let modelID,
              models.contains(where: { $0.repoID == modelID })
        else {
            return
        }

        didApplyInitialReasoningDefault = true
        if let profile = model.settings.modelProfile(for: modelID) {
            model.settings.applyProfile(profile)
            disableThinkingIfUnsupported(modelID: modelID, models: models)
        } else {
            model.settings.rememberProfile(forModel: modelID)
        }
    }

    private func applyModelConfigOnSwitch(
        from oldModelID: String?,
        to newModelID: String?,
        models: [LocalModel]
    ) {
        if let oldModelID, !oldModelID.isEmpty {
            model.settings.rememberProfile(forModel: oldModelID)
        }
        guard let newModelID, !newModelID.isEmpty else {
            return
        }
        applyModelConfig(to: newModelID, models: models)
    }

    private func applyModelConfig(to modelID: String, models: [LocalModel]) {
        if let profile = model.settings.modelProfile(for: modelID) {
            model.settings.applyProfile(profile)
            disableThinkingIfUnsupported(modelID: modelID, models: models)
            return
        }
        let isReasoning = models.first(where: { $0.repoID == modelID })?
            .capabilities.contains(.reasoning) == true
        if isReasoning {
            applyReasoningLevel(.max)
        } else {
            model.settings.thinkingEnabled = false
        }
        model.settings.speculativeDecodingEnabled = false
        model.settings.rememberProfile(forModel: modelID)
    }

    private func provider(for modelID: String) -> LocalModelProvider? {
        LocalModelProviderResolver.resolve(
            repoID: modelID,
            modelType: nil,
            architectures: []
        )
    }

    private var actionButtonColor: Color {
        if showsStopButton || effectiveCanSend {
            return .accentColor
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    /// The hint is a first-run affordance: once the gesture has been used it has
    /// taught what it was there to teach, and a permanent label in the
    /// placeholder is just noise.
    private var showsRecallHint: Bool {
        viewModel.canRecallPreviousPrompt && !model.settings.hasUsedPromptRecall
    }

    private func recallPreviousPrompt() -> Bool {
        guard viewModel.recallPreviousPrompt() else { return false }
        if !model.settings.hasUsedPromptRecall {
            model.settings.hasUsedPromptRecall = true
        }
        return true
    }

    private var cancelPromptEditingAction: (() -> Void)? {
        guard viewModel.promptEditContext != nil else {
            return nil
        }
        return viewModel.cancelPromptEditing
    }

    private var actionButtonHelp: String {
        if showsStopButton {
            return "Stop response"
        }
        if let blockingNotice = attachmentNotices.first(where: {
            $0.severity == .error || $0.severity == .progress
        }) {
            return blockingNotice.message
        }
        if viewModel.promptEditContext != nil {
            return "Save and regenerate (Return)"
        }
        return "Send (Return)"
    }

    private var showsStopButton: Bool {
        viewModel.isCurrentSessionSending && !canSend
    }

    private func send() {
        guard effectiveCanSend else { return }
        onSend(
            selectedLocalModel?.capabilities.contains(.tools) == true,
            !modelLacksVision
        )
    }

    private func dismissAttachmentNotice(_ noticeID: String) {
        switch noticeID {
        case "attachment-import-error":
            viewModel.clearAttachmentImportError()
        case "document-context-limit":
            viewModel.clearDocumentContextOmissions()
        default:
            break
        }
    }

    private var editorHeight: CGFloat {
        min(max(editorContentHeight, editorMinimumHeight), editorMaximumHeight)
    }
}

private struct ChatGenerationStatusRow: View, Equatable {
    let startedAt: Date
    let metrics: ChatResponseMetrics?

    var body: some View {
        HStack(spacing: 8) {
            if let metrics {
                ChatLiveDecodeMetricsBadge(metrics: metrics)
                    .equatable()
                    .layoutPriority(1)
                    .transition(.opacity)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(startedAt)
                Text("Working for \(NativFormatting.elapsedDuration(elapsed))…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        // Animate presence changes, not the frequent token and speed updates.
        .animation(.easeInOut(duration: 0.2), value: metrics != nil)
    }
}

private struct ChatLiveDecodeMetricsBadge: View, Equatable {
    let metrics: ChatResponseMetrics

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)

            Text("Decode")
                .foregroundStyle(.secondary)

            if let generatedTokens = metrics.generatedTokens {
                Text("\(NativFormatting.integer(generatedTokens)) tokens")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            if metrics.generatedTokens != nil,
                metrics.decodeTokensPerSecond != nil
            {
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            if let decodeTokensPerSecond = metrics.decodeTokensPerSecond {
                Text(NativFormatting.rate(decodeTokensPerSecond))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Decode metrics")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [
            metrics.generatedTokens.map { "\($0) generated tokens" },
            metrics.decodeTokensPerSecond.map(NativFormatting.rate),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// Tells you the gesture exists, in the one place you would be about to use it.
private struct ChatRecallHint: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up")
                .imageScale(.small)
            Text("to show last")
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

private struct ChatPromptEditBanner: View {
    let onCancel: () -> Void
    @State private var isCancelHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "pencil")

            Text("Edit last message")

            Spacer(minLength: 12)

            Button(action: onCancel) {
                Text("Cancel")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isCancelHovered ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .onHover { isCancelHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isCancelHovered)
            .help("Cancel editing")
        }
        .font(.caption)
        // Uniformly secondary and unaccented. This sits directly above the
        // composer while you are typing into it, so it should read as a state
        // the editor is in, not as something asking to be dealt with.
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}

private struct ChatAccessPicker: View {
    let selection: ChatAccessMode
    let onSelect: (ChatAccessMode) -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var showsOptions = false
    @State private var showsComparison = false

    var body: some View {
        Button {
            showsOptions.toggle()
        } label: {
            Label(selection.title, systemImage: selection.accessSymbol)
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(selection == .fullAccess ? Color.orange : .primary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(isEnabled && (isHovered || showsOptions) ? 0.07 : 0), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = isEnabled && $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered || showsOptions)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                isHovered = false
                showsOptions = false
            }
        }
        .accessibilityLabel("Tool access: \(selection.title)")
        .help("Choose how Nativ asks for approval")
        .background {
            NativArrowlessPopoverPresenter(isPresented: $showsOptions, alignment: .leading, title: "Access level",
                                          anchorTogglesPresentation: true) {
                ChatAccessOptions(selection: selection) { mode in
                    onSelect(mode)
                    showsOptions = false
                } onLearnMore: {
                    showsOptions = false
                    showsComparison = true
                }
            }
        }
        .sheet(isPresented: $showsComparison) {
            ChatAccessComparison()
        }
    }
}

private extension ChatAccessMode {
    var accessSymbol: String {
        switch self {
        case .standard: "hand.raised"
        case .medium: "shield.lefthalf.filled"
        case .fullAccess: "exclamationmark.shield"
        }
    }

    var accessDescription: String {
        switch self {
        case .standard: "Ask before work-pane and sensitive actions"
        case .medium: "Browse and edit; ask before sensitive actions"
        case .fullAccess: "Ask only before commands and scripts"
        }
    }
}

private struct ChatAccessOptions: View {
    let selection: ChatAccessMode
    let onSelect: (ChatAccessMode) -> Void
    let onLearnMore: () -> Void
    @State private var hoveredMode: ChatAccessMode?
    @State private var isLearnMoreHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Access level")
                    .legacyTextStyle(.supportingEmphasized)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onLearnMore) {
                    Text("Learn more")
                        .legacyTextStyle(.supportingEmphasized)
                        .underline()
                        .foregroundStyle(isLearnMoreHovered ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .onHover { isLearnMoreHovered = $0 }
                .accessibilityLabel("Learn more about access levels")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ForEach(ChatAccessMode.allCases) { mode in
                Button { onSelect(mode) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: mode.accessSymbol)
                            .font(.system(size: 15))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .legacyTextStyle(.rowTitle)
                            Text(mode.accessDescription)
                                .legacyTextStyle(.supporting)
                                .foregroundStyle(mode == .fullAccess ? Color.orange : .secondary)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                            .opacity(selection == mode ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(mode == .fullAccess ? Color.orange : .primary)
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.primary.opacity(hoveredMode == mode ? 0.07 : 0))
                    }
                }
                .buttonStyle(.plain)
                .onHover { hoveredMode = $0 ? mode : nil }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(mode.title + ". " + mode.accessDescription)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }

        }
        .padding(10)
        .frame(width: 400)
    }
}

private struct ChatAccessComparison: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tool approvals")
                    .legacyTextStyle(.sheetTitle)
                Spacer()
                NativHoverCloseButton { dismiss() }
                    .accessibilityLabel("Close access levels")
                    .keyboardShortcut(.defaultAction)
            }

            Text("When Nativ asks for approval in this chat.")
                .legacyTextStyle(.supporting)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    Text("Action").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(ChatAccessMode.allCases) { mode in
                        Text(mode.title).frame(width: 88)
                    }
                }
                .legacyTextStyle(.rowTitle)
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Read and search local files", operation: .routine)
                row("Create and edit ordinary files", operation: .routine)
                row("Edit protected instructions or configuration", operation: .sensitive)
                row("Search and read the web", operation: .routine)
                row("Generate or edit images", operation: .routine)
                row("List models and view system/server stats", operation: .routine)
                row("Switch models", operation: .sensitive)
                row("Work pane: list, read, inspect, and list attachments", operation: .workPane)
                row("Work pane: create and edit documents or code", operation: .workPane)
                row("Browser: open, search, navigate, back, forward, reload", operation: .workPane)
                row("Browser: click, type, or upload attachments", operation: .sensitive)
                row("Interrupt a terminal command", operation: .workPane)
                row("Run commands or custom scripts", operation: .command)
                row("Filesystem MCP: read, list, search, and ordinary edits", operation: .routine)
                row("Filesystem MCP: protected writes or moves", operation: .sensitive)
                row("Other MCP tools and custom endpoints", operation: .external)
            }
        }
        .padding(24)
        .frame(width: 880)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // Register Escape separately so the visible close button also handles Return.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func row(_ action: String, operation: ChatToolOperation) -> some View {
        GridRow {
            Text(action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ChatAccessMode.allCases) { mode in
                Text(mode.requiresApproval(for: operation) ? "Ask" : "Automatic")
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 88)
            }
        }
        .legacyTextStyle(.body)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action)
        .accessibilityValue(ChatAccessMode.allCases.map { mode in
            mode.title + ": " + (mode.requiresApproval(for: operation) ? "Ask" : "Automatic")
        }.joined(separator: ". "))
        Divider()
            .opacity(0.5)
            .gridCellUnsizedAxes(.horizontal)
    }
}

struct ComposerModelPicker: View {
    @State private var isPickerHovered = false
    @State private var isMenuOpen = false

    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let selectedModelDetail: String?
    let showsFastIndicator: Bool
    let secondarySections: [ComposerModelPickerSecondarySection]
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?
    let isDisabled: Bool
    let statusLabel: String
    let helpText: String
    let accessibilityValue: String
    let shortcutLabel: String?
    let emptyStateActionTitle: String?
    let onEmptyStateAction: (() -> Void)?
    let onSelectModel: (LocalModel) -> Void
    let onSwitchModel: (String) -> Void

    var body: some View {
        Button { isMenuOpen.toggle() } label: {
            pickerLabel
                .background(
                    Color.primary.opacity(isMenuOpen ? 0.1 : isPickerHovered ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcutLabel == nil ? nil : KeyboardShortcut("m", modifiers: [.control, .shift]))
        .fixedSize()
        .frame(height: 32)
        .background {
            NativArrowlessPopoverPresenter(
                isPresented: $isMenuOpen, gap: 14, alignment: .trailing,
                cornerRadius: 14, title: "Choose model", drawsSurface: false
            ) {
                ComposerModelPickerMenu(
                    models: models,
                    selectedModelID: selectedModelID,
                    selectedModelLabel: selectedModelLabel,
                    selectedModelProvider: selectedModelProvider,
                    secondarySections: secondarySections,
                    isEnabled: !isDisabled,
                    statusLabel: statusLabel,
                    emptyStateActionTitle: emptyStateActionTitle,
                    onEmptyStateAction: onEmptyStateAction,
                    onSelectModel: selectModel,
                    onDismiss: { isMenuOpen = false }
                )
            }
            .id(isMenuOpen)
        }
        .background {
            NativArrowlessPopoverPresenter(
                isPresented: tooltipPresentation, gap: 10, isInteractive: false
            ) {
                ComposerModelPickerTooltip(
                    title: pickerTooltip,
                    shortcutLabel: isDisabled ? nil : shortcutLabel
                )
            }
        }
        .disabled(isDisabled)
        .onHover { isPickerHovered = $0 }
        .onChange(of: isMenuOpen) { _, isOpen in
            if !isOpen { isPickerHovered = false }
        }
        .accessibilityLabel("Model")
        .accessibilityValue(accessibilityValue)
    }

    private func selectModel(_ modelID: String) {
        guard !isDisabled else { return }
        isMenuOpen = false
        if let model = models.first(where: { $0.repoID == modelID }) {
            onSelectModel(model)
        } else {
            onSwitchModel(modelID)
        }
    }

    private var pickerLabel: some View {
        ComposerModelPickerLabel(
            selectedModelLabel: selectedModelLabel,
            selectedModelProvider: selectedModelProvider,
            selectedModelDetail: selectedModelDetail,
            showsFastIndicator: showsFastIndicator,
            isModelLoading: isModelLoading,
            modelLoadingPercentage: modelLoadingPercentage
        )
    }

    private var pickerTooltip: String {
        isDisabled ? helpText : "Choose Model"
    }

    private var tooltipPresentation: Binding<Bool> {
        Binding(
            get: { isPickerHovered && !isMenuOpen },
            set: { isPickerHovered = $0 }
        )
    }

}

private struct ComposerModelPickerMenu: View {
    let models: [LocalModel]
    let selectedModelID: String?
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let secondarySections: [ComposerModelPickerSecondarySection]
    let isEnabled: Bool
    let statusLabel: String
    let emptyStateActionTitle: String?
    let onEmptyStateAction: (() -> Void)?
    let onSelectModel: (String) -> Void
    let onDismiss: () -> Void
    @State private var search = ""
    @State private var showsModelPicker = false
    @State private var highlightedModelID: String?
    @State private var showsSpeedPicker = false
    @State private var isSpeedHovered = false
    @State private var previewReasoningID: String?
    @FocusState private var searchIsFocused: Bool

    private var modelIDs: [String] {
        let installedIDs = models.map(\.repoID)
        if let selectedModelID, !installedIDs.contains(selectedModelID) {
            return [selectedModelID] + installedIDs
        }
        return installedIDs
    }

    private var matches: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelIDs.filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsModelPicker {
                modelPage
                    .padding(4)
                    .modifier(ComposerModelMenuSurface())
            } else if showsSpeedPicker, let speedSection {
                speedPage(speedSection)
                    .frame(width: 270)
                    .modifier(ComposerModelMenuSurface())
            }
            mainPage
                .modifier(ComposerModelMenuSurface())
        }
        .font(.system(size: 12))
        .frame(width: 360)
        .background {
            Color.clear.contentShape(.rect).onTapGesture { dismissSubmenu() }
        }
        .onExitCommand {
            if showsSpeedPicker || showsModelPicker { dismissSubmenu() }
            else { onDismiss() }
        }
    }

    private func dismissSubmenu() {
        showsSpeedPicker = false
        showsModelPicker = false
        searchIsFocused = false
    }

    private var speedSection: ComposerModelPickerSecondarySection? {
        secondarySections.first { $0.id == "drafter" }
    }

    private var reasoningSection: ComposerModelPickerSecondarySection? {
        secondarySections.first { $0.id == "reasoning" }
    }

    private var mainPage: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if let speedSection { speedButton(speedSection) }
                NativPickerRow(isHighlighted: showsModelPicker) {
                    showsSpeedPicker = false
                    showsModelPicker.toggle()
                    searchIsFocused = showsModelPicker
                } content: {
                    Text(selectedModelLabel).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                    if let reasoningSection {
                        Text(previewReasoningID ?? reasoningSection.selectedLabel)
                            .foregroundStyle(.secondary).fixedSize()
                    }
                    Image(systemName: showsModelPicker ? "chevron.up" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .help("Choose model")
                .accessibilityLabel("Choose model")
                if let speedSection, !speedSection.selectedID.isEmpty {
                    Text(speedSection.selectedLabel.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Speed: \(speedSection.selectedLabel)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let reasoningSection, reasoningSection.options.count > 1 {
                ComposerReasoningSlider(
                    options: reasoningSection.options, selectedID: reasoningSection.selectedID,
                    onPreview: { previewReasoningID = $0; dismissSubmenu() },
                    onSelect: reasoningSection.onSelect
                )
                .frame(height: 30)
                .disabled(!isEnabled)
                .help("Reasoning: \(reasoningSection.selectedLabel)")
            }
        }
        .padding(12)
    }

    private func speedButton(_ section: ComposerModelPickerSecondarySection) -> some View {
        let active = !section.selectedID.isEmpty
        let method = section.selectedOption?.speedMethod
        let hasChoices = section.options.filter { !$0.id.isEmpty }.count > 1
        return HStack(spacing: 0) {
            Button {
                dismissSubmenu()
                if let option = section.speedToggleOption { section.onSelect(option.id) }
                else if let action = section.onAction, section.actionTitle != nil { onDismiss(); action() }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ComposerLightningBolt()
                        .fill(.foreground)
                        .frame(width: 17, height: 17)
                    if method?.rank == 2 {
                        Text("+").font(.system(size: 8, weight: .bold)).offset(x: 5, y: 3)
                    }
                }
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: 32, height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || (section.speedToggleOption == nil && section.actionTitle == nil))
            .accessibilityLabel(active ? "Turn speed off" : section.speedToggleOption != nil ? "Turn speed on" : "Find draft models")
            .accessibilityValue(section.selectedLabel)
            .onHover { isSpeedHovered = $0 }
            .background {
                NativArrowlessPopoverPresenter(
                    isPresented: Binding(get: { isSpeedHovered && !showsSpeedPicker },
                                         set: { isSpeedHovered = $0 }),
                    gap: 8, alignment: .leading, cornerRadius: 8, isInteractive: false
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active ? "\(section.selectedLabel) on" : "Speed off").fontWeight(.medium)
                        Text(section.selectedOption?.detail ?? "Standard decoding").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11)).padding(8)
                }
            }
            if hasChoices {
                Divider().frame(height: 20)
                Button {
                    showsModelPicker = false
                    searchIsFocused = false
                    showsSpeedPicker.toggle()
                } label: {
                    Image(systemName: showsSpeedPicker ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 30).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel("Choose speed tier")
            }
        }
        .background(.primary.opacity(active || showsSpeedPicker ? 0.08 : 0.04),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
    }

    private var modelPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .onSubmit {
                        if isEnabled, let modelID = highlightedModelID ?? matches.first {
                            onSelectModel(modelID)
                        }
                    }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                Button(action: dismissSubmenu) {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close model list")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .frame(height: 30)
            Group {
                if matches.isEmpty {
                    Text(modelIDs.isEmpty ? statusLabel : "No matching models")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(matches, id: \.self) { modelID in
                                    NativPickerRow(isHighlighted: highlightedModelID == modelID) {
                                        onSelectModel(modelID)
                                    } content: {
                                        ChatComposerModelIcon(provider: models.first { $0.repoID == modelID }?.provider
                                                              ?? (modelID == selectedModelID ? selectedModelProvider : nil))
                                        Text(LocalModel.displayTitle(for: modelID))
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        if modelID == selectedModelID {
                                            Image(systemName: "checkmark").fontWeight(.medium)
                                        }
                                    }
                                    .id(modelID)
                                    .disabled(!isEnabled)
                                    .help(modelID)
                                    .accessibilityValue(modelID == selectedModelID ? "Selected" : "")
                                }
                            }
                        }
                        .onChange(of: highlightedModelID) { _, modelID in
                            if let modelID { proxy.scrollTo(modelID) }
                        }
                    }
                }
            }
            .frame(height: CGFloat(max(1, min(modelIDs.count, 7)) * 26))
            if modelIDs.isEmpty, let title = emptyStateActionTitle, let action = onEmptyStateAction {
                separator
                NativPickerRow {
                    onDismiss()
                    action()
                } content: {
                    Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 14)
                    Text(title)
                    Spacer(minLength: 4)
                }
                .disabled(!isEnabled)
            }
        }
        .onAppear { searchIsFocused = true }
        .onChange(of: search) { _, _ in highlightedModelID = matches.first }
    }

    private func speedPage(_ section: ComposerModelPickerSecondarySection) -> some View {
        VStack(spacing: 0) {
            ForEach(section.options) { option in
                Button {
                    showsSpeedPicker = false
                    section.onSelect(option.id)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title).fontWeight(.medium)
                            Text(option.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let method = option.speedMethod, !method.label.isEmpty {
                            Text(method.label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Image(systemName: "checkmark").fontWeight(.medium)
                            .opacity(option.id == section.selectedID ? 1 : 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(ComposerSpeedOptionStyle(isSelected: option.id == section.selectedID))
                .disabled(!isEnabled || !option.isEnabled)
                .help(option.id.isEmpty ? option.detail : option.id)
                .accessibilityValue(option.id == section.selectedID ? "Selected" : "")
            }
            if let status = section.statusTitle {
                separator
                Text(status).foregroundStyle(.secondary).padding(8)
            } else if let title = section.actionTitle, let action = section.onAction {
                separator
                NativPickerRow {
                    onDismiss()
                    action()
                } content: {
                    Text(title)
                    Spacer(minLength: 4)
                }
                .disabled(!isEnabled)
            }
        }
        .padding(4)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 4).padding(.vertical, 4)
    }

    private func moveHighlight(_ offset: Int) {
        let ids = matches
        guard !ids.isEmpty else { return }
        let current = highlightedModelID.flatMap { ids.firstIndex(of: $0) }
            ?? (offset > 0 ? -1 : ids.count)
        highlightedModelID = ids[max(0, min(ids.count - 1, current + offset))]
    }
}

private struct ComposerModelMenuSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct ComposerSpeedOptionStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, isSelected: isSelected)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(configuration.isPressed ? 0.14 : isHovered || isSelected ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 9))
                .onHover { isHovered = $0 }
        }
    }
}

private struct ComposerLightningBolt: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [CGPoint] = [
            CGPoint(x: 15, y: 1), CGPoint(x: 3, y: 14),
            CGPoint(x: 10, y: 14), CGPoint(x: 8, y: 23),
            CGPoint(x: 22, y: 9), CGPoint(x: 14, y: 9),
        ]
        return Path { path in
            path.addLines(points.map {
                CGPoint(x: rect.minX + $0.x * rect.width / 24,
                        y: rect.minY + $0.y * rect.height / 24)
            })
            path.closeSubpath()
        }
    }
}

private struct ComposerReasoningSlider: View {
    let options: [ComposerModelPickerSecondaryOption]
    let selectedID: String
    let onPreview: (String?) -> Void
    let onSelect: (String) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragIndex: Int?
    @FocusState private var isFocused: Bool

    private var selectedIndex: Int { options.firstIndex { $0.id == selectedID } ?? 0 }
    private var index: Int { min(dragIndex ?? selectedIndex, max(0, options.count - 1)) }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 28)
            let progress = CGFloat(index) / CGFloat(max(1, options.count - 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12)).frame(height: 22)
                Capsule().fill(Color.accentColor).frame(width: 28 + travel * progress, height: 22)
                    .opacity(index == 0 ? 0 : 1)
                HStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { tick in
                        if tick > 0 { Spacer(minLength: 0) }
                        Circle().fill(tick <= index && index > 0 ? .white.opacity(0.4) : .primary.opacity(0.25))
                            .frame(width: 3, height: 3)
                    }
                }
                .padding(.horizontal, 14)
                Circle().fill(.white).shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .frame(width: 28, height: 28).offset(x: travel * progress)
            }
            .frame(height: 30)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled, !options.isEmpty else { return }
                    isFocused = true
                    let fraction = min(1, max(0, (value.location.x - 14) / travel))
                    dragIndex = Int((fraction * CGFloat(options.count - 1)).rounded())
                    onPreview(options[index].title)
                }
                .onEnded { _ in
                    guard isEnabled, !options.isEmpty else { return }
                    let option = options[index]
                    dragIndex = nil
                    onPreview(nil)
                    if option.id != selectedID { onSelect(option.id) }
                })
        }
        .focusable(isEnabled)
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning")
        .accessibilityValue(options.indices.contains(index) ? options[index].title : "Off")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }

    private func adjust(_ delta: Int) {
        guard isEnabled, !options.isEmpty else { return }
        let next = min(options.count - 1, max(0, selectedIndex + delta))
        if next != selectedIndex { onSelect(options[next].id) }
    }
}

private struct ComposerModelPickerLabel: View {
    let selectedModelLabel: String
    let selectedModelProvider: LocalModelProvider?
    let selectedModelDetail: String?
    let showsFastIndicator: Bool
    let isModelLoading: Bool
    let modelLoadingPercentage: Int?

    var body: some View {
        HStack(spacing: 5) {
            if showsFastIndicator {
                ComposerLightningBolt()
                    .fill(.foreground)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }

            Label {
                HStack(spacing: 4) {
                    pickerTitle
                        .lineLimit(1)
                    if isModelLoading, let modelLoadingPercentage {
                        Text("· \(modelLoadingPercentage)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Group {
                    if isModelLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ChatComposerModelIcon(provider: selectedModelProvider)
                    }
                }
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .legacyTextStyle(.supportingEmphasized)
        .foregroundStyle(Color.primary)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
    }

    private var pickerTitle: Text {
        let modelName = Text(selectedModelLabel)
        guard let selectedModelDetail else {
            return modelName
        }
        return Text("\(modelName)  \(selectedModelDetail)").foregroundColor(.secondary)
    }

}

private struct ComposerModelPickerTooltip: View {
    let title: String
    let shortcutLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            if let shortcutLabel {
                Text(shortcutLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.12), in: Capsule())
            }
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .fixedSize()
    }
}

private struct ChatComposerModelIcon: View {
    let provider: LocalModelProvider?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if provider?.needsLightIconBackgroundInDarkMode == true,
               colorScheme == .dark {
                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: 18, height: 18)
            }

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
                    .frame(width: 15, height: 15)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 7 : 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: provider.iconTintColor))
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

struct ChatComposerActionMenu: NSViewRepresentable {
    let isEnabled: Bool
    let canPasteImage: Bool
    var uploadMenuTitle = "Upload Image…"
    var uploadMenuSystemImage = "photo.badge.plus"
    let onAttachImages: () -> Void
    let onPasteImage: () -> Void
    let onCaptureScreenshot: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "More message options"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        button.setAccessibilityLabel("More message options")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ChatComposerActionMenu

        init(parent: ChatComposerActionMenu) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = makeMenu()
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: sender)
            } else {
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: -8, y: sender.bounds.maxY + 4),
                    in: sender
                )
            }
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.minimumWidth = 190

            let fileItem = NSMenuItem(
                title: parent.uploadMenuTitle,
                action: #selector(attachImages(_:)),
                keyEquivalent: ""
            )
            fileItem.target = self
            fileItem.image = menuImage(
                parent.uploadMenuSystemImage,
                description: parent.uploadMenuTitle
            )
            fileItem.isEnabled = true
            menu.addItem(fileItem)

            let pasteItem = NSMenuItem(
                title: "Paste Image",
                action: #selector(pasteImage(_:)),
                keyEquivalent: ""
            )
            pasteItem.target = self
            pasteItem.image = menuImage("doc.on.clipboard", description: "Paste Image")
            pasteItem.isEnabled = parent.canPasteImage
            menu.addItem(pasteItem)

            let screenshotItem = NSMenuItem(
                title: "Take a Screenshot",
                action: #selector(captureScreenshot(_:)),
                keyEquivalent: ""
            )
            screenshotItem.target = self
            screenshotItem.image = menuImage("camera.viewfinder", description: "Take a screenshot")
            screenshotItem.isEnabled = true
            menu.addItem(screenshotItem)

            return menu
        }

        @objc private func attachImages(_ sender: NSMenuItem) {
            parent.onAttachImages()
        }

        @objc private func pasteImage(_ sender: NSMenuItem) {
            parent.onPasteImage()
        }

        @objc private func captureScreenshot(_ sender: NSMenuItem) {
            parent.onCaptureScreenshot()
        }

        private func menuImage(_ systemName: String, description: String) -> NSImage? {
            NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: description
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            )
        }

    }
}

struct ChatComposerAddButton: View {
    let isEnabled: Bool
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("More message options")
    }
}

struct ChatComposerActionPanel: View {
    let canPasteImage: Bool
    var showsGlobalTools = false
    var isWebSearchEnabled = false
    var isWebSearchAvailable = false
    var webSearchProviderLabel: String?
    var isWebReadEnabled = false
    var isWebReadAvailable = false
    var webReadProviderLabel: String?
    let onAttachImages: () -> Void
    let onPasteImage: () -> Void
    let onCaptureScreenshot: () -> Void
    var onToggleWebSearch: () -> Void = {}
    var onToggleWebRead: () -> Void = {}
    var onOpenKits: (() -> Void)? = nil
    var onOpenCapabilities: (() -> Void)? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                section("Add") {
                    ChatComposerActionRow(
                        title: "Upload File",
                        detail: "Choose an image or document from your Mac",
                        systemName: "doc.badge.plus",
                        action: onAttachImages
                    )

                    if canPasteImage {
                        ChatComposerActionRow(
                            title: "Paste Image",
                            detail: "Use an image from your clipboard",
                            systemName: "doc.on.clipboard",
                            action: onPasteImage
                        )
                    }

                    ChatComposerActionRow(
                        title: "Take a Screenshot",
                        detail: "Capture part of your screen",
                        systemName: "camera.viewfinder",
                        action: onCaptureScreenshot
                    )
                }

                if showsGlobalTools {
                    section("Tools") {
                        ChatComposerActionRow(
                            title: "Web Search",
                            detail: capabilityDetail(
                                provider: webSearchProviderLabel,
                                isAvailable: isWebSearchAvailable
                            ),
                            systemName: "globe",
                            isSelected: isWebSearchEnabled,
                            showsDisclosure: !isWebSearchAvailable,
                            action: onToggleWebSearch
                        )

                        ChatComposerActionRow(
                            title: "Web Read",
                            detail: capabilityDetail(
                                provider: webReadProviderLabel,
                                isAvailable: isWebReadAvailable
                            ),
                            systemName: "doc.text.magnifyingglass",
                            isSelected: isWebReadEnabled,
                            showsDisclosure: !isWebReadAvailable,
                            action: onToggleWebRead
                        )
                    }
                }

                if onOpenKits != nil || onOpenCapabilities != nil {
                    section("Capabilities") {
                        if let onOpenKits {
                            ChatComposerActionRow(
                                title: "Kits",
                                detail: "Enable a bundled set of capabilities",
                                systemName: "shippingbox",
                                showsDisclosure: true,
                                action: onOpenKits
                            )
                        }

                        if let onOpenCapabilities {
                            ChatComposerActionRow(
                                title: "Directory",
                                detail: "Manage tools, skills, and connections",
                                systemName: "square.grid.2x2",
                                showsDisclosure: true,
                                action: onOpenCapabilities
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 500)
    }

    private func capabilityDetail(provider: String?, isAvailable: Bool) -> String {
        isAvailable ? (provider ?? "Ready") : "Needs setup"
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .legacyTextStyle(.supportingEmphasized)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 1) {
                content()
            }
        }
    }
}

private struct ChatComposerActionRow: View {
    let title: String
    let detail: String
    let systemName: String
    var isSelected = false
    var showsDisclosure = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .legacyTextStyle(.rowTitle)
                        .foregroundStyle(.primary)

                    Text(detail)
                        .legacyTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .frame(width: 18, height: 18)
                } else if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowBackground)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "Enabled globally" : "")
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.green.opacity(isHovering ? 0.16 : 0.10)
        }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}

private struct ChatQueueTray: View {
    let prompts: [ChatQueuedPrompt]
    let onSteer: (UUID) -> Void
    let onPrioritize: (UUID) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        Group {
            if prompts.count <= 3 {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    rows
                }
                .frame(maxHeight: 168)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
        .animation(.snappy(duration: 0.2), value: prompts)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                if index > 0 {
                    Divider()
                        .padding(.leading, 46)
                }

                ChatQueuedPromptRow(
                    prompt: prompt,
                    onSteer: { onSteer(prompt.id) },
                    onPrioritize: { onPrioritize(prompt.id) },
                    onRemove: { onRemove(prompt.id) }
                )
            }
        }
    }
}

private struct ChatQueuedPromptRow: View {
    let prompt: ChatQueuedPrompt
    let onSteer: () -> Void
    let onPrioritize: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayContent)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if prompt.attachmentCount > 0 {
                    Label(attachmentLabel, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onSteer) {
                Label("Steer", systemImage: "arrow.turn.down.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop the current response and run this message next")

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from queue")

            Menu {
                Button(action: onPrioritize) {
                    Label("Move to Front", systemImage: "arrow.up.to.line")
                }
                .disabled(prompt.position == 1)

                Divider()

                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Queue", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Queue options")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private var displayContent: String {
        prompt.content.isEmpty ? attachmentLabel : prompt.content
    }

    private var attachmentLabel: String {
        prompt.attachmentCount == 1
            ? "1 attachment"
            : "\(prompt.attachmentCount) attachments"
    }
}

struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    var onCancel: (() -> Void)?
    var onRecallPrevious: (() -> Bool)?
    let onPasteImage: (NSPasteboard) -> Bool
    let onContentHeightChange: (CGFloat) -> Void
    var acceptsImageDrops = false
    var onImageDropTargetChange: ((Bool) -> Void)?
    var maximumHeight: CGFloat = .infinity
    var fontScale: Double = 1.0
    var focusToken: Int = 0
    var focusOnAppearance = false
    var forwardsKeysToPendingDecision = false
    var onNavigatePendingSelection: ((Int) -> Bool)?
    var onCancelPendingDecision: (() -> Void)?
    var onPasteText: ((String, NSRange, UndoManager?) -> Void)?
    var onTextEdit: ((NSRange, String, UndoManager?) -> Void)?
    var onTextCommit: ((String, UndoManager?) -> Void)?
    var resetToken = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onRecallPrevious: onRecallPrevious,
            onPasteImage: onPasteImage,
            onContentHeightChange: onContentHeightChange,
            focusToken: focusToken,
            focusOnAppearance: focusOnAppearance
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.handleSubmit
        textView.onCancel = context.coordinator.handleCancel
        textView.onRecallPrevious = context.coordinator.handleRecallPrevious
        textView.onPasteImage = context.coordinator.handlePasteImage
        textView.onPasteText = context.coordinator.handlePasteText
        textView.forwardsKeysToPendingDecision = forwardsKeysToPendingDecision
        textView.onNavigatePendingSelection = onNavigatePendingSelection
        textView.onCancelPendingDecision = onCancelPendingDecision
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = ChatFontMetrics.bodyNSFont(scale: fontScale)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.usesDraftUndo = onTextEdit != nil || onTextCommit != nil
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.acceptsImageDrops = acceptsImageDrops
        textView.onImageDropTargetChange = onImageDropTargetChange

        let scrollView = ChatComposerNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.onLayout = context.coordinator.reportContentHeight

        context.coordinator.textView = textView
        context.coordinator.maximumHeight = maximumHeight
        context.coordinator.onPasteText = onPasteText
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onTextCommit = onTextCommit
        context.coordinator.reportContentHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        context.coordinator.onPasteImage = onPasteImage
        context.coordinator.onPasteText = onPasteText
        context.coordinator.onTextEdit = onTextEdit
        context.coordinator.onTextCommit = onTextCommit
        context.coordinator.onContentHeightChange = onContentHeightChange
        context.coordinator.maximumHeight = maximumHeight

        guard let textView = context.coordinator.textView else {
            return
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = ChatFontMetrics.bodyNSFont(scale: fontScale)

        if let composerTextView = textView as? ChatComposerNSTextView {
            composerTextView.acceptsImageDrops = acceptsImageDrops
            composerTextView.onImageDropTargetChange = onImageDropTargetChange
            composerTextView.forwardsKeysToPendingDecision = forwardsKeysToPendingDecision
            composerTextView.onNavigatePendingSelection = onNavigatePendingSelection
            composerTextView.onCancelPendingDecision = onCancelPendingDecision
        }
        (textView as? ChatComposerNSTextView)?.usesDraftUndo = onTextEdit != nil || onTextCommit != nil

        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            textView.composerUndoManager?.removeAllActions()
        }
        context.coordinator.reportContentHeight()
        context.coordinator.requestFocus(ifNeeded: focusToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        var onCancel: (() -> Void)?
        var onRecallPrevious: (() -> Bool)?
        var onPasteImage: (NSPasteboard) -> Bool
        var onPasteText: ((String, NSRange, UndoManager?) -> Void)?
        var onTextEdit: ((NSRange, String, UndoManager?) -> Void)?
        var onTextCommit: ((String, UndoManager?) -> Void)?
        var lastResetToken = 0
        private var pendingEdit: (range: NSRange, replacement: String)?
        var onContentHeightChange: (CGFloat) -> Void
        var maximumHeight: CGFloat = .infinity
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat?
        private var lastFocusToken: Int?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: (() -> Void)?,
            onRecallPrevious: (() -> Bool)?,
            onPasteImage: @escaping (NSPasteboard) -> Bool,
            onContentHeightChange: @escaping (CGFloat) -> Void,
            focusToken: Int,
            focusOnAppearance: Bool
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onRecallPrevious = onRecallPrevious
            self.onPasteImage = onPasteImage
            self.onContentHeightChange = onContentHeightChange
            // Add to chat can reveal a composer that was removed by the expanded work pane.
            lastFocusToken = focusOnAppearance ? nil : focusToken
        }

        func handlePasteImage(_ pasteboard: NSPasteboard) -> Bool {
            onPasteImage(pasteboard)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else {
                return
            }

            guard !textView.hasMarkedText() else {
                reportContentHeight()
                return
            }

            defer { pendingEdit = nil }
            if onTextEdit != nil || onTextCommit != nil,
               textView.composerUndoManager?.isUndoing == true || textView.composerUndoManager?.isRedoing == true {
                reportContentHeight()
                return
            }
            if let onTextEdit, let edit = pendingEdit,
               Range(edit.range, in: text) != nil,
               (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == textView.string {
                onTextEdit(edit.range, edit.replacement, textView.composerUndoManager)
            } else if let onTextCommit {
                onTextCommit(textView.string, textView.composerUndoManager)
            } else {
                text = textView.string
            }
            reportContentHeight()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            pendingEdit = replacementString.map { (affectedCharRange, $0) }
            return true
        }

        func handlePasteText(_ pastedText: String, range: NSRange) -> Bool {
            guard let onPasteText else { return false }
            onPasteText(pastedText, range, textView?.composerUndoManager)
            return true
        }

        func handleSubmit() {
            onSubmit()
        }

        func handleCancel() -> Bool {
            guard let onCancel else { return false }
            onCancel()
            return true
        }

        func handleRecallPrevious() -> Bool {
            onRecallPrevious?() ?? false
        }

        func requestFocus(ifNeeded focusToken: Int) {
            guard focusToken != lastFocusToken, let textView else {
                return
            }
            lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            }
        }

        func reportContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textContainer.containerSize.width > 0
            else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = ceil(usedRect.maxY + (textView.textContainerInset.height * 2))

            // Enable the scroller only once the editor is capped and the text can
            // actually scroll. Letting AppKit auto-toggle it while the editor is
            // still growing loops with legacy scrollers ("Show scroll bars:
            // Always"): the scroller takes width, the text rewraps, the height
            // changes, the editor resizes, and the scroller toggles again.
            let needsScroller = measuredHeight > maximumHeight
            if let scrollView = textView.enclosingScrollView,
               scrollView.hasVerticalScroller != needsScroller {
                scrollView.hasVerticalScroller = needsScroller
            }

            guard lastReportedHeight.map({ abs($0 - measuredHeight) >= 0.5 }) ?? true else {
                return
            }

            lastReportedHeight = measuredHeight
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedHeight == measuredHeight else {
                    return
                }
                self.onContentHeightChange(measuredHeight)
            }
        }
    }
}

private final class ChatComposerNSScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private extension NSTextView {
    var composerUndoManager: UndoManager? {
        (self as? ChatComposerNSTextView)?.draftHistory ?? undoManager
    }
}

private final class ChatComposerNSTextView: NSTextView {
    var usesDraftUndo = false {
        didSet { allowsUndo = !usesDraftUndo }
    }
    private let draftUndoManager = UndoManager()

    var draftHistory: UndoManager? {
        usesDraftUndo ? (window?.undoManager ?? draftUndoManager) : super.undoManager
    }

    @objc func undo(_ sender: Any?) {
        composerUndoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        composerUndoManager?.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return composerUndoManager?.canUndo == true
        case #selector(redo(_:)): return composerUndoManager?.canRedo == true
        default: return super.validateMenuItem(menuItem)
        }
    }

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onPasteImage: ((NSPasteboard) -> Bool)?
    var onImageDropTargetChange: ((Bool) -> Void)?
    var acceptsImageDrops = false {
        didSet {
            if acceptsImageDrops {
                registerForDraggedTypes([.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) })
            }
        }
    }
    var forwardsKeysToPendingDecision = false
    var onNavigatePendingSelection: ((Int) -> Bool)?
    var onCancelPendingDecision: (() -> Void)?
    var onPasteText: ((String, NSRange) -> Bool)?
    /// Returns whether the recall happened, so an Up key that recalls nothing
    /// still moves the caret.
    var onRecallPrevious: (() -> Bool)?

    private func isImageDrop(_ sender: NSDraggingInfo) -> Bool {
        acceptsImageDrops && ChatImageAttachment.canReadImages(from: sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender) {
            let canDrop = isEditable && sender.draggingSourceOperationMask.contains(.copy)
            onImageDropTargetChange?(canDrop)
            return canDrop ? .copy : []
        }
        onImageDropTargetChange?(false)
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender) {
            let canDrop = isEditable && sender.draggingSourceOperationMask.contains(.copy)
            onImageDropTargetChange?(canDrop)
            return canDrop ? .copy : []
        }
        onImageDropTargetChange?(false)
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onImageDropTargetChange?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onImageDropTargetChange?(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isImageDrop(sender) {
            return isEditable && sender.draggingSourceOperationMask.contains(.copy)
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onImageDropTargetChange?(false) }
        if isImageDrop(sender) {
            // NSTextView otherwise inserts the file path into this plain-text editor.
            guard isEditable, sender.draggingSourceOperationMask.contains(.copy) else { return false }
            return onPasteImage?(sender.draggingPasteboard) ?? false
        }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Return confirms a marked composition in input methods such as Japanese
        // and Chinese. Let NSTextView route those events through the input method
        // before applying the composer send/newline behavior.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            if onCancel?() != true {
                onCancelPendingDecision?()
            }
            return
        }

        let arrow = string.isEmpty ? ComposerArrowKey(event) : nil

        if forwardsKeysToPendingDecision, let arrow,
            onNavigatePendingSelection?(arrow.offset) == true {
            return
        }

        // Up in an empty composer recalls the last prompt. Guarded on empty
        // rather than on caret position so that Up never stops being Up while
        // there is text to move through.
        if arrow == .up, onRecallPrevious?() == true {
            return
        }

        switch ComposerReturnBehavior.resolve(for: event) {
        case .submit:
            if forwardsKeysToPendingDecision, string.isEmpty,
                window?.performKeyEquivalent(with: event) == true
            {
                return
            }
            onSubmit?()
        case .insertNewline:
            insertText("\n", replacementRange: selectedRange())
        case .passthrough:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if onPasteImage?(NSPasteboard.general) == true {
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string),
              ChatPastedText.shouldCollapse(text), let onPasteText else {
            super.paste(sender)
            return
        }
        breakUndoCoalescing()
        let range = selectedRange()
        guard onPasteText(text, range) else {
            super.paste(sender)
            return
        }
        // The attachment lives outside NSTextView. Only the selected ordinary text disappears.
        if range.length > 0 {
            string = (string as NSString).replacingCharacters(in: range, with: "")
            setSelectedRange(NSRange(location: range.location, length: 0))
        }
        breakUndoCoalescing()
    }
}

/// Whether an Up key should recall the previous prompt.
private enum ComposerArrowKey {
    case up
    case down

    init?(_ event: NSEvent) {
        guard
            event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .isDisjoint(with: [.command, .option, .control, .shift])
        else {
            return nil
        }
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        default: return nil
        }
    }

    var offset: Int {
        self == .up ? -1 : 1
    }
}

private enum ComposerReturnBehavior {
    case submit
    case insertNewline
    case passthrough

    static func resolve(for event: NSEvent) -> ComposerReturnBehavior {
        guard isReturnKey(event) else {
            return .passthrough
        }

        let modifiers = relevantModifiers(for: event)
        if modifiers == [.command] {
            return .insertNewline
        }
        if modifiers.isEmpty {
            return .submit
        }
        return .passthrough
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private static func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
}

struct ChatPastedTextCard: View {
    let pastedText: ChatPastedText
    var onRemove: (() -> Void)?
    @State private var showsPreview = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { showsPreview = true } label: {
                label
            }
            .buttonStyle(.plain)
            .help("View pasted text")

            if let onRemove {
                Button("Remove pasted text", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Remove pasted text")
            }
        }
        .sheet(isPresented: $showsPreview) {
            preview
                .frame(width: 640, height: 480)
        }
    }

    private var label: some View {
        let lineCount = pastedText.lineCount
        return HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pasted text")
                    .font(.callout.weight(.medium))
                Text(lineCount == 1 ? "1 line" : "\(lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 180)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Pasted text")
                    .font(.headline)
                Text(pastedText.lineCount == 1 ? "1 line" : "\(pastedText.lineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "document.on.document") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pastedText.text, forType: .string)
                }
                .labelStyle(.iconOnly)
                .help("Copy raw text")
                Button("Close", systemImage: "xmark") { showsPreview = false }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(16)
            Divider()
            ChatPastedTextRawView(text: pastedText.text)
        }
    }
}

/// A plain, selectable text view keeps large pastes out of the Markdown renderer.
private struct ChatPastedTextRawView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.setAccessibilityLabel("Raw pasted text")
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

struct ChatPendingImageAttachmentView: View {
    let attachment: ChatImageAttachment
    var validation: ChatAttachmentValidation? = nil
    var modelRejectsImage = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ChatAttachmentThumbnail(
                attachment: attachment,
                width: 42,
                height: 32
            )

            Text(attachment.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            statusIndicator

            Button("Remove Attachment", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .frame(width: 14, height: 14)
                .buttonStyle(.plain)
                .help("Remove \(attachment.filename)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(attachmentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(attachmentBorder, lineWidth: hasIssue ? 0.75 : 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if modelRejectsImage {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .help("Requires a vision-capable model")
                .accessibilityLabel("Unsupported by the selected model")
        } else if let validation {
            switch validation {
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .help("Reading document")
                    .accessibilityLabel("Reading document")
            case .blocked(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                    .help(message)
                    .accessibilityLabel("Attachment cannot be used")
            case .ready:
                EmptyView()
            }
        }
    }

    private var hasIssue: Bool {
        if modelRejectsImage {
            return true
        }
        guard let validation else {
            return false
        }
        switch validation {
        case .blocked:
            return true
        case .processing, .ready:
            return false
        }
    }

    private var attachmentBackground: Color {
        hasIssue
            ? Color.orange.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor)
    }

    private var attachmentBorder: Color {
        hasIssue
            ? Color.orange.opacity(0.30)
            : Color(nsColor: .separatorColor)
    }
}
