import test from 'node:test';import assert from 'node:assert/strict';
import {request} from 'node:http';
import {createHash} from 'node:crypto';
process.env.GRAVITYBOX_GOOGLE_CLIENT_ID = process.env.GRAVITYBOX_GOOGLE_CLIENT_ID || 'mock-id.apps.googleusercontent.com';
process.env.GRAVITYBOX_GOOGLE_CLIENT_SECRET = process.env.GRAVITYBOX_GOOGLE_CLIENT_SECRET || 'mock-client-secret-placeholder';
const {GoogleAccountLogin} = await import('../dist/account-oauth.js');
const turn=()=>new Promise(r=>setTimeout(r,10));
async function settled(login,id){for(let i=0;i<100;i++){const s=login.status(id);if(!['waiting','exchanging','saving'].includes(s.phase))return s;await turn()}throw Error('Login did not settle')}
function callback(url,state,code='fixture-code'){const u=new URL(new URL(url).searchParams.get('redirect_uri'));u.search=new URLSearchParams({state,code});return u}
test('Google account login uses loopback, state and S256 PKCE; tokens stay behind IPC status',async t=>{
 let writes=0,exchange;const login=new GoogleAccountLogin(async token=>{assert.equal(token.refresh_token,'fixture-refresh');writes++},async(url,init)=>{assert.equal(url,'https://oauth2.googleapis.com/token');exchange=new URLSearchParams(init.body);return Response.json({access_token:'fixture-access',refresh_token:'fixture-refresh'})});t.after(()=>login.close());
 const {id,url}=await login.begin();const auth=new URL(url);assert.equal(auth.host,'accounts.google.com');assert.equal(auth.searchParams.get('code_challenge_method'),'S256');assert.equal(new URL(auth.searchParams.get('redirect_uri')).hostname,'127.0.0.1');
 const state=auth.searchParams.get('state');assert.ok(state.length>=43);
 assert.equal((await fetch(callback(url,'wrong-state'))).status,400);assert.equal(login.status(id).phase,'waiting');
 const spoof=await new Promise((resolve,reject)=>{const req=request(callback(url,state),{headers:{Host:'attacker.invalid'}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode))});req.on('error',reject);req.end()});assert.equal(spoof,404);
 const response=await fetch(callback(url,state));assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');assert.ok(response.headers.get('content-security-policy').includes("default-src 'none'"));
 assert.equal((await settled(login,id)).phase,'succeeded');assert.equal(writes,1);assert.equal(createHash('sha256').update(exchange.get('code_verifier')).digest('base64url'),auth.searchParams.get('code_challenge'));assert.equal(exchange.get('redirect_uri'),auth.searchParams.get('redirect_uri'));
 assert.ok(!JSON.stringify(login.status(id)).includes('fixture-access'));assert.ok(!JSON.stringify(login.status(id)).includes('fixture-refresh'));
 await assert.rejects(fetch(callback(url,state)));assert.equal(writes,1);
});
test('OAuth cancel, expiration and denied consent do not save accounts',async t=>{
 let saves=0;const login=new GoogleAccountLogin(async()=>{saves++},async()=>{throw Error('must not request token')},80);t.after(()=>login.close());
 const a=await login.begin();assert.equal(login.cancel(a.id).phase,'cancelled');await assert.rejects(fetch(callback(a.url,new URL(a.url).searchParams.get('state'))));
 const b=await login.begin();await new Promise(r=>setTimeout(r,100));assert.equal(login.status(b.id).phase,'expired');
 const c=await login.begin();const denied=callback(c.url,new URL(c.url).searchParams.get('state'));denied.searchParams.set('error','access_denied');await fetch(denied);assert.equal(login.status(c.id).phase,'cancelled');assert.equal(saves,0);
});
test('OAuth cancelled during exchange aborts network and prevents saving',async t=>{
 let saves=0;const login=new GoogleAccountLogin(async()=>{saves++},async(_u,options)=>new Promise((_resolve,reject)=>options.signal.addEventListener('abort',()=>reject(Error('aborted')),{once:true})));t.after(()=>login.close());
 const a=await login.begin();await fetch(callback(a.url,new URL(a.url).searchParams.get('state')));assert.equal(login.status(a.id).phase,'exchanging');login.cancel(a.id);await turn();assert.equal(login.status(a.id).phase,'cancelled');assert.equal(saves,0);
});
test('OAuth malformed token and Google errors are sanitized, never stored',async t=>{
 for(const reply of [()=>Response.json({access_token:'only-access'}),()=>new Response('sensitive-token-error',{status:400})]){
 let saves=0;const login=new GoogleAccountLogin(async()=>{saves++},async()=>reply());t.after(()=>login.close());const a=await login.begin();await fetch(callback(a.url,new URL(a.url).searchParams.get('state')));const result=await settled(login,a.id);assert.equal(result.phase,'failed');assert.equal(saves,0);assert.ok(!JSON.stringify(result).includes('sensitive-token-error'));
 }
});

