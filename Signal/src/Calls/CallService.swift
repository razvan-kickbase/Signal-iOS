//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import LibSignalClient
import SignalMessaging
import SignalRingRTC
import SignalUI
import WebRTC

// All Observer methods will be invoked from the main thread.
protocol CallServiceObserver: AnyObject {
    /**
     * Fired whenever the call changes.
     */
    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?)
}

/// Manages events related to both 1:1 and group calls, while the main app is
/// running.
///
/// Responsible for the 1:1 or group call this device is currently active in, if
/// any, as well as any other updates to other calls that we learn about.
public final class CallService: LightweightGroupCallManager {
    public typealias CallManagerType = CallManager<SignalCall, CallService>

    private var _callManager: CallManagerType! = nil
    public private(set) var callManager: CallManagerType {
        get { _callManager }
        set {
            if _callManager == nil {
                _callManager = newValue
            } else {
                owsFailDebug("Should only be set once")
            }
        }
    }

    public var callUIAdapter: CallUIAdapter!

    @objc
    public let individualCallService = IndividualCallService()
    let groupCallRemoteVideoManager = GroupCallRemoteVideoManager()

    /// Needs to be lazily initialized, because it uses singletons that are not
    /// available when this class is initialized.
    private lazy var groupCallAccessoryMessageDelegate: GroupCallAccessoryMessageDelegate = {
        return GroupCallAccessoryMessageHandler(
            databaseStorage: databaseStorage,
            groupCallRecordManager: DependenciesBridge.shared.groupCallRecordManager,
            messageSenderJobQueue: SSKEnvironment.shared.messageSenderJobQueueRef
        )
    }()

    /// Needs to be lazily initialized, because it uses singletons that are not
    /// available when this class is initialized.
    private lazy var groupCallRecordRingUpdateDelegate: GroupCallRecordRingUpdateDelegate = {
        return GroupCallRecordRingUpdateHandler(
            callRecordStore: DependenciesBridge.shared.callRecordStore,
            groupCallRecordManager: DependenciesBridge.shared.groupCallRecordManager,
            interactionStore: DependenciesBridge.shared.interactionStore,
            threadStore: DependenciesBridge.shared.threadStore
        )
    }()

    lazy private(set) var audioService = CallAudioService()

    public var earlyRingNextIncomingCall = false

    /// Current call *must* be set on the main thread. It may be read off the main thread if the current call state must be consulted,
    /// but othere call state may race (observer state, sleep state, etc.)
    private var _currentCallLock = UnfairLock()
    private var _currentCall: SignalCall?

    /// Represents the call currently occuring on this device.
    @objc
    public private(set) var currentCall: SignalCall? {
        get {
            _currentCallLock.withLock {
                _currentCall
            }
        }
        set {
            AssertIsOnMainThread()

            let oldValue: SignalCall? = _currentCallLock.withLock {
                let oldValue = _currentCall
                _currentCall = newValue
                return oldValue
            }

            oldValue?.removeObserver(self)
            newValue?.addObserverAndSyncState(observer: self)

            updateIsVideoEnabled()

            // Prevent device from sleeping while we have an active call.
            if oldValue != newValue {
                if let oldValue = oldValue {
                    DeviceSleepManager.shared.removeBlock(blockObject: oldValue)
                    if !UIDevice.current.isIPad {
                        UIDevice.current.endGeneratingDeviceOrientationNotifications()
                    }
                }

                if let newValue = newValue {
                    assert(calls.contains(newValue))
                    DeviceSleepManager.shared.addBlock(blockObject: newValue)

                    if newValue.isIndividualCall {

                        // By default, individual calls should start out with speakerphone disabled.
                        self.audioService.requestSpeakerphone(isEnabled: false)

                        individualCallService.startCallTimer()
                    }

                    if !UIDevice.current.isIPad {
                        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                    }
                } else {
                    individualCallService.stopAnyCallTimer()
                }
            }

            // To be safe, we reset the early ring on any call change so it's not left set from an unexpected state change
            earlyRingNextIncomingCall = false

            Logger.debug("\(oldValue as Optional) -> \(newValue as Optional)")

            let observers = self.observers
            DispatchQueue.main.async {
                for observer in observers.elements {
                    observer.didUpdateCall(from: oldValue, to: newValue)
                }
            }
        }
    }

    /// True whenever CallService has any call in progress.
    /// The call may not yet be visible to the user if we are still in the middle of signaling.
    public var hasCallInProgress: Bool {
        calls.count > 0
    }

    /// Track all calls that are currently "in play". Usually this is 1 or 0, but when dealing
    /// with a rapid succession of calls, it's possible to have multiple.
    ///
    /// For example, if the client receives two call offers, we hand them both off to RingRTC,
    /// which will let us know which one, if any, should become the "current call". But in the
    /// meanwhile, we still want to track that calls are in-play so we can prevent the user from
    /// placing an outgoing call.
    private let _calls = AtomicSet<SignalCall>()
    private var calls: Set<SignalCall> { _calls.allValues }

    private func addCall(_ call: SignalCall) {
        _calls.insert(call)
        postActiveCallsDidChange()
    }

    private func removeCall(_ call: SignalCall) -> Bool {
        let didRemove = _calls.remove(call)
        postActiveCallsDidChange()
        return didRemove
    }

    public static let activeCallsDidChange = Notification.Name("activeCallsDidChange")

    private func postActiveCallsDidChange() {
        NotificationCenter.default.postNotificationNameAsync(Self.activeCallsDidChange, object: nil)
    }

