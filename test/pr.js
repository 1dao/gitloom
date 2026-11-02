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
let repos = path.join(work, 'repos'), data = path.join(work, 'data');
const tmp = path.join(work, 'tmp');
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
async function start(extra = []) {
    const fd = fs.openSync(path.join(work, 'server.log'), 'a');
    server = spawn(runtime, ['main.lua', 'LISTEN_PORT='+port, 'REPO_ROOT='+repos,
        'DATA_DIR='+data, 'TMP_DIR='+tmp, 'USERS_FILE='+path.join(data,'users.json'),
        'ADMIN_USER=admin', 'ADMIN_PASSWORD='+password, 'DB_DRIVER=', 'GIT_STREAM=off',
        'AUTH_ALLOW_REGISTRATION=0', 'ANON_READ=1', 'LOG_DIR='+path.join(work,'logs'), ...extra],
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
function snapshot(command, archive, repoRoot = repos, dataRoot = data, expected = 0) {
    const args = [path.join(root, 'deploy/backup.py'), command, archive, '--offline',
        '-D', 'LISTEN_HOST=127.0.0.1', '-D', 'LISTEN_PORT='+port,
        '-D', 'REPO_ROOT='+repoRoot, '-D', 'DATA_DIR='+dataRoot,
        '-D', 'USERS_FILE='+path.join(dataRoot,'users.json'), '-D', 'DB_DRIVER=none'];
    const {spawnSync} = require('node:child_process');
    const result = spawnSync(process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),
        args, {cwd:root, encoding:'utf8', windowsHide:true});
    assert.equal(result.status, expected, result.stderr || result.error?.message);
    count++; console.log('PASS snapshot '+command+' -> '+expected);
    return result;
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
    const approved=await api('POST',pr+'/reviews',{...review,head_oid:newHead});
    check('approval records a conclusion without merging',()=>{
        assert.equal(approved.state,'open');assert.equal(git(['rev-parse','main'],bare),first);
    });
    const attempts=await Promise.all([0,1].map(()=>api('POST',pr+'/merge',
        {base_oid:first,head_oid:newHead},'admin',[200,409])));
    const merged=attempts.find(p=>p.state==='merged');
    check('concurrent merge operations update exactly once',()=>assert.equal(attempts.filter(p=>p.state==='merged').length,1));
    check('explicit merge creates real two-parent merge',()=>{
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
    await api('POST',pulls+'/2/reviews',{state:'approve',base_oid:conflictBase,head_oid:conflictHead});
    await api('POST',pulls+'/2/merge',{base_oid:conflictBase,head_oid:conflictHead},'admin',409);
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
    await api('POST',pulls+'/4/reviews',{state:'approve',base_oid:newHead,head_oid:newHead});
    await api('POST',pulls+'/4/merge',{base_oid:newHead,head_oid:newHead},'admin',409);
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
    await api('PATCH','users/bob',{disabled:true});
    await stop(); await start();
    await api('GET','user',undefined,'bob',401);
    const accounts=await api('GET','users');
    check('disabled account survives restart',()=>assert.equal(accounts.users.find(u=>u.username==='bob').disabled,true));
    await api('PATCH','users/bob',{disabled:false});
    await api('GET','user',undefined,'bob');
    await api('POST','organizations',{slug:'company',name:'Internal team'},'admin',201);
    await api('PUT','organizations/company/members/bob',{role:'member'});
    await api('POST','organizations/company/teams',{name:'developers'},'admin',201);
    await api('PUT','organizations/company/teams/developers/members/bob',{role:'member'});
    await api('POST','repos',{owner:'company',name:'snapshot',private:true},'admin',201);
    await api('PUT','repos/company/snapshot/teams/developers',{permission:'write'});
    const savedRemote=base.replace('http://','http://admin:'+password+'@')+'/company/snapshot.git';
    git(['push',savedRemote,'main','feature'],local);
    await api('POST','repos/company/snapshot/issues',{title:'Preserve this issue',body:'Backup discussion'},'bob',201);
    await api('POST','repos/company/snapshot/pulls',{title:'Preserve this PR',base:'main',head:'feature'},'bob',201);
    await api('PATCH','users/reader',{disabled:true});
    const archive=path.join(work,'snapshot.zip');
    check('snapshot refuses an active server',()=>assert.match(snapshot('backup',archive,repos,data,1).stderr,/listener is active/));
    await stop();
    snapshot('backup',archive);
    check('snapshot never overwrites an archive',()=>assert.match(snapshot('backup',archive,repos,data,1).stderr,/exist/i));
    snapshot('restore',archive,repos,data,1);
    const restoreRoot=path.join(work,'restored');
    const newRepos=path.join(restoreRoot,'repos'), newData=path.join(restoreRoot,'data');
    const python=process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
    execFileSync(python,['-c',`
import hashlib,json,sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as source:
    entries={name:source.read(name) for name in source.namelist()}
for mode in ('checksum','traversal'):
    changed=dict(entries)
    if mode=='checksum':
        changed['accounts.json']=b'corrupt account data'
    else:
        changed['../escaped.txt']=b'escape'
        manifest=json.loads(changed['manifest.json'])
        manifest['files']['../escaped.txt']={'size':6,'sha256':hashlib.sha256(b'escape').hexdigest()}
        changed['manifest.json']=json.dumps(manifest).encode()
    with zipfile.ZipFile(sys.argv[1]+'.'+mode,'w') as output:
        for name,body in changed.items(): output.writestr(name,body)
`,archive],{windowsHide:true});
    for (const mode of ['checksum','traversal']) {
        const rejected=snapshot('restore',archive+'.'+mode,newRepos,newData,1);
        check('restore rejects '+mode+' before writing',()=>{
            assert.match(rejected.stderr,/checksum mismatch|unsafe snapshot entry/);
            assert.equal(fs.existsSync(newRepos),false);assert.equal(fs.existsSync(newData),false);
            assert.equal(fs.existsSync(path.join(work,'escaped.txt')),false);
        });
    }
    snapshot('restore',archive,newRepos,newData);
    git(['fsck','--full'],path.join(newRepos,'company','snapshot.git'));
    git(['fsck','--full'],path.join(newRepos,'admin','renamed.git'));
    check('restore preserves empty bare repositories',()=>assert.equal(git(['rev-parse','--is-bare-repository'],path.join(newRepos,'admin','renamed.git')),'true'));
    check('restored branch objects match',()=>assert.equal(git(['rev-parse','feature'],path.join(newRepos,'company','snapshot.git')),newHead));
    repos=newRepos;data=newData;await start();
    await api('GET','user',undefined,'reader',401);
    await api('GET','repos/company/snapshot',undefined,'bob');
    const restoredIssue=await api('GET','repos/company/snapshot/issues/1',undefined,'bob');
    check('restore preserves issues',()=>assert.equal(restoredIssue.title,'Preserve this issue'));
    const restoredPr=await api('GET','repos/company/snapshot/pulls/1',undefined,'bob');
    check('restore preserves pull requests',()=>assert.equal(restoredPr.title,'Preserve this PR'));
    const restoredTeams=await api('GET','organizations/company/teams');
    check('restore preserves team membership',()=>assert.equal(restoredTeams.teams[0].members.bob,'member'));
    const protectedRepo='repos/company/snapshot';
    const indexFile=path.join(repos,'index.json');
    fs.renameSync(indexFile,indexFile+'.saved');fs.mkdirSync(indexFile);
    await api('PATCH',protectedRepo,{require_pr:true,merge_users:['bob']},'admin',500);
    const unchangedPolicy=await api('GET',protectedRepo);
    check('failed policy persistence never publishes permissions',()=>{
        assert.equal(unchangedPolicy.require_pr,false);assert.deepEqual(unchangedPolicy.merge_users,[]);
    });
    fs.rmdirSync(indexFile);fs.renameSync(indexFile+'.saved',indexFile);
    await api('PATCH',protectedRepo,{require_pr:'yes'},'admin',400);
    await api('PATCH',protectedRepo,{merge_users:['missing-account']},'admin',400);
    await api('PATCH',protectedRepo,{require_pr:true},'bob',403);
    await api('PATCH',protectedRepo,{require_pr:true,merge_users:['bob']});
    function refusedPush(remoteUrl, refspec) {
        assert.throws(()=>git(['push',remoteUrl,refspec],local),error=>{
            assert.match(String(error.stderr),/requires an approved pull request|deletion of the current branch prohibited/);
            return true;
        });
        count++;console.log('PASS policy refuses direct push '+refspec);
    }
    refusedPush(savedRemote,'feature:main');
    const bobRemote=base.replace('http://','http://bob:'+password+'@')+'/company/snapshot.git';
    refusedPush(bobRemote,'feature:main');
    refusedPush(savedRemote,'+feature:main');
    refusedPush(savedRemote,':main');
    git(['push',bobRemote,'feature:refs/heads/extra'],local);
    check('PR policy leaves source branches writable',()=>assert.equal(git(['rev-parse','extra'],path.join(repos,'company','snapshot.git')),newHead));
    const reviewBody={state:'approve',base_oid:restoredPr.base_oid,head_oid:restoredPr.head_oid};
    await api('POST',protectedRepo+'/pulls/1/reviews',reviewBody);
    await api('POST',protectedRepo+'/pulls/1/merge',reviewBody,'admin',403);
    await api('PATCH',protectedRepo,{merge_users:['admin']});
    await stop();await start(['PROTECT_DEFAULT_BRANCH=0']);
    const policy=await api('GET',protectedRepo);
    check('required PR and merge allowlist survive restart',()=>{assert.equal(policy.require_pr,true);assert.deepEqual(policy.merge_users,['admin']);});
    refusedPush(savedRemote,'feature:main');
    const gatedMerge=await api('POST',protectedRepo+'/pulls/1/merge',reviewBody);
    check('approved PR updates protected main',()=>assert.equal(git(['rev-parse','main'],path.join(repos,'company','snapshot.git')),gatedMerge.merge_oid));
    git(['fetch',savedRemote,'main'],local);git(['checkout','-B','direct','FETCH_HEAD'],local);
    fs.writeFileSync(path.join(local,'direct.txt'),'direct push\n');git(['add','.'],local);git(['commit','-m','direct'],local);
    refusedPush(savedRemote,'direct:main');
    await api('PATCH',protectedRepo,{require_pr:false,merge_users:[]});
    git(['push',savedRemote,'direct:main'],local);
    check('explicitly disabling PR policy restores fast-forward pushes',()=>assert.equal(git(['rev-parse','main'],path.join(repos,'company','snapshot.git')),git(['rev-parse','direct'],local)));
    await api('POST','repos',{owner:'company',name:'seed',require_pr:true},'admin',201);
    await api('PUT','repos/company/seed/teams/developers',{permission:'write'});
    const seedRemote=base.replace('http://','http://admin:'+password+'@')+'/company/seed.git';
    const seedBob=base.replace('http://','http://bob:'+password+'@')+'/company/seed.git';
    refusedPush(seedBob,'main:main');
    git(['push',seedBob,'feature:refs/heads/topic'],local);
    const unseeded=await api('GET','repos/company/seed');
    check('a feature push cannot replace the protected default branch',()=>assert.equal(unseeded.default_branch,'main'));
    git(['push',seedRemote,'main:main'],local);
    refusedPush(seedRemote,'feature:main');
    await stop();await start(['REQUIRE_PR_DEFAULT_BRANCH=1','PROTECT_DEFAULT_BRANCH=0']);
    const inherited=await api('POST','repos',{owner:'company',name:'inherited'},'admin',201);
    check('new repository inherits required PR default',()=>assert.equal(inherited.require_pr,true));
    const inheritedRemote=base.replace('http://','http://admin:'+password+'@')+'/company/inherited.git';
    git(['push',inheritedRemote,'main:main'],local);
    refusedPush(inheritedRemote,'feature:main');
    await api('PATCH','repos/company/inherited',{require_pr:false});
    await stop();await start(['REQUIRE_PR_DEFAULT_BRANCH=1','PROTECT_DEFAULT_BRANCH=0']);
    const overridden=await api('GET','repos/company/inherited');
    check('explicit false overrides global policy after restart',()=>assert.equal(overridden.require_pr,false));
    git(['push',inheritedRemote,'feature:main'],local);
    // Versioned line discussions and independent approval/merge on real Git diffs.
    await api('POST','users',{username:'reviewer',password,admin:true},'admin',201);
    await api('POST','users',{username:'approver',password,admin:true},'admin',201);
    await api('POST','repos',{name:'review-lines',private:true,require_pr:false},'admin',201);
    const lineRepo='repos/admin/review-lines', linePull=lineRepo+'/pulls/1';
    await api('PUT',lineRepo+'/collaborators/bob',{permission:'write'});
    await api('PUT',lineRepo+'/collaborators/reader',{permission:'read'});
    await api('PATCH','users/reader',{disabled:false});
    const oldPath='old name 文.txt', newPath='new name 文.txt';
    git(['checkout','-B','line-base',first],local);
    fs.writeFileSync(path.join(local,oldPath),'alpha\nbravo\ncharlie\ndelta\necho\n');
    fs.writeFileSync(path.join(local,'deleted.txt'),'remove this\n');
    fs.writeFileSync(path.join(local,'binary.dat'),Buffer.from([0,1,2,3]));
    git(['add','.'],local);git(['commit','-m','line review base'],local);
    git(['checkout','-B','line-topic'],local);git(['mv',oldPath,newPath],local);
    fs.writeFileSync(path.join(local,newPath),'alpha\nbravo\nupdated\ndelta\necho\n');
    fs.unlinkSync(path.join(local,'deleted.txt'));
    fs.writeFileSync(path.join(local,'added.txt'),'new file\n');
    fs.writeFileSync(path.join(local,'binary.dat'),Buffer.from([0,9,8,7]));
    git(['add','.'],local);git(['commit','-m','line review change'],local);
    const lineRemote=base.replace('http://','http://admin:'+password+'@')+'/admin/review-lines.git';
    git(['push',lineRemote,'line-base:main','line-topic'],local);
    await api('POST',lineRepo+'/pulls',{title:'Review individual lines',base:'main',head:'line-topic'},'admin',201);
    let lineDetail=await api('GET',linePull);
    let lineEnds={base_oid:lineDetail.base_oid,head_oid:lineDetail.head_oid};
    await api('GET',linePull+'/diff',undefined,null,404);
    const lineDiff=await api('GET',linePull+'/diff?base_oid='+lineEnds.base_oid+'&head_oid='+lineEnds.head_oid);
    function anchor(pathName,side) {
        const row=lineDiff.lines.find(row=>row[side+'_path']===pathName && row[side+'_line']);
        assert(row,'missing anchor '+pathName+' '+side);
        return {path:pathName,side,line:row[side+'_line'],...lineEnds,body:'Please check this line'};
    }
    check('quoted renamed paths retain old and new anchors',()=>{
        assert(lineDiff.lines.some(row=>row.old_path===oldPath));
        assert(lineDiff.lines.some(row=>row.new_path===newPath));
        assert(!lineDiff.lines.some(row=>row.new_path==='binary.dat' && row.new_line));
    });
    const newAnchor=anchor(newPath,'new');
    await api('POST',linePull+'/threads',newAnchor,null,401);
    await api('POST',linePull+'/threads',newAnchor,'reader',403);
    await api('POST',linePull+'/threads',{...newAnchor,path:'../escape'},'bob',400);
    await api('POST',linePull+'/threads',{...newAnchor,line:9999},'bob',400);
    await api('POST',linePull+'/threads',{...newAnchor,side:'invalid'},'bob',400);
    await api('POST',linePull+'/threads',{...newAnchor,path:'binary.dat'},'bob',400);
    await api('POST',linePull+'/threads',newAnchor,'bob');
    await api('POST',linePull+'/threads',anchor(oldPath,'old'));
    await api('POST',linePull+'/threads',anchor('deleted.txt','old'));
    await api('POST',linePull+'/threads',anchor('added.txt','new'));
    await api('POST',linePull+'/threads/1/comments',{body:'Reader reply'},'reader');
    await api('PATCH',linePull+'/threads/1',{resolved:true},'reader',403);
    await api('PATCH',linePull+'/threads/1',{resolved:'yes'},'bob',400);
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'admin',403);
    const lineApproved=await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'reviewer');
    check('approving leaves Git and PR state unchanged',()=>{
        assert.equal(lineApproved.state,'open');
        assert.equal(git(['rev-parse','main'],path.join(repos,'admin','review-lines.git')),lineEnds.base_oid);
    });
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    for (const id of [1,2,3,4]) await api('PATCH',linePull+'/threads/'+id,{resolved:true});
    await stop();await start();
    lineDetail=await api('GET',linePull);
    check('line comments, replies, resolutions and approval survive restart',()=>{
        assert.equal(lineDetail.threads.length,4);assert.equal(lineDetail.threads[0].comments[1].body,'Reader reply');
        assert(lineDetail.threads.every(t=>t.resolved));assert.equal(lineDetail.review_status.mergeable,true);
    });
    git(['checkout','line-topic'],local);fs.writeFileSync(path.join(local,'advance.txt'),'source advance\n');
    git(['add','.'],local);git(['commit','-m','source advance'],local);git(['push',lineRemote,'line-topic'],local);
    await api('POST',linePull+'/threads',newAnchor,'bob',409);
    await api('GET',linePull+'/diff?base_oid='+lineEnds.base_oid+'&head_oid='+lineEnds.head_oid,undefined,'admin',409);
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    lineDetail=await api('GET',linePull);lineEnds={base_oid:lineDetail.base_oid,head_oid:lineDetail.head_oid};
    check('source update makes approvals stale and retains old discussions',()=>{
        assert.equal(lineDetail.review_status.approved,false);assert(lineDetail.threads.every(t=>t.outdated));
    });
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'reviewer');
    git(['checkout','line-base'],local);fs.writeFileSync(path.join(local,'target.txt'),'target advance\n');
    git(['add','.'],local);git(['commit','-m','target advance'],local);git(['push',lineRemote,'line-base:main'],local);
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    lineDetail=await api('GET',linePull);lineEnds={base_oid:lineDetail.base_oid,head_oid:lineDetail.head_oid};
    check('target update invalidates the previous approval',()=>assert.equal(lineDetail.review_status.approved,false));
    await api('POST',linePull+'/reviews',{...lineEnds,state:'request_changes',body:'Please fix this'},'reviewer');
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'approver');
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('PATCH',linePull,{state:'closed'});await api('PATCH',linePull,{state:'open'});
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'approver');
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'reviewer');
    await api('PATCH','users/reviewer',{disabled:true});await api('PATCH','users/approver',{disabled:true});
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('PATCH','users/reviewer',{disabled:false});
    await api('PATCH',lineRepo,{merge_users:['admin']});
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'reviewer');
    await api('POST',linePull+'/merge',lineEnds,'reviewer',403);
    await api('PATCH',linePull+'/threads/1',{resolved:false},'bob');
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('PATCH',linePull+'/threads/1',{resolved:true});
    await api('PATCH',linePull,{state:'closed'});await api('PATCH',linePull,{state:'open'});
    await api('POST',linePull+'/merge',lineEnds,'admin',409);
    await api('POST',linePull+'/reviews',{...lineEnds,state:'approve'},'reviewer');
    await stop();
    const journalFile=path.join(data,'pull_requests.json'), journal=JSON.parse(fs.readFileSync(journalFile,'utf8'));
    journal['admin/review-lines']['1'].pending={oid:lineEnds.head_oid,actor:'admin',at:1,...lineEnds,independent:true};
    fs.writeFileSync(journalFile,JSON.stringify(journal));await start();
    const recoveredLine=await api('GET',linePull);
    check('failed independent merge recovery preserves the approval',()=>{
        assert.equal(recoveredLine.state,'open');assert.equal(recoveredLine.reviews.at(-1).state,'approve');
        assert.equal(recoveredLine.review_status.mergeable,true);
    });
    const explicitMerge=await api('POST',linePull+'/merge',lineEnds);
    check('PR author may explicitly merge after another reviewer approves',()=>{
        assert.equal(explicitMerge.state,'merged');assert.equal(explicitMerge.merged_by,'admin');
        assert.equal(explicitMerge.reviews.at(-1).author,'reviewer');assert.equal(explicitMerge.reviews.at(-1).state,'approve');
    });
    await api('POST',linePull+'/threads',newAnchor,'bob',409);
    await api('PATCH',linePull+'/threads/1',{resolved:false},'bob',409);
    await api('POST',linePull+'/threads/1/comments',{body:'Post-merge reply'},'reader');
    await stop();
    await assert.rejects(start(['PROTECT_DEFAULT_BRANCH=0','HOOKS_DIR='+path.join(work,'missing-hooks')]),/exited|timeout/);
    count++;console.log('PASS required PR policy refuses boot without its hook');
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
