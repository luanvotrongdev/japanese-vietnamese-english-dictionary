"""Data-quality scan for the transformed database.

Usage: python -I tools/scan.py javi.sqlite

Prints one line per check with its hit count and a few examples. Checks with
no hits are skipped unless --all is passed. docs/known-issues.md explains the
open findings.
"""

import re
import sqlite3
import sys
import unicodedata
from collections import Counter

sys.stdout.reconfigure(encoding='utf-8')

args = [a for a in sys.argv[1:] if not a.startswith('--')]
if len(args) != 1:
    sys.exit(__doc__)
SHOW_ALL = '--all' in sys.argv
db = sqlite3.connect(f'file:{args[0]}?mode=ro', uri=True)


def rows(sql, *params):
    return db.execute(sql, params).fetchall()


def report(name, hits, n_examples=5):
    if not hits and not SHOW_ALL:
        return
    print(f'\n## {name}: {len(hits)}')
    for hit in hits[:n_examples]:
        print('   ', hit)


def check(name, sql, n_examples=5):
    report(name, rows(sql), n_examples)


def text_check(name, table, col, pred, where='1', n_examples=3):
    hits = [(rowid, text) for rowid, text in rows(f'SELECT rowid, {col} FROM {table} WHERE {where}')
            if text is not None and pred(text)]
    report(name, hits, n_examples)


# ---------------------------------------------------------------- predicates

def extra_whitespace(s):
    return s != s.strip() or '  ' in s


def control_chars(s):
    return any(unicodedata.category(ch) in ('Cc', 'Cf') for ch in s)


def not_nfc(s):
    return not unicodedata.is_normalized('NFC', s)


def markup(s):
    return bool(re.search(r'<[^>]{1,60}>|&[a-z]+;?|&#\d+;', s))


ENGLISH_WORDS = set(
    'the of a an to in for with is are be by as at on from that this it its or and not '
    'you i me my your he she we they what how which who very something someone'.split())


def looks_english(s):
    """ASCII text with an English function word, a letter Vietnamese lacks
    (f, j, w, z), or a Latin species name."""
    if re.search(r'[^\x00-\x7f]', s):
        return False
    words = re.findall(r'[a-z]+', s.lower())
    return bool(words) and (
        any(w in ENGLISH_WORDS for w in words)
        or bool(re.search(r'[fjwz]', s.lower()))
        or bool(re.search(r'\([A-Z][a-z]+ [a-z]+\)', s)))


# ---------------------------------------------------------------- coverage

print('entries:', rows('SELECT count(*) FROM entry')[0][0])
check('entries with no senses (never crawled)',
      'SELECT ent_seq FROM entry e WHERE NOT EXISTS (SELECT 1 FROM sense s WHERE s.ent_seq = e.ent_seq)', 3)
check('senses with no glosses',
      'SELECT id, ent_seq, source FROM sense s WHERE NOT EXISTS (SELECT 1 FROM gloss g WHERE g.sense_id = s.id)')

name_codes = "('place','organization','company','product','serv','ev','char','person','surname','given'," \
             "'work','fict','leg','myth','dei','creat','relig','doc','obj','group','ship','station','oth','unclass')"
check('jmdict senses tagged with a name type (JMnedict senses)',
      f"SELECT s.id, s.ent_seq, t.tag_code FROM sense s JOIN sense_tag t ON t.sense_id = s.id "
      f"WHERE s.source = 'jmdict' AND t.tag_code IN {name_codes}", 3)
check('jmdict senses with no part of speech and no name tag',
      f"SELECT s.id, s.ent_seq FROM sense s WHERE s.source = 'jmdict' AND NOT EXISTS "
      f"(SELECT 1 FROM sense_tag t JOIN tag ON tag.code = t.tag_code WHERE t.sense_id = s.id "
      f"AND (tag.category = 'pos' OR t.tag_code IN {name_codes}))", 3)

# ---------------------------------------------------------------- text hygiene

for table, col in [('gloss', 'text'), ('entry', 'summary_vi'), ('example', 'ja'),
                   ('example', 'reading'), ('example', 'translation')]:
    text_check(f'{table}.{col}: extra whitespace', table, col, extra_whitespace)
    text_check(f'{table}.{col}: line breaks / invisible chars', table, col, control_chars)
    text_check(f'{table}.{col}: not NFC', table, col, not_nfc)
    text_check(f'{table}.{col}: HTML or markup', table, col, markup)
text_check('kanji_form.text: not NFC (compatibility ideographs; leave as is)', 'kanji_form', 'text', not_nfc)

