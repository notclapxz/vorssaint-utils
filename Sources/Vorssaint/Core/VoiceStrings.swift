// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Voice recording has its own strings instead of widening the recorder's:
/// that initializer is shared by every language upstream, and a field added
/// to it collides with each of their releases.
struct VoiceStrings {
    let toolTitle: String
    let selectionHint: String
    let startButton: String
    let fileNamePrefix: String
    let savedHUDFormat: String
    let indicatorTooltip: String
    let settingsCaption: String
    let microphoneLabel: String
    let systemMicrophone: String
    let disconnectedMicrophone: String
}

extension FeatureStrings {
    static func voice(_ language: AppLanguage) -> VoiceStrings {
        switch language {
        case .enUS:
            return VoiceStrings(
                toolTitle: "Voice", selectionHint: "Records only the microphone",
                startButton: "Start", fileNamePrefix: "Voice",
                savedHUDFormat: "Voice saved to %@", indicatorTooltip: "Recording your voice",
                settingsCaption: "Records the microphone alone into a small audio file, saved in the recordings folder.",
                microphoneLabel: "Microphone", systemMicrophone: "System input", disconnectedMicrophone: "Not connected")
        case .ptBR:
            return VoiceStrings(
                toolTitle: "Voz", selectionHint: "Grava só o microfone",
                startButton: "Começar", fileNamePrefix: "Voz",
                savedHUDFormat: "Voz salva em %@", indicatorTooltip: "Gravando sua voz",
                settingsCaption: "Grava só o microfone em um arquivo de áudio leve, salvo na pasta das gravações.",
                microphoneLabel: "Microfone", systemMicrophone: "Entrada do sistema", disconnectedMicrophone: "Não conectado")
        case .tr:
            return VoiceStrings(
                toolTitle: "Ses", selectionHint: "Yalnızca mikrofonu kaydeder",
                startButton: "Başlat", fileNamePrefix: "Ses",
                savedHUDFormat: "Ses %@ klasörüne kaydedildi", indicatorTooltip: "Sesiniz kaydediliyor",
                settingsCaption: "Yalnızca mikrofonu küçük bir ses dosyasına kaydeder ve kayıtlar klasörüne koyar.",
                microphoneLabel: "Mikrofon", systemMicrophone: "Sistem girişi", disconnectedMicrophone: "Bağlı değil")
        case .ru:
            return VoiceStrings(
                toolTitle: "Голос", selectionHint: "Записывает только микрофон",
                startButton: "Начать", fileNamePrefix: "Голос",
                savedHUDFormat: "Голос сохранён в %@", indicatorTooltip: "Идёт запись голоса",
                settingsCaption: "Записывает только микрофон в небольшой аудиофайл в папке записей.",
                microphoneLabel: "Микрофон", systemMicrophone: "Системный вход", disconnectedMicrophone: "Не подключён")
        case .es:
            return VoiceStrings(
                toolTitle: "Voz", selectionHint: "Graba solo el micrófono",
                startButton: "Empezar", fileNamePrefix: "Voz",
                savedHUDFormat: "Voz guardada en %@", indicatorTooltip: "Grabando tu voz",
                settingsCaption: "Graba solo el micrófono en un archivo de audio ligero, en la carpeta de las grabaciones.",
                microphoneLabel: "Micrófono", systemMicrophone: "Entrada del sistema", disconnectedMicrophone: "No conectado")
        case .sk:
            return VoiceStrings(
                toolTitle: "Hlas", selectionHint: "Nahráva iba mikrofón",
                startButton: "Začať", fileNamePrefix: "Hlas",
                savedHUDFormat: "Hlas uložený do %@", indicatorTooltip: "Nahráva sa váš hlas",
                settingsCaption: "Nahráva iba mikrofón do malého zvukového súboru v priečinku nahrávok.",
                microphoneLabel: "Mikrofón", systemMicrophone: "Vstup systému", disconnectedMicrophone: "Nepripojený")
        case .de:
            return VoiceStrings(
                toolTitle: "Stimme", selectionHint: "Nimmt nur das Mikrofon auf",
                startButton: "Starten", fileNamePrefix: "Stimme",
                savedHUDFormat: "Stimme in %@ gesichert", indicatorTooltip: "Deine Stimme wird aufgenommen",
                settingsCaption: "Nimmt nur das Mikrofon in einer kleinen Audiodatei im Aufnahmeordner auf.",
                microphoneLabel: "Mikrofon", systemMicrophone: "Systemeingang", disconnectedMicrophone: "Nicht verbunden")
        case .fr:
            return VoiceStrings(
                toolTitle: "Voix", selectionHint: "Enregistre seulement le micro",
                startButton: "Démarrer", fileNamePrefix: "Voix",
                savedHUDFormat: "Voix enregistrée dans %@", indicatorTooltip: "Enregistrement de votre voix",
                settingsCaption: "Enregistre seulement le micro dans un fichier audio léger, dans le dossier des enregistrements.",
                microphoneLabel: "Micro", systemMicrophone: "Entrée du système", disconnectedMicrophone: "Non connecté")
        case .it:
            return VoiceStrings(
                toolTitle: "Voce", selectionHint: "Registra solo il microfono",
                startButton: "Inizia", fileNamePrefix: "Voce",
                savedHUDFormat: "Voce salvata in %@", indicatorTooltip: "Registrazione della voce",
                settingsCaption: "Registra solo il microfono in un file audio leggero, nella cartella delle registrazioni.",
                microphoneLabel: "Microfono", systemMicrophone: "Ingresso di sistema", disconnectedMicrophone: "Non collegato")
        case .ja:
            return VoiceStrings(
                toolTitle: "音声", selectionHint: "マイクだけを録音します",
                startButton: "開始", fileNamePrefix: "音声",
                savedHUDFormat: "音声を%@に保存しました", indicatorTooltip: "音声を録音中",
                settingsCaption: "マイクだけを小さな音声ファイルに録音し、録画と同じフォルダに保存します。",
                microphoneLabel: "マイク", systemMicrophone: "システムの入力", disconnectedMicrophone: "未接続")
        case .ko:
            return VoiceStrings(
                toolTitle: "음성", selectionHint: "마이크만 녹음합니다",
                startButton: "시작", fileNamePrefix: "음성",
                savedHUDFormat: "음성을 %@에 저장했습니다", indicatorTooltip: "음성 녹음 중",
                settingsCaption: "마이크만 작은 오디오 파일로 녹음해 녹화 폴더에 저장합니다.",
                microphoneLabel: "마이크", systemMicrophone: "시스템 입력", disconnectedMicrophone: "연결되지 않음")
        case .uk:
            return VoiceStrings(
                toolTitle: "Голос", selectionHint: "Записує лише мікрофон",
                startButton: "Почати", fileNamePrefix: "Голос",
                savedHUDFormat: "Голос збережено в %@", indicatorTooltip: "Триває запис голосу",
                settingsCaption: "Записує лише мікрофон у невеликий аудіофайл у теці записів.",
                microphoneLabel: "Мікрофон", systemMicrophone: "Системний вхід", disconnectedMicrophone: "Не підключено")
        case .zhHans:
            return VoiceStrings(
                toolTitle: "语音", selectionHint: "只录制麦克风",
                startButton: "开始", fileNamePrefix: "语音",
                savedHUDFormat: "语音已存到%@", indicatorTooltip: "正在录制你的声音",
                settingsCaption: "只把麦克风录成一个小音频文件，存放在录屏文件夹中。",
                microphoneLabel: "麦克风", systemMicrophone: "系统输入", disconnectedMicrophone: "未连接")
        case .zhTW:
            return VoiceStrings(
                toolTitle: "語音", selectionHint: "只錄製麥克風",
                startButton: "開始", fileNamePrefix: "語音",
                savedHUDFormat: "語音已存到%@", indicatorTooltip: "正在錄製你的聲音",
                settingsCaption: "只把麥克風錄成一個小音訊檔，存放在錄影資料夾中。",
                microphoneLabel: "麥克風", systemMicrophone: "系統輸入", disconnectedMicrophone: "未連接")
        case .zhHK:
            return VoiceStrings(
                toolTitle: "語音", selectionHint: "只錄製咪高峰",
                startButton: "開始", fileNamePrefix: "語音",
                savedHUDFormat: "語音已存到%@", indicatorTooltip: "正在錄製你的聲音",
                settingsCaption: "只把咪高峰錄成一個小音訊檔，存放在錄影資料夾中。",
                microphoneLabel: "咪高峰", systemMicrophone: "系統輸入", disconnectedMicrophone: "未連接")
        }
    }
}
