import Foundation
import Virtualization

enum VMConfigurationFactory {
    /// 共享目录在 macOS 客体中会自动挂载到 /Volumes/My Shared Files
    nonisolated static let incomingShareName = "传入"
    nonisolated static let outgoingShareName = "传出"

    static func make(bundle: VirtualMacBundle, config: VirtualMacConfig) throws -> VZVirtualMachineConfiguration {
        let vm = VZVirtualMachineConfiguration()

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try bundle.loadHardwareModel()
        platform.machineIdentifier = try bundle.loadMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        vm.platform = platform
        vm.bootLoader = VZMacOSBootLoader()

        vm.cpuCount = min(max(config.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vm.memorySize = min(max(UInt64(config.memoryGB) << 30, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // 固定分辨率（1440×900 点 @2x），保证睡眠/唤醒时配置一致；窗口缩放时由视图自动重配
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2880, heightInPixels: 1800, pixelsPerInch: 220)]
        vm.graphicsDevices = [graphics]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        vm.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        if config.networkEnabled {
            let net = VZVirtioNetworkDeviceConfiguration()
            net.attachment = VZNATNetworkDeviceAttachment()
            if let mac = VZMACAddress(string: config.macAddress) { net.macAddress = mac }
            vm.networkDevices = [net]
        }

        vm.keyboards = [VZMacKeyboardConfiguration()]
        vm.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        if config.audioEnabled {
            // 只提供扬声器，不接入麦克风
            let sound = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            sound.streams = [output]
            vm.audioDevices = [sound]
        }

        vm.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vm.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // 文件交换：传入只读（虚拟 Mac 不能篡改/回写），传出可写
        let share = VZMultipleDirectoryShare(directories: [
            incomingShareName: VZSharedDirectory(url: bundle.incomingURL, readOnly: true),
            outgoingShareName: VZSharedDirectory(url: bundle.outgoingURL, readOnly: false),
        ])
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fs.share = share
        vm.directorySharingDevices = [fs]

        try vm.validate()
        return vm
    }
}
