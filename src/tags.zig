//! JMdict entity codes and the Jisho labels that map to them.
//!
//! Jisho shows JMdict entities as English labels ("Godan verb with 'ru' ending");
//! Mazii already uses the codes ("v5r"). The transform logs any label or code
//! it can't map, so the tables below can be extended.

const std = @import("std");
const Db = @import("db.zig").Db;

pub const Category = enum { pos, misc, field, dialect };

pub const Tag = struct {
    code: []const u8,
    category: Category,
};

fn pos(code: []const u8) Tag {
    return .{ .code = code, .category = .pos };
}
fn misc(code: []const u8) Tag {
    return .{ .code = code, .category = .misc };
}
fn field(code: []const u8) Tag {
    return .{ .code = code, .category = .field };
}
fn dialect(code: []const u8) Tag {
    return .{ .code = code, .category = .dialect };
}

/// Jisho label -> JMdict entity. A code may have several labels; `seed` keeps
/// the shortest as its `tag.label_en`.
pub const by_jisho_label = std.StaticStringMap(Tag).initComptime(.{
    // ------------------------------------------------ parts of speech
    .{ "Noun", pos("n") },
    .{ "Noun, used as a suffix", pos("n-suf") },
    .{ "Noun, used as a prefix", pos("n-pref") },
    .{ "Adverbial noun (fukushitekimeishi)", pos("n-adv") },
    .{ "Noun (temporal) (jisoumeishi)", pos("n-t") },
    .{ "Proper noun", pos("n-pr") },
    .{ "Noun which may take the genitive case particle 'no'", pos("adj-no") },
    .{ "Noun or verb acting prenominally", pos("adj-f") },
    .{ "Na-adjective (keiyodoshi)", pos("adj-na") },
    .{ "Archaic/formal form of na-adjective", pos("adj-nari") },
    .{ "I-adjective (keiyoushi)", pos("adj-i") },
    .{ "I-Adjective (keiyoushi) - yoi/ii class", pos("adj-ix") },
    .{ "'taru' adjective", pos("adj-t") },
    .{ "'ku' adjective (archaic)", pos("adj-ku") },
    .{ "'shiku' adjective (archaic)", pos("adj-shiku") },
    .{ "'kari' adjective (archaic)", pos("adj-kari") },
    .{ "Pre-noun adjectival (rentaishi)", pos("adj-pn") },
    .{ "Adverb (fukushi)", pos("adv") },
    .{ "Adverb taking the 'to' particle", pos("adv-to") },
    .{ "Expressions (phrases, clauses, etc.)", pos("exp") },
    .{ "Interjection (kandoushi)", pos("int") },
    .{ "Auxiliary", pos("aux") },
    .{ "Auxiliary verb", pos("aux-v") },
    .{ "Auxiliary adjective", pos("aux-adj") },
    .{ "Copula", pos("cop") },
    .{ "Suffix", pos("suf") },
    .{ "Prefix", pos("pref") },
    .{ "Counter", pos("ctr") },
    .{ "Pronoun", pos("pn") },
    .{ "Particle", pos("prt") },
    .{ "Numeric", pos("num") },
    .{ "Conjunction", pos("conj") },
    .{ "Unclassified", pos("unc") },
    .{ "Transitive verb", pos("vt") },
    .{ "Intransitive verb", pos("vi") },
    .{ "Suru verb", pos("vs") },
    .{ "Suru verb - special class", pos("vs-s") },
    .{ "Suru verb - included", pos("vs-i") },
    .{ "Su verb - precursor to the modern suru", pos("vs-c") },
    .{ "Kuru verb - special class", pos("vk") },
    .{ "Irregular ru verb, plain form ends with -ri", pos("vr") },
    .{ "Irregular nu verb", pos("vn") },
    .{ "Ichidan verb", pos("v1") },
    .{ "Ichidan verb - kureru special class", pos("v1-s") },
    .{ "Ichidan verb - zuru verb (alternative form of -jiru verbs)", pos("vz") },
    .{ "Godan verb with 'u' ending", pos("v5u") },
    .{ "Godan verb with 'u' ending (special class)", pos("v5u-s") },
    .{ "Godan verb with 'ku' ending", pos("v5k") },
    .{ "Godan verb - Iku/Yuku special class", pos("v5k-s") },
    .{ "Godan verb with 'gu' ending", pos("v5g") },
    .{ "Godan verb with 'su' ending", pos("v5s") },
    .{ "Godan verb with 'tsu' ending", pos("v5t") },
    .{ "Godan verb with 'nu' ending", pos("v5n") },
    .{ "Godan verb with 'bu' ending", pos("v5b") },
    .{ "Godan verb with 'mu' ending", pos("v5m") },
    .{ "Godan verb with 'ru' ending", pos("v5r") },
    .{ "Godan verb with 'ru' ending (irregular verb)", pos("v5r-i") },
    .{ "Godan verb - -aru special class", pos("v5aru") },
    .{ "Godan verb - Uru old class verb (old form of Eru)", pos("v5uru") },
    .{ "Yodan verb with 'ku' ending (archaic)", pos("v4k") },
    .{ "Yodan verb with 'gu' ending (archaic)", pos("v4g") },
    .{ "Yodan verb with 'su' ending (archaic)", pos("v4s") },
    .{ "Yodan verb with 'tsu' ending (archaic)", pos("v4t") },
    .{ "Yodan verb with 'nu' ending (archaic)", pos("v4n") },
    .{ "Yodan verb with 'hu/fu' ending (archaic)", pos("v4h") },
    .{ "Yodan verb with 'bu' ending (archaic)", pos("v4b") },
    .{ "Yodan verb with 'mu' ending (archaic)", pos("v4m") },
    .{ "Yodan verb with 'ru' ending (archaic)", pos("v4r") },
    .{ "Nidan verb with 'u' ending (archaic)", pos("v2a-s") },
    .{ "Nidan verb (upper class) with 'ku' ending (archaic)", pos("v2k-k") },
    .{ "Nidan verb (upper class) with 'gu' ending (archaic)", pos("v2g-k") },
    .{ "Nidan verb (upper class) with 'tsu' ending (archaic)", pos("v2t-k") },
    .{ "Nidan verb (upper class) with 'dzu' ending (archaic)", pos("v2d-k") },
    .{ "Nidan verb (upper class) with 'hu/fu' ending (archaic)", pos("v2h-k") },
    .{ "Nidan verb (upper class) with 'bu' ending (archaic)", pos("v2b-k") },
    .{ "Nidan verb (upper class) with 'mu' ending (archaic)", pos("v2m-k") },
    .{ "Nidan verb (upper class) with 'yu' ending (archaic)", pos("v2y-k") },
    .{ "Nidan verb (upper class) with 'ru' ending (archaic)", pos("v2r-k") },
    .{ "Nidan verb (lower class) with 'ku' ending (archaic)", pos("v2k-s") },
    .{ "Nidan verb (lower class) with 'gu' ending (archaic)", pos("v2g-s") },
    .{ "Nidan verb (lower class) with 'su' ending (archaic)", pos("v2s-s") },
    .{ "Nidan verb (lower class) with 'zu' ending (archaic)", pos("v2z-s") },
    .{ "Nidan verb (lower class) with 'tsu' ending (archaic)", pos("v2t-s") },
    .{ "Nidan verb (lower class) with 'dzu' ending (archaic)", pos("v2d-s") },
    .{ "Nidan verb (lower class) with 'nu' ending (archaic)", pos("v2n-s") },
    .{ "Nidan verb (lower class) with 'hu/fu' ending (archaic)", pos("v2h-s") },
    .{ "Nidan verb (lower class) with 'bu' ending (archaic)", pos("v2b-s") },
    .{ "Nidan verb (lower class) with 'mu' ending (archaic)", pos("v2m-s") },
    .{ "Nidan verb (lower class) with 'yu' ending (archaic)", pos("v2y-s") },
    .{ "Nidan verb (lower class) with 'ru' ending (archaic)", pos("v2r-s") },
    .{ "Nidan verb (lower class) with 'u' ending and 'we' conjugation (archaic)", pos("v2w-s") },

    // ------------------------------------------------ usage, register
    .{ "Usually written using kana alone", misc("uk") },
    .{ "Abbreviation", misc("abbr") },
    .{ "Archaic", misc("arch") },
    .{ "Rare term", misc("rare") },
    .{ "Obscure term", misc("obsc") },
    .{ "Historical term", misc("hist") },
    .{ "Obsolete term", misc("obs") },
    .{ "Dated term", misc("dated") },
    .{ "Formal or literary term", misc("form") },
    .{ "Poetical term", misc("poet") },
    .{ "Colloquial", misc("col") },
    .{ "Familiar language", misc("fam") },
    .{ "Slang", misc("sl") },
    .{ "Internet slang", misc("net-sl") },
    .{ "Manga slang", misc("m-sl") },
    .{ "Jocular, humorous term", misc("joc") },
    .{ "Euphemistic", misc("euph") },
    .{ "Derogatory", misc("derog") },
    .{ "Sensitive", misc("sens") },
    .{ "Vulgar expression or word", misc("vulg") },
    .{ "Rude or X-rated term (not displayed in educational software)", misc("X") },
    .{ "Children's language", misc("chn") },
    .{ "Female term or language", misc("fem") },
    .{ "Male term or language", misc("male") },
    .{ "Honorific or respectful (sonkeigo) language", misc("hon") },
    .{ "Polite (teineigo) language", misc("pol") },
    .{ "Humble (kenjougo) language", misc("hum") },
    .{ "Idiomatic expression", misc("id") },
    .{ "Proverb", misc("proverb") },
    .{ "Quotation", misc("quote") },
    .{ "Onomatopoeic or mimetic word", misc("on-mim") },
    .{ "Yojijukugo (four character compound)", misc("yoji") },
    // Not a JMdict entity: Jisho shows lsource ls_wasei="y" this way.
    .{ "Wasei, word made in Japan", misc("wasei") },

    // ------------------------------------------------ name types
    // Jisho lists these as parts of speech; JMdict has them as misc entities.
    .{ "Place", misc("place") },
    .{ "Place name", misc("place") },
    .{ "Organization", misc("organization") },
    .{ "Organization name", misc("organization") },
    .{ "Company", misc("company") },
    .{ "Company name", misc("company") },
    .{ "Product", misc("product") },
    .{ "Product name", misc("product") },
    .{ "Service", misc("serv") },
    .{ "Event", misc("ev") },
    .{ "Character", misc("char") },
    .{ "Full name of a particular person", misc("person") },
    .{ "Full name", misc("person") },
    .{ "Family or surname", misc("surname") },
    .{ "Given name or forename, gender not specified", misc("given") },
    .{ "Work of art, literature, music, etc. name", misc("work") },
    .{ "Fiction", misc("fict") },
    .{ "Legend", misc("leg") },
    .{ "Mythology", misc("myth") },
    .{ "Deity", misc("dei") },
    .{ "Creature", misc("creat") },
    .{ "Religion", misc("relig") },
    .{ "Document", misc("doc") },
    .{ "Object", misc("obj") },
    .{ "Group", misc("group") },
    .{ "Ship name", misc("ship") },
    .{ "Train station", misc("station") },
    .{ "Other", misc("oth") },
    .{ "Unclassified name", misc("unclass") },

    // ------------------------------------------------ fields
    .{ "Agriculture", field("agric") },
    .{ "Anatomy", field("anat") },
    .{ "Archeology", field("archeol") },
    .{ "Architecture", field("archit") },
    .{ "Art, aesthetics", field("art") },
    .{ "Astronomy", field("astron") },
    .{ "Audiovisual", field("audvid") },
    .{ "Aviation", field("aviat") },
    .{ "Baseball", field("baseb") },
    .{ "Biochemistry", field("biochem") },
    .{ "Biology", field("biol") },
    .{ "Botany", field("bot") },
    .{ "Boxing", field("boxing") },
    .{ "Buddhism", field("Buddh") },
    .{ "Business", field("bus") },
    .{ "Card games", field("cards") },
    .{ "Chemistry", field("chem") },
    .{ "Chinese mythology", field("chmyth") },
    .{ "Christianity", field("Christn") },
    .{ "Civil engineering", field("civeng") },
    .{ "Clothing", field("cloth") },
    .{ "Computing", field("comp") },
    .{ "Crystallography", field("cryst") },
    .{ "Dentistry", field("dent") },
    .{ "Ecology", field("ecol") },
    .{ "Economics", field("econ") },
    .{ "Electricity, elec. eng.", field("elec") },
    .{ "Electronics", field("electr") },
    .{ "Embryology", field("embryo") },
    .{ "Engineering", field("engr") },
    .{ "Entomology", field("ent") },
    .{ "Figure skating", field("figskt") },
    .{ "Film", field("film") },
    .{ "Finance", field("finc") },
    .{ "Fishing", field("fish") },
    .{ "Food, cooking", field("food") },
    .{ "Gardening, horticulture", field("gardn") },
    .{ "Genetics", field("genet") },
    .{ "Geography", field("geogr") },
    .{ "Geology", field("geol") },
    .{ "Geometry", field("geom") },
    .{ "Go (game)", field("go") },
    .{ "Golf", field("golf") },
    .{ "Grammar", field("gramm") },
    .{ "Greek mythology", field("grmyth") },
    .{ "Hanafuda", field("hanaf") },
    .{ "Horse racing", field("horse") },
    .{ "Internet", field("internet") },
    .{ "Networking, WWW", field("internet") },
    .{ "Japanese mythology", field("jpmyth") },
    .{ "Kabuki", field("kabuki") },
    .{ "Law", field("law") },
    .{ "Linguistics", field("ling") },
    .{ "Logic", field("logic") },
    .{ "Mahjong", field("mahj") },
    .{ "Manga", field("manga") },
    .{ "Martial arts", field("MA") },
    .{ "Mathematics", field("math") },
    .{ "Mechanical engineering", field("mech") },
    .{ "Medicine", field("med") },
    .{ "Meteorology", field("met") },
    .{ "Military", field("mil") },
    .{ "Mineralogy", field("min") },
    .{ "Mining", field("mining") },
    .{ "Motorsport", field("motor") },
    .{ "Music", field("music") },
    .{ "Noh", field("noh") },
    .{ "Ornithology", field("ornith") },
    .{ "Paleontology", field("paleo") },
    .{ "Pathology", field("pathol") },
    .{ "Pharmacology", field("pharm") },
    .{ "Philosophy", field("phil") },
    .{ "Photography", field("photo") },
    .{ "Physics", field("physics") },
    .{ "Physiology", field("physiol") },
    .{ "Politics", field("politics") },
    .{ "Printing", field("print") },
    .{ "Professional wrestling", field("prowres") },
    .{ "Psychiatry", field("psy") },
    .{ "Psychoanalysis", field("psyanal") },
    .{ "Psychology", field("psych") },
    .{ "Railway", field("rail") },
    .{ "Roman mythology", field("rommyth") },
    .{ "Shinto", field("Shinto") },
    .{ "Shogi", field("shogi") },
    .{ "Skiing", field("ski") },
    .{ "Sports", field("sports") },
    .{ "Statistics", field("stat") },
    .{ "Stock market", field("stockm") },
    .{ "Sumo", field("sumo") },
    .{ "Surgery", field("surg") },
    .{ "Telecommunications", field("telec") },
    .{ "Television", field("tv") },
    .{ "Trademark", field("tradem") },
    .{ "Veterinary terms", field("vet") },
    .{ "Video games", field("vidg") },
    .{ "Zoology", field("zool") },

    // ------------------------------------------------ dialects
    .{ "Brazilian", dialect("bra") },
    .{ "Hokkaido dialect", dialect("hob") },
    .{ "Kansai dialect", dialect("ksb") },
    .{ "Kantou dialect", dialect("ktb") },
    .{ "Kyoto dialect", dialect("kyb") },
    .{ "Kyuushuu dialect", dialect("kyu") },
    .{ "Nagano dialect", dialect("nab") },
    .{ "Osaka dialect", dialect("osb") },
    .{ "Ryuukyuu dialect", dialect("rkb") },
    .{ "Touhoku dialect", dialect("thb") },
    .{ "Tosa dialect", dialect("tsb") },
    .{ "Tsugaru dialect", dialect("tsug") },
});

