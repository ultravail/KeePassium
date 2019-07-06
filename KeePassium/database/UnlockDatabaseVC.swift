//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib

class UnlockDatabaseVC: UIViewController, Refreshable {
    @IBOutlet private weak var databaseNameLabel: UILabel!
    @IBOutlet private weak var inputPanel: UIView!
    @IBOutlet private weak var passwordField: UITextField!
    @IBOutlet private weak var keyFileField: UITextField!
    @IBOutlet private weak var keyboardAdjView: UIView!
    @IBOutlet private weak var errorMessagePanel: UIView!
    @IBOutlet private weak var errorLabel: UILabel!
    @IBOutlet private weak var errorDetailButton: UIButton!
    @IBOutlet private weak var watchdogTimeoutLabel: UILabel!
    @IBOutlet private weak var databaseIconImage: UIImageView!
    @IBOutlet weak var masterKeyKnownLabel: UILabel!
    @IBOutlet weak var getPremiumButton: UIButton!
    
    public var databaseRef: URLReference! {
        didSet {
            guard isViewLoaded else { return }
            hideErrorMessage(animated: false)
            refresh()
        }
    }
    
    private var keyFileRef: URLReference?
    private var databaseManagerNotifications: DatabaseManagerNotifications!
    private var fileKeeperNotifications: FileKeeperNotifications!