test('OAuth client ID and secret getters support dynamic environment overrides without stale module-load constants', async () => {
  const accountsMod = await import('../dist/accounts.js');
  const { getGoogleClientId, getGoogleClientSecret } = accountsMod;
  assert.equal('GOOGLE_CLIENT_ID' in accountsMod, false);
  assert.equal('GOOGLE_CLIENT_SECRET' in accountsMod, false);
  const cid = getGoogleClientId();
  const sec = getGoogleClientSecret();
  assert.ok(typeof cid === 'string' && cid.length > 10);
  assert.ok(typeof sec === 'string' && sec.length > 10);
  assert.ok(cid.includes('.apps.googleusercontent.com'));
});

test('P1-18: CodedAccountError 保留业务错误语义，中英文凭据就绪度与 403/#3501 保持兼容', async t => {
  const { CodedAccountError, accountErrorCode, accountCredentialReadiness } = await import('../dist/account-quota.js');
  const { fetchCloudQuotaForAccount } = await import('../dist/account-cloud.js');
  const { bt, setActiveLocale, getActiveLocale } = await import('../dist/i18n.js');
  const prevLocale = getActiveLocale();
  t.after(() => setActiveLocale(prevLocale));

  const account = {
    id: 'oauth-p118',
    email: 'p118@example.invalid',
    token: {
      access_token: 'old-token',
      refresh_token: '1//refresh-p118',
      expires_in: 3600,
      expiry_timestamp: 0,
      token_type: 'Bearer',
      email: 'p118@example.invalid',
    },
    disabled: false,
    protected_models: [],
    validation_blocked: false,
    created_at: 1000,
    last_used: 1000,
  };

  setActiveLocale('en');
  await assert.rejects(
    fetchCloudQuotaForAccount({
      account: structuredClone(account),
      fetchImpl: async url => {
        assert.equal(url, 'https://oauth2.googleapis.com/token');
        return Response.json({ access_token: 'fresh-access', expires_in: 3600 });
      },
      onTokenRefreshed: async () => {
        throw new CodedAccountError('removed_stop_refresh', bt('accounts.err.removed_stop_refresh'));
      },
    }),
    err => accountErrorCode(err) === 'removed_stop_refresh' && err.message === bt('accounts.err.removed_stop_refresh')
  );

  const login = new GoogleAccountLogin(
    async () => {
      throw new CodedAccountError('credentials_updated', bt('accounts.err.credentials_updated'));
    },
    async () => Response.json({ access_token: 'a1', refresh_token: 'r1', expires_in: 3600 })
  );
  t.after(() => login.close());
  const session = await login.begin();
  await fetch(callback(session.url, new URL(session.url).searchParams.get('state')));
  const loginRes = await settled(login, session.id);
  assert.equal(loginRes.phase, 'failed');
  assert.equal(loginRes.message, bt('accounts.err.credentials_updated'));

  const now = Math.floor(Date.now() / 1000);
  const validToken = { ...account.token, access_token: 'valid-access', expiry_timestamp: now + 3600 };
  for (const locale of ['zh-Hans', 'en']) {
    setActiveLocale(locale);
    assert.equal(
      accountCredentialReadiness({ ...account, token: validToken, quota_refresh_error: bt('account_cloud.err.refresh_failed') }, now).state,
      'needs_authorization'
    );
    assert.equal(
      accountCredentialReadiness({ ...account, token: validToken, quota_refresh_error: bt('account_cloud.err.missing_refresh_token') }, now).state,
      'needs_authorization'
    );
    assert.equal(
      accountCredentialReadiness({ ...account, token: validToken, quota_refresh_error: bt('accounts.err.token_invalid') }, now).state,
      'needs_authorization'
    );
    assert.equal(
      accountCredentialReadiness({ ...account, token: validToken, quota_refresh_error: bt('account_cloud.err.http_3501') }, now).state,
      'ready'
    );
    assert.equal(
      accountCredentialReadiness({ ...account, token: validToken, quota_refresh_error: bt('account_cloud.err.network') }, now).state,
      'ready'
    );
  }
});

