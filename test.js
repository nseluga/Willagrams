import assert from 'node:assert';
import { WORDS, scramble, isCorrect } from './game.js';

const sorted = (s) => [...s].sort().join('');

for (const w of WORDS) {
  const s = scramble(w);
  assert.strictEqual(sorted(s), sorted(w), `${w}: letters changed`);
  assert.notStrictEqual(s, w, `${w}: not scrambled`);
}

// Words that can't be scrambled are returned as-is instead of looping forever.
assert.strictEqual(scramble('a'), 'a');
assert.strictEqual(scramble('aaa'), 'aaa');

assert.ok(isCorrect('  Listen ', 'listen'));
assert.ok(!isCorrect('silent', 'listen'));

console.log('ok');