    public override init() {
        super.init()
        callManager = CallManager(
            httpClient: httpClient,
            fieldTrials: RingrtcFieldTrials.trials(with: CurrentAppContext().appUserDefaults())
        )
        callManager.delegate = self
        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: .OWSApplicationDidEnterBackground,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: .OWSApplicationDidBecomeActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configureDataMode),
            name: Self.callServicePreferencesDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationChanged),
            name: .registrationStateDidChange,
            object: nil)

        // Note that we're not using the usual .owsReachabilityChanged
        // We want to update our data mode if the app has been backgrounded
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configureDataMode),
            name: .reachabilityChanged,
            object: nil)

        // We don't support a rotating call screen on phones,
        // but we do still want to rotate the various icons.
        if !UIDevice.current.isIPad {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(phoneOrientationDidChange),
                                                   name: UIDevice.orientationDidChangeNotification,
                                                   object: nil)
        }

        AppReadiness.runNowOrWhenAppWillBecomeReady {
            if let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci {
                self.callManager.setSelfUuid(localAci.rawUUID)
            }
        }

        AppReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            SDSDatabaseStorage.shared.appendDatabaseChangeDelegate(self)

            self.addObserverAndSyncState(observer: self.groupCallAccessoryMessageDelegate)
            self.addObserverAndSyncState(observer: self.groupCallRemoteVideoManager)
        }
    }

    /**
     * Choose whether to use CallKit or a Notification backed interface for calling.
     */
    public func createCallUIAdapter() {
        AssertIsOnMainThread()

        if let call = callService.currentCall {
            Logger.warn("ending current call in. Did user toggle callkit preference while in a call?")
            callService.terminate(call: call)
        }

        self.callUIAdapter = CallUIAdapter()
    }

    // MARK: - Observers

    private var observers = WeakArray<CallServiceObserver>()

    func addObserverAndSyncState(observer: CallServiceObserver) {
        addObserver(observer: observer, syncStateImmediately: true)
    }

    func addObserver(observer: CallServiceObserver, syncStateImmediately: Bool) {
        AssertIsOnMainThread()

        observers.append(observer)

        if syncStateImmediately {
            // Synchronize observer with current call state
            observer.didUpdateCall(from: nil, to: currentCall)
        }
    }

    // The observer-related methods should be invoked on the main thread.
    func removeObserver(_ observer: CallServiceObserver) {
        AssertIsOnMainThread()
        observers.removeAll { $0 === observer }
    }

    // The observer-related methods should be invoked on the main thread.
    func removeAllObservers() {
        AssertIsOnMainThread()

        observers = []
    }

    // MARK: -

    /**
     * Local user toggled to mute audio.
     */
    func updateIsLocalAudioMuted(isLocalAudioMuted: Bool) {
        AssertIsOnMainThread()

        // Keep a reference to the call before permissions were requested...
        guard let call = currentCall else {
            owsFailDebug("missing currentCall")
            return
        }

        // If we're disabling the microphone, we don't need permission. Only need
        // permission to *enable* the microphone.
        guard !isLocalAudioMuted else {
            return updateIsLocalAudioMutedWithMicrophonePermission(call: call, isLocalAudioMuted: isLocalAudioMuted)
        }

        // This method can be initiated either from the CallViewController.videoButton or via CallKit
        // in either case we want to show the alert on the callViewWindow.
        guard let frontmostViewController =
                UIApplication.shared.findFrontmostViewController(ignoringAlerts: true,
                                                                 window: WindowManager.shared.callViewWindow) else {
            owsFailDebug("could not identify frontmostViewController")
            return
        }

        frontmostViewController.ows_askForMicrophonePermissions { granted in
            // Make sure the call is still valid (the one we asked permissions for).
            guard self.currentCall === call else {
                Logger.info("ignoring microphone permissions for obsolete call")
                return
            }

            if !granted {
                frontmostViewController.ows_showNoMicrophonePermissionActionSheet()
            }

            let mutedAfterAskingForPermission = !granted
            self.updateIsLocalAudioMutedWithMicrophonePermission(call: call, isLocalAudioMuted: mutedAfterAskingForPermission)
        }
    }

    private func updateIsLocalAudioMutedWithMicrophonePermission(call: SignalCall, isLocalAudioMuted: Bool) {
        AssertIsOnMainThread()

        guard call === self.currentCall else {
            cleanupStaleCall(call)
            return
        }

        switch call.mode {
        case .group(let groupCall):
            groupCall.isOutgoingAudioMuted = isLocalAudioMuted
            call.groupCall(onLocalDeviceStateChanged: groupCall)
        case .individual(let individualCall):
            individualCall.isMuted = isLocalAudioMuted
            individualCallService.ensureAudioState(call: call)
        }
    }

    /**
     * Local user toggled video.
     */
    func updateIsLocalVideoMuted(isLocalVideoMuted: Bool) {
        AssertIsOnMainThread()

        // Keep a reference to the call before permissions were requested...
        guard let call = currentCall else {
            owsFailDebug("missing currentCall")
            return
        }

        // If we're disabling local video, we don't need permission. Only need
        // permission to *enable* video.
        guard !isLocalVideoMuted else {
            return updateIsLocalVideoMutedWithCameraPermissions(call: call, isLocalVideoMuted: isLocalVideoMuted)
        }

        // This method can be initiated either from the CallViewController.videoButton or via CallKit
        // in either case we want to show the alert on the callViewWindow.
        guard let frontmostViewController =
                UIApplication.shared.findFrontmostViewController(ignoringAlerts: true,
                                                                 window: WindowManager.shared.callViewWindow) else {
            owsFailDebug("could not identify frontmostViewController")
            return
        }

        frontmostViewController.ows_askForCameraPermissions { granted in
            // Make sure the call is still valid (the one we asked permissions for).
            guard self.currentCall === call else {
                Logger.info("ignoring camera permissions for obsolete call")
                return
            }

            let mutedAfterAskingForPermission = !granted
            self.updateIsLocalVideoMutedWithCameraPermissions(call: call, isLocalVideoMuted: mutedAfterAskingForPermission)
        }
    }

    private func updateIsLocalVideoMutedWithCameraPermissions(call: SignalCall, isLocalVideoMuted: Bool) {
        AssertIsOnMainThread()

        guard call === self.currentCall else {
            cleanupStaleCall(call)
            return
        }

        switch call.mode {
        case .group(let groupCall):
            groupCall.isOutgoingVideoMuted = isLocalVideoMuted
            call.groupCall(onLocalDeviceStateChanged: groupCall)
        case .individual(let individualCall):
            individualCall.hasLocalVideo = !isLocalVideoMuted
        }

        updateIsVideoEnabled()
    }

    func updateCameraSource(call: SignalCall, isUsingFrontCamera: Bool) {
        AssertIsOnMainThread()

        call.videoCaptureController.switchCamera(isUsingFrontCamera: isUsingFrontCamera)
    }

    func cleanupStaleCall(_ staleCall: SignalCall, function: StaticString = #function, line: UInt = #line) {
        assert(staleCall !== currentCall)
        if let currentCall = currentCall {
            let error = OWSAssertionError("trying \(function):\(line) for call: \(staleCall) which is not currentCall: \(currentCall as Optional)")
            handleFailedCall(failedCall: staleCall, error: error)
        } else {
            Logger.info("ignoring \(function):\(line) for call: \(staleCall) since currentCall has ended.")
        }
    }

    @objc
    private func configureDataMode() {
        guard AppReadiness.isAppReady else { return }
        guard let currentCall = currentCall else { return }

        switch currentCall.mode {
        case let .group(call):
            let useLowData = Self.shouldUseLowDataWithSneakyTransaction(for: call.localDeviceState.networkRoute)
            Logger.info("Configuring call for \(useLowData ? "low" : "standard") data")
            call.updateDataMode(dataMode: useLowData ? .low : .normal)
        case let .individual(call) where call.state == .connected:
            let useLowData = Self.shouldUseLowDataWithSneakyTransaction(for: call.networkRoute)
            Logger.info("Configuring call for \(useLowData ? "low" : "standard") data")
            callManager.updateDataMode(dataMode: useLowData ? .low : .normal)
        default:
            // Do nothing. We'll reapply the data mode once connected
            break
        }
    }

    static func shouldUseLowDataWithSneakyTransaction(for networkRoute: NetworkRoute) -> Bool {
        let highDataInterfaces = databaseStorage.read { readTx in
            Self.highDataNetworkInterfaces(readTx: readTx)
        }
        if let allowsHighData = highDataInterfaces.includes(networkRoute.localAdapterType) {
            return !allowsHighData
        }
        // If we aren't sure whether the current route's high-data, fall back to checking reachability.
        // This also handles the situation where WebRTC doesn't know what interface we're on,
        // which is always true on iOS 11.
        return !Self.reachabilityManager.isReachable(with: highDataInterfaces)
    }

    // MARK: -

    // This method should be called when a fatal error occurred for a call.
    //
    // * If we know which call it was, we should update that call's state
    //   to reflect the error.
    // * IFF that call is the current call, we want to terminate it.
    public func handleFailedCall(failedCall: SignalCall, error: Error) {
        AssertIsOnMainThread()
        Logger.debug("")

        let callError: SignalCall.CallError = {
            switch error {
            case let callError as SignalCall.CallError:
                return callError
            default:
                return SignalCall.CallError.externalError(underlyingError: error)
            }
        }()

        failedCall.error = callError

        if failedCall.isIndividualCall {
            individualCallService.handleFailedCall(failedCall: failedCall, error: callError, shouldResetUI: false, shouldResetRingRTC: true)
        } else {
            terminate(call: failedCall)
        }
    }

    func handleLocalHangupCall(_ call: SignalCall) {
        AssertIsOnMainThread()

        if call.isIndividualCall {
            individualCallService.handleLocalHangupCall(call)
        } else {
            if case .incomingRing(_, let ringId) = call.groupCallRingState {
                guard let (groupThread, _) = call.unpackGroupCall() else {
                    return
                }

                groupCallAccessoryMessageDelegate.localDeviceDeclinedGroupRing(
                    ringId: ringId,
                    groupThread: groupThread
                )

                do {
                    try callManager.cancelGroupRing(
                        groupId: groupThread.groupId,
                        ringId: ringId,
                        reason: .declinedByUser
                    )
                } catch {
                    owsFailDebug("RingRTC failed to cancel group ring \(ringId): \(error)")
                }
            }
            terminate(call: call)
        }
    }

    /**
     * Clean up any existing call state and get ready to receive a new call.
     */
    func terminate(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("call: \(call as Optional)")

        // If call is for the current call, clear it out first.
        if call === currentCall { currentCall = nil }

        if !removeCall(call) {
            owsFailDebug("unknown call: \(call)")
        }

        if !hasCallInProgress {
            audioSession.isRTCAudioEnabled = false
        }
        audioSession.endAudioActivity(call.audioActivity)

        switch call.mode {
        case .individual:
            break
        case .group(let groupCall):
            groupCall.leave()
            groupCall.disconnect()

            // Kick off a peek now that we've disconnected to get an updated participant state.
            if let thread = call.thread as? TSGroupThread {
                peekGroupCallAndUpdateThread(
                    thread,
                    peekTrigger: .localEvent()
                )
            } else {
                owsFailDebug("Invalid thread type")
            }
        }
    }

    // MARK: - Video

    var shouldHaveLocalVideoTrack: Bool {
        AssertIsOnMainThread()

        guard let call = self.currentCall else {
            return false
        }

        // The iOS simulator doesn't provide any sort of camera capture
        // support or emulation (http://goo.gl/rHAnC1) so don't bother
        // trying to open a local stream.
        guard !Platform.isSimulator else { return false }
        guard UIApplication.shared.applicationState != .background else { return false }

        switch call.mode {
        case .individual(let individualCall):
            return individualCall.state == .connected && individualCall.hasLocalVideo
        case .group(let groupCall):
            return !groupCall.isOutgoingVideoMuted
        }
    }

    func updateIsVideoEnabled() {
        AssertIsOnMainThread()

        guard let call = self.currentCall else { return }

        switch call.mode {
        case .individual(let individualCall):
            if individualCall.state == .connected || individualCall.state == .reconnecting {
                callManager.setLocalVideoEnabled(enabled: shouldHaveLocalVideoTrack, call: call)
            } else {
                // If we're not yet connected, just enable the camera but don't tell RingRTC
                // to start sending video. This allows us to show a "vanity" view while connecting.
                if !Platform.isSimulator && individualCall.hasLocalVideo {
                    call.videoCaptureController.startCapture()
                } else {
                    call.videoCaptureController.stopCapture()
                }
            }
        case .group:
            if shouldHaveLocalVideoTrack {
                call.videoCaptureController.startCapture()
            } else {
                call.videoCaptureController.stopCapture()
            }
        }
    }

    // MARK: -

    func buildAndConnectGroupCallIfPossible(thread: TSGroupThread, videoMuted: Bool) -> SignalCall? {
        AssertIsOnMainThread()
        guard !hasCallInProgress else { return nil }

        guard let call = SignalCall.groupCall(thread: thread) else { return nil }
        addCall(call)

        // By default, group calls should start out with speakerphone enabled.
        self.audioService.requestSpeakerphone(isEnabled: true)

        call.groupCall.isOutgoingAudioMuted = false
        call.groupCall.isOutgoingVideoMuted = videoMuted

        currentCall = call

        guard call.groupCall.connect() else {
            terminate(call: call)
            return nil
        }

        return call
    }

    func joinGroupCallIfNecessary(_ call: SignalCall) {
        owsAssertDebug(call.isGroupCall)

        let currentCall = self.currentCall
        if currentCall == nil {
            self.currentCall = call
        } else if currentCall != call {
            return owsFailDebug("A call is already in progress")
        }

        // If we're not yet connected, connect now. This may happen if, for
        // example, the call ended unexpectedly.
        if call.groupCall.localDeviceState.connectionState == .notConnected {
            guard call.groupCall.connect() else {
                terminate(call: call)
                return
            }
        }

        // If we're not yet joined, join now. In general, it's unexpected that
        // this method would be called when you're already joined, but it is
        // safe to do so.
        if call.groupCall.localDeviceState.joinState == .notJoined {
            call.groupCall.join()
            // Group calls can get disconnected, but we don't count that as ending the call.
            // So this call may have already been reported.
            if call.systemState == .notReported && !call.groupCallRingState.isIncomingRing {
                callUIAdapter.startOutgoingCall(call: call)
            }
        }
    }

    @discardableResult
    @objc
    public func initiateCall(thread: TSThread, isVideo: Bool) -> Bool {
        initiateCall(thread: thread, isVideo: isVideo, untrustedThreshold: nil)
    }

    private func initiateCall(thread: TSThread, isVideo: Bool, untrustedThreshold: Date?) -> Bool {
        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            Logger.warn("aborting due to user not being registered.")
            OWSActionSheets.showActionSheet(title: OWSLocalizedString("YOU_MUST_COMPLETE_ONBOARDING_BEFORE_PROCEEDING",
                                                                     comment: "alert body shown when trying to use features in the app before completing registration-related setup."))
            return false
        }

        guard let frontmostViewController = UIApplication.shared.frontmostViewController else {
            owsFailDebug("could not identify frontmostViewController")
            return false
        }

        if let groupThread = thread as? TSGroupThread {
            return GroupCallViewController.presentLobby(thread: groupThread, videoMuted: !isVideo)
        }

        guard let thread = thread as? TSContactThread else {
            owsFailDebug("cannot initiate call to group thread")
            return false
        }

        let newUntrustedThreshold = Date()
        let showedAlert = SafetyNumberConfirmationSheet.presentIfNecessary(
            addresses: [thread.contactAddress],
            confirmationText: CallStrings.confirmAndCallButtonTitle,
            untrustedThreshold: untrustedThreshold
        ) { didConfirmIdentity in
            guard didConfirmIdentity else { return }
            _ = self.initiateCall(thread: thread, isVideo: isVideo, untrustedThreshold: newUntrustedThreshold)
        }
        guard !showedAlert else {
            return false
        }

        frontmostViewController.ows_askForMicrophonePermissions { granted in
            guard granted == true else {
                Logger.warn("aborting due to missing microphone permissions.")
                frontmostViewController.ows_showNoMicrophonePermissionActionSheet()
                return
            }

            if isVideo {
                frontmostViewController.ows_askForCameraPermissions { granted in
                    guard granted else {
                        Logger.warn("aborting due to missing camera permissions.")
                        return
                    }

                    self.callUIAdapter.startAndShowOutgoingCall(thread: thread, hasLocalVideo: true)
                }
            } else {
                self.callUIAdapter.startAndShowOutgoingCall(thread: thread, hasLocalVideo: false)
            }
        }

        return true
    }

    func buildOutgoingIndividualCallIfPossible(thread: TSContactThread, hasVideo: Bool) -> SignalCall? {
        AssertIsOnMainThread()
        guard !hasCallInProgress else { return nil }

        let call = SignalCall.outgoingIndividualCall(thread: thread)
        call.individualCall.offerMediaType = hasVideo ? .video : .audio

        addCall(call)

        return call
    }

    func prepareIncomingIndividualCall(
        thread: TSContactThread,
        sentAtTimestamp: UInt64,
        callType: SSKProtoCallMessageOfferType
    ) -> SignalCall {
        AssertIsOnMainThread()

        let offerMediaType: TSRecentCallOfferType
        switch callType {
        case .offerAudioCall:
            offerMediaType = .audio
        case .offerVideoCall:
            offerMediaType = .video
        }

        let newCall = SignalCall.incomingIndividualCall(
            thread: thread,
            sentAtTimestamp: sentAtTimestamp,
            offerMediaType: offerMediaType
        )

        addCall(newCall)

        return newCall
    }

    // MARK: - Notifications

    @objc
    private func didEnterBackground() {
        AssertIsOnMainThread()
        self.updateIsVideoEnabled()
    }

    @objc
    private func didBecomeActive() {
        AssertIsOnMainThread()
        self.updateIsVideoEnabled()
    }

    @objc
    private func registrationChanged() {
        AssertIsOnMainThread()
        if let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci {
            callManager.setSelfUuid(localAci.rawUUID)
        }
    }

    /// The object is the rotation angle necessary to match the new orientation.
    static var phoneOrientationDidChange = Notification.Name("CallService.phoneOrientationDidChange")

    @objc
    private func phoneOrientationDidChange() {
        guard currentCall != nil else {
            return
        }
        sendPhoneOrientationNotification()
    }

    private func shouldReorientUI(for call: SignalCall) -> Bool {
        owsAssertDebug(!UIDevice.current.isIPad, "iPad has full UIKit rotation support")

        guard call.isIndividualCall else {
            // If we're in a group call, we don't want to use rotating icons,
            // because we don't rotate user video at the same time,
            // and that's very obvious for grid view or any non-speaker tile in speaker view.
            return false
        }

        // If we're in an audio-only 1:1 call, the user isn't going to be looking at the screen.
        // Don't distract them with rotating icons.
        return call.individualCall.hasLocalVideo || call.individualCall.isRemoteVideoEnabled
    }

    private func sendPhoneOrientationNotification() {
        owsAssertDebug(!UIDevice.current.isIPad, "iPad has full UIKit rotation support")

        let rotationAngle: CGFloat
        if let call = currentCall, !shouldReorientUI(for: call) {
            // We still send the notification in case we *previously* rotated the UI and now we need to revert back.
            // Example:
            // 1. In a 1:1 call, either the user or their contact (but not both) has video on
            // 2. the user has the phone in landscape
            // 3. whoever had video turns it off (but the icons are still landscape-oriented)
            // 4. the user rotates back to portrait
            rotationAngle = 0
        } else {
            switch UIDevice.current.orientation {
            case .landscapeLeft:
                rotationAngle = .halfPi
            case .landscapeRight:
                rotationAngle = -.halfPi
            case .portrait, .portraitUpsideDown, .faceDown, .faceUp, .unknown:
                fallthrough
            @unknown default:
                rotationAngle = 0
            }
        }

        NotificationCenter.default.post(name: Self.phoneOrientationDidChange, object: rotationAngle)
    }

    /// Pretend the phone just changed orientations so that the call UI will autorotate.
    func sendInitialPhoneOrientationNotification() {
        guard !UIDevice.current.isIPad else {
            return
        }
        sendPhoneOrientationNotification()
    }

    // MARK: -

    private func updateGroupMembersForCurrentCallIfNecessary() {
        DispatchQueue.main.async {
            guard let call = self.currentCall, call.isGroupCall,
                  let groupThread = call.thread as? TSGroupThread else { return }

            let membershipInfo: [GroupMemberInfo]
            do {
                membershipInfo = try self.databaseStorage.read {
                    try self.groupMemberInfo(for: groupThread, transaction: $0)
                }
            } catch {
                owsFailDebug("Failed to fetch membership info: \(error)")
                return
            }
            call.groupCall.updateGroupMembers(members: membershipInfo)
        }
    }

    // MARK: - Data Modes

    static let callServicePreferencesDidChange = Notification.Name("CallServicePreferencesDidChange")
    private static let keyValueStore = SDSKeyValueStore(collection: "CallService")
    // This used to be called "high bandwidth", but "data" is more accurate.
    private static let highDataPreferenceKey = "HighBandwidthPreferenceKey"

    static func setHighDataInterfaces(_ interfaceSet: NetworkInterfaceSet, writeTx: SDSAnyWriteTransaction) {
        Logger.info("Updating preferred low data interfaces: \(interfaceSet.rawValue)")

        keyValueStore.setUInt(interfaceSet.rawValue, key: highDataPreferenceKey, transaction: writeTx)
        writeTx.addSyncCompletion {
            NotificationCenter.default.postNotificationNameAsync(callServicePreferencesDidChange, object: nil)
        }
    }

    static func highDataNetworkInterfaces(readTx: SDSAnyReadTransaction) -> NetworkInterfaceSet {
        guard let highDataPreference = keyValueStore.getUInt(
                highDataPreferenceKey,
                transaction: readTx) else { return .wifiAndCellular }

        return NetworkInterfaceSet(rawValue: highDataPreference)
    }

    // MARK: -

    override public func peekGroupCallAndUpdateThread(
        _ thread: TSGroupThread,
        peekTrigger: PeekTrigger,
        completion: (() -> Void)? = nil
    ) {
        // If the currentCall is for the provided thread, we don't need to perform an explicit
        // peek. Connected calls will receive automatic updates from RingRTC
        guard currentCall?.thread != thread else {
            Logger.info("Ignoring peek request for the current call")
            return
        }

        super.peekGroupCallAndUpdateThread(
            thread,
            peekTrigger: peekTrigger,
            completion: completion
        )
    }

    override public func postUserNotificationIfNecessary(
        groupCallMessage: OWSGroupCallMessage,
        joinedMemberAcis: [Aci],
        creatorAci: Aci,
        groupThread: TSGroupThread,
        tx: SDSAnyWriteTransaction
    ) {
        AssertNotOnMainThread()

        // The message can't be for the current call
        guard self.currentCall?.thread != groupThread else { return }

        super.postUserNotificationIfNecessary(
            groupCallMessage: groupCallMessage,
            joinedMemberAcis: joinedMemberAcis,
            creatorAci: creatorAci,
            groupThread: groupThread,
            tx: tx
        )
    }
}

