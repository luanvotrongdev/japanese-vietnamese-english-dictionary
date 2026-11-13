# javi: Japanese → Vietnamese dictionary for Kobo and Yomitan

[Tiếng Việt](README.md) | **English**

Builds a Japanese → Vietnamese (and English) dictionary from JMdict headwords, with meanings from **Mazii** (Vietnamese) and **Jisho** (English), and exports it as:

- a **Kobo** dictionary (`dicthtml-ja.zip`), for looking words up in Japanese books on a Kobo e-reader
- a **Yomitan** dictionary (`lulujv.zip`), for the browser pop-up dictionary

Everything runs in one Zig program, `javi-transform`, with no other tools to install.

> A personal side project, built to read Japanese books with Vietnamese definitions. Use it at your own risk.

## What an entry looks like

```
食べる 【たべる】 [2]  N5 · thông dụng
Cách viết khác: 喰べる
Động từ nhóm 2 · tha động từ
 1. ăn
    食べるほど食欲がでる。
    Tôi càng ăn nhiều thì sự thèm ăn của tôi càng lớn.
English
 1. Ichidan verb, Transitive verb
    to eat
 2. to live on (e.g. a salary); to live off; to subsist on
```

Looking up a single kanji also shows its kanji card: Hán Việt reading, Vietnamese explanation, on/kun readings, radical, components, a memory tip and example words.

You can look a word up by any of its kanji spellings, its hiragana reading or its katakana form.

## The data is not included

This repository contains no dictionary data. The Vietnamese and English meanings come from Mazii and Jisho, and their content belongs to them, so it can't be redistributed. You build your own copy with the steps below: import JMdict, crawl Mazii and Jisho, build the database, export.

## Requirements

