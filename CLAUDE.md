# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository transforms and standardizes a crawled Japanese dictionary cache (`jmdict-cache.sqlite`) into a clean, normalized database. The target is a Japanese → Vietnamese (and English) dictionary ("javi"). The transform is written in Zig. The only input is the SQLite file at the repo root. The same binary exports the built database (`javi.sqlite`) as a Kobo dictionary and a Yomitan dictionary.

## Commands

Requires Zig **0.16.0** exactly (pinned in `build.zig.zon`; installed with `winget install zig.zig --version 0.16.0`). Zig's standard library changes between releases, so check APIs against the installed std source (`zig env` → `std_dir`) rather than memory.

```bash
zig build                                   # debug build → zig-out/bin/javi-transform.exe
zig build -Doptimize=ReleaseFast            # use this for full-data runs
zig build test                              # all unit tests
zig build test -Dtest-filter="Mazii kind"   # tests whose name contains the text
zig-out/bin/javi-transform check jmdict-cache.sqlite              # parse every crawl blob against src/crawl.zig
zig-out/bin/javi-transform build jmdict-cache.sqlite javi.sqlite  # rebuild the output DB from scratch
zig-out/bin/javi-transform crawl jmdict-cache.sqlite --dry-run    # count entries and kanji with no crawl row
zig-out/bin/javi-transform crawl jmdict-cache.sqlite              # fetch them from Mazii/Jisho (writes to the cache)
zig-out/bin/javi-transform kobo javi.sqlite dicthtml-ja.zip       # Kobo dictionary (copy to KOBOeReader/.kobo/custom-dict/)
zig-out/bin/javi-transform yomitan javi.sqlite lulujv.zip         # Yomitan dictionary
```

After a `build`, `python -I tools/scan.py javi.sqlite` runs data-quality checks on the output. Open problems, with sizes and planned fixes, are listed in `docs/known-issues.md`; update it as issues are fixed.

Run `check` after any change to `src/crawl.zig`. It reports failing row ids and byte offsets. In ReleaseFast, `check` takes about 8 s and `build` about 45 s on the full data; `kobo` takes about 10 s and `yomitan` about 6 s.

## Code layout