extension CallService: CallObserver {
    public func individualCallStateDidChange(_ call: SignalCall, state: CallState) {
        AssertIsOnMainThread()
        updateIsVideoEnabled()
        configureDataMode()
    }

    public func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {
        AssertIsOnMainThread()
        updateIsVideoEnabled()
    }

    public func groupCallLocalDeviceStateChanged(_ call: SignalCall) {
        AssertIsOnMainThread()

        guard let (groupThread, groupCall) = call.unpackGroupCall() else {
            return
        }

        Logger.info("")
        updateIsVideoEnabled()
        updateGroupMembersForCurrentCallIfNecessary()
        configureDataMode()

        if groupCall.localDeviceState.isJoined {
            if
                case .shouldRing = call.groupCallRingState,
                call.ringRestrictions.isEmpty,
                call.groupCall.remoteDeviceStates.isEmpty
            {
                // Don't start ringing until we join the call successfully.
                call.groupCallRingState = .ringing
                call.groupCall.ringAll()
                audioService.playOutboundRing()
            }

            if let eraId = groupCall.peekInfo?.eraId {
                groupCallAccessoryMessageDelegate.localDeviceMaybeJoinedGroupCall(
                    eraId: eraId,
                    groupThread: groupThread,
                    groupCallRingState: call.groupCallRingState
                )
            }
        } else {
            groupCallAccessoryMessageDelegate.localDeviceMaybeLeftGroupCall(
                groupThread: groupThread,
                groupCall: groupCall
            )
        }
    }

