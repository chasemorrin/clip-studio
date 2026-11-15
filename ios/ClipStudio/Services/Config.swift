import Foundation

enum Config {
    /// The Cloudflare server, set as ServerURL in project.yml.
    static var serverURL: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "ServerURL") as? String ?? ""
        return URL(string: s) ?? URL(string: "https://clip-studio.chasemorrin.workers.dev")!
    }

    /// What Claude knows about your music. Editable in Settings.
    static let defaultProfile = """
    Jazz pianist and educator working in an advanced, globally rooted jazz language, in the spirit of artists like Danilo Pérez and Sullivan Fortner. Mostly performance: concert footage, jazz standards in the practice room, free improvisation. Some education for serious musicians: groove and polyrhythm, tetrachordal theory, advanced harmonic ideas, strange or non-standard colors on familiar tunes.
    """

    static var profile: String {
        get { UserDefaults.standard.string(forKey: "profile") ?? defaultProfile }
        set { UserDefaults.standard.set(newValue, forKey: "profile") }
    }
}
