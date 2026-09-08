#!/usr/bin/env node
// Stop-hook notifier.
//
// Multiple Claude sessions commonly run as TABS in one Windows Terminal window.
// Tabs are not OS windows: there is one taskbar button and one window handle for
// all of them, and WT exposes no API to flash or focus a specific tab from
// outside. So a taskbar flash cannot point at the tab that finished, and the
// audio alone can't say WHICH session it was. The design therefore splits by
// what each channel can actually convey:
//   - AUDIO (wav + TTS) is DEBOUNCED machine-wide via a lock file (at most one
//     per CLAUDE_NOTIFY_DEBOUNCE_SECS, default 30) so N sessions finishing
//     together don't echo. First stopper wins; the rest stay silent.
//   - The TOAST fires PER SESSION and NAMES the session that finished (its
//     terminal tab title, with a "<project> · <session-id>" fallback). It is
//     silent (audio is handled above) and stacks in the notification center, so
//     you can see exactly which tabs are done. This is the real discriminator.
//   - The taskbar FLASH fires per session too — a coarse "something in this
//     window finished" cue; it no-ops when the window is already foreground.
//   - Re-fires (stop_hook_active in the hook payload) are skipped entirely.
//
// NOTE: the hook must WAIT for its child — the harness closes the hook's job
// object on exit and kills any fire-and-forget child (verified 2026-09-08:
// detached/unref'd children never ran).

const { spawn } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

const audioFile = path.join(__dirname, 'task-complete.wav');
const ps1File = path.join(__dirname, 'task-complete.ps1');
const lockFile = path.join(os.tmpdir(), 'claude-task-complete.lock');
const traceFile = path.join(os.tmpdir(), 'claude-notify-trace.log');
const DEBOUNCE_SECS = Number(process.env.CLAUDE_NOTIFY_DEBOUNCE_SECS || 30);

// End-to-end trace: one line per Stop, tagged with the short session id so it
// correlates with the ps1's flash/toast line (also tagged). Append-only, capped
// so it can be tail'd live without growing unbounded. Never throws.
function trace(fields) {
  try {
    try {
      if (fs.statSync(traceFile).size > 512 * 1024) fs.truncateSync(traceFile, 0);
    } catch {}
    const parts = Object.entries(fields).map(([k, v]) => `${k}=${v}`);
    fs.appendFileSync(traceFile, `${new Date().toISOString()} ${parts.join(' ')}\n`);
  } catch {}
}

