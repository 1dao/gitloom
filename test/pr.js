// Real HTTP/Git PR regression tests. Owns a scratch server and repository.
// Run: node test/pr.js; also included in test/smoke.sh when Node is available.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const {spawn, execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gitloom-pr-'));
const repos = path.join(work, 'repos'), data = path.join(work, 'data'), tmp = path.join(work, 'tmp');
[repos, data, tmp].forEach(p => fs.mkdirSync(p));
const runtime = path.join(root, 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
let server, base, port, count = 0;
const password = 'pr-test-password-123';
const delay = ms => new Promise(r => setTimeout(r, ms));
function git(args, cwd = root) {
    return execFileSync('git', ['-c', 'credential.helper=', '-c', 'credential.interactive=false', ...args],
        {cwd, encoding: 'utf8', env: {...process.env, GIT_TERMINAL_PROMPT: '0',
            GIT_AUTHOR_NAME: 'PR tester', GIT_AUTHOR_EMAIL: 'pr@test.local',
            GIT_COMMITTER_NAME: 'PR tester', GIT_COMMITTER_EMAIL: 'pr@test.local'}, stdio: ['pipe','pipe','pipe']}).trim();
}
function check(label, fn) { fn(); count++; console.log('PASS PR ' + label); }
async function api(method, suffix, body, user = 'admin', expected = 200) {
    const headers = {'Content-Type':'application/json'};
    if (user) headers.Authorization = 'Basic ' + Buffer.from(user + ':' + password).toString('base64');
    const response = await fetch(base + '/api/v1/' + suffix, {method, headers,
        body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000)});
    const text = await response.text();
    if (Array.isArray(expected)) assert(expected.includes(response.status), method+' '+suffix+': '+text);
    else assert.equal(response.status, expected, method + ' ' + suffix + ': ' + text);
    count++; console.log('PASS PR ' + method + ' ' + suffix + ' -> ' + expected);
    return response.status >= 400 ? text : JSON.parse(text);
}
async function start() {
    const fd = fs.openSync(path.join(work, 'server.log'), 'a');
    server = spawn(runtime, ['main.lua', 'LISTEN_PORT='+port, 'REPO_ROOT='+repos,
        'DATA_DIR='+data, 'TMP_DIR='+tmp, 'USERS_FILE='+path.join(data,'users.json'),
        'ADMIN_USER=admin', 'ADMIN_PASSWORD='+password, 'DB_DRIVER=', 'GIT_STREAM=off',
        'AUTH_ALLOW_REGISTRATION=0', 'ANON_READ=1', 'LOG_DIR='+path.join(work,'logs')],
        {cwd: root, stdio: ['ignore',fd,fd], windowsHide:true});
    fs.closeSync(fd);
    for (let i=0;i<100;i++) {
        if (server.exitCode !== null) throw new Error('PR server exited: '+server.exitCode);
        try { const r=await fetch(base+'/api/v1/version', {signal:AbortSignal.timeout(500)}); if (r.ok) return; } catch (_) {}
        await delay(200);
    }
    throw new Error('PR server boot timeout');
}
async function stop() {
    if (!server || server.exitCode !== null) return;
    const stopped = new Promise(resolve => server.once('exit',resolve));
    server.kill(); await stopped;
}
async function main() {
    const socket = net.createServer();
    await new Promise(resolve => socket.listen(0,'127.0.0.1',resolve));
    port = socket.address().port; await new Promise(resolve => socket.close(resolve));
    base = 'http://127.0.0.1:'+port;
    await start();
    await api('POST','users',{username:'bob',password},'admin',201);
    await api('POST','users',{username:'reader',password},'admin',201);
    await api('POST','repos',{name:'pulls'},'admin',201);
    await api('PUT','repos/admin/pulls/collaborators/bob',{permission:'write'});
    await api('PUT','repos/admin/pulls/collaborators/reader',{permission:'read'});
    const bare=path.join(repos,'admin','pulls.git'), local=path.join(work,'client');
    fs.mkdirSync(local); git(['init','-b','main'],local);
    fs.writeFileSync(path.join(local,'base.txt'),'base\n'); git(['add','.'],local); git(['commit','-m','base'],local);
    const first=git(['rev-parse','HEAD'],local);
    git(['checkout','-b','feature'],local);
    fs.writeFileSync(path.join(local,'feature.txt'),'feature\n'); git(['add','.'],local); git(['commit','-m','feature'],local);
    const head=git(['rev-parse','HEAD'],local);
    const remote=base.replace('http://','http://admin:'+password+'@')+'/admin/pulls.git';
    git(['push',remote,'main','feature'],local);
    const pulls='repos/admin/pulls/pulls', pr=pulls+'/1';
    await api('POST',pulls,{title:'test',base:'main',head:'feature'},null,401);
    await api('POST',pulls,{title:'test',base:'main',head:'feature'},'reader',403);
    await api('POST',pulls,{title:'test',base:'main',head:'missing'},'bob',409);
    await api('POST',pulls,{title:'test',base:'main',head:'bad\nbranch'},'bob',400);
    await api('POST',pulls,{title:'test',base:'main',head:'main'},'bob',400);
    const created=await api('POST',pulls,{title:'Contributor change',base:'main',head:'feature'},'bob',201);
    check('contributor creates request',()=>assert.equal(created.number,1));
    await api('POST',pulls,{title:'duplicate',base:'main',head:'feature'},'bob',409);
    const shown=await api('GET',pr,undefined,null);
    check('public detail has stable arrays and OIDs',()=>{
        assert.deepEqual(shown.comments,[]); assert.deepEqual(shown.reviews,[]);
        assert.equal(shown.head_oid,head); assert.equal(shown.base_oid,first);
    });
    const compared=await api('GET','repos/admin/pulls/compare/'+first+'/'+head,undefined,'admin');
    check('review compares exact commits',()=>assert.equal(compared.ahead,1));
    let review={state:'approve',base_oid:first,head_oid:head};
    await api('POST',pr+'/reviews',review,'bob',403);
    await api('POST',pr+'/reviews',review,'reader',403);
    await api('PATCH',pr,{state:'merged'},'bob',400);
    await api('POST',pr+'/merge',{},'admin',400);
    await api('POST',pr+'/comments',{body:'Review discussion'},'reader');
    await api('POST',pr+'/reviews',{...review,state:'request_changes',body:''},'admin',400);
    const changes=await api('POST',pr+'/reviews',{...review,state:'request_changes',body:'Please update'},'admin');
    check('request changes retains open state',()=>assert.equal(changes.state,'open'));
    await api('PATCH',pr,{state:'closed'},'bob');
    await api('POST',pr+'/reviews',review,'admin',409);
    await api('PATCH',pr,{state:'open'},'bob');
    fs.writeFileSync(path.join(local,'feature.txt'),'updated\n'); git(['add','.'],local); git(['commit','-m','update'],local);
    const newHead=git(['rev-parse','HEAD'],local); git(['push',remote,'feature'],local);
    await api('POST',pr+'/reviews',review,'admin',409);
    check('stale review leaves target unchanged',()=>assert.equal(git(['rev-parse','main'],bare),first));
    // A failed journal write must not mutate the cached record or any Git ref.
    const blocked=path.join(data,'pull_requests.json.tmp');fs.mkdirSync(blocked);
    fs.writeFileSync(path.join(blocked,'block'),'prevent atomic file staging');
    try {
        await api('POST',pr+'/comments',{body:'must not be saved'},'reader',500);
        const unchanged=await api('GET',pr);
        check('failed persistence preserves cached discussion',()=>assert.equal(unchanged.comments.length,1));
        await api('POST',pr+'/reviews',{...review,head_oid:newHead},'admin',500);
        check('failed journal write leaves target unchanged',()=>assert.equal(git(['rev-parse','main'],bare),first));
    } finally { fs.rmSync(blocked,{recursive:true,force:true}); }
    const attempts=await Promise.all([0,1].map(()=>api('POST',pr+'/reviews',
        {...review,head_oid:newHead},'admin',[200,409])));
    const merged=attempts.find(p=>p.state==='merged');
    check('concurrent approvals merge exactly once',()=>assert.equal(attempts.filter(p=>p.state==='merged').length,1));
    check('approval creates real two-parent merge',()=>{
        assert.equal(merged.state,'merged'); assert.equal(git(['rev-parse','main'],bare),merged.merge_oid);
        assert.equal(git(['show','-s','--format=%P',merged.merge_oid],bare),first+' '+newHead);
        assert.equal(git(['show','main:feature.txt'],bare),'updated');
    });
    await api('PATCH',pr,{state:'open'},'bob',409);
    await api('POST',pr+'/reviews',{...review,head_oid:newHead},'admin',409);
    const advertised=git(['ls-remote',remote],local);
    check('internal merge markers are hidden',()=>assert(!advertised.includes('refs/gitloom/')));
    try {git(['push',remote,'main:refs/gitloom/forbidden'],local); throw new Error('hidden ref push succeeded');}
    catch(e) {assert(!String(e.message).includes('hidden ref push succeeded')); count++;console.log('PASS PR hidden refs reject pushes');}
    await stop(); await start();
    const restored=await api('GET',pr);
    check('stored merge and review survive restart',()=>{
        assert.equal(restored.merge_oid,merged.merge_oid); assert.equal(restored.reviews.at(-1).state,'approve');
    });
    // Real conflicting branches, built from a common ancestor without moving main.
    git(['checkout','-b','conflict-base',first],local); fs.writeFileSync(path.join(local,'base.txt'),'target\n');
    git(['add','.'],local);git(['commit','-m','target conflict'],local);const conflictBase=git(['rev-parse','HEAD'],local);
    git(['checkout','-b','conflict-head',first],local);fs.writeFileSync(path.join(local,'base.txt'),'source\n');
    git(['add','.'],local);git(['commit','-m','source conflict'],local);const conflictHead=git(['rev-parse','HEAD'],local);
    git(['push',remote,'conflict-base','conflict-head'],local);
    await api('POST',pulls,{title:'Conflict',base:'conflict-base',head:'conflict-head'},'bob',201);
    await api('POST',pulls+'/2/reviews',{state:'approve',base_oid:conflictBase,head_oid:conflictHead},'admin',409);
    check('conflict cannot update the target',()=>assert.equal(git(['rev-parse','conflict-base'],bare),conflictBase));
    // A target update invalidates a review even if the source remains unchanged.
    git(['checkout','conflict-base'],local);fs.writeFileSync(path.join(local,'other.txt'),'new target\n');
    git(['add','.'],local);git(['commit','-m','target advance'],local);git(['push',remote,'conflict-base'],local);
    await api('POST',pulls+'/2/reviews',{state:'approve',base_oid:conflictBase,head_oid:conflictHead},'admin',409);
    count++;console.log('PASS PR target update invalidates review');
    await api('PATCH',pulls+'/2',{state:'closed'},'bob');
    await api('POST',pulls,{title:'Replacement conflict',base:'conflict-base',head:'conflict-head'},'bob',201);
    await api('PATCH',pulls+'/2',{state:'open'},'bob',409);
    await api('PATCH',pulls+'/3',{state:'closed'},'bob');
    await api('PATCH',pulls+'/2',{state:'open'},'bob');
    git(['update-ref','refs/heads/external-base',first],bare);
    git(['update-ref','refs/heads/external-head',newHead],bare);
    await api('POST',pulls,{title:'External merge',base:'external-base',head:'external-head'},'bob',201);
    git(['update-ref','refs/heads/external-base',newHead],bare);
    await api('POST',pulls+'/4/reviews',{state:'approve',base_oid:newHead,head_oid:newHead},'admin',409);
    check('already included source cannot create redundant merge',()=>assert.equal(git(['rev-parse','external-base'],bare),newHead));
    // Reconcile both crash windows from durable pending records on restart.
    await stop();
    const file=path.join(data,'pull_requests.json');const records=JSON.parse(fs.readFileSync(file,'utf8'));
    const p=records['admin/pulls']['1'];p.state='open';p.pending={oid:merged.merge_oid,actor:'admin',at:123,
        base_oid:first,head_oid:newHead};p.reviews.at(-1).state='merging';
    const conflict=records['admin/pulls']['2'];conflict.pending={oid:conflictHead,actor:'admin',at:124,
        base_oid:conflictBase,head_oid:conflictHead};if (!Array.isArray(conflict.reviews)) conflict.reviews=[];conflict.reviews.push({author:'admin',state:'merging',body:'',created_at:124});
    fs.writeFileSync(file,JSON.stringify(records)); await start();
    await api('PATCH','repos/admin/pulls',{name:'renamed'},'admin',409);
    await api('DELETE','repos/admin/pulls',undefined,'admin',409);
    const recovered=await api('GET',pr);
    check('committed pending merge reconciles',()=>{assert.equal(recovered.state,'merged');assert.equal(recovered.merging,false);});
    const failed=await api('GET',pulls+'/2');
    check('uncommitted pending merge reconciles',()=>{assert.equal(failed.state,'open');assert.equal(failed.reviews.at(-1).state,'merge_failed');});
    await api('PATCH','repos/admin/pulls',{name:'renamed'});
    const moved=await api('GET','repos/admin/renamed/pulls/1');
    check('rename carries PR history',()=>assert.equal(moved.merge_oid,merged.merge_oid));
    await api('DELETE','repos/admin/renamed');
    await api('POST','repos',{name:'renamed'},'admin',201);
    const empty=await api('GET','repos/admin/renamed/pulls');
    check('recreated repository does not inherit deleted PRs',()=>assert.deepEqual(empty.pull_requests,[]));
    await api('POST','repos',{name:'private',private:true},'admin',201);
    await api('GET','repos/admin/private/pulls',undefined,null,404);
    await api('GET','repos/admin/private/pulls',undefined,'bob',404);
    count++;console.log('PASS PR private repository visibility');
    console.log('[pr] '+count+' passed, 0 failed');
}
main().catch(error=>{
    console.error('FAIL PR',error.stack);
    console.error(fs.readFileSync(path.join(work,'server.log'),'utf8').split('\n').filter(line=>!/recovery code for|password|token/i.test(line)).slice(-30).join('\n'));process.exitCode=1;
}).finally(async()=>{
    await stop();
    if (process.exitCode) console.error('PR scratch evidence: '+work);
    else fs.rmSync(work,{recursive:true,force:true});
});
