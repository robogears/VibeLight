import CoreText
import SwiftUI

/// The bundled theme typefaces (Resources/Fonts, all SIL OFL 1.1 — each
/// family's licence ships beside it). Static instances cut from the variable
/// fonts and the Japanese families trimmed to Latin by
/// scripts/fonts/build-theme-fonts.py, which also gives them their own
/// PostScript names ("FrauncesVL-Black" …) so a copy of the family installed
/// on the Mac never shadows them. IBM Plex Sans Condensed ships unmodified
/// (its licence reserves the name "Plex"), so it keeps IBM's names.
enum ThemeFace: String, CaseIterable, Sendable {
    // Night Edition
    case frauncesBlack = "FrauncesVL-Black"
    case frauncesBlackItalic = "FrauncesVL-BlackItalic"
    case frauncesBoldItalic = "FrauncesVL-BoldItalic"
    case frauncesMediumItalic = "FrauncesVL-MediumItalic"
    case plexMedium = "IBMPlexSansCond-Medium"
    case plexSemiBold = "IBMPlexSansCond-SemiBold"
    case plexBold = "IBMPlexSansCond-Bold"
    // Grid 72
    case archivoExpandedBlack = "ArchivoVL-ExpandedBlack"
    case archivoMedium = "ArchivoVL-Medium"
    case archivoSemiBold = "ArchivoVL-SemiBold"
    case archivoBold = "ArchivoVL-Bold"
    case archivoExtraBold = "ArchivoVL-ExtraBold"
    case archivoNarrowMedium = "ArchivoVL-NarrowMedium"
    case archivoNarrowSemiBold = "ArchivoVL-NarrowSemiBold"
    case archivoNarrowBold = "ArchivoVL-NarrowBold"
    // Kabuki Cut
    case delaGothic = "DelaGothicOneVL-Regular"
    case zenKakuMedium = "ZenKakuGothicNewVL-Medium"
    case zenKakuBold = "ZenKakuGothicNewVL-Bold"
    case zenKakuBlack = "ZenKakuGothicNewVL-Black"

    /// The face at `size` points (fixed: the launcher scales its whole canvas
    /// instead of using Dynamic Type), or the system stand-in if the file
    /// didn't register.
    func font(_ size: CGFloat) -> Font {
        ThemeFonts.isAvailable(self) ? .custom(rawValue, fixedSize: size) : fallback(size)
    }

    /// The closest system face, so a missing file degrades to the right shape
    /// of type rather than to SF at a random weight.
    func fallback(_ size: CGFloat) -> Font {
        switch self {
        case .frauncesBlack:         .system(size: size, weight: .black, design: .serif)
        case .frauncesBlackItalic:   .system(size: size, weight: .black, design: .serif).italic()
        case .frauncesBoldItalic:    .system(size: size, weight: .bold, design: .serif).italic()
        case .frauncesMediumItalic:  .system(size: size, weight: .medium, design: .serif).italic()
        case .plexMedium:            .system(size: size, weight: .medium).width(.condensed)
        case .plexSemiBold:          .system(size: size, weight: .semibold).width(.condensed)
        case .plexBold:              .system(size: size, weight: .bold).width(.condensed)
        case .archivoExpandedBlack:  .system(size: size, weight: .black).width(.expanded)
        case .archivoMedium:         .system(size: size, weight: .medium)
        case .archivoSemiBold:       .system(size: size, weight: .semibold)
        case .archivoBold:           .system(size: size, weight: .bold)
        case .archivoExtraBold:      .system(size: size, weight: .heavy)
        case .archivoNarrowMedium:   .system(size: size, weight: .medium).width(.condensed)
        case .archivoNarrowSemiBold: .system(size: size, weight: .semibold).width(.condensed)
        case .archivoNarrowBold:     .system(size: size, weight: .bold).width(.condensed)
        case .delaGothic:            .system(size: size, weight: .black)
        case .zenKakuMedium:         .system(size: size, weight: .medium)
        case .zenKakuBold:           .system(size: size, weight: .bold)
        case .zenKakuBlack:          .system(size: size, weight: .black)
        }
    }

    /// Night Edition's UI weights: Medium, SemiBold, Bold.
    static func plex(_ weight: Font.Weight) -> ThemeFace {
        switch weight {
        case .semibold: .plexSemiBold
        case .bold, .heavy, .black: .plexBold
        default: .plexMedium
        }
    }

    /// Grid 72's normal width: Medium up to ExtraBold.
    static func archivo(_ weight: Font.Weight) -> ThemeFace {
        switch weight {
        case .semibold: .archivoSemiBold
        case .bold: .archivoBold
        case .heavy, .black: .archivoExtraBold
        default: .archivoMedium
        }
    }

    /// Grid 72's narrow width, for dense data.
    static func archivoNarrow(_ weight: Font.Weight) -> ThemeFace {
        switch weight {
        case .semibold: .archivoNarrowSemiBold
        case .bold, .heavy, .black: .archivoNarrowBold
        default: .archivoNarrowMedium
        }
    }

    /// Kabuki Cut's UI weights: Medium, Bold, Black.
    static func zenKaku(_ weight: Font.Weight) -> ThemeFace {
        switch weight {
        case .semibold, .bold: .zenKakuBold
        case .heavy, .black: .zenKakuBlack
        default: .zenKakuMedium
        }
    }
}

/// Registers the bundled fonts with Core Text for this process only — no
/// Info.plist entry, the same on macOS and iOS — and remembers which faces
/// resolved, so a font that failed to load falls back to a system face.
enum ThemeFonts {
    /// The PostScript names that resolved. Built once, on first use; `register()`
    /// makes that first use app launch.
    private static let available: Set<String> = registerBundledFonts()

    /// Registers the fonts now (idempotent). Returns how many faces resolved.
    @discardableResult
    static func register() -> Int { available.count }

    static func isAvailable(_ face: ThemeFace) -> Bool { available.contains(face.rawValue) }

    private static func registerBundledFonts() -> Set<String> {
        // Synchronous, one file at a time: each face is usable the moment this returns.
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (the family is installed on this Mac, say)
                // or unreadable: the name check below has the last word.
                _ = error?.takeRetainedValue()
            }
        }
        var resolved = Set<String>()
        for face in ThemeFace.allCases {
            let font = CTFontCreateWithName(face.rawValue as CFString, 12, nil)
            if CTFontCopyPostScriptName(font) as String == face.rawValue {
                resolved.insert(face.rawValue)
            }
        }
        return resolved
    }
}
