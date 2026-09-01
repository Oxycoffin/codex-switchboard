#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const swift = fs.readFileSync(path.join(root, 'CodexSwitchboard.swift'), 'utf8');
const catalog = fs.readFileSync(path.join(root, 'es.lproj', 'Localizable.strings'), 'utf8');
const keys = new Set([...catalog.matchAll(/^\s*"((?:\\.|[^"])*)"\s*=/gm)].map(match => match[1]));
const patterns = [
  /\b(?:Text|Label|Button|Toggle|Section|Menu|Picker)\(\s*"((?:\\.|[^"])*)"/g,
  /\.help\(\s*"((?:\\.|[^"])*)"/g,
  /\.alert\(\s*"((?:\\.|[^"])*)"/g,
];
const missing = new Set();
for (const pattern of patterns) {
  for (const match of swift.matchAll(pattern)) {
    const key = match[1];
    if (key && !key.includes('\\(') && !keys.has(key)) missing.add(key);
  }
}
if (missing.size) throw new Error(`Unlocalized visible strings:\n${[...missing].sort().join('\n')}`);
process.stdout.write('visible strings verified\n');
