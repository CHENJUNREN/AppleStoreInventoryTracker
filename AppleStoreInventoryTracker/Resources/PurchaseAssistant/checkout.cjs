// Review-only browser worker. No submission action, form values or browser logs are exported.
const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fail = code => { const e = new Error('Stopped'); e.code = code; throw e; };
const normalize = text => text.replace(/\s/g, '');
async function main(request) {
  const {chromium} = require(path.join(request.directory, 'node_modules/playwright-core'));
  const profileDirectory = path.join(request.directory, 'chrome-profile');
  fs.mkdirSync(profileDirectory, {recursive:true, mode:0o700});
  const connect = async () => {
    const [port, endpoint] = fs.readFileSync(path.join(profileDirectory, 'DevToolsActivePort'), 'utf8').trim().split('\n');
    if (!/^\d+$/.test(port) || !endpoint.startsWith('/devtools/browser/')) throw Error('Invalid endpoint');
    return chromium.connectOverCDP(`ws://127.0.0.1:${port}${endpoint}`, {timeout:2000});
  };
  let browser;
  try { browser = await connect(); } catch {
    const child = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
      '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', `--user-data-dir=${profileDirectory}`,
      '--no-first-run', '--no-default-browser-check', 'about:blank'
    ], {stdio:'ignore', detached:true});
    child.on('error', () => {}); child.unref();
    for (let i=0;i<40;i++) { try { browser = await connect(); break; } catch { await sleep(500); } }
  }
  if (!browser) fail(20);
  const context = browser.contexts()[0];
  const page = context.pages().find(p => /apple\.com\.cn/.test(p.url())) || await context.newPage();
  await page.bringToFront();
  page.setDefaultTimeout(30000);
  const a = id => page.locator(`${id.startsWith('form-field-')?'input':''}[data-autom="${id}"]`);
  const click = async id => {
    if (!['add-to-cart','checkout','fulfillment-continue-button','continue-button-label','continue-button-review','fulfillment-pickup-store-search-button','show-more-stores-button'].includes(id)) fail(20);
    await page.locator(`button[data-autom="${id}"],a[data-autom="${id}"]`).filter({visible:true}).first().click();
  };
  if (request.mode === 'login') {
    await page.goto('https://secure.www.apple.com.cn/shop/account/home', {waitUntil:'domcontentloaded'});
    return;
  }
  const profile = JSON.parse(fs.readFileSync(path.join(request.directory,'profile.json'), 'utf8'));
  const fields = ['lastName','firstName','emailAddress','fullDaytimePhone','nationalIdSelf'];
  if (fields.some(k => !profile[k]?.trim() || /[*•●]/.test(profile[k])) || !['alipay','wechat'].includes(profile.payment)) fail(20);
  if (!/^[a-z0-9]+\/a$/i.test(request.product) || !request.stores.length || request.stores.some(s=>!/^R\d+$/.test(s))) fail(20);
  // Require an empty bag. Never remove the user's products or reuse an uncertain purchase.
  const rows = () => page.evaluate(() => [...document.querySelectorAll('[data-autom]')].filter(e=>/^bag-item-\d+$/.test(e.dataset.autom)).map(e=>({
    name:e.querySelector('[data-autom="bag-item-name"],h2,h3')?.textContent||'',
    quantity:e.querySelector('select[data-autom="item-quantity-dropdown"]')?.value||e.innerText.match(/数量\s*(\d+)/)?.[1]||''
  })));
  await page.goto('https://www.apple.com.cn/shop/bag', {waitUntil:'domcontentloaded'});
  await page.locator('[data-autom="bag-empty-continueshopping-button"],[data-autom="bag-item-remove-button"]').first().waitFor();
  if ((await rows()).length) fail(11);
  await a('bag-empty-continueshopping-button').waitFor();
  await page.goto('https://www.apple.com.cn/shop/product/'+request.product.toLowerCase(), {waitUntil:'domcontentloaded'});
  await a('summary-productName').waitFor();
  const expectedName = normalize(await a('summary-productName').innerText());
  if (!expectedName || expectedName !== normalize(request.expectedName || "")) fail(20);
  await a('choose-noTradeIn').check();
  await a('noapplecare').waitFor();
  if (request.appleCare) {
    const group = await a('noapplecare').getAttribute('name');
    if (!group) fail(13);
    const candidates = page.locator('input[type=radio]');
    const ids = await candidates.evaluateAll((es,group) => es.filter(e=>e.name===group && e.dataset.autom!=='noapplecare').map(e=>e.id), group);
    if (ids.length !== 1 || !ids[0]) fail(13);
    const choice = page.locator(`[id=${JSON.stringify(ids[0])}]`);
    await choice.check(); if (!await choice.isChecked()) fail(13);
  } else { await a('noapplecare').check(); }
  if (!await a('choose-noTradeIn').isChecked()) fail(20);
  await click('add-to-cart');
  await page.waitForURL(u=>u.pathname==='/shop/bag'||u.searchParams.get('step')==='attach', {timeout:60000});
  await page.goto('https://www.apple.com.cn/shop/bag', {waitUntil:'domcontentloaded'});
  await a('checkout').first().waitFor();
  const verify = async () => { const items = await rows(); if (items.length!==1 || normalize(items[0].name)!==expectedName || items[0].quantity!=='1') fail(11); };
  await verify();
  await click('checkout');
  await page.waitForFunction(()=>/signin/i.test(location.href)||document.querySelector('[data-autom="guest-checkout-btn"]')||[...document.querySelectorAll('button')].some(e=>e.innerText.trim()==='我要取货'), null, {timeout:60000});
  if (/signin/i.test(page.url()) || await a('guest-checkout-btn').isVisible()) fail(10);
  const pickup=page.getByRole('radio',{name:'我要取货',exact:true});
  if (await pickup.getAttribute('aria-checked')!=='true') await pickup.click();
  await page.locator('input[name="store-locator-result"]').first().waitFor({state:'attached',timeout:60000});
  await click('fulfillment-pickup-store-search-button');
  for (const [part,value] of [['state',request.region.province],['city',request.region.city],['district',request.region.district]]) {
    const panel=a(`address-field-provinceselector-${part}-panel`).filter({visible:true});
    if (part==='city' && !await panel.count()) continue;
    const escaped=value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    await panel.getByRole('button',{name:new RegExp('^'+escaped+'市?$')}).click();
    if(part==='state') {
      await page.locator('[data-autom="address-field-provinceselector-city-panel"],[data-autom="address-field-provinceselector-district-panel"]').filter({visible:true}).first().waitFor();
    }
  }
  await page.locator('input[name="store-locator-result"]').first().waitFor({state:'attached',timeout:60000});
  let selected=false;
  for (const id of request.stores) {
    const store=page.locator(`input[name="store-locator-result"][value="${id}"]`);
    if (!await store.count() && await a('show-more-stores-button').isVisible()) await click('show-more-stores-button');
    if (!await store.count() || await store.isDisabled()) continue;
    await page.locator(`label[for="${await store.getAttribute('id')}"]`).click();
    const slots=a('pickup-availablewindow-dropdown');
    try { await slots.waitFor({timeout:10000}); } catch { continue; }
    const deadline=Date.now()+45000;
    while(Date.now()<deadline) {
      if (await store.isDisabled()) break;
      if (!await store.isChecked()) await page.locator(`label[for="${await store.getAttribute('id')}"]`).click();
      const first=await slots.locator('option').evaluateAll(es=>es.find(e=>e.value&&!e.disabled)?.value);
      if (!first) break;
      await slots.selectOption(first);
      await sleep(3000);
      if (!await store.isChecked() || await slots.inputValue()!==first) continue;
      await click('fulfillment-continue-button');
      try { await a('form-field-lastName').waitFor({timeout:20000}); selected=true; break; }
      catch { if (!await slots.isVisible()) fail(20); }
    }
    if(selected) break;
  }
  if(!selected) fail(12);
  for(const field of fields) { await a('form-field-'+field).fill(profile[field]); await a('form-field-'+field).blur(); }
  // Personal invoice is the website default; do not fill company fields or select business invoicing.
  await click('continue-button-label');
  await page.locator('button[data-autom="continue-button-review"],button[data-autom="continue-button-placeOrder"]').filter({visible:true}).first().waitFor({timeout:60000});
  if(!await a('continue-button-placeOrder').isVisible()) {
    const choice=a('checkout-billingOptions-'+profile.payment.toUpperCase());
    await choice.waitFor({state:'attached'});
    if(!await choice.isChecked()) await page.locator(`label[for="${await choice.getAttribute('id')}"]`).click();
    if(!await choice.isChecked()) fail(20);
    await click('continue-button-review');
  }
  await a('continue-button-placeOrder').waitFor({timeout:60000});
  await verify();
  if(new URL(page.url()).searchParams.get('_s')!=='Review') fail(20);
  // Exit without closing Chrome: review, confirmation and payment belong to the user.
}
let input='';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input+=chunk; if(input.length>65536) process.exit(20); });
process.stdin.on('end', () => main(JSON.parse(input)).then(()=>process.exit(0)).catch(e=>process.exit(Number.isInteger(e.code)?e.code:20)));
setTimeout(()=>process.exit(20), 8*60*1000).unref();
