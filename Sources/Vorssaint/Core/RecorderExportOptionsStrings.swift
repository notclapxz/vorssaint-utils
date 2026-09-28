// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Kept apart from the recorder's strings, whose initializer every upstream
/// language shares.
struct RecorderExportOptionsStrings {
    let resolutionLabel: String
    let originalSize: String
    let frameRateLabel: String
    let asRecorded: String
}

extension FeatureStrings {
    static func recorderExportOptions(_ language: AppLanguage) -> RecorderExportOptionsStrings {
        switch language {
        case .enUS: return .init(resolutionLabel: "Resolution", originalSize: "Original",
                                 frameRateLabel: "Frame rate", asRecorded: "As recorded")
        case .ptBR: return .init(resolutionLabel: "Resolução", originalSize: "Original",
                                 frameRateLabel: "Quadros por segundo", asRecorded: "Como foi gravado")
        case .tr: return .init(resolutionLabel: "Çözünürlük", originalSize: "Özgün",
                               frameRateLabel: "Kare hızı", asRecorded: "Kaydedildiği gibi")
        case .ru: return .init(resolutionLabel: "Разрешение", originalSize: "Исходное",
                               frameRateLabel: "Частота кадров", asRecorded: "Как записано")
        case .es: return .init(resolutionLabel: "Resolución", originalSize: "Original",
                               frameRateLabel: "Fotogramas", asRecorded: "Como se grabó")
        case .sk: return .init(resolutionLabel: "Rozlíšenie", originalSize: "Pôvodné",
                               frameRateLabel: "Snímková frekvencia", asRecorded: "Ako sa nahralo")
        case .de: return .init(resolutionLabel: "Auflösung", originalSize: "Original",
                               frameRateLabel: "Bildrate", asRecorded: "Wie aufgenommen")
        case .fr: return .init(resolutionLabel: "Résolution", originalSize: "Originale",
                               frameRateLabel: "Images par seconde", asRecorded: "Comme enregistré")
        case .it: return .init(resolutionLabel: "Risoluzione", originalSize: "Originale",
                               frameRateLabel: "Fotogrammi al secondo", asRecorded: "Come registrato")
        case .ja: return .init(resolutionLabel: "解像度", originalSize: "オリジナル",
                               frameRateLabel: "フレームレート", asRecorded: "録画のまま")
        case .ko: return .init(resolutionLabel: "해상도", originalSize: "원본",
                               frameRateLabel: "프레임 속도", asRecorded: "녹화한 그대로")
        case .uk: return .init(resolutionLabel: "Роздільна здатність", originalSize: "Вихідна",
                               frameRateLabel: "Частота кадрів", asRecorded: "Як записано")
        case .zhHans: return .init(resolutionLabel: "分辨率", originalSize: "原始",
                                   frameRateLabel: "帧率", asRecorded: "与录制相同")
        case .zhTW: return .init(resolutionLabel: "解析度", originalSize: "原始",
                                 frameRateLabel: "影格速率", asRecorded: "與錄製相同")
        case .zhHK: return .init(resolutionLabel: "解像度", originalSize: "原始",
                                 frameRateLabel: "影格速率", asRecorded: "與錄製相同")
        }
    }
}
