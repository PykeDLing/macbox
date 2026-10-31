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
                    .overlay(alignment: .top) { messages }
            } else if vm.status == .starting {
                ProgressView(String(localized: "正在启动…"))
            } else {
                ContentUnavailableView {
                    Label(vm.config.installed ? String(localized: "虚拟 Mac 未运行")
                                              : String(localized: "虚拟 Mac 还没有设置"),
                          systemImage: "desktopcomputer")
                } description: {
                    Text(vm.lastError ?? vm.notice ?? "")
                } actions: {
                    if vm.status == .stopped {
                        Button(vm.isAsleep ? String(localized: "唤醒") : String(localized: "启动")) { Task { await vm.start() } }
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
        .navigationSubtitle(vm.displayStatus)
        .dropDestination(for: URL.self) { urls, _ in
            // 复制在后台进行，这里只能同步回答「收下了」
            Task { await vm.sendToGuest(urls) }
            return !urls.isEmpty
        }
        .toolbar {
            ToolbarItemGroup {
                // 拖放和「放入文件」都在后台复制，跨卷时可能要很久：这里给个进行中的提示
                if vm.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在复制到虚拟 Mac…")
                }
                Button { choosingFiles = true } label: {
                    Label("放入文件", systemImage: "tray.and.arrow.down")
                }
                .help("复制到虚拟 Mac 的「传入」文件夹")
                .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { Task { await vm.sendToGuest(urls) } }
                }
                Button {
                    Task { await vm.openOutgoingFolder() }
                } label: {
                    Label(String(localized: "virtualMac.toolbar.outgoing", defaultValue: "传出", comment: "工具栏按钮：打开「传出」文件夹"),
                          systemImage: "tray.and.arrow.up")
                }
                .help("打开虚拟 Mac 的「传出」文件夹")
                if vm.status == .running || vm.status == .paused {
                    Button { Task { await vm.togglePause() } } label: {
                        vm.status == .paused ? Label("继续", systemImage: "play.fill")
                                             : Label("暂停", systemImage: "pause.fill")
                    }
                    Button { Task { await vm.sleep() } } label: { Label("睡眠", systemImage: "moon.zzz.fill") }
                        .help("保存当前状态并关闭，下次几秒内恢复")
                    shutDownMenu
                }
            }
        }
    }

    /// 虚拟机画面显示时，下面的 ContentUnavailableView 看不到：放入的结果、出错信息浮在画面上方，可以关掉
    @ViewBuilder
    private var messages: some View {
        if vm.lastError != nil || vm.notice != nil {
            VStack(spacing: 8) {
                if let error = vm.lastError {
                    Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) { vm.lastError = nil }
                }
                if let notice = vm.notice {
                    Banner(text: notice, systemImage: "info.circle.fill", tint: .blue) { vm.notice = nil }
                }
            }
            .padding(10)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    /// 暂停时虚拟机不能正常关机：去掉主按钮的直接动作（点一下只展开菜单），菜单里的「关机」也禁用，
    /// 只留「强制关机」，免得点了没反应
    @ViewBuilder
    private var shutDownMenu: some View {
        let canShutDown = vm.status == .running
        let items = Group {
            Button("关机") { vm.requestShutdown() }
                .disabled(!canShutDown)
            Divider()
            Button("强制关机", role: .destructive) { Task { await vm.forceStop() } }
        }
        let label = Label("关机", systemImage: "power")
        if canShutDown {
            Menu { items } label: { label } primaryAction: { vm.requestShutdown() }
        } else {
            Menu { items } label: { label }
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
