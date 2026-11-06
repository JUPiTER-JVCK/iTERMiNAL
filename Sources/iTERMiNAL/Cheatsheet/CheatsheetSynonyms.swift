import Foundation

/// Words that mean nearly the same thing to someone asking for a command, so
/// "delete a folder" finds a recipe that says "remove a directory".
///
/// Each line is one family. Written by hand, short on purpose: a family only
/// earns its place when people ask one way and commands answer another, and a
/// word in two families joins them, which is how "undo" ends up near "restore".
/// A match through a synonym counts for less than a match on the word itself.
enum CheatSynonyms {
    private static let groups = """
    delete remove erase unlink trash discard destroy wipe uninstall rm
    undo revert rollback uncommit reset restore
    list show display print view see ls
    find search locate lookup grep
    folder directory dir
    big large huge biggest largest heavy
    compress zip archive pack gzip bundle tar
    extract unzip untar unpack decompress uncompress
    copy duplicate clone cp
    move rename relocate mv
    kill stop terminate quit end halt pkill
    port listening listen socket
    permission chmod access executable mode
    download fetch curl wget
    upload send push
    remote server ssh host
    disk space usage storage capacity df du
    process running task pid ps
    text string contents content
    branch switch checkout
    install setup
    update upgrade refresh sync
    empty blank clear clean cleanup purge prune
    replace substitute swap
    count total wc
    sort order arrange
    unique uniq dedupe duplicates
    clipboard pasteboard paste pbcopy pbpaste
    network internet connection online ping reachable
    password passphrase secret credential
    key keypair identity
    history log changelog
    compare difference diff
    run execute launch start
    stage track index
    pause suspend freeze
    hidden dotfile invisible
    awake sleep wake caffeinate
    tunnel forward proxy
    line row
    column field
    file document
    name title
    size length bytes
    recent latest newest
    readable pretty human prettify beautify format formatted indent
    convert transform translate
    monitor watch observe
    old oldest previous prior earlier former
    """

    /// Stem to the stems of the words in its families.
    private static let related: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for line in groups.split(separator: "\n") {
            let stems = Set(line.split(separator: " ").map { CheatText.stem(String($0)) })
            for stem in stems { map[stem, default: []].formUnion(stems.subtracting([stem])) }
        }
        return map
    }()

    /// The stems that mean nearly what `stem` does; empty if it has no family.
    static func related(to stem: String) -> Set<String> {
        related[stem] ?? []
    }

    static func knows(_ stem: String) -> Bool {
        related[stem] != nil
    }
}
