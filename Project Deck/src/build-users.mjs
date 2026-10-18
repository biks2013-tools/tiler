// Build tiler-users.html: screenshots → data URIs, then the nbg-design pipeline.
// Usage: node src/build-users.mjs   (from "Project Deck")
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const SKILL = process.env.NBG_DESIGN_SCRIPTS
  ?? '/Users/giorgosmarinos/.claude/plugins/cache/nbg-design/nbg-design/1.26.0/skills/nbg-design/scripts';
const shots = { SHOT_MENU: 'menu', SHOT_OVERLAY: 'shortcuts-overlay', SHOT_GENERAL: 'settings-general',
  SHOT_LAYOUT: 'settings-layout', SHOT_SHORTCUTS: 'settings-shortcuts', SHOT_APPS: 'settings-apps', SHOT_MOVE: 'move-resize-hud', SHOT_FOCUS: 'settings-focus' };
let html = readFileSync('src/tiler-users.src.html', 'utf8');
for (const [tok, name] of Object.entries(shots)) {
  const uri = 'data:image/png;base64,' + readFileSync(`screenshots/${name}.png`).toString('base64');
  html = html.split(`{{${tok}}}`).join(uri);
}
writeFileSync('tiler-users.html', html);
const run = (s, ...a) => execFileSync('node', [`${SKILL}/${s}`, ...a], { stdio: 'inherit' });
run('embed-assets.mjs', 'tiler-users.html', '--theme', 'biks2013');
run('add-deck-menu.mjs', 'tiler-users.html', '--theme', 'biks2013');
run('verify-deck.mjs', 'tiler-users.html', '--strict');
