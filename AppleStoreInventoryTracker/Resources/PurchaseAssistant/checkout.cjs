// Review-only browser worker. No submission action, form values or browser logs are exported.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const {spawn, execFileSync} = require('node:child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const fail = code => { const e = new Error('Stopped'); e.code = code; throw e; };
const normalize = text => text.replace(/\s/g, '');
let appleRequestRejected = false;
function isAppleRequestRejection(status, url) {
  try { return status === 541 && /(^|\.)apple\.com\.cn$/.test(new URL(url).hostname); } catch { return false; }
}

// Re-read after every removal: Apple's bag row IDs can be renumbered.
async function clearBag(adapter) {
  for (let count = 0; count < 100; count++) {
    if (await adapter.empty()) return;
    await adapter.removeFirst();
    await adapter.settled();
  }
  fail(11);
}
async function openBag(page) {
  const ready = page.locator('[data-autom="bag-empty-continueshopping-button"],[data-autom="bag-item-remove-button"]').filter({visible:true}).first();
  // A prior navigation can time out while the bag itself has already rendered.
  if (new URL(page.url()).pathname === '/shop/bag' && await ready.isVisible()) return;
  await page.goto('https://www.apple.com.cn/shop/bag', {waitUntil:'commit'});
  await ready.waitFor();
}

function retryableError(error, stage) {
  // Never navigate away automatically once contact/payment/review may need attention.
  return !['校验取货资料','填写取货资料','选择付款方式','核对订单'].includes(stage) &&
    (error?.name === 'TimeoutError' || /net::ERR_(CONNECTION|NETWORK|INTERNET|TIMED_OUT|NAME_NOT_RESOLVED)/.test(error?.message || ''));
}


// Bounded, allowlisted diagnostics: never record DOM, URLs, form values or raw exceptions.
function createDiagnostics(request) {
  const started = Date.now();
  let stage = '启动', file;
  const events = [];
  if (/^[a-f0-9-]{36}$/i.test(request.diagnosticID || '')) {
    try {
      const directory = path.join(request.directory, 'Diagnostics');
      fs.mkdirSync(directory, {recursive:true, mode:0o700});
      const files = fs.readdirSync(directory).filter(n => /^[a-f0-9-]{36}\.json$/i.test(n))
        .sort((a,b) => fs.statSync(path.join(directory,b)).mtimeMs - fs.statSync(path.join(directory,a)).mtimeMs);
      for (const name of files.slice(19)) fs.unlinkSync(path.join(directory,name));
      file = path.join(directory, request.diagnosticID + '.json');
    } catch { /* Diagnostics must not change checkout behavior. */ }
  }
  const record = (code, category = 'running') => {
    const event = {stage, elapsedMs:Date.now()-started, category};
    events.push(event);
    const snapshot = {...event, time:new Date().toISOString(), code, events:events.slice(-80)};
    if (file) try { fs.writeFileSync(file, JSON.stringify(snapshot), {mode:0o600}); } catch {}
  };
  return {
    get stage() { return stage; },
    step(value) { stage=value; record(); },
    finish(code, error) { record(code, code === 0 ? 'complete' : error?.name === 'TimeoutError' ? 'timeout' : Number.isInteger(error?.code) ? 'stopped' : 'unexpected'); }
  };
}

function browserProfileDirectory(directory) {
  const selection = path.join(directory, 'browser-profile.json');
  const name = fs.existsSync(selection) ? JSON.parse(fs.readFileSync(selection, 'utf8')) : 'chrome-profile';
  if (typeof name !== 'string' || !/^chrome-profile(?:-[a-f0-9-]+)?$/i.test(name)) throw Error('Invalid browser profile');
  return path.join(directory, name);
}

