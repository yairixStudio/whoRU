import Foundation

/// Minimal string table for the core. The app's UI strings live in its own
/// String Catalog; these are the strings the core itself produces (headlines,
/// reasons) so that the command line and every front end agree.
public enum L10n {
    public static func text(_ key: String, locale: String, _ params: [String: String] = [:]) -> String {
        let lang = String(locale.prefix(2)).lowercased()
        let table = tables[lang] ?? tables["en"]!
        var text = table[key] ?? tables["en"]?[key] ?? key
        for (name, value) in params {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    public static var supportedLanguages: [String] { Array(tables.keys).sorted() }

    static let tables: [String: [String: String]] = [
        "en": [
            "headline.safe": "Safe to allow",
            "headline.probablyFine": "Probably fine",
            "headline.systemComponent": "Part of macOS",
            "headline.worthALook": "Worth a look",
            "headline.doNotAllow": "Do not allow",
            "headline.unresolved": "Not identified",
            "headline.checking": "Checking…",
            "headline.notSystemDialog": "Not a system dialog",

            "reason.dialog.fake": "This window is not a macOS permission dialog. It was drawn by {owner}{signer}.",
            "reason.dialog.fake.signer": ", signed by {signer}",
            "reason.signature.broken": "The code signature is broken: the file was modified after it was signed.",
            "reason.impersonation": "It uses the name “{name}” but is not signed by that publisher.",
            "reason.virustotal.flagged": "{count} antivirus engines flag this file.",
            "reason.publisher.blocked": "You blocked {publisher}.",
            "reason.signed.apple": "{name} is a component of macOS, signed by Apple.",
            "reason.manifest.match": "Signed by {publisher} and identical to the official release.",
            "reason.publisher.trusted": "Signed by {publisher}, a publisher you trust.",
            "reason.signed.appStore": "Installed from the App Store and signed by Apple for {publisher}.",
            "reason.signed.notarized": "Signed by {publisher} and notarized by Apple. Not compared to an official source.",
            "reason.signed.knownPublisher": "Signed by {publisher}, a known publisher. Not compared to an official source.",
            "reason.unsigned": "The file is not signed, so nobody vouches for it.",
            "reason.adhoc": "The file carries an ad-hoc signature, which identifies no publisher.",
            "reason.signer.unknown": "The signature could not be examined.",
            "reason.publisher.unknown": "Signed by {publisher}, a publisher not in the known list, and not notarized.",
            "reason.notarized.unknown": "Signed by {publisher}, but not notarized and not compared to an official source.",
            "reason.download.unknown": "Downloaded from an unknown source.",
            "reason.location.suspicious": "It lives in an unusual place: {location}.",
            "reason.resolver.low": "The file could not be identified with confidence.",
            "reason.resolver.collision": "{n} different programs on this Mac use this name. Until the system says which one is asking, the evidence may be about the wrong one.",
            "reason.identity.unconfirmed": "The system has no record of this request, so whoRU cannot confirm this window is a genuine permission prompt rather than one a program drew to look like it.",
            "reason.gatekeeper.rejected": "macOS Gatekeeper refuses to run this program; its signature may have been revoked.",
            "reason.signature.revoked": "Apple revoked the certificate that signed this program.",
            "reason.running.invalid": "The program running in memory fails code-signature validation.",
            "reason.running.mismatch": "The program running in memory is not the file on disk that was checked.",
            "reason.unresolved": "No file with this name was found. You can pick it manually.",
            "reason.history.flagged": "A previous check of this exact file ended with a warning.",
            "reason.history.denied": "You denied this exact file last time.",

            "history.justNow": "just now",
            "history.verdict.fine": "fine",
            "history.verdict.flagged": "a warning",
            "history.verdict.unknown": "no verdict",
            "history.sameFile.once": "Checked once before, {when}: {verdict}.",
            "history.sameFile.many": "Checked {n} times before, last {when}: {verdict}.",
            "history.decision.allowed": "You allowed it then.",
            "history.decision.denied": "You denied it then.",
            "history.publisher.once": "Another program from {publisher} was checked {when}.",
            "history.publisher.many": "{n} earlier checks of programs from {publisher}, last {when}.",
        ],
        "he": [
            "headline.safe": "בטוח לאשר",
            "headline.probablyFine": "כנראה בסדר",
            "headline.systemComponent": "חלק מ־macOS",
            "headline.worthALook": "כדאי לבדוק",
            "headline.doNotAllow": "אל תאשר",
            "headline.unresolved": "לא זוהה",
            "headline.checking": "בודק…",
            "headline.notSystemDialog": "לא דיאלוג של המערכת",

            "reason.dialog.fake": "החלון הזה אינו דיאלוג הרשאות של macOS. הוא צויר על ידי {owner}{signer}.",
            "reason.dialog.fake.signer": ", חתום על ידי {signer}",
            "reason.signature.broken": "החתימה שבורה: הקובץ שונה אחרי שנחתם.",
            "reason.impersonation": "משתמש בשם ״{name}״ אבל לא חתום על ידי המפרסם הזה.",
            "reason.virustotal.flagged": "{count} מנועי אנטי־וירוס מזהים את הקובץ.",
            "reason.publisher.blocked": "חסמת את {publisher}.",
            "reason.signed.apple": "{name} הוא רכיב של macOS, חתום על ידי Apple.",
            "reason.manifest.match": "חתום על ידי {publisher} וזהה לשחרור הרשמי.",
            "reason.publisher.trusted": "חתום על ידי {publisher}, מפרסם שסימנת כמהימן.",
            "reason.signed.appStore": "הותקן מה־App Store וחתום על ידי Apple עבור {publisher}.",
            "reason.signed.notarized": "חתום על ידי {publisher} ואושר על ידי Apple. לא הושווה למקור רשמי.",
            "reason.signed.knownPublisher": "חתום על ידי {publisher}, מפרסם מוכר. לא הושווה למקור רשמי.",
            "reason.unsigned": "הקובץ לא חתום, כך שאף אחד לא ערב לו.",
            "reason.adhoc": "הקובץ חתום בחתימה עצמית שלא מזהה מפרסם.",
            "reason.signer.unknown": "לא ניתן היה לבדוק את החתימה.",
            "reason.publisher.unknown": "חתום על ידי {publisher}, מפרסם שאינו ברשימה המוכרת, ולא אושר על ידי Apple.",
            "reason.notarized.unknown": "חתום על ידי {publisher}, אבל לא אושר על ידי Apple ולא הושווה למקור רשמי.",
            "reason.download.unknown": "הורד ממקור לא ידוע.",
            "reason.location.suspicious": "נמצא במקום לא שגרתי: {location}.",
            "reason.resolver.low": "לא ניתן היה לזהות את הקובץ בוודאות.",
            "reason.resolver.collision": "{n} תוכנות שונות במק הזה משתמשות בשם הזה. עד שהמערכת תאמר מי מהן מבקשת, הראיות עלולות להיות על התוכנה הלא נכונה.",
            "reason.identity.unconfirmed": "למערכת אין תיעוד של הבקשה הזאת, ולכן whoRU לא יכול לוודא שהחלון הזה הוא דיאלוג הרשאות אמיתי ולא כזה שתוכנה ציירה כדי שייראה כמו אחד.",
            "reason.gatekeeper.rejected": "‏Gatekeeper של macOS מסרב להריץ את התוכנה; ייתכן שהחתימה שלה בוטלה.",
            "reason.signature.revoked": "‏Apple ביטלה את התעודה שחתמה על התוכנה הזאת.",
            "reason.running.invalid": "התוכנה שרצה בזיכרון נכשלת באימות חתימת הקוד.",
            "reason.running.mismatch": "התוכנה שרצה בזיכרון אינה הקובץ בדיסק שנבדק.",
            "reason.unresolved": "לא נמצא קובץ בשם הזה. אפשר לבחור אותו ידנית.",
            "reason.history.flagged": "בדיקה קודמת של הקובץ הזה בדיוק הסתיימה באזהרה.",
            "reason.history.denied": "דחית את הקובץ הזה בדיוק בפעם הקודמת.",

            "history.justNow": "לפני רגע",
            "history.verdict.fine": "בסדר",
            "history.verdict.flagged": "אזהרה",
            "history.verdict.unknown": "בלי פסק דין",
            "history.sameFile.once": "נבדק פעם אחת בעבר, {when}: {verdict}.",
            "history.sameFile.many": "נבדק {n} פעמים בעבר, לאחרונה {when}: {verdict}.",
            "history.decision.allowed": "אישרת אותו אז.",
            "history.decision.denied": "דחית אותו אז.",
            "history.publisher.once": "תוכנה אחרת של {publisher} נבדקה {when}.",
            "history.publisher.many": "{n} בדיקות קודמות של תוכנות מ־{publisher}, האחרונה {when}.",
        ],
    ]
}
