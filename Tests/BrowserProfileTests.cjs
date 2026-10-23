const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {browserProfileDirectory, chromeArguments, clearAppleLoginData, profileProcessState, createDiagnostics, clearBag, retryableError, openBag, isAppleRequestRejection} = require('../AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'browser-profile-test-'));
try {
  const profile = path.join(directory, 'chrome-profile');
  assert.equal(profileProcessState('Z <defunct>', profile), false, 'exiting Chrome is not an ownership failure');
  assert.equal(profileProcessState('', profile), false, 'already exited process is stopped');
  assert.equal(profileProcessState('S /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=' + profile, profile), true);
  assert.throws(() => profileProcessState('S /usr/bin/other --user-data-dir=' + profile, profile));
  assert.throws(() => profileProcessState('S /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=' + profile + '-other', profile));
  const loginArgs = chromeArguments(profile, 'login');
  assert(!loginArgs.some(arg => arg.startsWith('--remote-debugging')), 'manual login must not enable debugging');
  assert(loginArgs.includes('--user-data-dir=' + profile));
  assert(loginArgs.includes('https://secure.www.apple.com.cn/shop/account/home'));
  const purchaseArgs = chromeArguments(profile, 'purchase', 19223);
  assert(purchaseArgs.includes('--remote-debugging-port=19223'));
  assert.throws(() => chromeArguments(profile, 'purchase', 0));
  assert.throws(() => chromeArguments(profile, 'purchase', 65536));
  assert(purchaseArgs.includes('--user-data-dir=' + profile), 'checkout reuses the manual login profile');
  assert.equal(browserProfileDirectory(directory), path.join(directory, 'chrome-profile'));
  const selection = path.join(directory, 'browser-profile.json');
  fs.writeFileSync(selection, JSON.stringify('chrome-profile-1234-abcd'));
  assert.equal(browserProfileDirectory(directory), path.join(directory, 'chrome-profile-1234-abcd'));
  for (const invalid of ['../other-profile', '/tmp/other-profile', null, 42, '']) {
    fs.writeFileSync(selection, JSON.stringify(invalid));
    assert.throws(() => browserProfileDirectory(directory));
  }
  fs.writeFileSync(selection, JSON.stringify('chrome-profile-1234-abcd'));
  const run = mode => spawnSync(process.execPath, [path.resolve(__dirname, '../AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs')], {
    input: JSON.stringify({mode, directory}), encoding: 'utf8', timeout: 5000
  }).status;
  assert.equal(run('finish-login'), 25, 'completion needs an explicit pending login');
  const diagnosticID = '00000000-0000-4000-8000-000000000001';
  const diagnosed = spawnSync(process.execPath, [path.resolve(__dirname, '../AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs')], {
    input: JSON.stringify({mode: 'finish-login', directory, diagnosticID}), encoding: 'utf8', timeout: 5000
  });
  assert.equal(diagnosed.status, 25);
  const diagnostic = JSON.parse(fs.readFileSync(path.join(directory, 'Diagnostics', diagnosticID + '.json'), 'utf8'));
  assert.equal(diagnostic.code, 25);
  assert.equal(diagnostic.stage, '登录检查');
  assert.equal(diagnostic.category, 'stopped');
  assert(diagnostic.events.length > 0);
  assert(!JSON.stringify(diagnostic).includes(directory), 'diagnostics exclude local profile paths');
  const timeoutDiagnostic = createDiagnostics({directory, diagnosticID});
  timeoutDiagnostic.step('选择门店与取货时段');
  timeoutDiagnostic.finish(20, {name:'TimeoutError', message:'PRIVATE_FORM_VALUE', stack:'PRIVATE_URL'});
  const timeoutText = fs.readFileSync(path.join(directory, 'Diagnostics', diagnosticID + '.json'), 'utf8');
  assert.equal(JSON.parse(timeoutText).category, 'timeout');
  assert.equal(JSON.parse(timeoutText).stage, '选择门店与取货时段');
  assert(!timeoutText.includes('PRIVATE_'), 'raw browser errors must not enter diagnostics');
  const marker = path.join(directory, 'manual-login.json');
  fs.writeFileSync(marker, JSON.stringify('chrome-profile-1234-abcd'));
  assert.equal(run('purchase'), 25, 'pending manual authentication cannot trigger checkout');
  fs.symlinkSync(os.hostname() + '-' + process.pid, path.join(directory, 'chrome-profile-1234-abcd', 'SingletonLock'));
  assert.equal(run('finish-login'), 24, 'refuse to signal a process that is not the dedicated Chrome');
  assert.equal(run('login'), 24, 'refuse to open login in an unidentified running browser');
  fs.writeFileSync(selection, '{invalid');
  assert.throws(() => browserProfileDirectory(directory));
  console.log('PASS: profile selection, ordinary login launch, checkout handoff gates and process ownership checks');
} finally {
  fs.rmSync(directory, {recursive: true, force: true});
}

(async () => {
  assert(isAppleRequestRejection(541, 'https://www.apple.com.cn/shop/bagx'));
  assert(!isAppleRequestRejection(200, 'https://www.apple.com.cn/shop/404'));
  assert(!isAppleRequestRejection(541, 'https://fakeapple.com.cn/shop/bagx'));
  let navigations = 0, readyWaits = 0;
  const ready = {filter(){return this;}, first(){return this;}, isVisible:async()=>true, waitFor:async()=>{readyWaits++;}};
  const bagPage = {url:()=> 'https://www.apple.com.cn/shop/bag', locator:()=>ready, goto:async()=>{navigations++;}};
  await openBag(bagPage);
  assert.equal(navigations, 0, 'already rendered empty bag must not reload on retry');
  bagPage.url = () => 'https://www.apple.com.cn/shop/product/example';
  bagPage.goto = async (url, options) => { assert.equal(options.waitUntil, 'commit'); navigations++; };
  await openBag(bagPage);
  assert.equal(navigations, 1);
  assert.equal(readyWaits, 1, 'wait for bag UI instead of whole document lifecycle');
  let bag = ['other', 'target', 'extra'], removed = 0;
  await clearBag({empty:async()=>bag.length===0, removeFirst:async()=>{bag.shift();removed++;}, settled:async()=>{}});
  assert.equal(removed, 3, 'remove all rows despite renumbering');
  await clearBag({empty:async()=>true, removeFirst:async()=>assert.fail('empty bag is unchanged'), settled:async()=>{}});
  await assert.rejects(clearBag({empty:async()=>false, removeFirst:async()=>{}, settled:async()=>{}}), e=>e.code===11, 'stuck bag cannot loop forever');
  assert(retryableError({name:'TimeoutError'}, '选择门店与取货时段'));
  assert(retryableError({message:'net::ERR_CONNECTION_RESET'}, '检查购物袋'));
  for (const stage of ['填写取货资料','选择付款方式','核对订单']) assert(!retryableError({name:'TimeoutError'}, stage));
  assert(!retryableError({name:'Error',message:'Unexpected selector'}, '检查购物袋'));
  console.log('PASS: bag clearing, bounded mutation and retry classification');
  const calls = [], blanked = [];
  const page = {
    frames: () => [{url: () => 'https://secure7.www.apple.com.cn/shop/account/home'}, {url: () => 'https://example.org/'}],
    goto: async url => blanked.push(url)
  };
  const context = {
    pages: () => [page],
    clearCookies: async filter => calls.push(['cookies', filter.domain]),
    newCDPSession: async () => ({send: async (method,args) => calls.push([method,args]), detach: async () => {}})
  };
  await clearAppleLoginData(context);
  assert.deepEqual(blanked, ['about:blank'], 'unload pages before clearing login data');
  const filter = calls.find(c => c[0] === 'cookies')[1];
  assert(filter.test('.apple.com.cn') && filter.test('idmsa.apple.com'));
  assert(!filter.test('example.org') && !filter.test('fakeapple.com.cn'));
  const origins = calls.filter(c => c[0] === 'Storage.clearDataForOrigin').map(c => c[1].origin);
  assert(origins.includes('https://secure7.www.apple.com.cn'));
  assert(!origins.includes('https://example.org'), 'other sites retain their storage');
  assert(calls.some(c => c[0] === 'Network.clearBrowserCache'));
  console.log('PASS: relogin clears Apple data through Chrome APIs without replacing the profile');
})().catch(error => { console.error(error); process.exitCode = 1; });