const chromeExecutable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const accountURL = 'https://secure.www.apple.com.cn/shop/account/home';
function chromeArguments(profileDirectory, mode, port) {
  if (mode !== 'login' && (!Number.isInteger(port) || port < 1 || port > 65535)) throw Error('Invalid debugging port');
  const args = [`--user-data-dir=${profileDirectory}`, '--no-first-run', '--no-default-browser-check'];
  return mode === 'login' ? [...args, accountURL] : [
    '--remote-debugging-address=127.0.0.1', `--remote-debugging-port=${port}`, ...args, 'about:blank'
  ];
}
function profileProcessState(output, profileDirectory) {
  const match = output.trim().match(/^(\S+)\s+(.+)$/);
  if (!match || match[1].startsWith('Z')) return false;
  const command = match[2];
  const argument = `--user-data-dir=${profileDirectory}`;
  if (!command.startsWith(chromeExecutable + ' ') ||
      !(command.includes(argument + ' ') || command.endsWith(argument))) fail(24);
  return true;
}
function profileProcess(profileDirectory) {
  let lock;
  try { lock = fs.readlinkSync(path.join(profileDirectory, 'SingletonLock')); }
  catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  const pid = Number(lock.match(/-(\d+)$/)?.[1]);
  if (!Number.isSafeInteger(pid) || pid <= 1) fail(24);
  try { process.kill(pid, 0); } catch (e) { if (e.code === 'ESRCH') return null; throw e; }
  let output;
  try { output = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'stat=', '-o', 'command='], {encoding:'utf8'}); }
  catch (e) { if (e.status === 1) return null; throw e; }
  // A dead/zombie Chrome may briefly leave its lock behind; never signal another process.
  return profileProcessState(output, profileDirectory) ? pid : null;
}
async function launchChrome(profileDirectory, mode) {
  const port = mode === 'login' ? undefined : await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const selected = server.address().port;
      server.close(error => error ? reject(error) : resolve(selected));
    });
  });
  const child = spawn(chromeExecutable, chromeArguments(profileDirectory, mode, port), {stdio:'ignore', detached:true});
  await new Promise((resolve,reject) => { child.once('spawn',resolve); child.once('error',reject); });
  child.unref();
  if (port) fs.writeFileSync(path.join(profileDirectory, 'PurchaseAssistantEndpoint.json'), JSON.stringify({port, pid:child.pid}), {mode:0o600});
}