    static func make(databaseRef: URLReference) -> UnlockDatabaseVC {
        let vc = UnlockDatabaseVC.instantiateFromStoryboard()
        vc.databaseRef = databaseRef
        return vc
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        passwordField.delegate = self
        keyFileField.delegate = self
        
        databaseManagerNotifications = DatabaseManagerNotifications(observer: self)
        fileKeeperNotifications = FileKeeperNotifications(observer: self)
        // listen for
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPremiumStatus),
            name: PremiumManager.statusUpdateNotification,
            object: nil)

        // make background image
        view.backgroundColor = UIColor(patternImage: UIImage(asset: .backgroundPattern))
        view.layer.isOpaque = false
        
        // hide the hidden labels
        watchdogTimeoutLabel.alpha = 0.0
        errorMessagePanel.alpha = 0.0

        // Fix UIKeyboardAssistantBar constraints warnings for secure input field
        passwordField.inputAssistantItem.leadingBarButtonGroups = []
        passwordField.inputAssistantItem.trailingBarButtonGroups = []
        
        // Back button to return to this VC (that is, to be shown in ViewGroupVC)
        let lockDatabaseButton = UIBarButtonItem(
            title: NSLocalizedString("Close", comment: "Button to close currently opened database, when leaving the root group"),
            style: .plain,
            target: nil,
            action: nil)
        navigationItem.backBarButtonItem = lockDatabaseButton
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPremiumStatus()
        refresh()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fileKeeperNotifications.startObserving()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        onAppDidBecomeActive()
        
        if FileKeeper.shared.hasPendingFileOperations {
            processPendingFileOperations()
        }
        
        maybeFocusOnPassword()
    }
    
    @objc func onAppDidBecomeActive() {
        if Watchdog.shared.isDatabaseTimeoutExpired {
            showWatchdogTimeoutMessage()
        } else {
            hideWatchdogTimeoutMessage(animated: false)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        fileKeeperNotifications.stopObserving()
        super.viewWillDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        Diag.error("Received a memory warning")
        DatabaseManager.shared.progress.cancel(reason: .lowMemoryWarning)
    }
    
    func refresh() {
        guard isViewLoaded else { return }
        
        databaseIconImage.image = UIImage.databaseIcon(for: databaseRef)
        databaseNameLabel.text = databaseRef.info.fileName
        if databaseRef.info.hasError {
            showErrorMessage(databaseRef.info.errorMessage)
        }
        
        let associatedKeyFileRef = Settings.current
            .premiumGetKeyFileForDatabase(databaseRef: databaseRef)
        if let associatedKeyFileRef = associatedKeyFileRef {
            // Stored reference can be from the main app (inaccessible),
            // so make sure 1) it is available, or at least 2) there is a same-name available file.
            let allAvailableKeyFiles = FileKeeper.shared
                .getAllReferences(fileType: .keyFile, includeBackup: false)
            if let availableKeyFileRef = associatedKeyFileRef
                .find(in: allAvailableKeyFiles, fallbackToNamesake: true)
            {
                setKeyFile(urlRef: availableKeyFileRef)
            }
        }
        
        refreshInputMode()
    }
    
    @objc private func refreshPremiumStatus() {
        switch PremiumManager.shared.status {
        case .initialGracePeriod,
             .freeLightUse,
             .freeHeavyUse:
            getPremiumButton.isHidden = false
        case .subscribed,
             .lapsed:
            getPremiumButton.isHidden = true
        }
    }
    
    /// Switch the UI depending on whether the master key is already known.
    private func refreshInputMode() {
        let isDatabaseKeyStored = try? DatabaseManager.shared.hasKey(for: databaseRef)
            // throws KeychainError, ignored
        
        let shouldInputMasterKey = !(isDatabaseKeyStored ?? false)
        masterKeyKnownLabel.isHidden = shouldInputMasterKey
        inputPanel.isHidden = !shouldInputMasterKey
    }

    /// Makes password field the first responder, if visible
    private func maybeFocusOnPassword() {
        if !inputPanel.isHidden {
            passwordField.becomeFirstResponder()
        }
    }
    
    // MARK: - Showing/hiding various messagess

    /// Shows an error message about database loading.
    func showErrorMessage(_ message: String?, details: String?=nil) {
        guard let message = message else { return }
        
        if let details = details {
            errorLabel.text = " \(message)\n\(details) "
        } else {
            errorLabel.text = message
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            options: .curveEaseIn,
            animations: {
                [weak self] in
                self?.errorMessagePanel.alpha = 1.0
            },
            completion: {
                [weak self] (finished) in
                self?.errorMessagePanel.shake()
            }
        )
    }
    
    /// Hides the previously shown error message, if any.
    func hideErrorMessage(animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: 0.3,
                delay: 0.0,
                options: .curveEaseOut,
                animations: {
                    [weak self] in
                    self?.errorMessagePanel.alpha = 0.0
                },
                completion: {
                    [weak self] (finished) in
                    self?.errorLabel.text = nil
                }
            )
        } else {
            errorMessagePanel.isHidden = true
            errorLabel.text = nil
        }
    }
    
    func showWatchdogTimeoutMessage() {
        UIView.animate(
            withDuration: 0.5,
            delay: 0.0,
            options: .curveEaseOut,
            animations: {
                [weak self] in
                self?.watchdogTimeoutLabel.alpha = 1.0
            },
            completion: nil)
    }
    
    func hideWatchdogTimeoutMessage(animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                options: .curveEaseOut,
                animations: {
                    [weak self] in
                    self?.watchdogTimeoutLabel.alpha = 0.0
                },
                completion: nil)
        } else {
            watchdogTimeoutLabel.alpha = 0.0
        }
    }

    // MARK: - Progress tracking
    private var progressOverlay: ProgressOverlay?
    fileprivate func showProgressOverlay() {
        progressOverlay = ProgressOverlay.addTo(
            keyboardAdjView,
            title: LString.databaseStatusLoading,
            animated: true)
        progressOverlay?.isCancellable = true
        
        // Disable navigation so the user won't switch to another DB while unlocking.
        if let leftNavController = splitViewController?.viewControllers.first as? UINavigationController,
            let chooseDatabaseVC = leftNavController.topViewController as? ChooseDatabaseVC {
                chooseDatabaseVC.isEnabled = false
        }
        navigationItem.hidesBackButton = true
    }
    
    fileprivate func hideProgressOverlay() {
        UIView.animateKeyframes(
            withDuration: 0.2,
            delay: 0.0,
            options: [.beginFromCurrentState],
            animations: {
                [weak self] in
                self?.progressOverlay?.alpha = 0.0
            },
            completion: {
                [weak self] finished in
                guard let _self = self else { return }
                _self.progressOverlay?.removeFromSuperview()
                _self.progressOverlay = nil
            }
        )
        // Enable navigation
        navigationItem.hidesBackButton = false
        if let leftNavController = splitViewController?.viewControllers.first as? UINavigationController,
            let chooseDatabaseVC = leftNavController.topViewController as? ChooseDatabaseVC {
            chooseDatabaseVC.isEnabled = true
        }

        let p = DatabaseManager.shared.progress
        Diag.verbose("Final progress: \(p.completedUnitCount) of \(p.totalUnitCount)")
    }

    // MARK: - Key file selection
    
    func selectKeyFileAction(_ sender: Any) {
        Diag.verbose("Selecting key file")
        hideErrorMessage(animated: true)
        let keyFileChooser = ChooseKeyFileVC.make(popoverSourceView: keyFileField, delegate: self)
        present(keyFileChooser, animated: true, completion: nil)
    }
    
    // MARK: - Actions
    
    @IBAction func didPressErrorDetails(_ sender: Any) {
        let diagInfoVC = ViewDiagnosticsVC.make()
        present(diagInfoVC, animated: true, completion: nil)
    }
    
    @IBAction func didPressUnlock(_ sender: Any) {
        tryToUnlockDatabase()
    }
    
    private var premiumCoordinator: PremiumCoordinator?
    @IBAction func didPressUpgradeToPremium(_ sender: Any) {
        assert(premiumCoordinator == nil)
        premiumCoordinator = PremiumCoordinator(presentingViewController: self)
        premiumCoordinator?.delegate = self
        premiumCoordinator?.start()
    }
    
    // MARK: - DB unlocking
    
    func tryToUnlockDatabase() {
        Diag.clear()
        let password = passwordField.text ?? ""
        passwordField.resignFirstResponder()
        hideWatchdogTimeoutMessage(animated: true)
        databaseManagerNotifications.startObserving()
        
        do {
            if let databaseKey = try Keychain.shared.getDatabaseKey(databaseRef: databaseRef) {
                // throws KeychainError
                DatabaseManager.shared.startLoadingDatabase(
                    database: databaseRef,
                    compositeKey: databaseKey)
            } else {
                DatabaseManager.shared.startLoadingDatabase(
                    database: databaseRef,
                    password: password,
                    keyFile: keyFileRef)
            }
        } catch {
            Diag.error(error.localizedDescription)
            showErrorMessage(error.localizedDescription)
        }
    }
    
    /// Called when the DB is successfully loaded, shows it in ViewGroupVC
    func showDatabaseRoot(loadingWarnings: DatabaseLoadingWarnings) {
        guard let database = DatabaseManager.shared.database else {
            assertionFailure()
            return
        }
        let viewGroupVC = ViewGroupVC.make(group: database.root, loadingWarnings: loadingWarnings)
        guard let leftNavController =
            splitViewController?.viewControllers.first as? UINavigationController else
        {
            fatalError("No leftNavController?!")
        }
        leftNavController.show(viewGroupVC, sender: self)
    }
}

