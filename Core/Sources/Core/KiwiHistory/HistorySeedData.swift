import Foundation

/// Kiwi: 履歴が空のときに投入する初期データ（定型句）。
///
/// コールドスタート（履歴ゼロで予測に何も出ない）を避けるための初期シード。
/// 前方一致予測で価値が出る「数文字打てば長い定型句が出る」語を中心に選ぶ
/// （単語1つの変換は本体の変換エンジンで十分なため、あえて含めない）。
/// `HistoryManager.seedIfNeeded` から使う。実利用の学習が貯まれば自然に上書きされる。
public enum HistorySeedData {
    /// シードのバージョン。エントリを追加したらインクリメントする。
    /// `HistoryManager.seedIfNeeded` が meta テーブルの投入済みバージョンと比較し、
    /// 新しい場合のみ差分投入する（既存 DB にも後から追加できる）。
    /// v1: 日本語定型句 / v2: 英語定型句を追加 / v3: 日英とも大幅拡充
    public static let version = 3

    /// (読み, 表層) の組。読みは日本語はひらがな（`convertTarget` と揃える）、
    /// 英語は小文字（英語 composing の入力そのまま。照合は ASCII 大文字小文字を区別しない）。
    public static let entries: [(reading: String, surface: String)] = [
        // あいさつ・書き出し
        ("おはようございます", "おはようございます"),
        ("こんにちは", "こんにちは"),
        ("こんばんは", "こんばんは"),
        ("はじめまして", "はじめまして"),
        ("おつかれさまです", "お疲れ様です"),
        ("おつかれさまでした", "お疲れ様でした"),
        ("おさきにしつれいします", "お先に失礼します"),
        ("しつれいいたします", "失礼いたします"),
        ("おせわになっております", "お世話になっております"),
        ("おせわになります", "お世話になります"),
        ("いつもおせわになっております", "いつもお世話になっております"),
        ("たいへんおせわになっております", "大変お世話になっております"),
        ("ごぶさたしております", "ご無沙汰しております"),
        ("はじめてごれんらくいたします", "初めてご連絡いたします"),

        // お礼
        ("ありがとうございます", "ありがとうございます"),
        ("ありがとうございました", "ありがとうございました"),
        ("まことにありがとうございます", "誠にありがとうございます"),
        ("まことにありがとうございました", "誠にありがとうございました"),
        ("ごたいおうありがとうございます", "ご対応ありがとうございます"),
        ("ごかくにんありがとうございます", "ご確認ありがとうございます"),
        ("ごへんしんありがとうございます", "ご返信ありがとうございます"),
        ("ごれんらくありがとうございます", "ご連絡ありがとうございます"),
        ("じんそくなごたいおうありがとうございます", "迅速なご対応ありがとうございます"),
        ("ごきょうりょくありがとうございます", "ご協力ありがとうございます"),
        ("おかげさまで", "おかげさまで"),
        ("たすかります", "助かります"),
        ("たすかりました", "助かりました"),

        // 謝罪
        ("もうしわけございません", "申し訳ございません"),
        ("もうしわけありません", "申し訳ありません"),
        ("たいへんもうしわけございません", "大変申し訳ございません"),
        ("ごめいわくをおかけしております", "ご迷惑をおかけしております"),
        ("ごめいわくをおかけしました", "ご迷惑をおかけしました"),
        ("ごめいわくをおかけしてもうしわけございません", "ご迷惑をおかけして申し訳ございません"),
        ("へんしんがおそくなりもうしわけありません", "返信が遅くなり申し訳ありません"),
        ("たびたびもうしわけございません", "度々申し訳ございません"),
        ("おそくなりましてもうしわけございません", "遅くなりまして申し訳ございません"),

        // クッション言葉・依頼
        ("おてすうをおかけします", "お手数をおかけします"),
        ("おてすうをおかけしますが", "お手数をおかけしますが"),
        ("おてすうですが", "お手数ですが"),
        ("おそれいります", "恐れ入ります"),
        ("おそれいりますが", "恐れ入りますが"),
        ("おいそがしいところおそれいりますが", "お忙しいところ恐れ入りますが"),
        ("おいそがしいところきょうしゅくですが", "お忙しいところ恐縮ですが"),
        ("きょうしゅくですが", "恐縮ですが"),
        ("さしつかえなければ", "差し支えなければ"),
        ("もしよろしければ", "もしよろしければ"),
        ("ごかくにんください", "ご確認ください"),
        ("ごかくにんいただけますでしょうか", "ご確認いただけますでしょうか"),
        ("ごかくにんのほどよろしくおねがいいたします", "ご確認のほどよろしくお願いいたします"),
        ("ごかくにんよろしくおねがいします", "ご確認よろしくお願いします"),
        ("ごけんとうください", "ご検討ください"),
        ("ごけんとうのほどよろしくおねがいいたします", "ご検討のほどよろしくお願いいたします"),
        ("ごきょうじいただけますとさいわいです", "ご教示いただけますと幸いです"),
        ("ごたいおういただけますとさいわいです", "ご対応いただけますと幸いです"),
        ("ごへんしんいただけますとさいわいです", "ご返信いただけますと幸いです"),
        ("ごれんらくください", "ご連絡ください"),
        ("ごれんらくいただけますでしょうか", "ご連絡いただけますでしょうか"),
        ("ごれんらくおまちしております", "ご連絡お待ちしております"),
        ("ごへんしんおまちしております", "ご返信お待ちしております"),
        ("おしらせください", "お知らせください"),
        ("おしえてください", "教えてください"),

        // 返答・確認
        ("しょうちしました", "承知しました"),
        ("しょうちいたしました", "承知いたしました"),
        ("しょうちです", "承知です"),
        ("かしこまりました", "かしこまりました"),
        ("りょうかいしました", "了解しました"),
        ("りょうかいです", "了解です"),
        ("もんだいありません", "問題ありません"),
        ("もんだいございません", "問題ございません"),
        ("だいじょうぶです", "大丈夫です"),
        ("かくにんします", "確認します"),
        ("かくにんしました", "確認しました"),
        ("かくにんいたします", "確認いたします"),

        // 報告・連絡・共有
        ("ごれんらくいたします", "ご連絡いたします"),
        ("ごほうこくいたします", "ご報告いたします"),
        ("とりいそぎごれんらくまで", "取り急ぎご連絡まで"),
        ("とりいそぎごほうこくまで", "取り急ぎご報告まで"),
        ("きょうゆういたします", "共有いたします"),
        ("ごきょうゆういたします", "ご共有いたします"),
        ("ごさんこうまでに", "ご参考までに"),
        ("ねんのためきょうゆういたします", "念のため共有いたします"),
        ("てんぷふぁいるをごかくにんください", "添付ファイルをご確認ください"),
        ("しりょうをてんぷいたします", "資料を添付いたします"),

        // 日程調整
        ("ごつごういかがでしょうか", "ご都合いかがでしょうか"),
        ("ごつごうのよいにちじをおしらせください", "ご都合のよい日時をお知らせください"),
        ("にっていちょうせいのごれんらくです", "日程調整のご連絡です"),
        ("かきのにっていでいかがでしょうか", "下記の日程でいかがでしょうか"),
        ("うちあわせのけん", "打ち合わせの件"),

        // 結び
        ("よろしくおねがいします", "よろしくお願いします"),
        ("よろしくおねがいいたします", "よろしくお願いいたします"),
        ("どうぞよろしくおねがいいたします", "どうぞよろしくお願いいたします"),
        ("ひきつづきよろしくおねがいいたします", "引き続きよろしくお願いいたします"),
        ("なにとぞよろしくおねがいいたします", "何卒よろしくお願いいたします"),
        ("こんごともよろしくおねがいいたします", "今後ともよろしくお願いいたします"),
        ("いじょうよろしくおねがいいたします", "以上よろしくお願いいたします"),

        // 日常・季節
        ("おめでとうございます", "おめでとうございます"),
        ("あけましておめでとうございます", "あけましておめでとうございます"),
        ("ことしもよろしくおねがいします", "今年もよろしくお願いします"),
        ("おだいじになさってください", "お大事になさってください"),
        ("おきをつけて", "お気をつけて"),
        ("よいしゅうまつを", "良い週末を"),

        // 英語: 書き出し
        ("good morning", "Good morning,"),
        ("good afternoon", "Good afternoon,"),
        ("hi team", "Hi team,"),
        ("hello everyone", "Hello everyone,"),
        ("i hope", "I hope this email finds you well."),
        ("i hope you", "I hope you're doing well."),
        ("hope this helps", "Hope this helps!"),
        ("nice to meet you", "Nice to meet you."),
        ("long time no see", "Long time no see!"),

        // 英語: お礼
        ("thank you", "Thank you very much."),
        ("thank you for", "Thank you for your reply."),
        ("thank you for your", "Thank you for your support."),
        ("thank you for the", "Thank you for the update."),
        ("thank you for your patience", "Thank you for your patience."),
        ("thanks", "Thanks!"),
        ("thanks for", "Thanks for your help."),
        ("thanks in advance", "Thanks in advance."),
        ("much appreciated", "Much appreciated."),
        ("i appreciate", "I appreciate your help."),
        ("i really appreciate", "I really appreciate it."),

        // 英語: 謝罪
        ("sorry for", "Sorry for the late reply."),
        ("sorry for the", "Sorry for the inconvenience."),
        ("apologies for", "Apologies for the delay."),
        ("my apologies", "My apologies."),
        ("i am sorry", "I am sorry for the confusion."),

        // 英語: 依頼
        ("could you please", "Could you please"),
        ("could you", "Could you check this when you have a moment?"),
        ("would you", "Would you mind checking this?"),
        ("would it be possible", "Would it be possible to"),
        ("please let me know", "Please let me know if you have any questions."),
        ("please let me know if", "Please let me know if that works for you."),
        ("please find", "Please find attached"),
        ("please see", "Please see the attached file."),
        ("please review", "Please review the attached document."),
        ("please feel free", "Please feel free to contact me."),
        ("feel free", "Feel free to reach out anytime."),
        ("when you get a chance", "When you get a chance,"),
        ("if you have any questions", "If you have any questions, please let me know."),

        // 英語: 日程調整
        ("are you available", "Are you available"),
        ("does this time work", "Does this time work for you?"),
        ("lets schedule", "Let's schedule a meeting."),
        ("how about", "How about"),
        ("looking forward", "Looking forward to hearing from you."),
        ("looking forward to", "Looking forward to seeing you."),

        // 英語: フォローアップ
        ("just following up", "Just following up on"),
        ("just checking in", "Just checking in on"),
        ("gentle reminder", "Gentle reminder:"),
        ("just a gentle reminder", "Just a gentle reminder:"),
        ("as discussed", "As discussed,"),
        ("as mentioned", "As mentioned earlier,"),
        ("per our conversation", "Per our conversation,"),

        // 英語: 返答
        ("sounds good", "Sounds good!"),
        ("got it", "Got it, thanks!"),
        ("noted", "Noted with thanks."),
        ("will do", "Will do!"),
        ("no problem", "No problem!"),
        ("understood", "Understood."),
        ("that works", "That works for me."),

        // 英語: 結び
        ("best regards", "Best regards,"),
        ("kind regards", "Kind regards,"),
        ("warm regards", "Warm regards,"),
        ("regards", "Regards,"),
        ("sincerely", "Sincerely,"),
        ("best wishes", "Best wishes,"),
        ("cheers", "Cheers,"),
        ("talk soon", "Talk soon!"),
        ("have a great day", "Have a great day!"),
        ("have a nice weekend", "Have a nice weekend!"),
    ]
}