counts = Counter()
for (text,) in rows('SELECT text FROM gloss UNION ALL SELECT summary_vi FROM entry WHERE summary_vi IS NOT NULL'):
    for m in re.findall(r'<[^>]{1,60}>|&[a-z]+;?|&#\d+;', text):
        counts[re.sub(r'\s+', ' ', m)] += 1
if counts:
    print('\n## markup tokens in glosses and summaries (top 15):')
    print('   ', counts.most_common(15))

check('glosses split from an HTML entity ("&amp", "nbsp")',
      "SELECT sense_id, text FROM gloss WHERE text IN ('&amp', '&nbsp', 'nbsp', '&amp;nbsp')")

# ---------------------------------------------------------------- language

vi_gloss_where = "g.sense_id IN (SELECT id FROM sense WHERE lang = 'vi')"
text_check('Vietnamese glosses that look English', 'gloss g', 'g.text', looks_english, vi_gloss_where, 8)
text_check('summary_vi that looks English', 'entry', 'summary_vi', looks_english, n_examples=5)
text_check('example readings containing kanji', 'example', 'reading',
           lambda s: bool(re.search(r'[一-鿿]', s)))

# ---------------------------------------------------------------- duplicates

GLOSS_LIST = "(SELECT group_concat(text, '|') FROM (SELECT text FROM gloss g WHERE g.sense_id = s.id ORDER BY position))"
check('duplicate glosses inside one sense',
      'SELECT sense_id, text, count(*) FROM gloss GROUP BY sense_id, text HAVING count(*) > 1')
check('duplicate senses inside one entry (same source and glosses)',
      f'SELECT ent_seq, source, gl, count(*) FROM (SELECT s.ent_seq, s.source, {GLOSS_LIST} gl FROM sense s) '
      f'GROUP BY ent_seq, source, gl HAVING count(*) > 1')
check('duplicate examples inside one sense',
      'SELECT sense_id, ja, count(*) FROM example GROUP BY sense_id, ja HAVING count(*) > 1')

forms = {}
for ent_seq, text in rows('SELECT ent_seq, text FROM kanji_form UNION ALL SELECT ent_seq, text FROM reading_form'):
    forms.setdefault(ent_seq, set()).add(text)
english = dict(rows("SELECT s.ent_seq, group_concat(g.text, '|') FROM sense s JOIN gloss g ON g.sense_id = s.id "
                    "WHERE s.source = 'jmdict' GROUP BY s.ent_seq"))
by_forms = {}
for ent_seq, fs in forms.items():
    by_forms.setdefault(frozenset(fs), []).append(ent_seq)
shared = []
for group in by_forms.values():
    glosses = [english[e] for e in group if e in english]
    if len(group) > 1 and len(set(glosses)) < len(glosses):
        shared.append((sorted(group), sorted(forms[group[0]])[:3]))
report('entries with identical spellings that got the same Jisho result', shared)

# ---------------------------------------------------------------- references

check('cross-references pointing to their own entry',
      'SELECT x.sense_id, s.ent_seq, x.target_text FROM sense_xref x JOIN sense s ON s.id = x.sense_id '
      'WHERE x.target_ent_seq = s.ent_seq')
check('relations pointing to their own entry',
      'SELECT ent_seq, type, target_text FROM entry_relation WHERE target_ent_seq = ent_seq')
check('targets listed as both synonym and antonym',
      "SELECT a.ent_seq, a.target_text FROM entry_relation a JOIN entry_relation b "
      "ON b.ent_seq = a.ent_seq AND b.target_text = a.target_text WHERE a.type = 'synonym' AND b.type = 'antonym'")
check('sense restrictions naming a form the entry lacks',
      'SELECT r.sense_id, s.ent_seq, r.form_text FROM sense_restriction r JOIN sense s ON s.id = r.sense_id '
      'WHERE NOT EXISTS (SELECT 1 FROM kanji_form k WHERE k.ent_seq = s.ent_seq AND k.text = r.form_text) '
      'AND NOT EXISTS (SELECT 1 FROM reading_form f WHERE f.ent_seq = s.ent_seq AND f.text = r.form_text)')
check('pitch accents with an unexpected format',
      "SELECT ent_seq, text, pitch_accent FROM reading_form WHERE pitch_accent IS NOT NULL "
      "AND (pitch_accent GLOB '*[^LH-]*' OR pitch_accent LIKE '%-%-%')")

# ---------------------------------------------------------------- integrity

check('foreign key violations', 'PRAGMA foreign_key_check')
integrity = rows('PRAGMA integrity_check')
if integrity != [('ok',)]:
    report('integrity_check problems', integrity)