- **Target schema:** `src/schema.sql` is the DDL. It is embedded with `@embedFile` and run on a fresh output DB. `docs/schema.md` explains the design and the transform rules (how to pick the right Jisho/Mazii result, value normalization). Follow those rules when adding transform steps.
- **SQLite:** vendored amalgamation in `vendor/sqlite/` (3.54.1). `build.zig` compiles `sqlite3.c` into the binary and exposes the header as the `sqlite_c` module via `addTranslateC` (not `@cImport`). `src/db.zig` is the only file that touches the C API. `Stmt.run(.{...})` binds a tuple and steps. Text is bound without copying, so bound slices must outlive the step.
- **Pipeline:** `src/main.zig` `build` opens the input read-only, deletes and recreates the output, then runs every step inside one transaction with journaling off. Steps run in order: `tags.seed`, `forms.copy` (entries and kanji/reading forms, re-keyed from the cache's `entry.id` to `ent_seq`, skipping the JMdict metadata entry 9999999), `words.transform`, then `kanji.transform`.
- **Word step:** `src/words.zig` reads each crawl row, picks the matching Jisho result and Mazii word (`pickJisho` / `pickMazii`), and writes entry fields, senses, glosses, tags, examples, cross-references, relations, pitch accents and reading restrictions. Labels or codes it can't map are logged as `unmapped ...` warnings at the end of `build`. Add them to `src/tags.zig` (or `src/lang.zig` for loanword languages) rather than ignoring them. The `transforms crawl rows` test runs sample JSON through the whole step against an in-memory database.
- **Kanji step:** `src/kanji.zig` reads each `raw_kanji_crawl_json` row and fills `radical`, `kanji`, `kanji_reading`, `kanji_meaning`, `kanji_component` and `kanji_example`, linking example words to entries when word and reading match exactly one. It runs after the word step and reuses its helpers (`trim`, `Unmapped`). The `transforms kanji crawl rows` test runs sample JSON through it against an in-memory database.
- **Crawler:** `src/crawler.zig` (`crawl` command) is a port of the old Bun crawler. It only fills gaps: entries with no `raw_word_crawl_json` row (searched by first kanji spelling, else first reading) and kanji in any `keb` with no `raw_kanji_crawl_json` row. Kanji go first, then entries by `entry.id`. Each row is committed on its own, so it can be stopped with Ctrl+C and rerun. A failed item is retried with a doubling pause, and stops the run after 8 attempts (about 40 minutes). Options: `--limit N`, `--min-sleep MS`, `--max-sleep MS` (default pause 500–1500 ms per item; the full gap takes many hours). Jisho has no kanji API, so the kanji page HTML is scraped into the same fields the `unofficial-jisho-api` package produced. Requests have no read timeout.
- **JSON:** `src/crawl.zig` holds typed structs for both blob kinds, parsed with `std.json` (`ignore_unknown_fields`). Fields whose JSON type varies between rows use `std.json.Value`. Parse each row into an arena that is reset per row.
- **Exporters:** port of the old Bun exporters in `ja-vi-jmdict/` (a separate, git-ignored checkout kept for reference), reading `javi.sqlite` instead of the crawl JSON. `src/entries.zig` reads words and kanji into structs (Wikipedia senses left out, at most 2 examples per Vietnamese sense, Vietnamese word-type labels for Mazii tags). `src/kobo.zig` renders HTML and writes the dictzip directly, with no dictgen: Kobo's Japanese lookup needs its own shard names (`shardPrefix`: 1 character for kanji words, 2 for kana, after [kobo_jp_dict](https://github.com/cessen/kobo_jp_dict)), all-kana keys also get a katakana key, and entries sharing a key are merged (common words, other words, kanji). Kobo's default Georgia lacks Vietnamese letters (ư ơ ạ ế …), so entries ask for Kobo Nickel inline, but some devices ignore that and drop those letters; there the fix is the system font replacement from [lelinhtinh/kobo-tieng-viet](https://github.com/lelinhtinh/kobo-tieng-viet) (confirmed on-device 2026-11-12). `src/marisa.zig` builds the dictzip's `words` index; it is a Zig port of marisa-trie's build path and its test checks bytes against `marisa-build`. `src/yomitan.zig` writes the format-3 banks (one term per kanji × reading pair, respecting reading restrictions; inflection rules; pitch meta; ★/JLPT tags). `src/zip.zig` is a minimal ZIP writer (store or deflate, no ZIP64). `src/entries.zig` cleans every display string with `src/text.zig`, as the old exporter did, plus Mazii's HTML: tags stripped and entities decoded (subject labels like `<Y>` kept); NFC (decomposed Vietnamese accents render badly on Kobo), invisible and control characters removed (Kobo parses shards as XML, where control characters are invalid), line breaks collapsed, Mazii's space before punctuation removed, values with no letter or digit dropped, repeated glosses dropped. The NFC data in `src/nfc_table.zig` is generated by `tools/gen_nfc.py` and only covers marks U+0300–U+036F, so Japanese text is never changed. `text.zig` is meant to move into the transform when known issues #4–#8 are fixed there. Kanji cards come from the kanji tables; a kanji with no Hán Việt reading and no meaning gets no card.
- **Tags:** `src/tags.zig` maps Jisho labels to JMdict entity codes with a compile-time `StaticStringMap`, normalizes Mazii codes (aliases plus an ignore list), and fills the `tag` table. `sense_tag` has a foreign key to `tag`, so a code must be in `by_jisho_label` before it can be stored.

## Source database: `jmdict-cache.sqlite`

- About 1.2 GB. `.gitignore` excludes all `*.sqlite` files (plus journal/WAL files), so the generated `javi.sqlite` (about 140 MB) stays out of git too. Neither may be committed: GitHub rejects files over 100 MB.
- Treat it as read-only input, except for the `crawl` command, which only inserts missing crawl rows. Open it read-only (`file:jmdict-cache.sqlite?mode=ro` with `uri=True` in Python) and write transformed output to a separate database or file.
- The DDL style (backtick quoting, `<table>_<col>_unique` index names) shows it was generated by Drizzle ORM (sqlite). The crawler that produced it lives in another project.
- `sqlite3` CLI is not installed on this machine. For ad-hoc exploration, use Python's built-in `sqlite3` module. On Windows, call `sys.stdout.reconfigure(encoding='utf-8')` before printing Japanese/Vietnamese text, or output fails with cp1252 `UnicodeEncodeError`. (`PYTHONIOENCODING` is ignored when running with `python -I`.)
- Full-table scans over `raw_word_crawl_json` are slow (about 1 GB of JSON). Use `LIMIT` while exploring and SQLite's `json_extract` / `json_array_length` to filter in SQL.

### Tables

| Table | Rows | Contents |
|---|---|---|
| `entry` | 214,014 | One row per JMdict entry. `ent_seq` is the JMdict sequence number (unique). `id` is the internal key used by the other tables. |
| `k_ele` | 226,209 | Kanji spellings (`keb`) per entry, ordered by `position`. |
| `r_ele` | 259,363 | Kana readings (`reb`) per entry, ordered by `position`. `re_nokanji` is currently always NULL. |
| `raw_word_crawl_json` | 190,058 | One crawled JSON blob per entry (`entry_id` → `entry.id`). About 24k entries have no crawl row. |
| `raw_kanji_crawl_json` | 5,994 | One crawled JSON blob per kanji character (`textId` = the character, unique). Not linked to `entry`. |

`entry`, `k_ele` and `r_ele` mirror the JMdict XML element names (`entry`, `k_ele/keb`, `r_ele/reb/re_nokanji`). Only those fields were imported; senses/glosses come from the crawl JSON.

### Crawl JSON shapes

Each blob combines responses from two sources: **Mazii** (Vietnamese) and **Jisho** (English, JMdict-based). Either side may be empty (`[]`, `"found": false`, or empty `data`).

Word (`raw_word_crawl_json.json`, `type` is always `"phrase"`):
```
{ "type": "phrase",
  "mazii": { "suggestWords": [...], "words": [ { word, phonetic, short_mean, means: [{mean, kind, examples}], label: "ja_vi", mobileId, weight, images, synsets, opposite_word, ... } ] },
  "jisho": { "meta": {status}, "data": [ { slug, is_common, tags, jlpt, japanese: [{word, reading}], senses: [{english_definitions, parts_of_speech, links, tags, restrictions, see_also, antonyms, source, info}], attribution } ] } }
```
- `mazii.words` may contain several candidates, not only an exact match for the entry. Matching against `k_ele.keb` / `r_ele.reb` is required.
- Mazii has one word per spelling: all readings of a spelling share one merged list of meanings, so homograph entries (上手 じょうず / うわて) can't be told apart on the Mazii side. The transform skips Mazii data for spellings shared by more than one entry (`pickMazii` / `isHomograph` in `src/words.zig`).
- Mazii `phonetic` is a space-separated mix of readings and spellings, not one reading.
- A few rows break the usual shape: Mazii `kind` can be `false` or a list of Vietnamese labels, and some examples have no `mean`.

Kanji (`raw_kanji_crawl_json.json`, `type` is always `"kanji"`):
```
{ "type": "kanji",
  "mazii": [ { kanji, mean (Hán Việt reading, uppercase), detail ("##"-separated Vietnamese explanations), level: ["N2"], kun, on, examples: [{w, m, p, h}], example_on: {reading: [{w, m, p}]}, example_kun, mobileId, ... } ],
  "jisho": { "query", "found", ... } }
```
- In examples: `w` = word, `m` = Vietnamese meaning, `p` = kana reading (often has a leading space), `h` = Hán Việt reading.
- `example_on` / `example_kun` sometimes hold `{"vi": null}` instead of examples.
