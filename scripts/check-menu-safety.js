#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(path.join(__dirname, '..', 'CodexSwitchboard.swift'), 'utf8');
const menuStart = source.indexOf('struct CodexSwitchboardApp: App');
const settingsStart = source.indexOf('struct SettingsView: View', menuStart);
if (menuStart < 0 || settingsStart < 0) throw new Error('Could not locate the menu-bar scene');
const menuSource = source.slice(menuStart, settingsStart);
if (/TimelineView\s*\(/.test(menuSource) || /Timer\.publish/.test(menuSource)) {
  throw new Error('Continuously invalidating views are forbidden inside MenuBarExtra');
}
process.stdout.write('menu-bar safety verified\n');
