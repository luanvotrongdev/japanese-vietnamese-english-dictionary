# Standardized schema (proposal)

Target schema for the database built from `jmdict-cache.sqlite`. It replaces the raw JSON blobs with relational tables that follow JMdict / KANJIDIC structure, and keeps English (Jisho, JMdict-based) and Vietnamese (Mazii) content side by side.

Figures below come from profiling a 5% sample of `raw_word_crawl_json` and all of `raw_kanji_crawl_json`.

## Design decisions

1. **`ent_seq` is the entry key.** The cache's `entry.id` is an internal counter. `ent_seq` is JMdict's own ID, so it stays stable across rebuilds and lets the data be joined with other JMdict-based sources.
2. **One `sense` table for both languages.** English and Vietnamese senses don't line up one-to-one (Jisho and Mazii split meanings differently), so they are stored as separate sense lists per entry, told apart by `source` and `lang`. There is no attempt to pair them.
3. **All tags use JMdict entity codes** (`n`, `v5r`, `vt`, `uk`, `comp`, ...). Mazii already uses these codes (`kind: "n, vs"`). Jisho uses English labels (`"Godan verb with 'ru' ending"`), which get mapped back to codes through the `tag` table. One vocabulary means one filter works for both sources.
4. **Normalize repeated lists into child tables** (forms, glosses, tags, examples, readings) with a `position` column to keep source order.
5. **Keep only what a dictionary needs.** Drop crawler noise: Mazii `_id`, `_rev`, `weight`, `images`, `suggestWords`, `lang`, `label`; Jisho Wikipedia `links`, WaniKani tags, stroke-order URIs (derivable from the code point), Mazii `comp_graph`.
6. **Keep source IDs for tracing** (`mazii_id`), so any row can be traced back to the crawl.

## Tables

The DDL lives in [`src/schema.sql`](../src/schema.sql), which the transform embeds and runs on a fresh output database. Column comments there explain where each value comes from.

- **Words:** `entry`, `kanji_form`, `reading_form`, `reading_restriction`, `sense`, `gloss`, `sense_tag`, `sense_restriction`, `sense_xref`, `sense_origin`, `example`, `entry_relation`.
- **Kanji:** `kanji`, `radical`, `kanji_reading`, `kanji_meaning`, `kanji_component`, `kanji_example`.
- **Lookup:** `tag` (JMdict entity codes).

## Transform rules

### Picking the right crawl results

Both crawls returned search results for a form, not the exact entry, so each row needs filtering.

- **Jisho:** keep only results with `attribution.jmdict = true`. About 7% of results are Wikipedia-only (DBpedia) and 2% come from JMnedict (place, company and person names). Then keep the result whose `japanese[]` word/reading set overlaps the entry's `kanji_form` / `reading_form` the most. About 22% of rows have more than one result, mostly homographs. Jisho results carry no `ent_seq`, so form overlap is the only key.
- **Wikipedia senses:** Jisho appends a sense with part of speech `"Wikipedia definition"` (16% of senses). These are stored as `source = 'wikipedia'` without tags, never as JMdict senses.
- **Name senses:** results attributed to both JMdict and JMnedict carry name-type parts of speech (`"Place"`, `"Organization"`, `"Full name"`, ...). These are kept and tagged with JMdict's name entities (`place`, `organization`, `person`, ...).
- **Mazii:** keep only `words[]` whose `word` exactly matches one of the entry's kanji forms, or one of its readings when the entry has no kanji forms. A kana-only Mazii word on an entry with kanji is almost always a different word with the same reading (火器 "firearm" vs かき "persimmon"). When several match, keep the one whose `phonetic` contains one of the entry's readings. In the full data, 141,611 of 190,057 rows get a Mazii match.
- **Mazii homographs:** Mazii merges every reading of a spelling into one word (上手: phonetic `"かみて じょうしゅ うわて じょうず じょうて"`, one combined list of meanings), and nothing links a meaning to a reading. So a Mazii word is skipped when its spelling belongs to more than one entry: a kanji form shared with another entry, or, for kana-only entries, a reading shared with another kana-only entry. Those entries get no Vietnamese senses. This skips 5,420 rows, including some common words whose spelling is shared with a rare entry (両面 りょうめん and the mahjong term リャンメン).

### Normalizing values

- Store all text as Unicode NFC and trim whitespace (Mazii kanji example readings often start with a space).
- Mazii `kind`: split on `,` and spaces, map retired codes to current ones (`adv-n` → `n-adv`, `gram` → `gramm`, `osk` → `osb`), and keep known JMdict codes. Drop catch-alls and noise (`v`, `adj`, `v5`, `noun`, `phrase`, ...; see `tags.mazii_ignored`). A few rows hold `false` or a list of Vietnamese labels (`["danh từ"]`); those get no tags.
- Mazii `mean`: split on `;` into separate glosses, and drop a single trailing period ("ăn." → "ăn") but keep "v.v." (etc.) and ellipses.
- Mazii examples with no `mean` (translation) are skipped, since `example.translation` is required.
- Kanji `example_on` / `example_kun` sometimes hold `{"vi": null}` instead of examples; skip null entries.
- Jisho `parts_of_speech` and `tags`: map labels to JMdict codes with `tags.by_jisho_label`. The transform logs every label it can't map (none in the current data). "Wasei, word made in Japan" is not a JMdict entity, so it gets the custom misc code `wasei`.
- Jisho `see_also` / `antonyms` (`"雑煮 ぞうに"` = spelling, then reading) and Mazii synonyms/antonyms get `target_ent_seq` only when exactly one entry matches (96% of cross-references, 89% of relations).
- Reading restrictions: a reading that Jisho pairs with only some of the entry's kanji forms is restricted to those. Kanji forms that appear in no pair are left out of the comparison, since Jisho hides some forms entirely.
- JLPT: `'jlpt-n3'` (words) and `'N3'` (kanji) become the integer `3`. A word listed at several levels keeps the easiest (largest number).
- The JMdict metadata entry (`ent_seq` 9999999, "ＪＭｄｉｃｔ") is skipped.
- Kanji readings: take them from Jisho (`onyomi`, `kunyomi`), which already uses KANJIDIC notation (`ひび.く`). Use Mazii's space-separated `on` / `kun` strings only when Jisho has none.
- Mazii `pronunciation[]`: copy `accent` onto the `reading_form` whose text equals `kana`.

## Open questions

- **Kanji JLPT source:** Jisho (`jlptLevel`) and Mazii (`level[]`) can disagree. Pick one as primary.
- **Unicode NFC:** not applied yet; Zig's standard library has no normalization, so it needs a library such as `zg`.
- **Search:** add an FTS5 table over `gloss.text` if the app needs Vietnamese or English reverse lookup.
