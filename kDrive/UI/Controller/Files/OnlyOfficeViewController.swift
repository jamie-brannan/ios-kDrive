/*
Infomaniak kDrive - iOS App
Copyright (C) 2021 Infomaniak Network SA

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

import UIKit
import WebKit
import kDriveCore
import Sentry

class OnlyOfficeViewController: UIViewController, WKNavigationDelegate {

    var driveFileManager: DriveFileManager!
    var file: File!
    weak var previewParent: PreviewViewController?

    var webView: WKWebView!
    let progressView = UIProgressView()

    private var progressObserver: NSKeyValueObservation?

    class func open(driveFileManager: DriveFileManager, file: File, viewController: UIViewController) {
        guard file.isOfficeFile else { return }

        if let newExtension = file.onlyOfficeConvertExtension {
            let driveFloatingPanelController = UnsupportedExtensionFloatingPanelViewController.instantiatePanel()
            let attrString = NSMutableAttributedString(string: KDriveStrings.Localizable.notSupportedExtensionDescription(file.name), boldText: file.name, color: KDriveAsset.titleColor.color)
            guard let floatingPanelViewController = driveFloatingPanelController.contentViewController as? UnsupportedExtensionFloatingPanelViewController else { return }
            floatingPanelViewController.titleLabel.text = KDriveStrings.Localizable.notSupportedExtensionTitle(file.extension)
            floatingPanelViewController.descriptionLabel.attributedText = attrString
            floatingPanelViewController.rightButton.setTitle(KDriveStrings.Localizable.buttonCreateOnlyOfficeCopy(newExtension), for: .normal)
            floatingPanelViewController.cancelHandler = { _ in
                viewController.dismiss(animated: true)
                let onlyOfficeViewController = OnlyOfficeViewController.instantiate(driveFileManager: driveFileManager, file: file, previewParent: viewController as? PreviewViewController)
                viewController.present(onlyOfficeViewController, animated: true)
            }
            floatingPanelViewController.actionHandler = { sender in
                sender.setLoading(true)
                driveFileManager.apiFetcher.convertFile(file: file) { response, _ in
                    sender.setLoading(false)
                    if let newFile = response?.data {
                        if let parent = file.parent {
                            driveFileManager.notifyObserversWith(file: parent)
                        }
                        viewController.dismiss(animated: true)
                        open(driveFileManager: driveFileManager, file: newFile, viewController: viewController)
                    } else {
                        UIConstants.showSnackBar(message: KDriveStrings.Localizable.errorGeneric)
                    }
                }
            }
            viewController.present(driveFloatingPanelController, animated: true)
        } else {
            let onlyOfficeViewController = OnlyOfficeViewController.instantiate(driveFileManager: driveFileManager, file: file, previewParent: viewController as? PreviewViewController)
            viewController.present(onlyOfficeViewController, animated: true)
        }
    }

    class func instantiate(driveFileManager: DriveFileManager, file: File, previewParent: PreviewViewController?) -> OnlyOfficeViewController {
        let onlyOfficeViewController = OnlyOfficeViewController()
        onlyOfficeViewController.driveFileManager = driveFileManager
        onlyOfficeViewController.file = file
        onlyOfficeViewController.previewParent = previewParent
        onlyOfficeViewController.modalPresentationStyle = .fullScreen
        return onlyOfficeViewController
    }

    override func loadView() {
        let webConfiguration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        if #available(iOS 13.0, *) {
            // Force mobile mode for better usage on iPadOS
            webView.configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        }
        progressObserver = webView.observe(\.estimatedProgress, options: .new) { [weak self] _, value in
            guard let newValue = value.newValue else {
                return
            }
            self?.progressView.isHidden = newValue == 1
            self?.progressView.setProgress(Float(newValue), animated: true)
        }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Add progress view
        view.addSubview(progressView)
        progressView.progressViewStyle = .bar
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor).isActive = true
        progressView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor).isActive = true
        progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true

        // Load request
        if let url = URL(string: ApiRoutes.mobileLogin(url: ApiRoutes.showOffice(file: file))) {
            if let token = driveFileManager.apiFetcher.currentToken {
                driveFileManager.apiFetcher.performAuthenticatedRequest(token: token) { token, _ in
                    if let token = token {
                        var request = URLRequest(url: url)
                        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
                        DispatchQueue.main.async {
                            self.webView.load(request)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.showErrorMessage()
                        }
                    }
                }
            } else {
                showErrorMessage()
            }
        } else {
            showErrorMessage(context: ["URL": "nil"])
        }
    }

    deinit {
        progressObserver?.invalidate()
    }

    private func showErrorMessage(context: [String: Any] = [:]) {
        SentrySDK.capture(message: "Failed to load office editor") { scope in
            scope.setContext(value: context, key: "office")
        }
        dismiss(animated: true) {
            UIConstants.showSnackBar(message: KDriveStrings.Localizable.errorLoadingOfficeEditor)
        }
    }

    private func dismiss() {
        dismiss(animated: true)
    }

    // MARK: - Web view navigation delegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString {
            if url == file.officeUrl?.absoluteString || url.contains("login.infomaniak.com") || url.contains("manager.infomaniak.com/v3/mobile_login") || url.contains("documentserver.drive.infomaniak.com") {
                decisionHandler(.allow)
                return
            }
        }
        decisionHandler(.cancel)
        dismiss()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let statusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode else {
            decisionHandler(.allow)
            return
        }

        if statusCode == 200 {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            showErrorMessage(context: ["URL": navigationResponse.response.url?.absoluteString ?? "", "Status code": statusCode])
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showErrorMessage(context: ["Error": error])
    }
}
