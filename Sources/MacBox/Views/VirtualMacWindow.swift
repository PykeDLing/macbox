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
                ProgressView("正在启动…")
            } else {
                ContentUnavailableView {
                    Label(vm.config.installed ? "虚拟 Mac 未运行" : "虚拟 Mac 还没有设置", systemImage: "desktopcomputer")
                } description: {
                    Text(vm.lastError ?? vm.notice ?? "")
                } actions: {
                    if vm.status == .stopped {
                        Button(vm.isAsleep ? "唤醒" : "启动") { Task { await vm.start() } }
                            .buttonStyle(.borderedProminent)
                    } else if vm.status == .notSetUp {
                        Button("前往设置虚拟 Mac…") { store.show(.virtualMac) }
                    } else if case .unreadable = vm.status {
                        Button("查看详情…") { store.show(.virtualMac) }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle("虚拟 Mac")
        .navigationSubtitle(vm.status.title)
        .dropDestination(for: URL.self) { urls, _ in
            vm.sendToGuest(urls)
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup {
                Button { choosingFiles = true } label: {
                    Label("放入文件", systemImage: "tray.and.arrow.down")
                }
                .help("复制到虚拟 Mac 的「传入」文件夹")
                .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { vm.sendToGuest(urls) }
                }
                Button {
                    try? vm.bundle.ensureExchangeFolders()
                    NSWorkspace.shared.open(vm.bundle.outgoingURL)
                } label: {
                    Label("传出", systemImage: "tray.and.arrow.up")
                }
                .help("打开虚拟 Mac 的「传出」文件夹")
                if vm.status == .running || vm.status == .paused {
                    Button { Task { await vm.togglePause() } } label: {
                        vm.status == .paused ? Label("继续", systemImage: "play.fill") : Label("暂停", systemImage: "pause.fill")
                    }
                    Button { Task { await vm.sleep() } } label: { Label("睡眠", systemImage: "moon.zzz.fill") }
                        .help("保存当前状态并关闭，下次几秒内恢复")
                    Menu {
                        Button("关机") { vm.requestShutdown() }
                        Divider()
                        Button("强制关机", role: .destructive) { Task { await vm.forceStop() } }
                    } label: {
                        Label("关机", systemImage: "power")
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
