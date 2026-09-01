#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const readKeys = language => {
  const file = path.join(root, `${language}.lproj`, 'Localizable.strings');
  const source = fs.readFileSync(file, 'utf8');
  return new Set([...source.matchAll(/^\s*"((?:\\.|[^"])*)"\s*=/gm)].map(match => match[1]));
};
const es = readKeys('es');
const en = readKeys('en');
const missingEnglish = [...es].filter(key => !en.has(key));
const missingSpanish = [...en].filter(key => !es.has(key));
if (missingEnglish.length || missingSpanish.length) {
  throw new Error(`Localization mismatch\nmissing en: ${missingEnglish.join(', ')}\nmissing es: ${missingSpanish.join(', ')}`);
}
process.stdout.write(`localizations verified: ${es.size} keys in es/en\n`);
