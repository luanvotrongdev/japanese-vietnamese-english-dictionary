-- Standardized output schema. Design notes and transform rules: docs/schema.md.
-- Embedded into the binary and run on a fresh output database.

-- Lookup for JMdict entity codes: part of speech, misc, field, dialect.
CREATE TABLE tag (
  code      TEXT PRIMARY KEY,          -- 'n', 'v5r', 'uk', 'comp', 'ksb', ...
  category  TEXT NOT NULL CHECK (category IN ('pos', 'misc', 'field', 'dialect')),
  label_en  TEXT NOT NULL,             -- Jisho label, used for mapping
  label_vi  TEXT
);

-- ---------------------------------------------------------------- words

CREATE TABLE entry (
  ent_seq     INTEGER PRIMARY KEY,     -- JMdict sequence number
  is_common   INTEGER NOT NULL DEFAULT 0 CHECK (is_common IN (0, 1)),
  jlpt        INTEGER CHECK (jlpt BETWEEN 1 AND 5),   -- 'jlpt-n3' -> 3; easiest (largest N) if several
  summary_vi  TEXT,                    -- Mazii short_mean
  mazii_id    INTEGER                  -- Mazii mobileId
);

CREATE TABLE kanji_form (               -- JMdict k_ele
  id        INTEGER PRIMARY KEY,
  ent_seq   INTEGER NOT NULL REFERENCES entry(ent_seq) ON DELETE CASCADE,
  position  INTEGER NOT NULL,
  text      TEXT NOT NULL,
  UNIQUE (ent_seq, position)
);
CREATE INDEX kanji_form_text ON kanji_form(text);

CREATE TABLE reading_form (             -- JMdict r_ele
  id            INTEGER PRIMARY KEY,
  ent_seq       INTEGER NOT NULL REFERENCES entry(ent_seq) ON DELETE CASCADE,
  position      INTEGER NOT NULL,
  text          TEXT NOT NULL,
  no_kanji      INTEGER NOT NULL DEFAULT 0 CHECK (no_kanji IN (0, 1)),
  pitch_accent  TEXT,                  -- Mazii pronunciation.accent, e.g. 'LHHHH-H'
  UNIQUE (ent_seq, position)
);
CREATE INDEX reading_form_text ON reading_form(text);

-- Reading applies only to these kanji forms (JMdict re_restr).
-- No rows for a reading = applies to all. Derived from Jisho japanese[] pairs.
CREATE TABLE reading_restriction (
  reading_id  INTEGER NOT NULL REFERENCES reading_form(id) ON DELETE CASCADE,
  kanji_id    INTEGER NOT NULL REFERENCES kanji_form(id) ON DELETE CASCADE,
  PRIMARY KEY (reading_id, kanji_id)
);

CREATE TABLE sense (
  id        INTEGER PRIMARY KEY,
  ent_seq   INTEGER NOT NULL REFERENCES entry(ent_seq) ON DELETE CASCADE,
  source    TEXT NOT NULL CHECK (source IN ('jmdict', 'wikipedia', 'mazii')),
  lang      TEXT NOT NULL CHECK (lang IN ('en', 'vi')),
  position  INTEGER NOT NULL,          -- order within (ent_seq, source)
  info      TEXT,                      -- Jisho info[] joined, e.g. 'oft. vocative'
  UNIQUE (ent_seq, source, position)
);

CREATE TABLE gloss (
  sense_id  INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  position  INTEGER NOT NULL,
  text      TEXT NOT NULL,
  PRIMARY KEY (sense_id, position)
);

CREATE TABLE sense_tag (
  sense_id  INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  tag_code  TEXT NOT NULL REFERENCES tag(code),
  PRIMARY KEY (sense_id, tag_code)
);

-- Sense applies only to these forms (JMdict stagk / stagr). No rows = all.
CREATE TABLE sense_restriction (
  sense_id   INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  form_text  TEXT NOT NULL,
  PRIMARY KEY (sense_id, form_text)
);

-- Cross-references from Jisho see_also[] and antonyms[].
CREATE TABLE sense_xref (
  sense_id        INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  type            TEXT NOT NULL CHECK (type IN ('see_also', 'antonym')),
  target_text     TEXT NOT NULL,
  target_ent_seq  INTEGER REFERENCES entry(ent_seq),   -- set only when unambiguous
  PRIMARY KEY (sense_id, type, target_text)
);