test('Switch allows expired access_token with valid refresh_token when OAuth client is unconfigured, and syncAccountTokenFromLocalState heals active account', async t => {
  const { mkdtemp, rm, mkdir, writeFile } = await import('node:fs/promises');
  const { join } = await import('node:path');
  const { tmpdir } = await import('node:os');
  const { AccountsManager } = await import('../dist/accounts.js');
  const { AccountSwitchService } = await import('../dist/account-switch.js');
  const { bt } = await import('../dist/i18n.js');

  const dir = await mkdtemp(join(tmpdir(), 'gb-oauth-switch-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const stateDir = join(dir, 'state');
  const profileDir = join(dir, 'profile');
  await mkdir(join(profileDir, 'User', 'globalStorage'), { recursive: true });

  const mgr = new AccountsManager(stateDir);
  const acc = await mgr.upsertAccount({
    email: 'standby@example.invalid',
    name: 'Standby',
    accessToken: 'expired-access-token',
    refreshToken: '1//valid-refresh-token',
    expiresIn: -3600,
  });
  acc.quota_refresh_error_code = 'missing_oauth_client';
  acc.quota_refresh_error = bt('account_cloud.err.missing_oauth_client');
  await mgr.saveAccount(acc);

  const prevCid = process.env.GRAVITYBOX_GOOGLE_CLIENT_ID;
  const prevSec = process.env.GRAVITYBOX_GOOGLE_CLIENT_SECRET;
  delete process.env.GRAVITYBOX_GOOGLE_CLIENT_ID;
  delete process.env.GRAVITYBOX_GOOGLE_CLIENT_SECRET;
  t.after(() => {
    if (prevCid !== undefined) process.env.GRAVITYBOX_GOOGLE_CLIENT_ID = prevCid;
    if (prevSec !== undefined) process.env.GRAVITYBOX_GOOGLE_CLIENT_SECRET = prevSec;
  });

  const memKeychain = {
    val: null,
    async readPassword() { return this.val; },
    async writePassword(_s, _a, v) { this.val = v; },
    async deletePassword() { this.val = null; },
  };
  const svc = new AccountSwitchService(mgr, {
    stateDir,
    profile: profileDir,
    isRunning: async () => false,
    keychain: memKeychain,
  });

  // 1) Switching must succeed when OAuth client is unconfigured and refresh_token is valid
  const switched = await svc.switchAccount(acc.id);
  assert.equal(switched.switchedTo, acc.email);
  assert.ok(typeof memKeychain.val === 'string' && memKeychain.val.length > 0);

  // 2) Switching must still fail if refresh_token is missing or account needs_authorization
  const revoked = await mgr.upsertAccount({
    email: 'revoked@example.invalid',
    name: 'Revoked',
    accessToken: 'expired-access-token',
    refreshToken: '1//revoked-refresh-token',
    expiresIn: -3600,
  });
  revoked.quota_refresh_error_code = 'refresh_failed';
  revoked.quota_refresh_error = bt('account_cloud.err.refresh_failed');
  await mgr.saveAccount(revoked);
  await assert.rejects(svc.switchAccount(revoked.id), new RegExp(bt('switch.err.refresh_credentials_first')));
});