// Detect project name from the closest CLAUDE.md or package.json
function getProjectName(cwd) {
  let dir = cwd || process.cwd();
  for (let i = 0; i < 10; i++) {
    const pkgPath = path.join(dir, 'package.json');
    if (fs.existsSync(pkgPath)) {
      try {
        const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
        if (pkg.name) return pkg.name;
      } catch {}
    }
    if (fs.existsSync(path.join(dir, 'CLAUDE.md'))) return path.basename(dir);
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return path.basename(cwd || process.cwd());
}

// The human name of the session = the "ai-title" claude generates (the terminal
// tab title). It is NOT reachable via the console — the hook runs detached from
// the tab's ConPTY — but it IS written to the session transcript, which the
// payload hands us the path to.
//
// A resumed/forked session's transcript can carry ai-title entries from OTHER
// session ids, so we do NOT blindly take the last one: we prefer the last
// ai-title whose sessionId matches THIS stop's session_id (when the entries
// carry one), and only fall back to the last ai-title overall when none match
// (older transcripts had no sessionId on the entry). Same for last-prompt.
// Guards against naming a stop after a foreign/stale session.
function readSessionTitle(transcriptPath, sessionId) {
  if (!transcriptPath) return '';
  let title = '', prompt = '';        // last overall (fallback)
  let ownTitle = '', ownPrompt = '';  // last whose sessionId matches
  try {
    for (const line of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
      // cheap prefilter before JSON.parse on a possibly-large transcript
      if (line.indexOf('"ai-title"') === -1 && line.indexOf('"last-prompt"') === -1) continue;
      try {
        const o = JSON.parse(line);
        const mine = !o.sessionId || !sessionId || o.sessionId === sessionId;
        if (o.type === 'ai-title' && o.aiTitle) {
          title = o.aiTitle;
          if (mine) ownTitle = o.aiTitle;
        } else if (o.type === 'last-prompt' && o.lastPrompt) {
          prompt = o.lastPrompt;
          if (mine) ownPrompt = o.lastPrompt;
        }
      } catch {}
    }
  } catch {}
  const t = (ownTitle || title).trim();
  if (t) return t;
  const p = (ownPrompt || prompt).trim();
  if (p) return p.replace(/\s+/g, ' ').slice(0, 60);
  return '';
}

// Always-available fallback when there is no transcript title yet: project name
// plus a short session-id so two sessions sharing a cwd stay distinguishable.
function sessionLabel(payload, projectName) {
  const sid = String(payload.session_id || '').replace(/[^0-9a-fA-F-]/g, '').slice(0, 6);
  return sid ? `${projectName} · ${sid}` : projectName;
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Machine-wide debounce for AUDIO only. Returns true if THIS invocation owns the
// audible slot. Write-then-verify (jittered settle) closes the race where
// several sessions stop within the same few milliseconds — the echo case.
function claimAudibleSlot() {
  try {
    const st = fs.statSync(lockFile);
    if ((Date.now() - st.mtimeMs) / 1000 < DEBOUNCE_SECS) return false;
  } catch {}
  const token = `${process.pid}:${Date.now()}:${Math.random()}`;
  try {
    fs.writeFileSync(lockFile, token);
    sleepMs(150 + Math.floor(Math.random() * 150));
    return fs.readFileSync(lockFile, 'utf-8') === token;
  } catch {
    return true; // temp dir misbehaving — better one extra chime than none
  }
}

// Spawn and let the process live until the child exits (see NOTE above).
function run(cmd, args, opts = {}) {
  try {
    spawn(cmd, args, { stdio: 'ignore', ...opts });
  } catch {}
}

// Pure resolution of what a stop should be labelled (no side effects) — the unit
// under test. Exported for task-complete.test.sh.
function resolveLabel(payload) {
  const projectName = getProjectName(payload.cwd || process.cwd());
  const title = readSessionTitle(payload.transcript_path, payload.session_id);
  return {
    projectName,
    label: title || sessionLabel(payload, projectName),
    src: title ? 'transcript' : (payload.transcript_path ? 'fallback-notitle' : 'fallback-nopath'),
  };
}

// The Stop hook means a turn FINISHED; the Notification hook means a session is
// WAITING on you (permission / idle input). Same session-identification, only
// the wording differs. Pure + exported for the test suite.
function resolveKind(payload, projectName) {
  const input = payload.hook_event_name === 'Notification';
  return {
    kind: input ? 'input' : 'done',
    headline: input ? 'Claude Code - needs your input' : 'Claude Code - task complete',
    speech: input ? `${projectName} needs you` : `for ${projectName}`,
  };
}

function notifyComplete(payload) {
  const platform = os.platform();
  const { projectName, label, src } = resolveLabel(payload);
  const { kind, headline, speech } = resolveKind(payload, projectName);
  const sid = String(payload.session_id || '').replace(/[^0-9a-fA-F-]/g, '').slice(0, 6) || 'none';

  // Dry run: print the resolved decision and do nothing else (for tests).
  if (process.env.CLAUDE_NOTIFY_DRYRUN) {
    process.stdout.write(JSON.stringify({ sid, project: projectName, label, src, kind, headline, speech }) + '\n');
    return;
  }

  // Opt-out for the waiting-on-you notifications (they fire on every permission
  // prompt, which is fine for some and noisy for others).
  if (kind === 'input' && process.env.CLAUDE_NOTIFY_NO_INPUT === '1') return;

  const audible = claimAudibleSlot(); // gates AUDIO only
  trace({
    ev: kind === 'input' ? 'input' : 'stop', sid, pid: process.pid, platform,
    proj: projectName, src, audible,
    label: `'${label}'`,
  });

  if (platform === 'win32') {
    // Toast + flash always (per session); sound only for the debounce winner.
    const args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1File,
      '-Project', projectName, '-Label', label, '-AudioFile', audioFile, '-Sid', sid,
      '-Headline', headline, '-Speech', speech,
    ];
    if (!audible) args.push('-NoSound');
    run('powershell.exe', args, { windowsHide: true });
  } else if (platform === 'linux') {
    // Notification per session (names the session); audio for the winner only.
    run('/bin/bash', [
      path.join(__dirname, 'task-complete.sh'),
      projectName, audioFile, label, audible ? '1' : '0', headline, speech,
    ]);
  } else if (audible && platform === 'darwin') {
    run('/bin/sh', ['-c',
      `say -v Alex "${speech}"; afplay "${audioFile}" 2>/dev/null || true`]);
  }
}

let notified = false;
function notifyOnce(payload) {
  if (notified) return;
  notified = true;
  notifyComplete(payload || {});
}

function main() {
  let raw = '';
  process.stdin.on('data', (d) => { raw += d; });
  process.stdin.on('end', () => {
    let payload = {};
    try {
      payload = JSON.parse(raw);
      if (payload.stop_hook_active) { notified = true; return; }
    } catch {}
    notifyOnce(payload);
  });
  // A hook always gets stdin, but never hang if something invokes us bare.
  setTimeout(() => notifyOnce({}), 1000).unref();
}

if (require.main === module) {
  main();
} else {
  module.exports = { readSessionTitle, sessionLabel, getProjectName, resolveLabel, resolveKind };
}
