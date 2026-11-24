//
//  SettingsService.swift
//  SpeakerPrep
//

import Foundation
import ServiceManagement

struct SettingsService {
    private static let defaults = UserDefaults.standard

    static func loadConfig() -> Config {
        var effectID: EffectID? = nil
        if defaults.object(forKey: "effectType") != nil {
            effectID = EffectID(
                componentType: UInt32(defaults.integer(forKey: "effectType")),
                componentSubType: UInt32(defaults.integer(forKey: "effectSubType")),
                componentManufacturer: UInt32(defaults.integer(forKey: "effectManufacturer"))
            )
        }
        return Config(
            deviceUID: defaults.string(forKey: "deviceUID"),
            left: defaults.object(forKey: "leftChannel") as? Int,
            effectID: effectID,
            isTapping: defaults.bool(forKey: "isTapping"),
            isBypassed: defaults.bool(forKey: "isBypassed")
        )
    }

    static func saveConfig(_ c: Config) {
        defaults.set(c.deviceUID, forKey: "deviceUID")
        defaults.set(c.left, forKey: "leftChannel")
        if let id = c.effectID {
            defaults.set(Int(id.componentType), forKey: "effectType")
            defaults.set(Int(id.componentSubType), forKey: "effectSubType")
            defaults.set(Int(id.componentManufacturer), forKey: "effectManufacturer")
        } else {
            defaults.removeObject(forKey: "effectType")
            defaults.removeObject(forKey: "effectSubType")
            defaults.removeObject(forKey: "effectManufacturer")
        }
        defaults.set(c.isTapping, forKey: "isTapping")
        defaults.set(c.isBypassed, forKey: "isBypassed")
    }

    static func loadEffectState(_ id: EffectID) -> [String: Any]? {
        return defaults.dictionary(forKey: effectStateKey(id))
    }

    static func saveEffectState(_ id: EffectID, _ state: [String: Any]) {
        defaults.set(state, forKey: effectStateKey(id))
    }

    static func isLaunchAtLogin() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static func effectStateKey(_ id: EffectID) -> String {
        return "effectState.\(id.componentType)-\(id.componentSubType)-\(id.componentManufacturer)"
    }
}
