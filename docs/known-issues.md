# Known issues in the transformed database

Problems found by scanning `javi.sqlite` on 2026-11-10, after the word step (commit `77731f8` plus the Mazii homograph skip). None are fixed yet. Each fix belongs in the transform (`src/words.zig` unless noted), not in a post-processing pass.

Re-run the scan after each fix to confirm the count drops:

```bash
python -I tools/scan.py javi.sqlite
```

The script prints each check's hit count and a few examples (`--all` also shows checks with no hits). Counts below are from that run.

## Summary

| # | Problem | Size | Priority |
|---|---|---|---|
| 1 | JMnedict name senses stored as JMdict senses | 5,984 senses | High |
| 2 | English text stored as Vietnamese | ~5,700 senses, 5,229 entries | High |
| 3 | Entries with identical spellings share one Jisho result | 192 groups | High |
| 4 | HTML entities split into junk glosses | 226 glosses | High |
| 5 | HTML tags, entities and Mazii subject labels in text | ~650 rows | Medium |
| 6 | Line breaks and invisible characters | ~320 rows (197 line breaks, 123 zero-width) | Medium |
| 7 | Vietnamese text not in NFC | 2,141 rows | Medium |
| 8 | Double or stray spaces | ~540 rows | Medium |
| 9 | Duplicate senses, glosses and examples | ~500 groups after #1 | Medium |
| 10 | Contradictory or self-pointing references | 42 rows | Low |
| 11 | Example readings that contain kanji | 217 rows | Low |
| – | Not fixable from this data | see below | – |

## High priority: wrong content

### 1. JMnedict name senses stored as JMdict senses

Jisho merges senses from JMnedict, its name dictionary, into JMdict results. Those senses carry a name type as their part of speech (`"Place"`, `"Organization"`, `"Company"`, `"Full name"`, ...) and are stored as `source = 'jmdict'`, tagged with the name code (`place`, `organization`, ...) and no part of speech.