    public func groupCallPeekChanged(_ call: SignalCall) {
        AssertIsOnMainThread()

        guard let (groupThread, groupCall) = call.unpackGroupCall() else {
            return
        }

        guard let peekInfo = call.groupCall.peekInfo else {
            Logger.warn("No peek info for call: \(call)")
            return
        }

        if
            groupCall.localDeviceState.isJoined,
            let eraId = peekInfo.eraId
        {
            groupCallAccessoryMessageDelegate.localDeviceMaybeJoinedGroupCall(
                eraId: eraId,
                groupThread: groupThread,
                groupCallRingState: call.groupCallRingState
            )
        }

        databaseStorage.asyncWrite { tx in
            self.updateGroupCallModelsForPeek(
                peekInfo: peekInfo,
                groupThread: groupThread,
                triggerEventTimestamp: Date.ows_millisecondTimestamp(),
                tx: tx
            )
        }
    }

    public func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {
        AssertIsOnMainThread()

        groupCallAccessoryMessageDelegate.localDeviceGroupCallDidEnd()
    }

    public func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {
        if case .ringing = call.groupCallRingState, !call.groupCall.remoteDeviceStates.isEmpty {
            // The first time someone joins after a ring, we need to mark the call accepted.
            // (But if we didn't ring, the call will have already been marked accepted.)
            callUIAdapter.recipientAcceptedCall(call)
        }
    }

