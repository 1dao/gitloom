// Run the real app entry point against a small DOM and a controlled network.
// These checks exercise the registration workflow, including slow responses,
// without creating accounts or storing test credentials in a running instance.
'use strict';
const assert = require('assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const script = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');
const flush = () => new Promise(resolve => setImmediate(resolve));

function harness(signedIn = false, oldMarkup = false) {
    const nodes = new Map();
    const all = [];
    const document = { documentElement: { dataset: {} }, activeElement: null };
    function node(tag, attrs = {}, offset = -1) {
        const handlers = {};
        const element = {
            tag, offset, value: '', textContent: '', hidden: 'hidden' in attrs,
            disabled: false, open: false, dataset: {},
            classList: { add() {}, remove() {}, toggle() {} },
            setAttribute(key, value) { attrs[key] = value; },
            appendChild() {},
            focus() { document.activeElement = element; },
            addEventListener(type, listener) { (handlers[type] ||= []).push(listener); },
            emit(type) {
                const event = { target: element, defaultPrevented: false,
                    preventDefault() { this.defaultPrevented = true; } };
                for (const listener of handlers[type] || []) listener(event);
                return event;
            },
            click() { if (!element.disabled) element.emit('click'); },
            showModal() { element.open = true; },
            close() { element.open = false; element.emit('close'); },
            reset() {
                const end = html.indexOf('</form>', offset);
                for (const field of all) {
                    if (field.tag === 'input' && field.offset > offset && field.offset < end) field.value = '';
                }
            },
        };
        if (attrs['data-dialog-close']) element.dataset.dialogClose = attrs['data-dialog-close'];
        return element;
    }
    for (const match of html.matchAll(/<([a-z][\w-]*)\b([^>]*)>/g)) {
        const attrs = {};
        for (const attr of match[2].matchAll(/([\w-]+)(?:="([^"]*)")?/g)) attrs[attr[1]] = attr[2] || '';
        const element = node(match[1], attrs, match.index);
        all.push(element);
        if (attrs.id) nodes.set(attrs.id, element);
    }
    const registerStart = html.indexOf('<dialog id="register-dialog"');
    const registerEnd = html.indexOf('</dialog>', registerStart);
    const registerButtons = all.filter(n => n.tag === 'button' && n.offset > registerStart && n.offset < registerEnd);
    if (oldMarkup) {
        for (const key of nodes.keys()) if (key.startsWith('register-') || key === 'auth-register') nodes.delete(key);
    }
    document.getElementById = id => nodes.get(id) || null;
    document.createElement = tag => node(tag);
    document.querySelectorAll = selector => selector === '#register-dialog button' ? registerButtons
        : selector === '[data-dialog-close]' ? all.filter(n => n.dataset.dialogClose) : [];
    const stored = new Map(signedIn ? [['gitloom.username', 'existing'], ['gitloom.token', 'test-token']] : []);
    const storage = { getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value),
        removeItem: key => stored.delete(key) };
    const requests = [];
    let answer;
    const window = { addEventListener() {}, setTimeout() {}, clearTimeout() {},
        btoa: s => Buffer.from(s).toString('base64') };
    vm.runInNewContext(script, {
        document, window, location: {hash: ''}, localStorage: storage, sessionStorage: storage,
        fetch(url, options) {
            if (url === '/api/v1/user/tokens') {
                return Promise.resolve({ok: true, status: 201, json: async () => ({token: 'fresh-token'})});
            }
            if (url !== '/api/v1/user/register') return new Promise(() => {});
            requests.push(options);
            return new Promise(resolve => { answer = resolve; });
        },
    });
    return {
        nodes, document, requests, stored, registerButtons,
        respond(status, data) {
            answer({ok: status < 400, status, json: async () => data, text: async () => JSON.stringify(data)});
        },
        fill(confirm = 'test-password') {
            nodes.get('register-user').value = '  newcomer  ';
            nodes.get('register-password').value = 'test-password';
            nodes.get('register-confirm').value = confirm;
        },
    };
}

(async function () {
    const h = harness();
    const get = id => h.nodes.get(id);
    assert.equal(get('register-toggle'), undefined, 'the top bar carries login alone');
    assert.equal(get('auth-dialog').open, true, 'signed-out visitors see the login dialog first');
    get('auth-toggle').click();
    // The only way in: the entry sits under the login form's own buttons.
    get('auth-register').click();
    assert.equal(get('auth-dialog').open, false, 'switching closes login');
    assert.equal(get('register-dialog').open, true);
    h.fill('different');
    get('register-form').emit('submit');
    assert.match(get('register-message').textContent, /不一致/);
    assert.equal(h.requests.length, 0, 'mismatch does not consume a registration attempt');

    for (const [status, detail, message] of [
        [403, 'account registration is disabled', /暂未开放注册/],
        [409, 'user already exists', /已经有人用了/],
        [400, 'password must be at least 12 characters', /12/],
        [429, 'too many requests', /次数过多/],
    ]) {
        h.fill();
        get('register-form').emit('submit');
        assert.equal(get('register-submit').disabled, true);
        h.respond(status, {error: detail});
        await flush();
        assert.match(get('register-message').textContent, message);
        assert.equal(get('register-submit').disabled, false, 'failure allows retry');
    }

    h.fill();
    get('register-email').value = ' newcomer@example.com ';
    const before = h.requests.length;
    get('register-form').emit('submit');
    get('register-form').emit('submit');
    assert.equal(h.requests.length, before + 1, 'duplicate submit cannot create a second request');
    assert.ok(h.registerButtons.every(button => button.disabled), 'pending request keeps close controls disabled');
    assert.equal(get('register-dialog').emit('cancel').defaultPrevented, true, 'Escape cannot hide an incoming recovery code');
    const sent = h.requests.at(-1);
    assert.equal(sent.headers.Authorization, undefined, 'registration is anonymous');
    assert.deepEqual(JSON.parse(sent.body), {username: 'newcomer', password: 'test-password', email: 'newcomer@example.com'});
    h.respond(201, {username: 'newcomer', recovery_code: 'TEST-RECOVERY-CODE'});
    await flush();
    assert.equal(get('register-success').hidden, false);
    assert.equal(get('register-form').hidden, true);
    assert.equal(get('register-dialog').open, true, 'recovery step stays visible');
    assert.equal(get('register-recovery-code').textContent, 'TEST-RECOVERY-CODE');
    assert.equal(h.stored.get('gitloom.username'), 'newcomer', 'registration signs the new account in');
    assert.equal(h.stored.get('gitloom.token'), 'fresh-token', 'registration receives a normal session token');
    assert.equal(get('register-password').value, '');
    assert.equal(get('register-confirm').value, '');
    assert.equal(h.stored.has('gitloom.password'), false, 'password is never persisted');
    assert.equal(h.stored.has('gitloom.recovery_code'), false, 'recovery code is never persisted');
    get('register-done').click();
    assert.equal(get('auth-dialog').open, false);
    assert.equal(get('register-recovery-code').textContent, '', 'closing clears recovery code');
    get('auth-register').click();
    assert.equal(get('register-dialog').open, false, 'a signed-in visitor cannot reopen registration');
    const signedIn = harness(true).nodes;
    signedIn.get('auth-register').click();
    assert.equal(signedIn.get('register-dialog').open, false, 'signed-in visitors do not see register');
    assert.equal(harness(false, true).nodes.get('auth-toggle').textContent, '登录', 'old markup can still initialize login');
    process.stdout.write('[webauth] registration workflow passed\n');
})().catch(error => {
    process.stderr.write('FAIL ' + error.stack + '\n');
    process.exitCode = 1;
});
