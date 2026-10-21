import AuthenticationServices
import CloudKit
import Foundation
import HomeKit
import os

/// Words a person can act on, for an error Caloma shows: what didn't work and what to do next,
/// never the system's own text or an error code. The raw error goes to the log.
///
///     problem = FriendlyError.message(for: error, doing: "rename this device")
///     // "Caloma couldn't rename this device. Make sure it's on…"
nonisolated enum FriendlyError {
    private static let log = Logger(subsystem: "com.stephenwarren.caloma", category: "errors")

    /// `action` finishes "Caloma couldn't …" ("save the change", "sign you in").
    static func message(for error: Error, doing action: String) -> String {
        log.error("Couldn't \(action, privacy: .public): \(String(describing: error), privacy: .public)")
        if let hint = hint(for: error) {
            return "Caloma couldn’t \(action). \(hint)"
        }
        return "Caloma couldn’t \(action). Please try again."
    }

    /// What to do next, for the errors people can do something about.
    static func hint(for error: Error) -> String? {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You’re offline. Connect to the internet and try again."
            case .timedOut, .cannotFindHost, .cannotConnectToHost:
                return "The connection is slow right now. Try again in a moment."
            default:
                return nil
            }
        }
        if let error = error as? CKError {
            switch error.code {
            case .partialFailure:
                return error.partialErrorsByItemID?.values.first.flatMap(hint(for:))
            case .networkUnavailable, .networkFailure:
                return "You’re offline. Changes sync when you’re back online."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud is busy right now. Caloma will try again on its own."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings, then try again."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free up space in Settings › [your name] › iCloud."
            case .permissionFailure, .participantMayNeedVerification:
                return "You don’t have permission to change the family’s shared data. Ask the person who set up your household."
            default:
                return nil
            }
        }
        if let error = error as? HMError {
            switch error.code {
            case .insufficientPrivileges:
                return "Only the home’s owner, or someone they made an admin in the Home app, can change this."
            case .homeAccessNotAuthorized:
                return "Allow Caloma to use your Home data in Settings, then try again."
            case .communicationFailure, .operationTimedOut:
                return "Make sure the device is on and near your home hub, then try again."
            default:
                return nil
            }
        }
        if error is ASAuthorizationError {
            return "Check that you’re signed in to your Apple Account in Settings, then try again."
        }
        return nil
    }
}
