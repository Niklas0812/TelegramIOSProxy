import Foundation
import SwiftSignalKit
import TelegramCore

/// Implements Telegram's ExperimentalInternalTranslationService protocol
/// to hook our AI translation into the existing translation infrastructure.
/// This plugs into the built-in message translation pipeline with zero
/// modifications to the message rendering code.
public final class AIExperimentalTranslationService: ExperimentalInternalTranslationService {
    public init() {}

    public func translate(
        texts: [AnyHashable: String],
        fromLang: String,
        toLang: String
    ) -> Signal<[AnyHashable: String]?, NoError> {
        // Return a never-completing signal. This keeps Telegram's pipeline "pending"
        // forever — it never emits a value, so _internal_translateMessagesByPeerId
        // never stores TranslationMessageAttribute. Our catch-up handles all translations.
        // Returning .single([:]) was WRONG — Telegram fell through to store the original
        // text as "translation", poisoning every message with German-as-English attributes.
        return Signal { _ in
            return ActionDisposable(action: {})
        }
    }
}

/// Call this during app initialization to register the AI translation service.
public func registerAITranslationService() {
    engineExperimentalInternalTranslationService = AIExperimentalTranslationService()
}

/// Call this when the global toggle changes to enable/disable the service.
public func updateAITranslationServiceRegistration() {
    if AITranslationSettings.enabled {
        engineExperimentalInternalTranslationService = AIExperimentalTranslationService()
    } else {
        engineExperimentalInternalTranslationService = nil
    }
}
