import AppKit
import SwiftUI
import Virtualization

/// 虚拟 Mac 的显示窗口
struct VirtualMacWindow: View {
    @Environment(VirtualMac.self) private var vm
    @Environment(BoxStore.self) private var store
    @State private var choosingFiles = false

    var body: some View {
        Group {
            if let machine = vm.virtualMachine {
                VMDisplayView(virtualMachine: machine)
                    .overlay {
                        if vm.status == .paused || vm.status == .saving {
                            ZStack {
                                Color.black.opacity(0.45)
                                Label(vm.status.title, systemImage: "pause.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
            } else if vm.status == .starting {
                ProgressView(L("正在启动…", "Starting…"))
            } else {
                ContentUnavailableView {
                    Label(vm.config.installed ? L("虚拟 Mac 未运行", "Virtual Mac Isn’t Running")
                                              : L("虚拟 Mac 还没有设置", "Virtual Mac Isn’t Set Up"),
                          systemImage: "desktopcomputer")
                } description: {
                    Text(vm.lastError ?? vm.notice ?? "")
                } actions: {
                    if vm.status == .stopped {
                        Button(vm.isAsleep ? L("唤醒", "Wake") : L("启动", "Start")) { Task { await vm.start() } }
                            .buttonStyle(.borderedProminent)
                    } else if vm.status == .notSetUp {
                        Button(L("前往设置虚拟 Mac…", "Set Up Virtual Mac…")) { store.show(.virtualMac) }
                    } else if case .unreadable = vm.status {
                        Button(L("查看详情…", "Show Details…")) { store.show(.virtualMac) }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(L("虚拟 Mac", "Virtual Mac"))
        .navigationSubtitle(vm.status.title)
        .dropDestination(for: URL.self) { urls, _ in
            vm.sendToGuest(urls)
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup {
                Button { choosingFiles = true } label: {
                    Label(L("放入文件", "Add Files"), systemImage: "tray.and.arrow.down")
                }
                .help(L("复制到虚拟 Mac 的「传入」文件夹", "Copy to the Virtual Mac’s “传入” (Incoming) folder"))
                .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { vm.sendToGuest(urls) }
                }
                Button {
                    try? vm.bundle.ensureExchangeFolders()
                    NSWorkspace.shared.open(vm.bundle.outgoingURL)
                } label: {
                    Label(L("传出", "Outgoing"), systemImage: "tray.and.arrow.up")
                }
                .help(L("打开虚拟 Mac 的「传出」文件夹", "Open the Virtual Mac’s “传出” (Outgoing) folder"))
                if vm.status == .running || vm.status == .paused {
                    Button { Task { await vm.togglePause() } } label: {
                        vm.status == .paused ? Label(L("继续", "Resume"), systemImage: "play.fill")
                                             : Label(L("暂停", "Pause"), systemImage: "pause.fill")
                    }
                    Button { Task { await vm.sleep() } } label: { Label(L("睡眠", "Sleep"), systemImage: "moon.zzz.fill") }
                        .help(L("保存当前状态并关闭，下次几秒内恢复", "Save the current state and close; resumes in seconds next time"))
                    Menu {
                        Button(L("关机", "Shut Down")) { vm.requestShutdown() }
                        Divider()
                        Button(L("强制关机", "Force Shut Down"), role: .destructive) { Task { await vm.forceStop() } }
                    } label: {
                        Label(L("关机", "Shut Down"), systemImage: "power")
                    } primaryAction: {
                        vm.requestShutdown()
                    }
                }
            }
        }
    }
}

struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> FocusingVMView {
        let view = FocusingVMView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        return view
    }

    func updateNSView(_ view: FocusingVMView, context: Context) {
        if view.virtualMachine !== virtualMachine { view.virtualMachine = virtualMachine }
    }
}

/// 放进窗口后立即接收键盘输入，不用先点一下画面
final class FocusingVMView: VZVirtualMachineView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
