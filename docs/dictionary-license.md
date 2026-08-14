# Dictionary provenance

`Sources/WillagramsRules/Resources/dictionary.txt`

| | |
|---|---|
| List | ENABLE (Enhanced North American Benchmark Lexicon), `enable1.txt` |
| Words | 172,823 |
| Source | https://raw.githubusercontent.com/dolph/dictionary/master/enable1.txt |
| Retrieved | 2026-08-14 |
| License | **Public domain** |
| Author | Alan Beale, released to the public domain |

## Normalization applied

Lowercased, CRs stripped, filtered to `^[a-z]{2,}$`, sorted, deduplicated.
Zero entries were dropped by the filter — the upstream list was already clean.
Single letters are excluded because a board word is a run of two or more tiles.

## Why not the Scrabble lists

TWL06/TWL2014 (North America) and SOWPODS/Collins (international) are the
tournament lists, and they are **not shippable**. They are proprietary to
Hasbro and Merriam-Webster in North America and to Collins internationally.
Bundling either would be exactly the infringement this project is built to
avoid.

ENABLE is public domain, was compiled for word-game use, and contains no proper
nouns. It is the list behind Words with Friends and most open word games, and
overlaps the tournament lists closely enough that competitive players will not
notice the difference.

## Replacing it

Any list can be dropped in, provided it stays one lowercase word per line
matching `^[a-z]{2,}$`. Update this file's word count, source, and license in
the same commit — `EnableWordList` asserts nothing about provenance, so this
document is the only record.
