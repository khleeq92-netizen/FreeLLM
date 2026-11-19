// Browser test for the Study Buddy UI. Needs the app running on :3100 with at
// least one working model (tests/mock-provider.mjs works offline).
// Usage: node tests/ui-test.cjs <screenshot-dir>
const { chromium } = require('playwright');

(async () => {
  const out = process.argv[2] || '.';
  const url = process.env.APP_URL || 'http://127.0.0.1:3100';
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1360, height: 900 } });
  const errors = [];
  p.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  p.on('console', (m) => { if (m.type() === 'error') errors.push('console: ' + m.text()); });

  await p.goto(url);
  await p.waitForSelector('#status.ok', { timeout: 15000 });
  console.log('status:', await p.textContent('#statusText'));
  await p.click('#sampleBtn');

  await p.fill('#question', 'What is photosynthesis?');
  await p.click('#askBtn');
  await p.waitForSelector('.msg.ai .meta', { timeout: 30000 });
  console.log('chat meta:', await p.textContent('.msg.ai .meta'));
  await p.screenshot({ path: out + '/1-chat.png' });

  await p.click('[data-tab=summary]');
  await p.click('#sumBtn');
  await p.waitForFunction(() => document.querySelector('#sumMeta').textContent.length > 0, null, { timeout: 30000 });
  console.log('summary html:', (await p.innerHTML('#sumOut')).slice(0, 120));

  await p.click('[data-tab=quiz]');
  await p.click('#quizBtn');
  await p.waitForSelector('.quiz-q', { timeout: 30000 });
  const qs = await p.$$('.quiz-q');
  for (const q of qs) { const opts = await q.$$('.opt'); await opts[1].click(); }
  console.log('quiz:', qs.length, 'questions;', await p.textContent('.score'));
  await p.screenshot({ path: out + '/2-quiz.png' });

  await p.click('[data-tab=cards]');
  await p.click('#cardBtn');
  await p.waitForSelector('.flash', { timeout: 30000 });
  await p.click('.flash');
  console.log('cards:', (await p.$$('.flash')).length, '| first card flipped:', await p.textContent('.flash'));
  await p.screenshot({ path: out + '/3-cards.png' });

  await p.click('[data-tab=log]');
  console.log('log stats:', (await p.textContent('#stats')).replace(/\s+/g, ' '));
  await p.screenshot({ path: out + '/4-log.png' });

  await p.click('#settingsBtn');
  await p.screenshot({ path: out + '/5-settings.png' });

  const m = await b.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark' });
  await m.goto(url);
  await m.waitForTimeout(800);
  console.log('mobile scrollWidth:', await m.evaluate(() => document.documentElement.scrollWidth));
  await m.screenshot({ path: out + '/6-mobile-dark.png' });

  console.log('errors:', errors.length ? errors : 'none');
  await b.close();
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