/// Jisho marks its appended Wikipedia sense with this part of speech.
pub const wikipedia_pos = "Wikipedia definition";

/// Old or misspelled codes Mazii uses -> current JMdict code.
pub const mazii_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "adv-n", "n-adv" },
    .{ "gram", "gramm" },
    .{ "osk", "osb" },
    .{ "tm", "tradem" },
    // Mazii's own codes with a close JMdict equivalent: conjunctive particle
    // (けど, なら) and subsidiary verb (ちまう).
    .{ "conj-p", "prt" },
    .{ "sub-v", "aux-v" },
});

/// Mazii codes that carry no usable tag: retired JMdict catch-alls ("v",
/// "adj", "v5", "iv"), kanji/reading notes ("ok", "ik", "gikun"), codes with
/// no JMdict equivalent ("word-for-el", word-forming element) and plain noise
/// ("verbal" comes from "verbal noun" written out in words).
pub const mazii_ignored = std.StaticStringMap(void).initComptime(.{
    .{"v"},           .{"v5"},   .{"adj"},    .{"iv"},       .{"ok"},
    .{"ik"},          .{"noun"}, .{"phrase"}, .{"compound"}, .{"adverbial"},
    .{"fig"},         .{"neg"},  .{"kanji"},  .{"gikun"},    .{"verbal"},
    .{"word-for-el"},
    .{"∫"},
});

