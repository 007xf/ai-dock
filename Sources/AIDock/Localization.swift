import Foundation

/// 界面语言。源码里的中文就是翻译键（简体中文），其他语言见 Translations.swift
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans", zhHant = "zh-Hant", en, ja, ko, es, fr, de

    var id: String { rawValue }

    /// 用这种语言自己的文字显示名字（和系统设置里一样）
    var nativeName: String {
        switch self {
        case .system: return L("跟随系统")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        }
    }

    /// 在翻译表里的列（简体中文是键本身）
    fileprivate var column: Int? {
        switch self {
        case .system, .zhHans: return nil
        case .zhHant: return 0
        case .en: return 1
        case .ja: return 2
        case .ko: return 3
        case .es: return 4
        case .fr: return 5
        case .de: return 6
        }
    }

    var localeID: String {
        switch self {
        case .system, .zhHans: return "zh_CN"
        case .zhHant: return "zh_TW"
        case .en: return "en_US"
        case .ja: return "ja_JP"
        case .ko: return "ko_KR"
        case .es: return "es_ES"
        case .fr: return "fr_FR"
        case .de: return "de_DE"
        }
    }

    /// 「跟随系统」时按系统首选语言挑一个支持的语言
    static func fromSystem() -> AppLanguage {
        for pref in Locale.preferredLanguages {
            let p = pref.lowercased()
            if p.hasPrefix("zh-hant") || p.hasPrefix("zh-tw") || p.hasPrefix("zh-hk") || p.hasPrefix("zh-mo") { return .zhHant }
            if p.hasPrefix("zh") { return .zhHans }
            for l in [AppLanguage.en, .ja, .ko, .es, .fr, .de] where p.hasPrefix(l.rawValue) { return l }
        }
        return .en
    }
}

enum Loc {
    /// 当前实际使用的语言（不会是 .system）
    static var language: AppLanguage = .fromSystem()
    static var locale: Locale { Locale(identifier: language.localeID) }

    static func apply(_ choice: AppLanguage) {
        language = choice == .system ? .fromSystem() : choice
        Fmt.resetFormatters()
    }
}

/// 翻译：没有对应翻译时原样返回中文
func L(_ key: String) -> String {
    guard let col = Loc.language.column, let row = Translations.table[key], col < row.count else { return key }
    return row[col]
}

/// 带参数的翻译：键里用 %@ 占位，译文可以用 %1$@ %2$@ 调整顺序
func L(_ key: String, _ args: String...) -> String {
    String(format: L(key), locale: Loc.locale, arguments: args.map { $0 as CVarArg })
}
