# Willagrams

Anagram word game. Unscramble the word, get a point, next word.

## Run

```
python3 -m http.server 8000   # any static server; ES modules need http, not file://
open http://localhost:8000
```

## Test

```
npm test
```

## Files

- `index.html` — the whole UI
- `game.js` — word list, scramble, guess check
- `test.js` — self-check
