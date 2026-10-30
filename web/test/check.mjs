// Checks the computer version's decoder, trail importer and route finder. Run: node web/test/check.mjs
// Uses the same test vectors as Packages/APRSCore/Tests and Tests/TrailImportCheck.
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { TNC2, AX25, KISS, KISSDecoder, RadioStreamDecoder, parseAPRS, packet, latin1 } from "../js/aprs.js";
import { importTrailFile, trailSystem, trailDifficulty } from "../js/trails.js";
import { TrailGraph, waysFromTrails, search } from "../js/nav.js";

let failed = 0;
const expect = (ok, msg) => { if (!ok) { failed++; console.log("FAIL: " + msg); } };
const near = (a, b, tol, msg) => expect(a != null && Math.abs(a - b) <= tol, `${msg}: ${a} vs ${b}`);

// ---- APRS ----
{
  const r = parseAPRS(TNC2.decode("N0CALL>APRS,WIDE1-1:!4903.50N/07201.75W-Test 001234"));
  expect(r.station === "N0CALL", "station");
  near(r.lat, 49.058333, 1e-5, "plain lat"); near(r.lon, -72.029167, 1e-5, "plain lon");
  expect(r.symbolCode === "-" && r.comment === "Test 001234", "symbol/comment");
}
{
  const p = parseAPRS(TNC2.decode("KD8ABC-7>APRS:@092345z3741.20N/08159.40Wj088/036/A=001500 on the trail"));
  near(p.lat, 37.686667, 1e-5, "ts lat"); near(p.lon, -81.99, 1e-5, "ts lon");
  expect(p.course === 88 && p.speedKnots === 36 && p.altitudeFeet === 1500 && p.comment === "on the trail", "course/speed/alt/comment " + JSON.stringify(p));
}
{
  const p = parseAPRS(packet("N0CALL", "APRS", [], "=/5L!!<*e7>7P["));
  near(p.lat, 49.5, 1e-4, "compressed lat"); near(p.lon, -72.75, 1e-4, "compressed lon");
  expect(p.course === 88, "compressed course"); near(p.speedKnots, 36.2, 0.1, "compressed speed");
}
{
  const p = parseAPRS(packet("N0CALL", "S32UVT", [], "`(_fn\"Oj/"));
  near(p.lat, 33 + 25.64 / 60, 1e-5, "mic-e lat"); near(p.lon, -(112 + 7.74 / 60), 1e-5, "mic-e lon");
  expect(p.speedKnots === 20 && p.course === 251 && p.symbolCode === "j" && p.symbolTable === "/", "mic-e speed/course/symbol " + JSON.stringify(p));
}
{
  const r = parseAPRS(packet("N0CALL", "APRS", [], ";CAMP     *092345z3741.20N/08159.40W;Base camp"));
  expect(r.station === "CAMP" && r.isObject && r.comment === "Base camp", "object");
}
{
  const p = parseAPRS(packet("N0CALL", "GPS", [], "$GPRMC,123519,A,3741.200,N,08159.400,W,022.4,084.4,230394,003.1,W*6A"));
  near(p.lat, 37.686667, 1e-5, "nmea lat"); near(p.lon, -81.99, 1e-5, "nmea lon"); expect(p.course === 84, "nmea course");
}
expect(parseAPRS(packet("IGATE", "APRS", [], "}N0CALL>APRS,TCPIP:!3741.20N/08159.40W>")).station === "N0CALL", "third party");
expect(parseAPRS(packet("N0CALL", "APRS", [], ">Just a status")) === null, "status is not a position");
{
  const p = packet("KD8ABC-7", "APRS", ["WIDE1-1*", "WIDE2-1"], "!3741.20N/08159.40Wj");
  const d = AX25.decode(AX25.encode(p));
  expect(d && d.source === "KD8ABC-7" && d.destination === "APRS" && d.path.join() === "WIDE1-1*,WIDE2-1" && latin1.string(d.info) === "!3741.20N/08159.40Wj", "ax25 round trip");
}
{
  const payload = [0x01, KISS.fend, 0x02, KISS.fesc, 0x03];
  const stream = [...KISS.encode(payload), ...KISS.encode([0x09])];
  const dec = new KISSDecoder(); let frames = [];
  for (const b of stream) frames = frames.concat(dec.feed([b]));
  expect(JSON.stringify(frames) === JSON.stringify([payload, [0x09]]), "kiss escaping/chunking");
}
{
  const bytes = KISS.encode(AX25.encode(packet("KD8ABC", "APRS", [], "!3741.20N/08159.40Wj")));
  const d = new RadioStreamDecoder();
  const out = [...d.feed(bytes.slice(0, 10)), ...d.feed(bytes.slice(10))];
  expect(out.length === 1 && out[0].source === "KD8ABC" && d.mode === "kiss", "stream kiss");
}
{
  const d = new RadioStreamDecoder();
  let out = d.feed([...latin1.bytes("KD8ABC>APRS:!3741.20N/0815")]);
  expect(out.length === 0, "partial line");
  out = out.concat(d.feed([...latin1.bytes("9.40Wj\r\nKD8XYZ>APRS:!3741.00N/08159.00Wj\r\n")]));
  expect(out.map((p) => p.source).join() === "KD8ABC,KD8XYZ" && d.mode === "text", "stream text");
  const d2 = new RadioStreamDecoder();
  expect(d2.feed([...latin1.bytes("KD8ABC>APRS:!3741.20N/08159.40Wj")]).length === 0 && d2.flush()[0]?.source === "KD8ABC", "flush");
}
expect(TNC2.decode("[RX] KD8ABC-9>APRS,WIDE1-1:!3741.20N/08159.40Wj")?.source === "KD8ABC-9", "tnc2 prefix");

