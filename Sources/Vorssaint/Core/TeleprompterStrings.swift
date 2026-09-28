// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The teleprompter's strings live apart from the recorder's for the same
/// reason voice's do: that initializer is shared by every upstream language.
struct TeleprompterStrings {
    let title: String
    let placeholder: String
    let editButton: String
    let readButton: String
    let restartButton: String
    let speedLabel: String
    let keysHint: String
    let openButton: String
    let settingsCaption: String
}

extension FeatureStrings {
    static func teleprompter(_ language: AppLanguage) -> TeleprompterStrings {
        switch language {
        case .enUS:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Paste or type your script here",
                editButton: "Edit", readButton: "Read", restartButton: "Back to the start",
                speedLabel: "Speed", keysHint: "Space pauses · ↑↓ speed",
                openButton: "Open teleprompter",
                settingsCaption: "Your script in a window under the camera that scrolls on its own. It never appears in screenshots or recordings.")
        case .ptBR:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Cole ou escreva seu roteiro aqui",
                editButton: "Editar", readButton: "Ler", restartButton: "Voltar ao início",
                speedLabel: "Velocidade", keysHint: "Espaço pausa · ↑↓ velocidade",
                openButton: "Abrir teleprompter",
                settingsCaption: "Seu roteiro numa janela sob a câmera que rola sozinha. Nunca aparece em capturas nem gravações.")
        case .tr:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Metninizi buraya yapıştırın veya yazın",
                editButton: "Düzenle", readButton: "Oku", restartButton: "Başa dön",
                speedLabel: "Hız", keysHint: "Boşluk duraklatır · ↑↓ hız",
                openButton: "Teleprompter’ı aç",
                settingsCaption: "Metniniz kameranın altındaki bir pencerede kendiliğinden kayar. Ekran görüntülerinde ve kayıtlarda görünmez.")
        case .ru:
            return TeleprompterStrings(
                title: "Телесуфлёр", placeholder: "Вставьте или напишите текст здесь",
                editButton: "Изменить", readButton: "Читать", restartButton: "В начало",
                speedLabel: "Скорость", keysHint: "Пробел: пауза · ↑↓ скорость",
                openButton: "Открыть телесуфлёр",
                settingsCaption: "Ваш текст в окне под камерой прокручивается сам. Он не попадает в снимки экрана и записи.")
        case .es:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Pega o escribe aquí tu guion",
                editButton: "Editar", readButton: "Leer", restartButton: "Volver al inicio",
                speedLabel: "Velocidad", keysHint: "Espacio pausa · ↑↓ velocidad",
                openButton: "Abrir teleprompter",
                settingsCaption: "Tu guion en una ventana bajo la cámara que avanza sola. Nunca sale en capturas ni grabaciones.")
        case .sk:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Sem vložte alebo napíšte svoj scenár",
                editButton: "Upraviť", readButton: "Čítať", restartButton: "Späť na začiatok",
                speedLabel: "Rýchlosť", keysHint: "Medzerník pozastaví · ↑↓ rýchlosť",
                openButton: "Otvoriť teleprompter",
                settingsCaption: "Váš scenár v okne pod kamerou sa posúva sám. Nikdy sa neobjaví na snímkach ani v nahrávkach.")
        case .de:
            return TeleprompterStrings(
                title: "Teleprompter", placeholder: "Füge dein Skript hier ein oder schreibe es",
                editButton: "Bearbeiten", readButton: "Lesen", restartButton: "Zum Anfang",
                speedLabel: "Tempo", keysHint: "Leertaste pausiert · ↑↓ Tempo",
                openButton: "Teleprompter öffnen",
                settingsCaption: "Dein Skript in einem Fenster unter der Kamera, das von selbst scrollt. Es erscheint nie in Bildschirmfotos oder Aufnahmen.")
        case .fr:
            return TeleprompterStrings(
                title: "Téléprompteur", placeholder: "Collez ou écrivez votre texte ici",
                editButton: "Modifier", readButton: "Lire", restartButton: "Revenir au début",
                speedLabel: "Vitesse", keysHint: "Espace met en pause · ↑↓ vitesse",
                openButton: "Ouvrir le téléprompteur",
                settingsCaption: "Votre texte dans une fenêtre sous la caméra, qui défile seule. Il n’apparaît jamais dans les captures ni les enregistrements.")
        case .it:
            return TeleprompterStrings(
                title: "Gobbo", placeholder: "Incolla o scrivi qui il tuo testo",
                editButton: "Modifica", readButton: "Leggi", restartButton: "Torna all’inizio",
                speedLabel: "Velocità", keysHint: "Spazio mette in pausa · ↑↓ velocità",
                openButton: "Apri il gobbo",
                settingsCaption: "Il tuo testo in una finestra sotto la fotocamera che scorre da sola. Non compare mai in screenshot o registrazioni.")
        case .ja:
            return TeleprompterStrings(
                title: "プロンプター", placeholder: "ここに原稿を貼り付けるか入力します",
                editButton: "編集", readButton: "読む", restartButton: "最初に戻る",
                speedLabel: "速度", keysHint: "スペースで一時停止 · ↑↓で速度",
                openButton: "プロンプターを開く",
                settingsCaption: "カメラの下のウインドウで原稿が自動でスクロールします。スクリーンショットや録画には写りません。")
        case .ko:
            return TeleprompterStrings(
                title: "프롬프터", placeholder: "여기에 원고를 붙여넣거나 입력하세요",
                editButton: "편집", readButton: "읽기", restartButton: "처음으로",
                speedLabel: "속도", keysHint: "스페이스로 일시정지 · ↑↓ 속도",
                openButton: "프롬프터 열기",
                settingsCaption: "카메라 아래 창에서 원고가 저절로 스크롤됩니다. 스크린샷이나 녹화에는 나타나지 않습니다.")
        case .uk:
            return TeleprompterStrings(
                title: "Телесуфлер", placeholder: "Вставте або напишіть текст тут",
                editButton: "Змінити", readButton: "Читати", restartButton: "На початок",
                speedLabel: "Швидкість", keysHint: "Пробіл: пауза · ↑↓ швидкість",
                openButton: "Відкрити телесуфлер",
                settingsCaption: "Ваш текст у вікні під камерою прокручується сам. Він не потрапляє в знімки екрана й записи.")
        case .zhHans:
            return TeleprompterStrings(
                title: "提词器", placeholder: "在此粘贴或输入你的稿子",
                editButton: "编辑", readButton: "阅读", restartButton: "回到开头",
                speedLabel: "速度", keysHint: "空格暂停 · ↑↓ 速度",
                openButton: "打开提词器",
                settingsCaption: "你的稿子在摄像头下方的窗口中自动滚动，不会出现在截图或录屏里。")
        case .zhTW:
            return TeleprompterStrings(
                title: "提詞機", placeholder: "在此貼上或輸入你的講稿",
                editButton: "編輯", readButton: "閱讀", restartButton: "回到開頭",
                speedLabel: "速度", keysHint: "空白鍵暫停 · ↑↓ 速度",
                openButton: "打開提詞機",
                settingsCaption: "你的講稿在相機下方的視窗中自動捲動，不會出現在截圖或錄影裡。")
        case .zhHK:
            return TeleprompterStrings(
                title: "提詞機", placeholder: "在此貼上或輸入你的講稿",
                editButton: "編輯", readButton: "閱讀", restartButton: "回到開頭",
                speedLabel: "速度", keysHint: "空白鍵暫停 · ↑↓ 速度",
                openButton: "打開提詞機",
                settingsCaption: "你的講稿在鏡頭下方的視窗中自動捲動，不會出現在截圖或錄影裡。")
        }
    }
}
