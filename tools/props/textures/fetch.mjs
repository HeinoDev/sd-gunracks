// The Poly Haven photographs the racks' materials are made from, and the studio HDRI the check renders are lit by.
// Every Poly Haven asset is CC0 (public domain).
//
//     node tools/props/textures/fetch.mjs [folder]
//
// Saves into tools/props/textures/maps/ (or the folder named): <name>_diff.jpg, <name>_nor.jpg (OpenGL), <name>_rough.jpg,
// studio.hdr, and meta.json: which asset each came from, its authors, licence, page and real size. Nothing here ships
// to the game: build.py bakes them into each rack's own textures.
import fs from 'node:fs';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// our name -> [Poly Haven asset, what it is used for, resolution]
export const ASSETS = {
  // woods (looks.py turns the grain along each part)
  oak: ['oak_veneer_01', 'golden oak: the floor rack', '2k'],
  walnut: ['smoked_walnut_veneer', 'walnut (and the cherry, tinted): the wall rack, the pistol board frame, the plaque, the corner rack', '2k'],
  barn: ['rough_wood', 'weathered boards: the pipe rack', '2k'],
  // soft goods
  felt: ['velour_velvet', 'felt / flocking in notches, cradles and the pistol board (recoloured)', '1k'],
  leather: ['brown_leather', 'leather pads and straps', '1k'],
  // metal
  paint: ['blue_metal_plate', 'scratches and smudges of painted sheet steel: powder coat (recoloured)', '2k'],
  steel: ['metal_plate_02', 'worn steel: pipes, fittings, hardware', '1k'],
  galvanised: ['corrugated_iron', 'mill-scale / galvanised mottle: the steel panel', '1k'],
  // rubber and grime
  grain: ['rubberized_track', 'moulded rubber and plastic grain: rubber dip, pads, end caps', '1k'],
  grime: ['dirty_concrete', 'breaks up the grime baked into every recess', '1k'],
};

export const STUDIO = 'studio_small_09';
export const LICENCE = 'CC0 1.0 Universal (public domain), Poly Haven';

function get(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'sd-gunracks/1.0' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return resolve(get(res.headers.location));
      }

      if (res.statusCode !== 200) return reject(new Error(url + ' -> ' + res.statusCode));

      const chunks = [];

      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    }).on('error', reject);
  });
}

function pick(files, names, resolution) {
  for (const name of names) {
    const map = files[name];
    if (!map) continue;
    for (const size of [resolution, '1k', '2k', '4k']) {
      if (map[size] && map[size].jpg) return map[size].jpg.url;
    }
  }
  return null;
}

const out = path.resolve(process.argv[2] || path.join(HERE, 'maps'));
fs.mkdirSync(out, { recursive: true });
const meta = {};
let failed = 0;

for (const [id, [asset, use, res]] of Object.entries(ASSETS)) {
  try {
    const info = JSON.parse((await get('https://api.polyhaven.com/info/' + asset)).toString());
    const files = JSON.parse((await get('https://api.polyhaven.com/files/' + asset)).toString());
    const urls = {
      diff: pick(files, ['Diffuse', 'diffuse', 'diff', 'Color'], res),
      nor: pick(files, ['nor_gl', 'Normal', 'nor_dx'], res),
      rough: pick(files, ['Rough', 'rough'], res),
    };
    meta[id] = {
      asset,
      name: info.name || asset,
      used_for: use,
      page: 'https://polyhaven.com/a/' + asset,
      licence: LICENCE,
      authors: Object.keys(info.authors || {}),
      dimensions_mm: info.dimensions || null,
      maps: {},
    };
    for (const [kind, url] of Object.entries(urls)) {
      if (!url) {
        meta[id].maps[kind] = null;
        continue;
      }

      const file = `${id}_${kind}.jpg`;
      const target = path.join(out, file);

      if (!fs.existsSync(target) || fs.statSync(target).size === 0) {
        fs.writeFileSync(target, await get(url));
      }

      meta[id].maps[kind] = { file, bytes: fs.statSync(target).size, from: url.split('/').slice(-1)[0] };
    }
    console.log(id.padEnd(12), asset.padEnd(20), meta[id].authors.join(', '));
  } catch (err) {
    failed += 1;
    console.log(id.padEnd(12), 'FAILED', err.message);
  }
}

try {
  const info = JSON.parse((await get('https://api.polyhaven.com/info/' + STUDIO)).toString());
  const studio = path.join(out, 'studio.hdr');
  if (!fs.existsSync(studio) || fs.statSync(studio).size === 0) {
    const files = JSON.parse((await get('https://api.polyhaven.com/files/' + STUDIO)).toString());
    fs.writeFileSync(studio, await get(files.hdri['2k'].hdr.url));
  }

  meta.studio = {
    asset: STUDIO,
    name: info.name || STUDIO,
    used_for: 'the light of the check renders (as the icons)',
    page: 'https://polyhaven.com/a/' + STUDIO,
    licence: LICENCE,
    authors: Object.keys(info.authors || {}),
    type: 'hdri',
    maps: { hdr: { file: 'studio.hdr', bytes: fs.statSync(studio).size } },
  };

  console.log('studio'.padEnd(12), STUDIO.padEnd(20), meta.studio.authors.join(', '));
} catch (err) {
  failed += 1;
  console.log('studio'.padEnd(12), 'FAILED', err.message);
}

fs.writeFileSync(path.join(out, 'meta.json'), JSON.stringify(meta, null, 1) + '\n');
process.exit(failed ? 1 : 0);