- [Zig](https://ziglang.org/download/) **0.16.0** exactly (the standard library changes between releases)
- An internet connection for the first steps: downloading JMdict and crawling Mazii and Jisho
- For Kobo: firmware **4.24.15672 or newer**, which supports custom dictionaries without patches

## Usage

### 1. Build the program

```bash
zig build -Doptimize=ReleaseFast
```

The program is `zig-out/bin/javi-transform` (`javi-transform.exe` on Windows).

### 2. Import JMdict

```bash
zig-out/bin/javi-transform jmdict jmdict-cache.sqlite
```

This downloads JMdict (`JMdict_e_examp.gz`, about 13 MB, from the EDRDG server) and stores every entry's headwords and readings in `jmdict-cache.sqlite`, the cache the next steps use. If the file doesn't exist yet, it is created.

Run it again any time to pick up a newer JMdict. Existing entries keep their crawled data, and only new or changed words need crawling. Words that JMdict has removed are reported; add `--prune` to delete them along with their crawled data. To use a JMdict file you already have, pass `--file JMdict_e_examp.gz` (a `.gz` or `.xml` file).

### 3. Crawl Mazii and Jisho

```bash
zig-out/bin/javi-transform crawl jmdict-cache.sqlite --dry-run
```

```bash
zig-out/bin/javi-transform crawl jmdict-cache.sqlite
```

This fetches the Vietnamese and English meanings for every word and kanji. `--dry-run` only counts the entries and kanji that have no Mazii/Jisho data yet. Without it, the program fetches them and saves each one to the cache as it goes. Stop it any time with Ctrl+C; rerunning continues where it left off. It waits 0.5–1.5 seconds between requests. Please don't make it faster: be gentle with Mazii and Jisho. A full crawl takes many hours. Options: `--limit N`, `--min-sleep MS`, `--max-sleep MS`.

### 4. Build the dictionary database

```bash
zig-out/bin/javi-transform build jmdict-cache.sqlite javi.sqlite
```

This turns the raw crawl data into a clean database, `javi.sqlite` (about a minute). Both exports read from it.

### 5a. Export the Kobo dictionary

```bash
zig-out/bin/javi-transform kobo javi.sqlite dicthtml-ja.zip
```

To install it:

1. Connect the Kobo to your computer.
2. Copy `dicthtml-ja.zip` into `KOBOeReader/.kobo/custom-dict/`. Create the folder if it doesn't exist; `.kobo` is a hidden folder.
3. Eject the Kobo.
4. In a book, long-press a word, then pick **日本語 (Custom)** in the dictionary pop-up.

**If Vietnamese letters are missing** (for example "CHIẾN" shows as "CHIN"), your Kobo is drawing the dictionary in its built-in Georgia font, which lacks letters like ư ơ ạ ế ự. The entries ask for a font that has them (Kobo Nickel), but some Kobos ignore that. Install the Vietnamese font fix from **[lelinhtinh/kobo-tieng-viet](https://github.com/lelinhtinh/kobo-tieng-viet)**. It replaces Kobo's Georgia and Avenir Next with Vietnamese-capable versions, which fixes the dictionary and Vietnamese text everywhere else on the device. In short: download `KoboRoot.tgz` from the project's latest release, copy it into `KOBOeReader/.kobo/`, and eject; the Kobo installs it and restarts. Follow that project's README for the current steps. It changes system files, and a firmware update can undo it.

### 5b. Export the Yomitan dictionary

```bash
zig-out/bin/javi-transform yomitan javi.sqlite lulujv.zip
```

In Yomitan, open **Settings → Dictionaries → Import** and select `lulujv.zip`. You get:

- word-type labels, numbered Vietnamese meanings with example sentences, and a separate English section
- pitch-accent graphs
- **★** (common word) and **JLPT** level tags
- all spellings of a word grouped into one result
- inflected forms found too (食べた → 食べる)
- kanji cards with Hán Việt, explanations and a stats table

Each part of an entry has a `data-sc-content` attribute (`vietnamese`, `english`, `example`, `word-types`, `section-label`), so you can restyle it with Yomitan's custom CSS.

## All commands

| Command | What it does |
| --- | --- |
| `jmdict <cache.sqlite> [--file PATH] [--url URL] [--prune]` | Download JMdict and import its headwords and readings into the cache (creates it if missing) |
| `crawl <cache.sqlite> [--dry-run] [--limit N] [--min-sleep MS] [--max-sleep MS]` | Fetch Mazii/Jisho data for entries and kanji that have none |
| `check <cache.sqlite>` | Check that every crawled response can be read, and report the ones that can't |
| `build <cache.sqlite> <javi.sqlite>` | Build the clean dictionary database |
| `kobo <javi.sqlite> <dicthtml-ja.zip>` | Export the Kobo dictionary |
| `yomitan <javi.sqlite> <lulujv.zip>` | Export the Yomitan dictionary |

Run the tests with `zig build test`. `docs/schema.md` describes the database, and `docs/known-issues.md` lists known data problems.

## Credits

- **[Mazii](https://mazii.net)**, the Japanese–Vietnamese dictionary: all Vietnamese meanings, example sentences, pitch accents and the kanji details (Hán Việt readings, explanations, components, memory tips).
- **[Jisho](https://jisho.org)**, the Japanese–English dictionary: English meanings, parts of speech, JLPT levels, common-word flags, and kanji readings, radicals and stroke counts.
- **[lelinhtinh/kobo-tieng-viet](https://github.com/lelinhtinh/kobo-tieng-viet)** by lelinhtinh: the Vietnamese font fix that makes Vietnamese text display on Kobo.
- [JMdict](https://www.edrdg.org/jmdict/edict.html) by the Electronic Dictionary Research and Development Group: the word list (headwords, spellings and readings), under the [EDRDG licence](https://www.edrdg.org/edrdg/licence.html).
- [cessen/kobo_jp_dict](https://github.com/cessen/kobo_jp_dict), for showing how Kobo looks up Japanese words; [pgaskin/dictutil](https://github.com/pgaskin/dictutil), for documenting the Kobo dictionary format; and [marisa-trie](https://github.com/s-yata/marisa-trie) by Susumu Yata, whose trie format Kobo uses for its word index (ported to Zig here).
- Written by Vo Trong Luan, with help from [Claude Code](https://claude.com/claude-code).

Neither Mazii nor Jisho is affiliated with this project. Their content belongs to them, and JMdict data is under the EDRDG licence.
