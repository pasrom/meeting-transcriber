// Real-meeting audio source for the browser-detection e2e (issue #503): joins a
// real Jitsi room with TWO tabs in one Chrome so it is a genuine 2-participant
// meeting over a real WebRTC SFU (not the in-page pc1<->pc2 fixture). Each tab's
// getUserMedia is overridden to a 440 Hz WebAudio-oscillator stream, so:
//   - no real microphone is touched (sidesteps the macOS Chrome mic-TCC gate
//     that hangs getUserMedia on a headless runner), and
//   - each tab sends the tone to the SFU, which relays it to the other tab,
//     which plays it out -> Chrome's output carries real server-transported
//     meeting audio for the app's CATap to capture.
// Chrome must already be running with --remote-debugging-port; this connects via
// CDP (puppeteer-core), joins, unmutes, prints readiness, and keeps the tabs in
// the meeting for --keep seconds, then exits (the driver quits Chrome to end it).
//
// Usage: node jitsi-keeper.mjs --host meet.ffmuc.net --room <name> --keep 90 --port 9222
import puppeteer from "puppeteer-core";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

const HOST = arg("host", "meet.ffmuc.net");
const ROOM = arg("room", "MtE2eRoom");
const KEEP = parseInt(arg("keep", "90"), 10);
const PORT = arg("port", "9222");

const OVERRIDE = () => {
  const AC = window.AudioContext || window.webkitAudioContext;
  navigator.mediaDevices.getUserMedia = async () => {
    const ctx = new AC();
    const osc = ctx.createOscillator();
    osc.frequency.value = 440;
    const gain = ctx.createGain();
    gain.gain.value = 0.3;
    const dst = ctx.createMediaStreamDestination();
    osc.connect(gain).connect(dst);
    osc.start();
    window.__toneCtx = ctx; // keep alive
    return dst.stream;
  };
};

const browser = await puppeteer.connect({ browserURL: `http://127.0.0.1:${PORT}`, defaultViewport: null });

async function joinTab(name) {
  const page = await browser.newPage();
  await page.evaluateOnNewDocument(OVERRIDE);
  const url = `https://${HOST}/${ROOM}`
    + "#config.prejoinConfig.enabled=false"
    + "&config.startWithVideoMuted=true"
    + `&userInfo.displayName=%22${name}%22`;
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 }).catch((e) => console.log(name, "goto", e.message));
  return page;
}

const a = await joinTab("e2e-a");
await new Promise((r) => setTimeout(r, 5000));
const b = await joinTab("e2e-b");
await new Promise((r) => setTimeout(r, 9000));

// Unmute both so the tone is actually transmitted (Jitsi may start muted).
for (let k = 0; k < 3; k++) {
  for (const p of [a, b]) {
    await p.evaluate(() => { try { if (window.APP?.conference?.isLocalAudioMuted?.()) window.APP.conference.muteAudio(false); } catch (e) {} }).catch(() => {});
  }
  await new Promise((r) => setTimeout(r, 1500));
}

const status = await a.evaluate(() => {
  try { return { members: window.APP?.conference?.membersCount, muted: window.APP?.conference?.isLocalAudioMuted?.() }; } catch (e) { return { err: String(e).slice(0, 60) }; }
});
console.log("KEEPER_JOINED " + JSON.stringify(status));

await new Promise((r) => setTimeout(r, KEEP * 1000));
await browser.disconnect();
console.log("KEEPER_DONE");
