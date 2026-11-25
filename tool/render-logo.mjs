import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Resvg } from '@resvg/resvg-js';
import sharp from 'sharp';
import toIco from 'to-ico';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const brandingDir = path.join(root, 'assets', 'branding');
const brandSvg = path.join(brandingDir, 'logo-zhen.svg');
const srcSvg = path.resolve(process.argv[2] || brandSvg);

if (!fs.existsSync(srcSvg)) {
  console.error(`SVG not found: ${srcSvg}`);
  process.exit(1);
}

const svg = fs.readFileSync(srcSvg);
const printingDir = path.join(root, 'assets', 'printing');
const winIcon = path.join(root, 'windows', 'runner', 'resources', 'app_icon.ico');
const macIconDir = path.join(root, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset');
fs.mkdirSync(brandingDir, { recursive: true });
fs.mkdirSync(printingDir, { recursive: true });
if (srcSvg !== brandSvg) fs.copyFileSync(srcSvg, brandSvg);

async function raster(size) {
  const resvg = new Resvg(svg, {
    fitTo: { mode: 'width', value: size },
    background: 'transparent',
  });
  return Buffer.from(resvg.render().asPng());
}

async function pngAt(size, background) {
  const buf = await raster(Math.max(size, 128));
  return sharp(buf)
    .resize(size, size, {
      fit: 'contain',
      background: background ?? { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toBuffer();
}

await sharp(await raster(512))
  .resize(256, 256, {
    fit: 'contain',
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  })
  .png()
  .toFile(path.join(brandingDir, 'zhenji-brand.png'));

await sharp(await raster(256))
  .resize(64, 64, {
    fit: 'contain',
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  })
  .png()
  .toFile(path.join(printingDir, 'tray.png'));

const icoSizes = [16, 32, 48, 64, 128, 256];
const icoPngs = [];
for (const size of icoSizes) {
  icoPngs.push(await pngAt(size));
}
const ico = await toIco(icoPngs);
fs.writeFileSync(path.join(printingDir, 'tray.ico'), ico);
fs.writeFileSync(winIcon, ico);

for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
  fs.writeFileSync(path.join(macIconDir, `app_icon_${size}.png`), await pngAt(size));
}

const android = [
  ['mipmap-mdpi', 48],
  ['mipmap-hdpi', 72],
  ['mipmap-xhdpi', 96],
  ['mipmap-xxhdpi', 144],
  ['mipmap-xxxhdpi', 192],
];
for (const [folder, size] of android) {
  const dir = path.join(root, 'android', 'app', 'src', 'main', 'res', folder);
  if (!fs.existsSync(dir)) continue;
  await sharp(
    await pngAt(size, { r: 255, g: 255, b: 255, alpha: 1 }),
  ).toFile(path.join(dir, 'ic_launcher.png'));
}

console.log('logo assets updated');
