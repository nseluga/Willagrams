export const WORDS = [
  'willow', 'garden', 'anagram', 'puzzle', 'letter', 'shuffle',
  'orange', 'silent', 'listen', 'planet', 'rocket', 'candle',
];

// Fisher-Yates, retried so the scramble never equals the original.
export function scramble(word, rand = Math.random) {
  if (word.length < 2 || new Set(word).size === 1) return word;
  let out;
  do {
    const a = [...word];
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    out = a.join('');
  } while (out === word);
  return out;
}

export const isCorrect = (guess, word) =>
  guess.trim().toLowerCase() === word.toLowerCase();
