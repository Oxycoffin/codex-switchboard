#!/usr/bin/env node

const fs = require('fs');

const manager = fs.readFileSync('CodexSwitchboard.swift', 'utf8');
const pulse = fs.readFileSync('Pulse.swift', 'utf8');

const checks = [
  [manager.includes('@Published var automaticRotation = false'), 'automatic switching must default to off'],
  [manager.includes('@Published var windowPrimingEnabled = false'), 'window preparation must default to off'],
  [manager.includes('automaticRotation = state.automaticRotation ?? false'), 'missing automatic-switch state must decode as off'],
  [manager.includes('windowPrimingEnabled = state.windowPrimingEnabled ?? false'), 'missing window-preparation state must decode as off'],
  [pulse.includes('state.windowPrimingEnabled ?? false else { return }'), 'the background helper must require explicit window-preparation opt-in'],
];

const failures = checks.filter(([passed]) => !passed).map(([, message]) => message);
if (failures.length) {
  console.error(`automation opt-in check failed:\n- ${failures.join('\n- ')}`);
  process.exit(1);
}

console.log('automation opt-in defaults verified');
