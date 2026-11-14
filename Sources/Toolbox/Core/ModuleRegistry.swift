import Foundation
import Combine

/// Central registry of all modules loaded by Toolbox.
/// To add a new module: append an instance to `modules` below.
@MainActor
final class ModuleRegistry: ObservableObject {
    static let shared = ModuleRegistry()

    let dockMinimize = DockMinimizeModule()
    let clipboard = ClipboardModule()
    let keepAwake = KeepAwakeModule()
    let customCommands = CustomCommandsModule()
    let scrollDirection = ScrollDirectionModule()

    lazy var modules: [any ToolboxModule] = [
        dockMinimize,
        clipboard,
        keepAwake,
        customCommands,
        scrollDirection
    ]

    @Published private(set) var revision: Int = 0

    private init() {}

    func module(withID id: String) -> (any ToolboxModule)? {
        modules.first { $0.id == id }
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
