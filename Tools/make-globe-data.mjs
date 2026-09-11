// Generates the two data files the World Clock's globe needs, so neither is a
// mystery blob in the repo. Run from anywhere:
//
//     node Tools/make-globe-data.mjs
//
//   land.json   coastlines, from Natural Earth 1:110m "land" — public domain,
//               no attribution required (naturalearthdata.com/about/terms-of-use).
//               Rings of [lon, lat, lon, lat, ...], rounded to 2dp: about 1km,
//               which is a tenth of a pixel on a 300px globe.
//   zones.json  a point for each IANA zone, from the zoneinfo database macOS
//               already ships at /usr/share/zoneinfo/zone.tab. tzdb is public
//               domain. A city's dot comes from its zone, which is the only
//               thing the app stores about where it is.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const web = join(dirname(fileURLToPath(import.meta.url)), "..", "Examples", "WorldClock", "web");
const SOURCE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson";

const round = (n) => Math.round(n * 100) / 100;
const geo = await (await fetch(SOURCE)).json();
const rings = [];
for (const f of geo.features) {
  for (const ring of f.geometry.coordinates) {
    if (ring.length < 4) continue;               // degenerate
    const flat = [];
    let last = null;
    for (const [lon, lat] of ring) {
      const p = [round(lon), round(lat)];
      if (last && p[0] === last[0] && p[1] === last[1]) continue;   // rounding made a duplicate
      flat.push(p[0], p[1]);
      last = p;
    }
    if (flat.length >= 8) rings.push(flat);
  }
}
writeFileSync(join(web, "land.json"), JSON.stringify(rings));

// ISO 6709: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
function degrees(s) {
  const split = s.slice(1).search(/[+-]/) + 1;
  const parts = [s.slice(0, split), s.slice(split)];
  return parts.map((p, i) => {
    const sign = p[0] === "-" ? -1 : 1, d = p.slice(1);
    const wide = i === 0 ? 2 : 3;                 // latitude is DD, longitude DDD
    const deg = +d.slice(0, wide), min = +d.slice(wide, wide + 2), sec = +(d.slice(wide + 2) || 0);
    return sign * (deg + min / 60 + sec / 3600);
  });
}
const zones = {};
for (const line of readFileSync("/usr/share/zoneinfo/zone.tab", "utf8").split("\n")) {
  if (!line || line.startsWith("#")) continue;
  const [, coord, name] = line.split("\t");
  const [lat, lon] = degrees(coord);
  zones[name] = [round(lat), round(lon)];
}
writeFileSync(join(web, "zones.json"), JSON.stringify(zones));

console.log(`land.json  ${rings.length} rings, ${rings.reduce((n, r) => n + r.length / 2, 0)} points`);
console.log(`zones.json ${Object.keys(zones).length} zones`);