extension UnlockDatabaseVC: KeyFileChooserDelegate {
    func setKeyFile(urlRef: URLReference?) {
        // can be nil, can have error, can be ok
        keyFileRef = urlRef
        Settings.current.setKeyFileForDatabase(databaseRef: databaseRef, keyFileRef: keyFileRef)

        guard let fileInfo = urlRef?.info else {
            Diag.debug("No key file selected")
            keyFileField.text = ""
            return
        }
        if let errorDetails = fileInfo.errorMessage {
            let errorMessage = NSLocalizedString("Key file error: \(errorDetails)", comment: "Error message related to key file")
            Diag.warning(errorMessage)
            showErrorMessage(errorMessage)
            keyFileField.text = ""
        } else {
            Diag.info("Key file set successfully")
            keyFileField.text = fileInfo.fileName
        }
    }
    
    func onKeyFileSelected(urlRef: URLReference?) {
        setKeyFile(urlRef: urlRef)
    }
}

extension UnlockDatabaseVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == self.passwordField {
            tryToUnlockDatabase()
        }
        return true
    }
    
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String) -> Bool
    {
        hideErrorMessage(animated: true)
        hideWatchdogTimeoutMessage(animated: true)
        return true
    }
    
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        if textField === keyFileField {
            //textField.endEditing(true) //TODO: does not work
            passwordField.becomeFirstResponder()
            selectKeyFileAction(textField)
            return false
        }
        return true
    }
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
    }
}