-- Loanword origin (JMdict lsource), from Jisho source[].
CREATE TABLE sense_origin (
  sense_id  INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  position  INTEGER NOT NULL,
  language  TEXT NOT NULL,             -- ISO 639-2: 'Portuguese' -> 'por'
  word      TEXT,                      -- curly quotes stripped
  PRIMARY KEY (sense_id, position)
);

-- Example sentences, from Mazii means[].examples.
CREATE TABLE example (
  id           INTEGER PRIMARY KEY,
  sense_id     INTEGER NOT NULL REFERENCES sense(id) ON DELETE CASCADE,
  position     INTEGER NOT NULL,
  ja           TEXT NOT NULL,          -- content
  reading      TEXT,                   -- transcription
  translation  TEXT NOT NULL,          -- mean
  lang         TEXT NOT NULL CHECK (lang IN ('en', 'vi'))
);

-- Word-level synonyms / antonyms, from Mazii synsets and opposite_word.
CREATE TABLE entry_relation (
  ent_seq         INTEGER NOT NULL REFERENCES entry(ent_seq) ON DELETE CASCADE,
  type            TEXT NOT NULL CHECK (type IN ('synonym', 'antonym')),
  target_text     TEXT NOT NULL,
  target_ent_seq  INTEGER REFERENCES entry(ent_seq),
  PRIMARY KEY (ent_seq, type, target_text)
);

-- ---------------------------------------------------------------- kanji

CREATE TABLE radical (
  symbol      TEXT PRIMARY KEY,
  meaning_en  TEXT
);

CREATE TABLE kanji (
  literal       TEXT PRIMARY KEY,      -- the character
  stroke_count  INTEGER,
  grade         INTEGER,               -- 'grade 4' -> 4, 'junior high' -> 8 (KANJIDIC style)
  jlpt          INTEGER CHECK (jlpt BETWEEN 1 AND 5),
  freq_rank     INTEGER,               -- Jisho newspaperFrequencyRank
  han_viet      TEXT,                  -- Mazii mean, e.g. 'THUẬN'
  radical       TEXT REFERENCES radical(symbol),
  mnemonic_vi   TEXT,                  -- Mazii tips.vi
  mazii_id      INTEGER
);

CREATE TABLE kanji_reading (
  literal   TEXT NOT NULL REFERENCES kanji(literal) ON DELETE CASCADE,
  type      TEXT NOT NULL CHECK (type IN ('on', 'kun')),
  position  INTEGER NOT NULL,
  text      TEXT NOT NULL,             -- KANJIDIC style: on in katakana, kun in hiragana, 'ひび.く'
  PRIMARY KEY (literal, type, position)
);

CREATE TABLE kanji_meaning (
  literal   TEXT NOT NULL REFERENCES kanji(literal) ON DELETE CASCADE,
  lang      TEXT NOT NULL CHECK (lang IN ('en', 'vi')),
  position  INTEGER NOT NULL,
  text      TEXT NOT NULL,             -- en: Jisho meaning split on ', '; vi: Mazii detail split on '##'
  PRIMARY KEY (literal, lang, position)
);

-- Visual parts (Jisho parts[]) plus Hán Việt names where Mazii compDetail has them.
CREATE TABLE kanji_component (
  literal    TEXT NOT NULL REFERENCES kanji(literal) ON DELETE CASCADE,
  position   INTEGER NOT NULL,
  component  TEXT NOT NULL,
  han_viet   TEXT,
  PRIMARY KEY (literal, position)
);

-- Example words: Jisho on/kunyomiExamples (en) and Mazii examples / example_on / example_kun (vi).
CREATE TABLE kanji_example (
  id            INTEGER PRIMARY KEY,
  literal       TEXT NOT NULL REFERENCES kanji(literal) ON DELETE CASCADE,
  reading_type  TEXT CHECK (reading_type IN ('on', 'kun')),
  word          TEXT NOT NULL,
  reading       TEXT,
  meaning       TEXT NOT NULL,
  han_viet      TEXT,
  lang          TEXT NOT NULL CHECK (lang IN ('en', 'vi')),
  ent_seq       INTEGER REFERENCES entry(ent_seq)       -- linked when word+reading match one entry
);
CREATE INDEX kanji_example_literal ON kanji_example(literal);