- 5,984 senses in 5,984 entries.
- They cause most of the 3,695 duplicate-sense groups (#9): "FBI" appears once tagged `n` (JMdict) and again tagged `organization` (JMnedict).
- Do not use the name tag alone to detect them: 5,847 genuine JMdict senses also carry a name tag next to a real part of speech (カンザス "Kansas": `n`, `place`).

**Fix:** in `addJisho`, treat a sense as JMnedict when its `parts_of_speech` contains only name-type labels. Store it with a new `source = 'jmnedict'` (add it to the `sense.source` CHECK in `src/schema.sql`), with its own position counter like `wikipedia`. Dropping these senses is the alternative.

### 2. English text stored as Vietnamese

For some words Mazii returns the English meaning instead of a Vietnamese one, and it is stored as a `lang = 'vi'` sense and as `summary_vi`.

- About 5,870 glosses in 5,714 senses, across 5,229 entries. In 4,670 entries every "Vietnamese" sense is English. About 4,390 `summary_vi` values are English too.
- Examples: "saw-edged perch (Niphon spinosus)", "unskillfulness", "dormie hole (golf)", "I wonder".
- The scan's detector (`looks_english` in `tools/scan.py`) flags ASCII text with an English function word, a letter Vietnamese doesn't use (f, j, w, z), or a Latin species name. Plain Vietnamese written without diacritics ("anh trai", "leng keng") is not flagged, but a few false positives remain ("to ra").

**Fix:** in `addMazii`, skip a mean whose glosses all look English, and leave `summary_vi` NULL when it looks English. These senses only repeat the Jisho English. Relabeling them `lang = 'en'` is the alternative.

### 3. Entries with identical spellings share one Jisho result

When two JMdict entries have exactly the same spellings and readings, `pickJisho` scores Jisho's results for them equally and gives both the first one.

- 192 groups of entries.
- Example: アウトロー 1014910 "outlaw" and 2841465 "low and away (pitch)" both got "outlaw". Jisho returned both meanings as separate results, with slugs `アウトロー` and `アウトロー-1`.

**Fix:** when several entries share the same form set, give each one a different tied Jisho result. Jisho's numbered slugs (`-1`, `-2`) and `ent_seq` order look like a usable pairing, since in the アウトロー case the lower `ent_seq` matches the unnumbered slug. Check that on more groups before relying on it.

### 4. HTML entities split into junk glosses

`splitGlosses` splits Mazii `mean` on `;` before decoding HTML, so `"&amp;nbsp;cầu chúc"` becomes the glosses `"&amp"`, `"nbsp"` and `"cầu chúc"`.

- 226 junk glosses (`&amp`, `nbsp`).

**Fix:** decode entities and strip tags (#5) before splitting.

## Medium priority: text cleanup

Fixes #5–#8 belong in one shared text-cleaning function applied to every Mazii string (glosses, `summary_vi`, example fields) before splitting or storing. Japanese spellings (`kanji_form`, `reading_form`) come from JMdict and stay untouched.

### 5. HTML tags, entities and Mazii subject labels

- Entities: `&amp;` / `&amp` about 350 times, plus `&nbsp;` and `&times;`.
- Tags: `<br>` 80 times, `<span style="…">…</span>` about 80 times. Some example sentences end with a long `<br style="…">`.
- Mazii subject labels in angle brackets, from its Vietnamese source dictionary: `<TIN>` computing, `<Y>` medicine, `<QSự>` military, `<HóA>` chemistry, `<THựC>` botany, `<PHẫU>` anatomy, `<CHTRị>` politics, `<độNG>` zoology, `<TôN>` religion, `<Mỹ>` American usage, and others. A few hundred in total.
- Rows affected: 320 glosses, 306 summaries, about 20 example fields.

**Fix:** decode entities, treat `<br>` as a gloss separator, and drop other tags. Map the subject labels to JMdict field tags where one exists (`<TIN>` → `comp`, `<Y>` → `med`, ...) or strip them.

### 6. Line breaks and invisible characters

- 128 glosses contain a line break (`\r\n`), which in practice separates two glosses ("không đáng tin cậy\r\nkhông đứng đắn").
- 123 rows contain zero-width characters (mostly U+200B: "ý kiến ​​khác").
- 69 other rows have line breaks, mostly example sentences written as dialogues.

**Fix:** split glosses on line breaks. Remove zero-width and other format characters. In examples, replace line breaks with a space or keep them deliberately for dialogues.

### 7. Vietnamese text not in NFC

Some Mazii text uses decomposed accents (base letter + combining mark), so it won't match a search typed in the usual composed form.

- 1,157 glosses, 942 `summary_vi`, 42 example translations.

**Fix:** compose to NFC. Zig's standard library has no normalization, but Vietnamese needs only Latin composition pairs. Generate a small table (base + combining mark → precomposed letter, plus the marks' combining classes) from Python's `unicodedata` into a Zig file, or use a library such as `zg`. Two `kanji_form` values use CJK compatibility ideographs (兔) that NFC would change; leave Japanese text alone.

### 8. Double or stray spaces

- About 500 glosses and 40 example translations ("chụp  tia X").

**Fix:** collapse runs of whitespace to one space in the cleaning function.

### 9. Duplicate senses, glosses and examples

- 3,695 groups of duplicate senses inside one entry. Most come from #1 and disappear with it. 373 groups are repeated Mazii senses.
- 129 examples repeated inside one sense, 3 glosses repeated inside one sense.

**Fix:** skip a Mazii sense whose gloss list matches one already inserted for the entry, and skip repeated examples and glosses within a sense.

## Low priority

### 10. Contradictory or self-pointing references

- 37 Mazii targets listed as both synonym and antonym of the same entry.
- 3 cross-references whose `target_ent_seq` is their own entry (フィックス, 寄る, 読手).
- 2 sense restrictions naming a spelling the entry doesn't have.

**Fix:** drop all three kinds at insert time.

### 11. Example readings that contain kanji

- 217 Mazii example transcriptions are not fully kana ("其れはわたしのかばんです").

**Fix:** keep them, or store NULL when the reading contains kanji. Low value either way.

## Not fixable from this data

- **24,043 entries have no senses.** They have no row in `raw_word_crawl_json`, so they were never crawled. Recrawling is the only fix.
- **703 English senses have no part of speech.** Jisho sent an empty `parts_of_speech` (お帰りなさい, お早うございます), although JMdict itself has one.
- **Mazii homographs:** 5,420 entries get no Vietnamese because Mazii merges all readings of a shared spelling into one word. This is a deliberate rule, described in `docs/schema.md`.
