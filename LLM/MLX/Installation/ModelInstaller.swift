import Foundation

// MARK: - MLXLocalLLMService install-state extension
//
// selectModel / isModelAvailable / installState / refreshModelInstallStates /
// downloadMetrics。纯 bookkeeping, 不触碰模型权重加载 (那在主类 load() 里)。

extension MLXLocalLLMService {

    public func selectModel(id: String) -> Bool {
        guard let option = Self.availableModels.first(where: { $0.id == id }),
              option != selectedModel else {
            return false
        }

        selectedModel = option
        statusMessage = isLoaded
            ? "已选择 \(option.displayName)，准备重新加载..."
            : "已选择 \(option.displayName)，等待加载..."
        return true
    }

    public func isModelAvailable(_ model: BundledModelOption) -> Bool {
        ModelPaths.bundled(for: model) != nil
            || ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model))
    }

    public func installState(for model: BundledModelOption) -> ModelInstallState {
        if ModelPaths.bundled(for: model) != nil {
            return .bundled
        }
        if ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model)) {
            return .downloaded
        }
        return modelInstallStates[model.id] ?? .notInstalled
    }

    public func refreshModelInstallStates() {
        cleanupStalePartialDirectories()
        for model in Self.availableModels {
            if ModelPaths.bundled(for: model) != nil {
                modelInstallStates[model.id] = .bundled
            } else if ModelPaths.hasRequiredFiles(model, at: ModelPaths.downloaded(for: model)) {
                modelInstallStates[model.id] = .downloaded
            } else if case .checkingSource = modelInstallStates[model.id] {
                continue
            } else if case .downloading = modelInstallStates[model.id] {
                continue
            } else {
                modelInstallStates[model.id] = .notInstalled
            }
        }
    }

    public func downloadMetrics(for modelID: String) -> ModelDownloadMetrics? {
        modelDownloadMetrics[modelID]
    }
}