    public func groupCallRequestMembershipProof(_ call: SignalCall) {
        owsAssertDebug(call.isGroupCall)
        Logger.info("groupCallUpdateGroupMembershipProof")

        guard call === currentCall else { return cleanupStaleCall(call) }

        guard let groupThread = call.thread as? TSGroupThread else {
            return owsFailDebug("unexpectedly missing thread")
        }

        firstly {
            fetchGroupMembershipProof(for: groupThread)
        }.done(on: DispatchQueue.main) { proof in
            call.groupCall.updateMembershipProof(proof: proof)
        }.catch(on: DispatchQueue.main) { error in
            if error.isNetworkFailureOrTimeout {
                Logger.warn("Failed to fetch group call credentials \(error)")
            } else {
                owsFailDebug("Failed to fetch group call credentials \(error)")
            }
        }
    }

    public func groupCallRequestGroupMembers(_ call: SignalCall) {
        owsAssertDebug(call.isGroupCall)
        Logger.info("groupCallUpdateGroupMembers")

        guard call === currentCall else { return cleanupStaleCall(call) }

        updateGroupMembersForCurrentCallIfNecessary()
    }
}

extension SignalCall {
    func unpackGroupCall() -> (TSGroupThread, GroupCall)? {
        guard
            isGroupCall,
            let groupCall = groupCall,
            let groupThread = thread as? TSGroupThread
        else {
            return nil
        }

        return (groupThread, groupCall)
    }
}