/// Splits a Mazii `kind` string such as "n, vs" into raw codes.
pub fn maziiKindCodes(kind: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, kind, ", ");
}

pub const MaziiCode = union(enum) {
    known: []const u8,
    ignored,
    unknown,
};

/// Classifies one raw Mazii code, applying aliases.
pub fn maziiCode(raw: []const u8) MaziiCode {
    if (mazii_ignored.has(raw)) return .ignored;
    const code = mazii_aliases.get(raw) orelse raw;
    return if (isKnownCode(code)) .{ .known = code } else .unknown;
}

/// True when `code` appears in `by_jisho_label`, so it exists in the `tag` table.
pub fn isKnownCode(code: []const u8) bool {
    for (by_jisho_label.values()) |tag| {
        if (std.mem.eql(u8, tag.code, code)) return true;
    }
    return false;
}

/// Fills the `tag` lookup table from `by_jisho_label`. `keys()` comes back
/// sorted by length, so the shortest label per code wins, not the listed order.
pub fn seed(db: Db) !void {
    const insert = try db.prepare("INSERT OR IGNORE INTO tag (code, category, label_en) VALUES (?, ?, ?)");
    defer insert.deinit();
    for (by_jisho_label.keys(), by_jisho_label.values()) |label, tag| {
        try insert.run(.{ tag.code, @tagName(tag.category), label });
    }
}

