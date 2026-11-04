const puppeteer = require('puppeteer');
const path = require('path');

(async () => {
  const browser = await puppeteer.launch({ headless: true });
  const page = await browser.newPage();

  const files = [
    { name: '1-sidebar.html', selector: '.window' },
    { name: '2-mappings.html', selector: '.card' },
    { name: '3-sync-history.html', selector: '.card' },
    { name: '4-destinations.html', selector: '.card' },
    { name: '5-menubar.html', selector: '.popover' },
  ];

  await page.setViewport({ width: 1200, height: 1200, deviceScaleFactor: 2 });

  for (const f of files) {
    const filePath = 'file://' + path.resolve(__dirname, f.name);
    await page.goto(filePath, { waitUntil: 'networkidle0' });

    // Remove body padding so element screenshot has no surrounding gap
    await page.evaluate(() => {
      document.body.style.padding = '0';
      document.body.style.margin = '0';
    });

    await page.evaluate(() => document.fonts.ready);
    await new Promise(r => setTimeout(r, 500));

    const element = await page.$(f.selector);
    const outName = f.name.replace('.html', '.png');
    await element.screenshot({
      path: path.resolve(__dirname, outName),
      omitBackground: true,
    });
    const box = await element.boundingBox();
    console.log(`Captured ${outName} (${Math.round(box.width * 2)}x${Math.round(box.height * 2)} @2x)`);
  }

  await browser.close();
  console.log('Done! 5 PNGs saved to mockups/');
})();
