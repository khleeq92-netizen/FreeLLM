// Builds the self-contained install.sh from installer/install.template.sh by
// embedding the app files. Run: node scripts/build-installer.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8').replace(/\n+$/, '');
const embeds = {
  '@@SERVER_MJS@@': read('app/server.mjs'),
  '@@INDEX_HTML@@': read('app/public/index.html'),
  '@@APP_PACKAGE_JSON@@': read('app/package.json'),
};

let out = read('installer/install.template.sh') + '\n';
for (const [marker, content] of Object.entries(embeds)) {
  if (content.includes('ASSISTANT_EMBED_EOF')) throw new Error(`${marker} content contains the heredoc delimiter`);
  if (!out.includes(marker)) throw new Error(`missing ${marker} in template`);
  out = out.replace(marker, () => content);
}
fs.writeFileSync(path.join(root, 'install.sh'), out, { mode: 0o755 });
console.log('wrote install.sh');