async function closeDedicatedChrome(profileDirectory) {
  const pid = profileProcess(profileDirectory);
  if (!pid) return;
  process.kill(pid, 'SIGTERM');
  for (let i=0;i<100 && profileProcess(profileDirectory);i++) await sleep(100);
  if (profileProcess(profileDirectory)) fail(24);
}
async function connectChrome(profileDirectory, chromium) {
  const connect = async () => {
    const saved = JSON.parse(fs.readFileSync(path.join(profileDirectory, 'PurchaseAssistantEndpoint.json'), 'utf8'));
    if (!Number.isInteger(saved.port) || saved.port < 1 || saved.port > 65535 || saved.pid !== profileProcess(profileDirectory)) throw Error('Invalid endpoint');
    return chromium.connectOverCDP(`http://127.0.0.1:${saved.port}`, {timeout:2000, noDefaults:true});
  };
  try { return await connect(); } catch {
    if (profileProcess(profileDirectory)) fail(24);
    await launchChrome(profileDirectory, 'purchase');
    for (let i=0;i<40;i++) { try { return await connect(); } catch { await sleep(500); } }
  }
  fail(20);
}
async function clearAppleLoginData(context) {
  const origins = new Set(['https://www.apple.com.cn', 'https://apple.com.cn',
    'https://secure.www.apple.com.cn', 'https://idmsa.apple.com.cn',
    'https://idmsa.apple.com', 'https://account.apple.com', 'https://account.apple.com.cn']);
  // Capture only Apple origins before unloading pages, so they cannot rewrite cleared data.
  for (const page of context.pages()) {
    for (const frame of page.frames()) {
      const url = new URL(frame.url());
      if (/(^|\.)apple\.com(\.cn)?$/.test(url.hostname)) origins.add(url.origin);
    }
    await page.goto('about:blank');
  }
  await context.clearCookies({domain: /(^|\.)apple\.com(\.cn)?$/});
  const page = context.pages()[0] || await context.newPage();
  const session = await context.newCDPSession(page);
  for (const origin of origins) await session.send('Storage.clearDataForOrigin', {origin, storageTypes:'all'});
  await session.send('Network.clearBrowserCache');
  await session.detach();
}
async function main(request, diagnostic) {
  diagnostic.step('登录检查');
  const profileDirectory = browserProfileDirectory(request.directory);
  fs.mkdirSync(profileDirectory, {recursive:true, mode:0o700});
  const loginMarker = path.join(request.directory, 'manual-login.json');
  const verifiedMarker = path.join(request.directory, 'verified-login.json');
  const profileName = path.basename(profileDirectory);
  const pendingLogin = fs.existsSync(loginMarker) && JSON.parse(fs.readFileSync(loginMarker, 'utf8')) === profileName;
  if (request.mode === 'login') {
    // The explicit login action reuses one profile and clears only its Apple site data.
    // Browser preferences, pickup details and the user's everyday Chrome are untouched.
    await closeDedicatedChrome(profileDirectory);
    fs.rmSync(verifiedMarker, {force:true});
    fs.rmSync(loginMarker, {force:true});
    if (fs.existsSync(path.join(profileDirectory, 'Default'))) {
      const {chromium} = require(path.join(request.directory, 'node_modules/playwright-core'));
      const browser = await connectChrome(profileDirectory, chromium);
      await clearAppleLoginData(browser.contexts()[0]);
      await closeDedicatedChrome(profileDirectory);
    }
    fs.writeFileSync(loginMarker, JSON.stringify(profileName), {mode:0o600});
    await launchChrome(profileDirectory, 'login');
    return;
  }
  if (request.mode === 'finish-login') {
    if (!pendingLogin) fail(25);
    await closeDedicatedChrome(profileDirectory);
  } else if (!['purchase','resume-purchase'].includes(request.mode)) { fail(20); }
  else if (pendingLogin) { fail(25); }
  diagnostic.step('连接浏览器');
  const {chromium} = require(path.join(request.directory, 'node_modules/playwright-core'));
  const browser = await connectChrome(profileDirectory, chromium);
  const context = browser.contexts()[0];
  const page = context.pages().find(p => request.mode === 'resume-purchase' ? new URL(p.url()).pathname === '/shop/checkout' : /apple\.com\.cn/.test(p.url())) || await context.newPage();
  page.on('response', response => {
    if (isAppleRequestRejection(response.status(), response.url())) appleRequestRejected = true;
  });
  await page.bringToFront();
  page.setDefaultTimeout(30000);
  const a = id => page.locator(`${id.startsWith('form-field-')?'input':''}[data-autom="${id}"]`);
  const click = async id => {
    if (!['add-to-cart','checkout','fulfillment-continue-button','continue-button-label','continue-button-review','fulfillment-pickup-store-search-button','show-more-stores-button'].includes(id)) fail(20);
    await page.locator(`button[data-autom="${id}"],a[data-autom="${id}"]`).filter({visible:true}).first().click();
  };
  if (request.mode === 'finish-login') {
    await page.goto(accountURL, {waitUntil:'domcontentloaded'});
    try { await page.getByRole('link', {name:/退出登录|注销|Sign Out/i}).first().waitFor({timeout:20000}); }
    catch { fs.rmSync(verifiedMarker, {force:true}); fail(26); }
    if (new URL(page.url()).pathname !== '/shop/account/home') fail(26);
    fs.writeFileSync(verifiedMarker, JSON.stringify(profileName), {mode:0o600});
    fs.unlinkSync(loginMarker);
    return;
  }
  if (context.pages().some(p => { try { return new URL(p.url()).searchParams.get('_s') === 'Review'; } catch { return false; } })) fail(27);
  diagnostic.step('校验取货资料');
  const profile = JSON.parse(fs.readFileSync(path.join(request.directory,'profile.json'), 'utf8'));
  const fields = ['lastName','firstName','emailAddress','fullDaytimePhone','nationalIdSelf'];
  if (fields.some(k => !profile[k]?.trim() || /[*•●]/.test(profile[k])) || !['alipay','wechat'].includes(profile.payment)) fail(20);
  if (!/^[a-z0-9]+\/a$/i.test(request.product) || !request.stores.length || request.stores.some(s=>!/^R\d+$/.test(s))) fail(20);
  // Single-product mode: rebuild the bag to preserve the requested AppleCare configuration.
  const rows = () => page.evaluate(() => [...document.querySelectorAll('[data-autom]')].filter(e=>/^bag-item-\d+$/.test(e.dataset.autom)).map(e=>({
    name:e.querySelector('[data-autom="bag-item-name"],h2,h3')?.textContent||'',
    quantity:e.querySelector('select[data-autom="item-quantity-dropdown"]')?.value||e.innerText.match(/数量\s*(\d+)/)?.[1]||''
  })));
  const expectedName = normalize(request.expectedName || '');
  if (!expectedName) fail(28);
  const verify = async () => { const items = await rows(); if (items.length!==1 || normalize(items[0].name)!==expectedName || items[0].quantity!=='1') fail(11); };
  if (request.mode === 'resume-purchase') {
    const url = new URL(page.url());
    if (!/(^|\.)apple\.com\.cn$/.test(url.hostname) || url.pathname !== '/shop/checkout' || !/^Fulfillment/.test(url.searchParams.get('_s') || '')) fail(20);
    const names = await page.locator('.rs-fulfillment-product-name').allTextContents();
    if (names.length) {
      if (names.length !== 1 || normalize(names[0]) !== expectedName) fail(11);
    } else {
      // Pickup mode hides shipment product names. Verify the same session's bag
      // in a separate page without navigating away from authenticated checkout.
      const checkPage = await context.newPage();
      try {
        await openBag(checkPage);
        const items = await checkPage.locator('[data-autom]').evaluateAll(es => es.filter(e=>/^bag-item-\d+$/.test(e.dataset.autom)).map(e=>({
          name:e.querySelector('[data-autom="bag-item-name"],h2,h3')?.textContent||'',
          quantity:e.querySelector('select[data-autom="item-quantity-dropdown"]')?.value||''
        })));
        if (items.length!==1 || normalize(items[0].name)!==expectedName || items[0].quantity!=='1') fail(11);
      } finally { await checkPage.close(); }
      await page.bringToFront();
    }
  } else {
  diagnostic.step('选择产品规格');
  await page.goto('https://www.apple.com.cn/shop/product/'+request.product.toLowerCase(), {waitUntil:'commit'});
  await a('summary-productName').waitFor();
  diagnostic.step('核对产品名称');
  // The summary can first render a generic model name before the selected SKU settles.
  try {
    await page.waitForFunction(expected => {
      const name = document.querySelector('[data-autom="summary-productName"]')?.innerText || '';
      return name.replace(/\s/g, '') === expected;
    }, expectedName, {timeout:30000});
  } catch (error) { if (error.name === 'TimeoutError') fail(28); throw error; }
  diagnostic.step('检查购物袋');
  await openBag(page);
  diagnostic.step('整理购物袋');
  let previousCount = 0;
  await clearBag({
    empty: () => a('bag-empty-continueshopping-button').isVisible(),
    removeFirst: async () => {
      const remove = a('bag-item-remove-button').filter({visible:true}).first();
      await remove.waitFor();
      previousCount = await page.locator('[data-autom]').evaluateAll(es => es.filter(e => /^bag-item-\d+$/.test(e.dataset.autom)).length);
      await remove.click();
    },
    settled: async () => {
      await page.waitForFunction(previous => {
        if (location.pathname === '/shop/404' || location.pathname === '/shop/541') return true;
        const visible = element => !!element && element.getClientRects().length > 0;
        if (visible(document.querySelector('[data-autom="bag-empty-continueshopping-button"]'))) return true;
        return [...document.querySelectorAll('[data-autom]')].filter(e => /^bag-item-\d+$/.test(e.dataset.autom)).length < previous;
      }, previousCount);
      if (appleRequestRejected) fail(31);
      if (['/shop/404', '/shop/541'].includes(new URL(page.url()).pathname)) fail(32);
    }
  });
  await a('bag-empty-continueshopping-button').waitFor();
  diagnostic.step('返回商品页面');
  await page.goto('https://www.apple.com.cn/shop/product/'+request.product.toLowerCase(), {waitUntil:'commit'});
  await a('summary-productName').waitFor();
  // Recheck after returning; never add a different SKU following a redirect.
  await page.waitForFunction(expected => (document.querySelector('[data-autom="summary-productName"]')?.innerText || '').replace(/\s/g, '') === expected, expectedName);
  diagnostic.step('选择不折抵换购');
  await a('choose-noTradeIn').check();
  diagnostic.step('选择 AppleCare+');
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
  diagnostic.step('核对不折抵换购');
  if (!await a('choose-noTradeIn').isChecked()) fail(29);
  diagnostic.step('加入购物袋');
  await page.waitForLoadState('load');
  await click('add-to-cart');
  await page.waitForURL(u=>u.pathname==='/shop/bag'||u.searchParams.get('step')==='attach'||u.pathname.endsWith('/404')||u.searchParams.has('add-to-cart'), {timeout:60000});
  if (appleRequestRejected) fail(31);
  if (new URL(page.url()).pathname.endsWith('/404') || new URL(page.url()).searchParams.has('add-to-cart')) fail(32);
  await openBag(page);
  await a('checkout').first().waitFor();

  await verify();
  diagnostic.step('进入结账');
  await click('checkout');
  await page.waitForFunction(()=>/signin/i.test(location.href)||document.querySelector('[data-autom="guest-checkout-btn"]')||[...document.querySelectorAll('button')].some(e=>e.innerText.trim()==='我要取货'), null, {timeout:60000});
  if (/signin/i.test(page.url()) || await a('guest-checkout-btn').isVisible()) { fs.rmSync(verifiedMarker, {force:true}); fail(10); }
  }
  diagnostic.step('选择取货地区');
  const pickup=page.getByRole('radio',{name:'我要取货',exact:true});
  if (await pickup.getAttribute('aria-checked')!=='true') await pickup.click();
  const hasPreferredStore = await page.locator('input[name="store-locator-result"]').evaluateAll((es,ids) => es.some(e => ids.includes(e.value)), request.stores);
  if (!hasPreferredStore) {
  // A fresh checkout has no store rows until the user chooses a region.
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
  }
  await page.locator('input[name="store-locator-result"]').first().waitFor({state:'attached',timeout:60000});
  diagnostic.step('选择门店与取货时段');
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
  diagnostic.step('填写取货资料');
  for(const field of fields) { await a('form-field-'+field).fill(profile[field]); await a('form-field-'+field).blur(); }
  // Personal invoice is the website default; do not fill company fields or select business invoicing.
  await click('continue-button-label');
  await page.locator('button[data-autom="continue-button-review"],button[data-autom="continue-button-placeOrder"]').filter({visible:true}).first().waitFor({timeout:60000});
  diagnostic.step('选择付款方式');
  if(!await a('continue-button-placeOrder').isVisible()) {
    const choice=a('checkout-billingOptions-'+profile.payment.toUpperCase());
    await choice.waitFor({state:'attached'});
    if(!await choice.isChecked()) await page.locator(`label[for="${await choice.getAttribute('id')}"]`).click();
    if(!await choice.isChecked()) fail(20);
    await click('continue-button-review');
  }
  diagnostic.step('核对订单');
  await a('continue-button-placeOrder').waitFor({timeout:60000});
  await verify();
  if(new URL(page.url()).searchParams.get('_s')!=='Review') fail(20);
  fs.writeFileSync(verifiedMarker, JSON.stringify(profileName), {mode:0o600});
  // Exit without closing Chrome: review, confirmation and payment belong to the user.
}
module.exports = {browserProfileDirectory, chromeArguments, clearAppleLoginData, profileProcessState, createDiagnostics, clearBag, retryableError, openBag, isAppleRequestRejection};
if (require.main === module) {
let input='', diagnostic;
const finish = (code, error) => { diagnostic?.finish(code, error); process.exit(code); };
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input+=chunk; if(input.length>65536) finish(20); });
process.stdin.on('end', async () => {
  try {
    const request = JSON.parse(input);
    diagnostic = createDiagnostics(request);
    await main(request, diagnostic);
    finish(0);
  } catch (error) { finish(appleRequestRejected ? 31 : Number.isInteger(error.code) ? error.code : retryableError(error, diagnostic?.stage) ? 21 : 20, error); }
});
setTimeout(() => finish(20, {name:'TimeoutError'}), 8*60*1000).unref();
}