// MARK: - DatabaseManagerDelegate extension
extension UnlockDatabaseVC: DatabaseManagerObserver {
    func databaseManager(willLoadDatabase urlRef: URLReference) {
        self.passwordField.text = "" // hide password length while decrypting
        showProgressOverlay()
    }
    
    func databaseManager(database urlRef: URLReference, isCancelled: Bool) {
        databaseManagerNotifications.stopObserving()
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef) // throws KeychainError, ignored
        refresh()
        hideProgressOverlay()
        // cancelled by the user, no errors to show
        maybeFocusOnPassword()
    }
    
    func databaseManager(progressDidChange progress: ProgressEx) {
        progressOverlay?.update(with: progress)
    }
    
    func databaseManager(database urlRef: URLReference, invalidMasterKey message: String) {
        databaseManagerNotifications.stopObserving()
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef) // throws KeychainError, ignored
        refresh()
        hideProgressOverlay()
        showErrorMessage(message)
        maybeFocusOnPassword()
    }
    
    func databaseManager(didLoadDatabase urlRef: URLReference, warnings: DatabaseLoadingWarnings) {
        databaseManagerNotifications.stopObserving()
        hideProgressOverlay()
        
//        Watchdog.shared.restart()
        
        if Settings.current.isRememberDatabaseKey {
            do {
                try DatabaseManager.shared.rememberDatabaseKey() // throws KeychainError
            } catch {
                Diag.error("Failed to remember database key [message: \(error.localizedDescription)]")
                let errorAlert = UIAlertController.make(
                    title: LString.titleKeychainError,
                    message: error.localizedDescription)
                present(errorAlert, animated: true, completion: nil)
            }
        }
        showDatabaseRoot(loadingWarnings: warnings)
    }

    func databaseManager(database urlRef: URLReference, loadingError message: String, reason: String?) {
        databaseManagerNotifications.stopObserving()
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef) // throws KeychainError, ignored
        refresh()
        hideProgressOverlay()
        showErrorMessage(message, details: reason)
        maybeFocusOnPassword()
    }
}

extension UnlockDatabaseVC: FileKeeperObserver {
    func fileKeeper(didAddFile urlRef: URLReference, fileType: FileType) {
        if fileType == .database {
            // (compact view only) show DB list to demonstrate that one has been added
            navigationController?.popViewController(animated: true)
        }
    }

    func fileKeeperHasPendingOperation() {
        processPendingFileOperations()
    }

    /// Adds pending files, if any
    private func processPendingFileOperations() {
        FileKeeper.shared.processPendingOperations(
            success: nil,
            error: {
                [weak self] (error) in
                guard let _self = self else { return }
                let alert = UIAlertController.make(
                    title: LString.titleError,
                    message: error.localizedDescription)
                _self.present(alert, animated: true, completion: nil)
            }
        )
    }
}

extension UnlockDatabaseVC: PremiumCoordinatorDelegate {
    func didUpgradeToPremium(in premiumCoordinator: PremiumCoordinator) {
        refresh()
        //TODO hurray
    }
    
    func didFinish(_ premiumCoordinator: PremiumCoordinator) {
        // it has already removed its modal VC
        self.premiumCoordinator = nil
    }
}
