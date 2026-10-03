//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Foundation
import SwiftUI
import UIKit

struct LCAppBannerConfiguration {
    let model: LCAppModel
    let dynamicColors: Bool
    let darkModeIcon: Bool
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        
    private let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    private var configuration: LCAppBannerConfiguration
    private var exportTemporaryDirectory: URL?
    
    init(delegate: LCAppBannerDelegate, config: LCAppBannerConfiguration) {
        self.delegate = delegate
        self.configuration = config
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = bannerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 0, height: LCAppBannerRootView.bannerHeight)
        bannerView.runControl.addTarget(self, action: #selector(runButtonTapped), for: .touchUpInside)
        bannerView.addInteraction(UIContextMenuInteraction(delegate: self))

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(bannerDoubleTapped))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        bannerView.addGestureRecognizer(doubleTapGesture)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshView()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshView()
        }
    }

    deinit {
        cleanupExportTemporaryDirectory()
    }

    func update(
        model: LCAppModel,
        dynamicColors: Bool,
        darkModeIcon: Bool
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon
        )
        refreshView()
    }

    private func refreshView() {
        bannerView.update(
            model: configuration.model,
            appInfo: configuration.model.appInfo,
            dynamicColors: configuration.dynamicColors,
            darkModeIcon: configuration.darkModeIcon,
            traitCollection: traitCollection
        )
    }

    @objc private func bannerDoubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        let location = gestureRecognizer.location(in: bannerView.runControl)
        guard !bannerView.runControl.bounds.contains(location) else {
            return
        }
        openSettings()
    }

    @objc private func runButtonTapped() {
        if #available(iOS 16.0, *),
           let currentDataFolder = configuration.model.uiSelectedContainer?.folderName,
           MultitaskManager.isUsing(container: currentDataFolder) {
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
            }
            if found {
                return
            }
        }

        Task { [weak self] in
            await self?.runApp()
        }
    }

    private func runApp(multitask: Bool? = nil) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        do {
            try await configuration.model.runApp(multitask: multitask)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        let appInfo = model.appInfo
        var menuChildren: [UIMenuElement] = []

        // 1. Containers Picker (Equivalent to a Menu with single selection)
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { [weak self] container in
                UIAction(
                    title: container.name,
                    state: container == model.uiSelectedContainer ? .on : .off
                ) { _ in
                    model.uiSelectedContainer = container
                    self?.refreshView()
                }
            }
            menuChildren.append(UIMenu(title: "Containers", options: .displayInline, children: containerActions))
        }

        // 2. Main Section
        var sectionChildren: [UIMenuElement] = []
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.openDataFolder".loc,
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            })
        }

        // Multitask Toggle
        if #available(iOS 16.0, *) {
            let shouldLaunchInMultitaskMode = model.shouldLaunchInMultitaskMode
            sectionChildren.append(UIAction(
                title: shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                image: UIImage(systemName: shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.runApp(multitask: !shouldLaunchInMultitaskMode)
                }
            })
        }

        let currentAssigned = model.uiAssignedContainer
        let assignSchemes: [(title: String, scheme: String?)] = [
            ("lc.appBanner.assignNone".loc, nil),
            ("LiveContainer 1 (Main)", "livecontainer"),
            ("LiveContainer 2", "livecontainer2"),
            ("LiveContainer 3", "livecontainer3"),
            ("LiveContainer 4", "livecontainer4"),
            ("LiveContainer 5", "livecontainer5")
        ]
        let assignActions = assignSchemes.map { item in
            let isSelected: Bool
            if let targetScheme = item.scheme {
                isSelected = (currentAssigned == targetScheme) || (targetScheme == "livecontainer" && currentAssigned == "livecontainer1")
            } else {
                isSelected = (currentAssigned == nil)
            }
            return UIAction(
                title: item.title,
                image: isSelected ? UIImage(systemName: "checkmark.circle.fill") : nil,
                state: isSelected ? .on : .off
            ) { [weak self] _ in
                self?.configuration.model.uiAssignedContainer = item.scheme
                self?.refreshView()
            }
        }
        let assignMenu = UIMenu(
            title: "lc.appBanner.assignToLiveContainer".loc,
            image: UIImage(systemName: "arrow.triangle.branch"),
            children: assignActions
        )
        sectionChildren.append(assignMenu)

        let addToHomeScreenMenu = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [
                UIAction(
                    title: "lc.appBanner.installInstantWebClip".loc,
                    image: UIImage(systemName: "bolt.badge.automatic.fill") ?? UIImage(systemName: "arrow.down.doc.fill")
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.installWebClipProfile()
                    }
                },
                UIAction(
                    title: "lc.appBanner.shareInstantWebClip".loc,
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.shareWebClipProfile()
                    }
                },
                UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.copyLaunchUrl()
                },
                UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.saveIcon()
                    }
                },
                UIAction(title: "lc.appBanner.createDedicatedLC".loc, image: UIImage(systemName: "shippingbox.fill")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.packageDedicatedLiveContainer()
                    }
                }
            ]
        )
        sectionChildren.append(addToHomeScreenMenu)

        sectionChildren.append(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        })

        if !model.uiIsShared {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.uninstall".loc,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.uninstall()
                }
            })
        }

        menuChildren.append(UIMenu(
            title: appInfo.relativeBundlePath ?? "",
            options: .displayInline,
            children: sectionChildren
        ))
        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    private func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: configuration.model)))
    }

    private func openDataFolder() {
        guard let folderName = configuration.model.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        let displayName = appInfo.displayName() ?? configuration.model.displayName
        let shouldUninstall = await presentConfirmation(
            title: "lc.appBanner.confirmUninstallTitle".loc,
            message: "lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(displayName),
            confirmTitle: "lc.appBanner.uninstall".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard shouldUninstall == true else {
            return
        }

        var shouldRemoveAppFolders = false
        let containers = appInfo.containers
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }

            let fileManager = FileManager.default
            try fileManager.removeItem(atPath: bundlePath)
            delegate.removeApp(app: configuration.model)

            if shouldRemoveAppFolders {
                for container in containers {
                    let dataUUID = container.folderName
                    try fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }



    private func copyLaunchUrl() {
        guard let relativeBundlePath = configuration.model.appInfo.relativeBundlePath else {
            return
        }

        let scheme = configuration.model.uiAssignedContainer ?? "livecontainer"
        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "\(scheme)://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(folderName)"
        } else {
            UIPasteboard.general.string = "\(scheme)://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    private func installWebClipProfile() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }
        let model = configuration.model
        if model.uiAssignedContainer == nil {
            model.uiAssignedContainer = "livecontainer"
            refreshView()
        }
        let appInfo = model.appInfo
        let displayName = appInfo.displayName() ?? model.displayName
        let rawBundlePath = appInfo.bundlePath() ?? appInfo.relativeBundlePath
        let containerFolder = model.uiSelectedContainer?.folderName
        let scheme = model.uiAssignedContainer

        guard let data = LCUtils.generateWebClipProfileData(
            withBundlePath: rawBundlePath,
            containerId: containerFolder,
            targetScheme: scheme,
            iconStyle: style
        ) else {
            showError("Failed to generate WebClip configuration profile.")
            return
        }

        let sanitizedName = displayName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let fileName = sanitizedName.isEmpty ? "profile.mobileconfig" : "\(sanitizedName).mobileconfig"
        let iconImage = appInfo.generateLiveContainerWrappedIcon(with: style)
        let iconData = iconImage?.pngData()

        if let serverURL = LCMobileConfigServer.shared().serveProfileData(data, fileName: fileName, displayName: displayName, iconData: iconData) {
            UIApplication.shared.open(serverURL, options: [:]) { [weak self] success in
                guard success else {
                    Task { [weak self] in
                        await self?.shareWebClipProfile()
                    }
                    return
                }
            }
            showWebClipInstallInstructions()
        } else {
            await shareWebClipProfile()
        }
    }

    private func showWebClipInstallInstructions() {
        let alert = UIAlertController(
            title: "lc.appBanner.webClipInstructionsTitle".loc,
            message: "lc.appBanner.webClipInstructionsMessage".loc,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "lc.appBanner.openSettings".loc, style: .default) { _ in
            if let url = URL(string: "App-prefs:General&path=ManagedConfigurationList"), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsUrl, options: [:], completionHandler: nil)
            }
        })
        alert.addAction(UIAlertAction(title: "lc.appBanner.shareInstantWebClip".loc, style: .default) { [weak self] _ in
            Task { [weak self] in
                await self?.shareWebClipProfile()
            }
        })
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .cancel, handler: nil))

        Task { @MainActor in
            await self.presentDismissingIfNeeded(alert, animated: true)
        }
    }

    private func shareWebClipProfile() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }
        let model = configuration.model
        if model.uiAssignedContainer == nil {
            model.uiAssignedContainer = "livecontainer"
            refreshView()
        }
        let appInfo = model.appInfo
        let displayName = appInfo.displayName() ?? model.displayName
        let rawBundlePath = appInfo.bundlePath() ?? appInfo.relativeBundlePath
        let containerFolder = model.uiSelectedContainer?.folderName
        let scheme = model.uiAssignedContainer

        guard let data = LCUtils.generateWebClipProfileData(
            withBundlePath: rawBundlePath,
            containerId: containerFolder,
            targetScheme: scheme,
            iconStyle: style
        ) else {
            showError("Failed to generate WebClip configuration profile.")
            return
        }

        do {
            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let sanitizedName = displayName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let fileBaseName = sanitizedName.isEmpty ? "profile" : sanitizedName
            let fileURL = temporaryDirectory.appendingPathComponent("\(fileBaseName).mobileconfig")
            try data.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = bannerView
                popover.sourceRect = bannerView.bounds
            }
            await presentDismissingIfNeeded(activityVC, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let rawDisplayName = configuration.model.appInfo.displayName() ?? configuration.model.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            documentPicker.delegate = self
            documentPicker.presentationController?.delegate = self
            present(documentPicker, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupExportTemporaryDirectory()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupExportTemporaryDirectory()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupExportTemporaryDirectory()
    }

    private func cleanupExportTemporaryDirectory() {
        guard let exportTemporaryDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: exportTemporaryDirectory)
        self.exportTemporaryDirectory = nil
    }

    @MainActor
    private func presentDismissingIfNeeded(_ viewControllerToPresent: UIViewController, animated: Bool = true) async {
        if let presented = presentedViewController {
            await withCheckedContinuation { cont in
                presented.dismiss(animated: animated) {
                    cont.resume()
                }
            }
        }
        guard viewIfLoaded?.window != nil else { return }
        present(viewControllerToPresent, animated: animated)
    }

    private func packageDedicatedLiveContainer() async {
        guard LCUtils.isAppGroupAltStoreLike() else {
            showError("lc.settings.unsupportedInstallMethod".loc)
            return
        }

        let model = configuration.model
        let appInfo = model.appInfo
        let displayName = appInfo.displayName() ?? model.displayName

        guard let targetSlot = await promptForSlotSelection() else {
            return
        }

        let installMethod = await promptForDedicatedLCInstallMethod(targetSlot: targetSlot, appName: displayName)
        guard installMethod != 0 else {
            return
        }

        do {
            try await model.moveToSharedAppGroupIfNeeded()
            try? await model.signApp(force: false)

            var extraInfo: [String: Any] = [:]
            if let containerName = model.uiSelectedContainer?.folderName {
                extraInfo["LCAutoLaunchContainer"] = containerName
            }

            guard let bundlePath = model.appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }

            let packedIpaUrl = try LCUtils.archiveIPA(
                withBundleName: targetSlot,
                guestAppBundlePath: bundlePath,
                guestAppDisplayName: displayName,
                includingExtraInfoDict: extraInfo
            )

            if installMethod == 2 {
                let launchURLStr = packedIpaUrl.absoluteString
                let bookmark = try packedIpaUrl.bookmarkData(
                    options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionFileBookmark")
                LCUtils.openSideStore(urlStr: launchURLStr)
                return
            }

            let activityVC = UIActivityViewController(activityItems: [packedIpaUrl], applicationActivities: nil)
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = bannerView
                popover.sourceRect = bannerView.bounds
            }
            await presentDismissingIfNeeded(activityVC, animated: true)

        } catch {
            showError(error.localizedDescription)
        }
    }

    private func promptForSlotSelection() async -> String? {
        guard viewIfLoaded?.window != nil else {
            return nil
        }

        let slots = ["LiveContainer2", "LiveContainer3", "LiveContainer4", "LiveContainer5"]
        let lc2Installed = UIApplication.shared.canOpenURL(URL(string: "livecontainer2://")!)
        if !lc2Installed {
            return "LiveContainer2"
        }

        return await withUnsafeContinuation { continuation in
            let alert = UIAlertController(
                title: "lc.appBanner.createDedicatedLCSlotPrompt".loc,
                message: "lc.settings.multiLCInstallAlertDesc %@".localizeWithFormat(LCUtils.getStoreName()),
                preferredStyle: .actionSheet
            )

            for slot in slots {
                let isInstalled = (slot == "LiveContainer2") ? lc2Installed : UIApplication.shared.canOpenURL(URL(string: "\(slot.lowercased())://")!)
                let title = isInstalled ? "\(slot) (Installed - Replace)" : slot
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak alert] _ in
                    alert?.dismiss(animated: true) {
                        continuation.resume(returning: slot)
                    }
                })
            }

            alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { [weak alert] _ in
                alert?.dismiss(animated: true) {
                    continuation.resume(returning: nil)
                }
            })

            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.bannerView
                popover.sourceRect = self.bannerView.bounds
            }

            Task { @MainActor in
                await self.presentDismissingIfNeeded(alert, animated: true)
            }
        }
    }

    private func promptForDedicatedLCInstallMethod(targetSlot: String, appName: String) async -> Int {
        guard viewIfLoaded?.window != nil else {
            return 0
        }

        return await withUnsafeContinuation { continuation in
            let alert = UIAlertController(
                title: "lc.appBanner.createDedicatedLC".loc,
                message: "lc.appBanner.createDedicatedLCDesc %@ %@".localizeWithFormat(appName, targetSlot),
                preferredStyle: .alert
            )

            if UserDefaults.sideStoreExist() {
                alert.addAction(UIAlertAction(title: "lc.settings.multiLCInstall.installWithBuiltInSideStore".loc, style: .default) { [weak alert] _ in
                    alert?.dismiss(animated: true) {
                        continuation.resume(returning: 2)
                    }
                })
            }

            alert.addAction(UIAlertAction(title: "lc.appBanner.shareOrExportIPA".loc, style: .default) { [weak alert] _ in
                alert?.dismiss(animated: true) {
                    continuation.resume(returning: 1)
                }
            })

            alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { [weak alert] _ in
                alert?.dismiss(animated: true) {
                    continuation.resume(returning: 0)
                }
            })

            Task { @MainActor in
                await self.presentDismissingIfNeeded(alert, animated: true)
            }
        }
    }
}