private extension LocalDeviceState {
    var isJoined: Bool {
        switch joinState {
        case .joined: return true
        case .pending, .joining, .notJoined: return false
        }
    }
}

// MARK: - Group call participant updates

extension CallService: DatabaseChangeDelegate {

    public func databaseChangesDidUpdate(databaseChanges: DatabaseChanges) {
        AssertIsOnMainThread()
        owsAssertDebug(AppReadiness.isAppReady)

        guard let thread = currentCall?.thread,
              thread.isGroupThread,
              databaseChanges.didUpdate(thread: thread) else { return }

        updateGroupMembersForCurrentCallIfNecessary()
    }

    public func databaseChangesDidUpdateExternally() {
        AssertIsOnMainThread()
        owsAssertDebug(AppReadiness.isAppReady)

        updateGroupMembersForCurrentCallIfNecessary()
    }

    public func databaseChangesDidReset() {
        AssertIsOnMainThread()
        owsAssertDebug(AppReadiness.isAppReady)

        updateGroupMembersForCurrentCallIfNecessary()
    }
}

extension CallService: CallManagerDelegate {
    public typealias CallManagerDelegateCallType = SignalCall

    /**
     * A call message should be sent to the given remote recipient.
     * Invoked on the main thread, asynchronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendCallMessage recipientUuid: UUID,
        message: Data,
        urgency: CallMessageUrgency
    ) {
        AssertIsOnMainThread()
        Logger.info("shouldSendCallMessage")

        let recipientAci = Aci(fromUUID: recipientUuid)

        // It's unlikely that this would ever have more than one call. But technically
        // we don't know which call this message is on behalf of. So we assume it's every
        // call with a participant with recipientUuid
        let relevantCalls = calls.filter { (call: SignalCall) -> Bool in
            call.participantAddresses.contains(where: { $0.serviceId == recipientAci })
        }

        databaseStorage.write(.promise) { transaction in
            TSContactThread.getOrCreateThread(
                withContactAddress: SignalServiceAddress(recipientAci),
                transaction: transaction
            )
        }.then(on: DispatchQueue.global()) { thread throws -> Promise<Void> in
            let opaqueBuilder = SSKProtoCallMessageOpaque.builder()
            opaqueBuilder.setData(message)
            opaqueBuilder.setUrgency(urgency.protobufValue)

            return try Self.databaseStorage.write { transaction in
                let callMessage = OWSOutgoingCallMessage(
                    thread: thread,
                    opaqueMessage: try opaqueBuilder.build(),
                    transaction: transaction
                )

                return ThreadUtil.enqueueMessagePromise(
                    message: callMessage,
                    limitToCurrentProcessLifetime: true,
                    isHighPriority: true,
                    transaction: transaction
                )
            }
        }.done(on: DispatchQueue.main) { _ in
            // TODO: Tell RingRTC we succeeded in sending the message. API TBD
        }.catch(on: DispatchQueue.main) { error in
            if error.isNetworkFailureOrTimeout {
                Logger.warn("Failed to send opaque message \(error)")
            } else if error is UntrustedIdentityError {
                relevantCalls.forEach { $0.publishSendFailureUntrustedParticipantIdentity() }
            } else {
                Logger.error("Failed to send opaque message \(error)")
            }
            // TODO: Tell RingRTC something went wrong. API TBD
        }
    }

    /**
     * A call message should be sent to all other members of the given group.
     * Invoked on the main thread, asynchronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendCallMessageToGroup groupId: Data,
        message: Data,
        urgency: CallMessageUrgency
    ) {
        AssertIsOnMainThread()
        Logger.info("")

        databaseStorage.read(.promise) { transaction throws -> TSGroupThread in
            guard let thread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
                throw OWSAssertionError("tried to send call message to unknown group")
            }
            return thread
        }.then(on: DispatchQueue.global()) { thread throws -> Promise<Void> in
            let opaqueBuilder = SSKProtoCallMessageOpaque.builder()
            opaqueBuilder.setData(message)
            opaqueBuilder.setUrgency(urgency.protobufValue)

            return try Self.databaseStorage.write { transaction in
                let callMessage = OWSOutgoingCallMessage(
                    thread: thread,
                    opaqueMessage: try opaqueBuilder.build(),
                    transaction: transaction
                )

                return ThreadUtil.enqueueMessagePromise(
                    message: callMessage,
                    limitToCurrentProcessLifetime: true,
                    isHighPriority: true,
                    transaction: transaction
                )
            }
        }.done(on: DispatchQueue.main) { _ in
            // TODO: Tell RingRTC we succeeded in sending the message. API TBD
        }.catch(on: DispatchQueue.main) { error in
            if error.isNetworkFailureOrTimeout {
                Logger.warn("Failed to send opaque message \(error)")
            } else {
                Logger.error("Failed to send opaque message \(error)")
            }
            // TODO: Tell RingRTC something went wrong. API TBD
        }
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldCompareCalls call1: SignalCall,
        call2: SignalCall
    ) -> Bool {
        Logger.info("shouldCompareCalls")
        return call1.thread.uniqueId == call2.thread.uniqueId
    }

    // MARK: - 1:1 Call Delegates

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldStartCall call: SignalCall,
        callId: UInt64,
        isOutgoing: Bool,
        callMediaType: CallMediaType
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        guard currentCall == nil else {
            handleFailedCall(failedCall: call, error: OWSAssertionError("a current call is already set"))
            return
        }

        if !calls.contains(call) {
            owsFailDebug("unknown call: \(call)")
        }

        call.individualCall.callId = callId

        // We grab this before updating the currentCall since it will unset it by default as a precaution.
        let shouldEarlyRing = earlyRingNextIncomingCall && !isOutgoing
        earlyRingNextIncomingCall = false

        // The call to be started is provided by the event.
        currentCall = call

        individualCallService.callManager(
            callManager,
            shouldStartCall: call,
            callId: callId,
            isOutgoing: isOutgoing,
            callMediaType: callMediaType,
            shouldEarlyRing: shouldEarlyRing
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onEvent call: SignalCall,
        event: CallManagerEvent
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            onEvent: call,
            event: event
        )
    }

    /**
     * onNetworkRouteChangedFor will be invoked when changes to the network routing (e.g. wifi/cellular) are detected.
     * Invoked on the main thread, asynchronously.
     */
    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onNetworkRouteChangedFor call: SignalCall,
        networkRoute: NetworkRoute
    ) {
        Logger.info("Network route changed for call: \(call): \(networkRoute.localAdapterType.rawValue)")
        call.individualCall.networkRoute = networkRoute
        configureDataMode()
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onAudioLevelsFor call: SignalCall,
        capturedLevel: UInt16,
        receivedLevel: UInt16
    ) {
        // TODO: Implement audio level handling for individual calls.
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onLowBandwidthForVideoFor call: SignalCall,
        recovered: Bool
    ) {
        // TODO: Implement handling of the "low outgoing bandwidth for video" notification.
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendOffer callId: UInt64,
        call: SignalCall,
        destinationDeviceId: UInt32?,
        opaque: Data,
        callMediaType: CallMediaType
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            shouldSendOffer: callId,
            call: call,
            destinationDeviceId: destinationDeviceId,
            opaque: opaque,
            callMediaType: callMediaType
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendAnswer callId: UInt64,
        call: SignalCall,
        destinationDeviceId: UInt32?,
        opaque: Data
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            shouldSendAnswer: callId,
            call: call,
            destinationDeviceId: destinationDeviceId,
            opaque: opaque
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendIceCandidates callId: UInt64,
        call: SignalCall,
        destinationDeviceId: UInt32?,
        candidates: [Data]
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            shouldSendIceCandidates: callId,
            call: call,
            destinationDeviceId: destinationDeviceId,
            candidates: candidates
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendHangup callId: UInt64,
        call: SignalCall,
        destinationDeviceId: UInt32?,
        hangupType: HangupType,
        deviceId: UInt32
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            shouldSendHangup: callId,
            call: call,
            destinationDeviceId: destinationDeviceId,
            hangupType: hangupType,
            deviceId: deviceId
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        shouldSendBusy callId: UInt64,
        call: SignalCall,
        destinationDeviceId: UInt32?
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            shouldSendBusy: callId,
            call: call,
            destinationDeviceId: destinationDeviceId
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onUpdateLocalVideoSession call: SignalCall,
        session: AVCaptureSession?
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            onUpdateLocalVideoSession: call,
            session: session
        )
    }

    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        onAddRemoteVideoTrack call: SignalCall,
        track: RTCVideoTrack
    ) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isIndividualCall)

        individualCallService.callManager(
            callManager,
            onAddRemoteVideoTrack: call,
            track: track
        )
    }

    /**
     * An update from `sender` has come in for the ring in `groupId` identified by `ringId`.
     *
     * `sender` will be the current user's ID if the update came from another device.
     *
     * Invoked on the main thread, asynchronously.
     */
    public func callManager(
        _ callManager: CallManager<SignalCall, CallService>,
        didUpdateRingForGroup groupId: Data,
        ringId: Int64,
        sender: UUID,
        update: RingUpdate
    ) {
        let senderAci = Aci(fromUUID: sender)

        if FeatureFlags.groupCallDisposition {
            /// Let our ``CallRecord`` delegate know we got a ring update.
            databaseStorage.asyncWrite { tx in
                self.groupCallRecordRingUpdateDelegate.didReceiveRingUpdate(
                    groupId: groupId,
                    ringId: ringId,
                    ringUpdate: update,
                    ringUpdateSender: senderAci,
                    tx: tx.asV2Write
                )
            }
        }

        guard update == .requested else {
            if let currentCall = self.currentCall,
               currentCall.isGroupCall,
               case .incomingRing(_, ringId) = currentCall.groupCallRingState {

                switch update {
                case .requested:
                    owsFail("checked above")
                case .expiredRing:
                    self.callUIAdapter.remoteDidHangupCall(currentCall)
                case .acceptedOnAnotherDevice:
                    self.callUIAdapter.didAnswerElsewhere(call: currentCall)
                case .declinedOnAnotherDevice:
                    self.callUIAdapter.didDeclineElsewhere(call: currentCall)
                case .busyLocally:
                    owsFailDebug("shouldn't get reported here")
                    fallthrough
                case .busyOnAnotherDevice:
                    self.callUIAdapter.wasBusyElsewhere(call: currentCall)
                case .cancelledByRinger:
                    self.callUIAdapter.remoteDidHangupCall(currentCall)
                }

                self.terminate(call: currentCall)
                currentCall.groupCallRingState = .incomingRingCancelled
            }

            databaseStorage.asyncWrite { transaction in
                do {
                    try CancelledGroupRing(id: ringId).insert(transaction.unwrapGrdbWrite.database)
                    try CancelledGroupRing.deleteExpired(expiration: Date().addingTimeInterval(-30 * kMinuteInterval),
                                                         transaction: transaction)
                } catch {
                    owsFailDebug("failed to update cancellation table: \(error)")
                }
            }

            return
        }

        let caller = SignalServiceAddress(senderAci)

        enum RingAction {
            case cancel
            case ring(TSGroupThread)
        }

        let action: RingAction = databaseStorage.read { transaction in
            guard let thread = TSGroupThread.fetch(groupId: groupId, transaction: transaction) else {
                owsFailDebug("discarding group ring \(ringId) from \(senderAci) for unknown group")
                return .cancel
            }

            guard GroupsV2MessageProcessor.discardMode(forMessageFrom: caller,
                                                       groupId: groupId,
                                                       transaction: transaction) == .doNotDiscard else {
                Logger.warn("discarding group ring \(ringId) from \(senderAci)")
                return .cancel
            }

            guard thread.groupMembership.fullMembers.count <= RemoteConfig.maxGroupCallRingSize else {
                Logger.warn("discarding group ring \(ringId) from \(senderAci) for too-large group")
                return .cancel
            }

            do {
                if try CancelledGroupRing.exists(transaction.unwrapGrdbRead.database, key: ringId) {
                    return .cancel
                }
            } catch {
                owsFailDebug("unable to check cancellation table: \(error)")
            }

            return .ring(thread)
        }

        switch action {
        case .cancel:
            do {
                try callManager.cancelGroupRing(groupId: groupId, ringId: ringId, reason: nil)
            } catch {
                owsFailDebug("RingRTC failed to cancel group ring \(ringId): \(error)")
            }
        case .ring(let thread):
            let currentCall = self.currentCall
            if currentCall?.thread.uniqueId == thread.uniqueId {
                // We're already ringing or connected, or at the very least already in the lobby.
                return
            }
            guard currentCall == nil else {
                do {
                    try callManager.cancelGroupRing(groupId: groupId, ringId: ringId, reason: .busy)
                } catch {
                    owsFailDebug("RingRTC failed to cancel group ring \(ringId): \(error)")
                }
                return
            }

            // Mute video by default unless the user has already approved it.
            // This keeps us from popping the "give permission to use your camera" alert before the user answers.
            let videoMuted = AVCaptureDevice.authorizationStatus(for: .video) != .authorized
            guard let groupCall = Self.callService.buildAndConnectGroupCallIfPossible(
                thread: thread,
                videoMuted: videoMuted
            ) else {
                return owsFailDebug("Failed to build group call")
            }

            groupCall.groupCallRingState = .incomingRing(caller: caller, ringId: ringId)

            self.callUIAdapter.reportIncomingCall(groupCall)
        }
    }
}

extension CallMessageUrgency {
    var protobufValue: SSKProtoCallMessageOpaqueUrgency {
    switch self {
    case .droppable: return .droppable
    case .handleImmediately: return .handleImmediately
    }
    }
}

extension NetworkInterfaceSet {
    func includes(_ ringRtcAdapter: NetworkAdapterType) -> Bool? {
        switch ringRtcAdapter {
        case .unknown, .vpn, .anyAddress:
            if self.isEmpty {
                return false
            } else if self.inverted.isEmpty {
                return true
            } else {
                // We don't know the underlying interface, so we can't assume anything.
                return nil
            }
        case .cellular, .cellular2G, .cellular3G, .cellular4G, .cellular5G:
            return self.contains(.cellular)
        case .ethernet, .wifi, .loopback:
            return self.contains(.wifi)
        }
    }
}
