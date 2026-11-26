const { chromium, devices } = require('playwright');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [, , root, out, base] = process.argv;
const skip = new Set(['node_modules', 'Pods', 'build', 'Screenshots', 'ios', 'android']);

function walk(dir, acc = [], depth = 0) {
  if (depth > 4) return acc;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (!skip.has(e.name) && !e.name.startsWith('.')) {
        walk(path.join(dir, e.name), acc, depth + 1);
      }
    } else if (/\.html?$/i.test(e.name)) {
      acc.push(path.relative(root, path.join(dir, e.name)));
    }
  }
  return acc;
}

(async () => {
  const pages = walk(root)
    .sort((a, b) => a === 'index.html' ? -1 : b === 'index.html' ? 1 : a.localeCompare(b))
    .slice(0, 12);

  const browser = await chromium.launch();
  const context = await browser.newContext({ ...devices['iPhone 14'] });
  const page = await context.newPage();

  const lines = [];
  const seen = new Set();
  let n = 0;

  async function snap(slug, title, full) {
    if (n >= 40) return false;
    await page.waitForTimeout(700);
    const buf = await page.screenshot({ fullPage: !!full });
    const key = crypto.createHash('md5').update(buf).digest('hex');
    if (seen.has(key)) return false;
    seen.add(key);
    n += 1;
    const name = String(n).padStart(2, '0') + '-' + slug;
    fs.writeFileSync(path.join(out, name + '.png'), buf);
    lines.push(name + '|' + title.replace(/[|\n]/g, ' '));
    return true;
  }

  const selector = 'button, [role=button], a[href^="#"], a[href$=".html"], [onclick]';

  for (const [i, p] of pages.entries()) {
    const url = base + '/' + p.split(path.sep).map(encodeURIComponent).join('/');

    try {
      await page.goto(url, { waitUntil: 'networkidle', timeout: 20000 });
    } catch (e) {
      try { await page.goto(url, { timeout: 20000 }); } catch (e2) { continue; }
    }

    await snap('page' + (i + 1), 'صفحة ' + p, false);
    await snap('page' + (i + 1) + '-full', 'صفحة ' + p + ' (كاملة)', true);

    const count = Math.min(await page.locator(selector).count(), 10);

    for (let j = 0; j < count; j++) {
      const el = page.locator(selector).nth(j);
      let label = '';
      try {
        if (!(await el.isVisible())) continue;
        label = (await el.innerText({ timeout: 1000 })).trim().slice(0, 30);
        await el.click({ timeout: 2000, noWaitAfter: true });
      } catch (e) { continue; }

      await snap('page' + (i + 1) + '-a' + (j + 1),
        'صفحة ' + p + ' › ' + (label || 'عنصر ' + (j + 1)), false);

      try { await page.goto(url, { waitUntil: 'load', timeout: 20000 }); } catch (e) {}
    }
  }

  fs.writeFileSync(path.join(out, 'index.txt'), lines.join('\n') + '\n');
  await browser.close();
  console.log('TOTAL_SCREENSHOTS: ' + n);
})();