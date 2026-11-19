// Browser test for FreeLLM Assistant. Needs the app running on :3100 with at
// least one working model (tests/mock-provider.mjs works offline).
// Usage: node tests/ui-test.cjs <screenshot-dir> <test-files-dir>
//   test-files-dir must contain fees.xlsx, circular.docx and notice.pdf.
const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const out = process.argv[2] || '.';
  const tf = process.argv[3] || '.';
  const url = process.env.APP_URL || 'http://127.0.0.1:3100';
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1400, height: 950 }, acceptDownloads: true });
  const p = await ctx.newPage();
  const errors = [];
  p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  const check = (cond, msg) => { if (!cond) throw new Error('CHECK FAILED: ' + msg); console.log('✓', msg); };

  await p.goto(url);
  await p.waitForSelector('#status.ok', { timeout: 15000 });
  console.log('status:', await p.textContent('#statusText'));

  // Upload Excel, Word and PDF together.
  await p.setInputFiles('#fileInput', ['fees.xlsx', 'circular.docx', 'notice.pdf'].map((f) => path.join(tf, f)));
  await p.waitForFunction(() => document.querySelectorAll('#fileList .file:not(#reading)').length === 3, null, { timeout: 20000 });
  const infos = await p.$$eval('#fileList .file', (els) => els.map((e) => e.innerText.replace(/\s+/g, ' ')));
  infos.forEach((i) => console.log('  file:', i));
  check(infos.some((i) => /fees\.xlsx.*2 sheets.*4 rows/.test(i)), 'Excel parsed (2 sheets)');
  check(infos.some((i) => /circular\.docx.*characters/.test(i)), 'Word parsed');
  check(infos.some((i) => /notice\.pdf.*characters/.test(i)), 'PDF parsed');
  check(!infos.some((i) => /Could not read/.test(i)), 'no file errors');

  // Chat with files.
  await p.fill('#question', 'When is the FYJC deadline?');
  await p.click('#askBtn');
  await p.waitForSelector('.msg.ai .meta', { timeout: 30000 });
  check((await p.textContent('#chatCtx')).includes('3 files'), 'chat uses the 3 ticked files');
  await p.screenshot({ path: out + '/1-chat.png' });

  // Write.
  await p.click('[data-tab=write]');
  await p.selectOption('#wLang', 'Marathi');
  await p.fill('#wTopic', 'Notice to parents about the FYJC admission deadline');
  await p.click('#wBtn');
  await p.waitForSelector('.outbar[data-for=wOut] button', { timeout: 30000 });
  check(true, 'write produced output with Copy/Download buttons');
  const [docDl] = await Promise.all([p.waitForEvent('download'), p.click('.outbar[data-for=wOut] [data-act=doc]')]);
  check(docDl.suggestedFilename().endsWith('.doc'), 'Word download: ' + docDl.suggestedFilename());

  // Translate a file.
  await p.click('[data-tab=translate]');
  const opts = await p.$$eval('#tSource option', (o) => o.map((x) => x.textContent));
  await p.selectOption('#tSource', { label: opts.find((o) => o.includes('circular.docx')) });
  await p.click('#tBtn');
  await p.waitForSelector('.outbar[data-for=tOut] button', { timeout: 30000 });
  check((await p.textContent('#tOut')).includes('[TRANSLATED]'), 'translated the Word file');

  // Summarise the PDF.
  await p.click('[data-tab=summary]');
  const sopts = await p.$$eval('#sSource option', (o) => o.map((x) => x.textContent));
  await p.selectOption('#sSource', { label: sopts.find((o) => o.includes('notice.pdf')) });
  await p.click('#sBtn');
  await p.waitForSelector('.outbar[data-for=sOut] button', { timeout: 30000 });
  check((await p.innerHTML('#sOut')).includes('<li>'), 'summary rendered');

  // Excel: preview, ask, edit, download.
  await p.click('[data-tab=excel]');
  await p.selectOption('#xFile', { label: 'fees.xlsx' });
  check((await p.textContent('#xInfo')).startsWith('3 rows × 4 columns'), 'Excel preview: ' + await p.textContent('#xInfo'));
  check((await p.$$eval('#xSheet option', (o) => o.map((x) => x.textContent))).join() === 'Fees,Staff', 'sheet selector lists both sheets');
  await p.fill('#xQ', 'Total fees due?');
  await p.click('#xAskBtn');
  await p.waitForSelector('.outbar[data-for=xAnswer] button', { timeout: 30000 });
  check(true, 'Excel question answered');
  await p.click('[data-xq*=Category]');
  await p.click('#xEditBtn');
  await p.waitForSelector('#xResultBar:not(.hidden)', { timeout: 60000 });
  const prog = await p.textContent('#xProg');
  check(/Done: 3 rows/.test(prog), 'edit finished: ' + prog.trim());
  const heads = await p.$$eval('#xResult th', (t) => t.map((x) => x.textContent));
  check(heads.includes('Category'), 'result has new Category column');
  await p.screenshot({ path: out + '/2-excel.png' });
  const [xl] = await Promise.all([p.waitForEvent('download'), p.click('#xDlXlsx')]);
  const saved = path.join(out, xl.suggestedFilename());
  await xl.saveAs(saved);
  const X = require(path.join(tf, '..', 'vend', 'node_modules', 'xlsx'));
  const rows = X.utils.sheet_to_json(X.readFile(saved).Sheets.Fees, { header: 1 });
  check(rows.length === 4 && rows[0][4] === 'Category' && rows[1][2] === 12000, 'downloaded .xlsx is valid, numbers kept as numbers: ' + JSON.stringify(rows[1]));

  // Persistence across reload.
  await p.reload();
  await p.waitForSelector('#status.ok');
  check((await p.$$('#fileList .file')).length === 3, 'files kept after reload');
  check((await p.$$('.msg.ai')).length === 1, 'chat kept after reload');

  await p.click('[data-tab=log]');
  console.log('log stats:', (await p.textContent('#stats')).replace(/\s+/g, ' '));
  await p.screenshot({ path: out + '/3-log.png' });

  const m = await b.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark' });
  await m.goto(url); await m.waitForTimeout(800);
  check((await m.evaluate(() => document.documentElement.scrollWidth)) <= 390, 'no horizontal scroll on phone width');
  await m.screenshot({ path: out + '/4-mobile-dark.png' });

  console.log('errors:', errors.length ? errors : 'none');
  if (errors.length) process.exitCode = 1;
  await b.close();
})().catch((e) => { console.error('FAIL', e.message); process.exit(1); });