test "maps Jisho labels to JMdict codes" {
    const tag = by_jisho_label.get("Godan verb with 'ru' ending").?;
    try std.testing.expectEqualStrings("v5r", tag.code);
    try std.testing.expectEqual(Category.pos, tag.category);
    try std.testing.expectEqual(Category.dialect, by_jisho_label.get("Kansai dialect").?.category);
    try std.testing.expectEqual(null, by_jisho_label.get(wikipedia_pos));
}

test "splits and classifies Mazii kind" {
    var it = maziiKindCodes("n, vs, adj-no");
    try std.testing.expectEqualStrings("n", it.next().?);
    try std.testing.expectEqualStrings("vs", it.next().?);
    try std.testing.expectEqualStrings("adj-no", it.next().?);
    try std.testing.expectEqual(null, it.next());

    try std.testing.expectEqualStrings("n-adv", maziiCode("adv-n").known);
    try std.testing.expectEqualStrings("tradem", maziiCode("tm").known);
    try std.testing.expectEqualStrings("prt", maziiCode("conj-p").known);
    try std.testing.expectEqualStrings("aux-v", maziiCode("sub-v").known);
    try std.testing.expectEqual(MaziiCode.ignored, maziiCode("gikun"));
    try std.testing.expectEqual(MaziiCode.ignored, maziiCode("noun"));
    try std.testing.expectEqual(MaziiCode.unknown, maziiCode("bogus"));
}
