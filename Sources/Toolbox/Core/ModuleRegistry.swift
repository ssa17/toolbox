import Foundation
import Combine

/// Central registry of all modules loaded by Toolbox.
/// To add a new module: append an instance to `modules` below.
@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    let dockMinimize = DockMinimizeModule()
    let clipboard = ClipboardModule()
    let portKiller = PortKillerModule()
    let screenOCR = ScreenOCRModule()
    let keepAwake = KeepAwakeModule()
    let cleanLock = CleanLockModule()
    let customCommands = CustomCommandsModule()
    let scrollDirection = ScrollDirectionModule()
    let callControls = CallControlsModule()
    let windowSnapper = WindowSnapperModule()
    let finderEnhancer = FinderEnhancerModule()
    let windowSwitcher = WindowSwitcherModule()
    let hyperKey = HyperKeyModule()
    let quickScreenshot = QuickScreenshotModule()

    lazy var modules: [any ToolboxModule] = [
        dockMinimize,
        clipboard,
        portKiller,
        screenOCR,
        keepAwake,
        cleanLock,
        customCommands,
        scrollDirection,
        callControls,
        windowSnapper,
        finderEnhancer,
        windowSwitcher,
        hyperKey,
        quickScreenshot
    ]

    @Published private(set) var revision: Int = 0

    private init() {}

    func module(withID id: String) -> (any ToolboxModule)? {
        modules.first { $0.id == id }
    }

    func orderedMenuBarModules(for config: ToolboxConfig) -> [any ToolboxModule] {
        let eligible = modules.filter(\.supportsMenuBar)
        let allIDs = eligible.map(\.id)
        let orderedIDs = config.general.normalizedMenuBarModuleOrder(allModuleIDs: allIDs)
        return orderedIDs.compactMap { id in
            eligible.first { $0.id == id }
        }
    }

    func visibleMenuBarModules(for config: ToolboxConfig) -> [any ToolboxModule] {
        orderedMenuBarModules(for: config).filter {
            config.general.isModuleVisibleInMenuBar($0.id)
        }
    }

    func reloadAll(with config: ToolboxConfig) {
        if config.general.appEnabled {
            for module in modules {
                module.reload(with: config)
            }
        } else {
            for module in modules {
                module.stop()
            }
        }
        revision &+= 1
    }

    func notifyChanged() {
        revision &+= 1
    }
}