// ---- Trail import (synthetic HMT-style KMZ) ----
const sample = fileURLToPath(new URL("../../Tests/TrailImportCheck/sample.kmz", import.meta.url));
const trails = await importTrailFile("sample.kmz", fs.readFileSync(sample));
expect(trails.length === 2, "2 trails, got " + trails.length);
expect(trails[0].label === "73", "label " + trails[0].label);
expect(trails[0].name === "Sample System Trail 73", "name " + trails[0].name);
expect(trails[0].color === "#000000", "style color " + trails[0].color);
expect(trails[1].color?.toUpperCase() === "#004DA8", "aabbggrr " + trails[1].color);
expect(Math.abs(trails[0].segments[0][0][0] + 81.9) < 1e-9 && Math.abs(trails[0].segments[0][0][1] - 37.7) < 1e-9, "lon/lat order");
expect(trails[0].details.Difficulty === "Most Difficult", "details from table");

// ---- Routing on a small synthetic network ----
// Trail 1 runs west-east; trail 2 leaves its middle heading north (a T junction 5 m off the line); trail 3 is single track.
const mk = (label, diff, pts) => ({ name: "T" + label, label, color: null, segments: [pts], details: { Trail_Syst: "Test", Difficulty: diff } });
const net = [
  mk("1", "Easiest", [[-81.90, 37.70], [-81.89, 37.70], [-81.88, 37.70]]),
  mk("2", "More Difficult", [[-81.89, 37.70005], [-81.89, 37.71]]),
  mk("3", "Single Track Most", [[-81.90, 37.70], [-81.90, 37.71], [-81.89, 37.71]]),
];
const g = new TrailGraph(waysFromTrails(net, trailSystem, trailDifficulty));
const r = g.route({ lat: 37.7, lon: -81.899 }, { lat: 37.7099, lon: -81.8901 }, { avoidSingleTrack: true, avoidMostDifficult: false });
expect(r && r.steps.map((s) => s.title).join() === "Trail 1,Trail 2", "route uses trails 1 then 2: " + (r && r.steps.map((s) => s.title)));
expect(r && r.steps[1].turn === "Turn left onto", "left turn onto trail 2: " + (r && r.steps[1].turn));
const r2 = g.route({ lat: 37.7, lon: -81.899 }, { lat: 37.7099, lon: -81.8901 }, { avoidSingleTrack: false, avoidMostDifficult: false });
expect(r2 && r2.length < r.length + 1, "single track allowed is no longer");
expect(search("test 2", net, trailSystem, null)[0]?.trails[0].label === "2", "search by system + number");
expect(search("1 & 2", net, trailSystem, null).length === 1, "junction search");

if (failed) { console.log(`${failed} check(s) failed`); process.exit(1); }
console.log("All checks passed");
