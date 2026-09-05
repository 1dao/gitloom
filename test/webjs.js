// test/webjs.js -- the browser's two parsers, tested away from a browser.
//
//   node test/webjs.js
//
// Run by test/smoke.sh when node is on PATH, skipped when it is not -- the same
// deal the xproc pipe test has. Node is a development convenience here and not
// a dependency of gitloom: nothing in bin/ or app/ needs it.
//
// WHAT THIS IS ACTUALLY FOR
//
// web/markdown.js renders a file written by whoever pushed the repository, on a
// page holding the reader's token, and it claims to be safe by construction
// rather than by sanitising: it never builds an HTML string, so the only way
// untrusted input can reach an attribute is through a URL. A claim like that is
// worth exactly as much as its test, so the DOM below is a stub that RECORDS --
// every element created, every URL assigned -- and the assertions are made
// against the record rather than against rendered markup. An attempt to create
// a <script> fails here even if nothing would have executed.

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

let passed = 0;
const failures = [];

function ok(name, condition, detail) {
    if (condition) { passed += 1; return; }
    failures.push(name + (detail ? ' -- ' + detail : ''));
}

function eq(name, actual, expected) {
    ok(name, actual === expected, 'got ' + JSON.stringify(actual) +
        ', wanted ' + JSON.stringify(expected));
}

// ---------------------------------------------------------------------------
// A DOM that keeps receipts
// ---------------------------------------------------------------------------

const created = [];      // every tag name ever created
const urls = [];         // every href/src ever assigned, by any route

function Node(tag) {
    this.tagName = tag.toUpperCase();
    this.nodeName = this.tagName;
    this.childNodes = [];
    this.attributes = Object.create(null);
    this.style = {};
    this.className = '';
    this.classList = {
        add: (name) => { this.className = (this.className + ' ' + name).trim(); },
        contains: (name) => this.className.split(/\s+/).indexOf(name) >= 0,
    };
}

function watchUrl(value) {
    urls.push(String(value));
}

Object.defineProperty(Node.prototype, 'href', {
    get() { return this.attributes.href; },
    set(v) { watchUrl(v); this.attributes.href = String(v); },
});
Object.defineProperty(Node.prototype, 'src', {
    get() { return this.attributes.src; },
    set(v) { watchUrl(v); this.attributes.src = String(v); },
});
Object.defineProperty(Node.prototype, 'textContent', {
    get() {
        return this.childNodes.map((c) => c.textContent === undefined ? c.data : c.textContent).join('');
    },
    set(v) {
        this.childNodes = [];
        if (v !== '') this.childNodes.push({ nodeName: '#text', data: String(v), textContent: String(v) });
    },
});

Object.defineProperty(Node.prototype, 'firstChild', {
    get() { return this.childNodes.length ? this.childNodes[0] : null; },
});

Node.prototype.removeChild = function (child) {
    const at = this.childNodes.indexOf(child);
    if (at >= 0) this.childNodes.splice(at, 1);
    return child;
};

// A real appendChild MOVES the node: it is removed from whatever parent it had.
// Code under test relies on that -- unwrapping a tight list item is a
// `while (p.firstChild) li.appendChild(p.firstChild)` loop, which never ends
// against a stub that only copies.
Node.prototype.appendChild = function (child) {
    if (child && child.nodeName === '#fragment') {
        const moving = child.childNodes.slice();
        child.childNodes = [];
        moving.forEach((c) => this.appendChild(c));
        return child;
    }
    if (child && child.parentNode) child.parentNode.removeChild(child);
    this.childNodes.push(child);
    if (child) child.parentNode = this;
    return child;
};
Node.prototype.setAttribute = function (name, value) {
    if (name === 'href' || name === 'src') watchUrl(value);
    this.attributes[name] = String(value);
};
Node.prototype.getAttribute = function (name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null;
};
Node.prototype.addEventListener = function () {};
Node.prototype.querySelector = function () { return null; };
Node.prototype.scrollIntoView = function () {};

// Depth-first walk, used by the assertions rather than by the code under test.
Node.prototype.find = function (tag) {
    const out = [];
    const want = tag.toUpperCase();
    (function walk(node) {
        (node.childNodes || []).forEach((child) => {
            if (child.tagName === want) out.push(child);
            walk(child);
        });
    }(this));
    return out;
};

const document = {
    createElement(tag) { created.push(tag.toLowerCase()); return new Node(tag); },
    createTextNode(data) { return { nodeName: '#text', data: String(data), textContent: String(data) }; },
    createDocumentFragment() {
        const frag = new Node('fragment');
        frag.nodeName = '#fragment';
        frag.tagName = undefined;
        return frag;
    },
};

const sandbox = {
    window: {}, document, console,
    CSS: { escape: (s) => String(s).replace(/["\\]/g, '') },
    String, Object, Array, Number, RegExp, Math, JSON, isFinite, parseInt, Error,
};
sandbox.window.document = document;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

function load(file) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'web', file), 'utf8');
    vm.runInContext(src, sandbox, { filename: file });
}

load('markdown.js');
load('highlight.js');

const md = sandbox.window.glMarkdown;
const hl = sandbox.window.glHighlight;

function render(source, options) {
    created.length = 0;
    urls.length = 0;
    return md.render(source, options || {});
}

// ---------------------------------------------------------------------------
// The security property
// ---------------------------------------------------------------------------

const HOSTILE = [
    '# Title <script>alert(1)</script>',
    '',
    '<img src=x onerror=alert(1)>',
    '<iframe src="https://evil.example"></iframe>',
    '<a href="javascript:alert(1)">raw anchor</a>',
    '',
    '[plain](javascript:alert(1))',
    '[entity](&#106;avascript:alert(1))',
    '[tabbed](jav&#x09;ascript&#58;alert(1))',
    '[vb](vbscript:msgbox(1))',
    '[datahtml](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==)',
    '[upper](JaVaScRiPt:alert(1))',
    '![img](javascript:alert(1))',
    '![ok](data:image/png;base64,iVBORw0KGgo=)',
    '<javascript:alert(1)>',
    '',
    '[ref][evil]',
    '',
    // The whitespace rules, which are what a browser does to a URL and so what
    // decides whether these run. Leading and trailing spaces are trimmed by it;
    // tab, newline and carriage return are deleted by it wherever they sit.
    '[lead](< javascript:alert(1)>)',
    '[trail](<javascript:alert(1) >)',
    '[inner](<java\tscript:alert(1)>)',
    '',
    '[evil]: javascript:alert(1)',
].join('\n');

const hostile = render(HOSTILE, {
    resolveLink: (p) => '#/owner/name/blob/main/' + p,
    resolveImage: (p, img) => { img.src = 'blob:stub/' + p; },
});

const FORBIDDEN = ['script', 'iframe', 'object', 'embed', 'style', 'link', 'meta', 'form', 'base'];
ok('no dangerous element is ever created',
    !created.some((tag) => FORBIDDEN.indexOf(tag) >= 0),
    'created: ' + created.join(','));

const BAD_URL = /^\s*(javascript|vbscript|data:text|data:application)/i;
ok('no dangerous URL reaches an attribute',
    !urls.some((u) => BAD_URL.test(u)),
    'urls: ' + JSON.stringify(urls));

ok('a data: image is still allowed through',
    urls.some((u) => /^data:image\/png;base64,/.test(u)),
    'urls: ' + JSON.stringify(urls));

const flat = hostile.textContent;
ok('a raw script tag survives as visible text, not as an element',
    flat.indexOf('<script>alert(1)</script>') >= 0, flat.slice(0, 120));
ok('a raw img tag survives as visible text',
    flat.indexOf('<img src=x onerror=alert(1)>') >= 0);
ok('the label of a rejected link is still shown',
    flat.indexOf('plain') >= 0 && flat.indexOf('entity') >= 0);

// A rejected destination must not leave a clickable element behind.
hostile.find('a').forEach((a) => {
    ok('rejected link ' + JSON.stringify(a.textContent) + ' has no href',
        !a.attributes.href || !BAD_URL.test(a.attributes.href), a.attributes.href);
});

// safeUrl, tested directly rather than only through a rendered href.
//
// It has to be, and finding that out is the whole reason it is: the renderer's
// fallback for anything it does not recognise is the RELATIVE branch, and the
// application turns a relative path into a `#/owner/name/blob/...` route. So an
// obfuscated `java<tab>script:` that slips past the scheme test does not become
// a dangerous link in this page -- it becomes a harmless one -- and a test that
// only looks at rendered hrefs therefore passes with the normalisation removed
// entirely. It was doing exactly that.
//
// What the normalisation actually buys, then, is that the scheme test sees what
// the BROWSER would see, so a dangerous address is recognised and rejected
// rather than quietly reclassified as a file name. That is worth keeping and
// worth testing, and this is where it has to be tested.
const URL_CASES = [
    ['javascript:alert(1)', null, 'a plain dangerous scheme'],
    [' javascript:alert(1)', null, 'a leading space, which the browser trims'],
    ['javascript:alert(1) ', null, 'a trailing space, likewise'],
    ['java\tscript:alert(1)', null, 'a tab, which the browser deletes'],
    ['java\nscript:alert(1)', null, 'a newline, likewise'],
    ['java\rscript:alert(1)', null, 'a carriage return, likewise'],
    ['JaVaScRiPt:alert(1)', null, 'case does not hide it'],
    ['vbscript:msgbox(1)', null, 'the other executable scheme'],
    ['data:text/html,<script>', null, 'a data: document as a link'],
    ['file:///etc/passwd', null, 'a local file'],
];
URL_CASES.forEach((row) => {
    ok('safeUrl rejects ' + row[2], md.safeUrl(row[0]) === null,
        JSON.stringify(md.safeUrl(row[0])));
});
eq('safeUrl keeps an ordinary https link',
    (md.safeUrl('https://example.com/a?b=c') || {}).href, 'https://example.com/a?b=c');
eq('safeUrl keeps an interior space in a relative path',
    (md.safeUrl('my docs/a.md') || {}).path, 'my docs/a.md');
eq('safeUrl still trims the ends of a relative path',
    (md.safeUrl('  my docs/a.md  ') || {}).path, 'my docs/a.md');
eq('safeUrl allows a data: image only when asked for an image',
    (md.safeUrl('data:image/png;base64,iVBOR', true) || {}).href, 'data:image/png;base64,iVBOR');
ok('safeUrl refuses that same data: image as a link',
    md.safeUrl('data:image/png;base64,iVBOR') === null);
ok('safeUrl refuses a data: SVG even as an image',
    md.safeUrl('data:image/svg+xml;base64,PHN2Zz4=', true) === null);

// The other half of the whitespace rule, and the one a stricter-looking fix
// gets wrong: an INTERIOR space is part of the path. Deleting it -- which is
// what stripping all whitespace does -- turns a link to a directory that exists
// into a link to one that does not, silently.
const SPACED = render('[doc](<my docs/a.md>) ![pic](<my docs/logo.png>)', {
    resolveLink: (p) => 'ROUTE:' + p,
    resolveImage: (p, img) => { img.src = 'IMG:' + p; },
});
eq('a space inside a relative link survives',
    SPACED.find('a')[0].attributes.href, 'ROUTE:my docs/a.md');
eq('a space inside a relative image survives',
    SPACED.find('img')[0].attributes.src, 'IMG:my docs/logo.png');

// ---------------------------------------------------------------------------
// Structure -- that it renders the things a README is made of
// ---------------------------------------------------------------------------

const SAMPLE = [
    '# gitloom',
    '',
    'A git host in *Lua*, with **streaming** and `pkt-line` and ~~no~~ few deps.',
    '',
    'Underlined',
    '==========',
    '',
    '## Install',
    '',
    '1. clone it',
    '2. run it',
    '   - on Linux',
    '   - on Windows',
    '',
    '- [x] streaming push',
    '- [ ] pull requests',
    '',
    '> It fits in one process.',
    '> Really.',
    '',
    '```lua',
    'local x = 1  -- a comment',
    'print("hi")',
    '```',
    '',
    '| Store | Windows | Linux |',
    '|:------|:-------:|------:|',
    '| JSON  | yes     | yes   |',
    '| MySQL | yes     | yes   |',
    '',
    '---',
    '',
    'See [the roadmap](docs/ROADMAP.md) and [the site](https://example.com).',
    'Bare: https://example.com/a?b=c and a jump to [Install](#install).',
    '',
    '![logo](docs/logo.png)',
    '',
    'A line with two trailing spaces  ',
    'continues here.',
].join('\n');

let painted = null;
const doc = render(SAMPLE, {
    resolveLink: (p) => '#/admin/site/blob/main/' + p,
    resolveImage: (p, img) => { img.src = 'blob:stub/' + p; },
    highlight: (code, lang) => { painted = lang; hl.paint(code, lang); },
});

eq('one h1 from the ATX heading plus one from setext', doc.find('h1').length, 2);
eq('the h2 is there', doc.find('h2').length, 1);
eq('emphasis renders', doc.find('em').length, 1);
eq('strong renders', doc.find('strong').length, 1);
eq('strikethrough renders', doc.find('del').length, 1);
eq('an ordered list', doc.find('ol').length, 1);
ok('a nested list inside it', doc.find('ol')[0].find('ul').length === 1);
eq('a blockquote', doc.find('blockquote').length, 1);
eq('a table', doc.find('table').length, 1);
eq('the table has two body rows', doc.find('tbody')[0].find('tr').length, 2);
eq('column alignment is carried', doc.find('th')[1].style.textAlign, 'center');
eq('a thematic break', doc.find('hr').length, 1);
eq('a hard break from two trailing spaces', doc.find('br').length, 1);
eq('the fenced block was offered to the highlighter', painted, 'lua');

const checks = doc.find('input');
eq('two task list checkboxes', checks.length, 2);
eq('the first is ticked', checks[0].checked, true);
eq('the second is not', checks[1].checked, false);
ok('task checkboxes cannot be operated', checks.every((c) => c.disabled === true));

const links = doc.find('a');
const byText = (t) => links.filter((a) => a.textContent === t)[0];
eq('a relative link is resolved into the app',
    byText('the roadmap').attributes.href, '#/admin/site/blob/main/docs/ROADMAP.md');
eq('an external link keeps its address',
    byText('the site').attributes.href, 'https://example.com');
eq('an external link cannot reach back through the opener',
    byText('the site').rel, 'noreferrer noopener');
ok('a bare URL is linked', links.some((a) => a.attributes.href === 'https://example.com/a?b=c'));
ok('an in-page jump gets NO href, so it cannot overwrite the route',
    byText('Install').attributes.href === undefined);
eq('a heading carries the slug that jump looks for',
    doc.find('h2')[0].getAttribute('data-md-slug'), 'install');

const images = doc.find('img');
eq('a relative image is fetched through the API', images[0].attributes.src, 'blob:stub/docs/logo.png');

// ---------------------------------------------------------------------------
// The highlighter
// ---------------------------------------------------------------------------

eq('a file name picks a language', hl.languageFor('app/http.lua'), 'lua');
eq('an unknown extension picks none', hl.languageFor('notes.xyz'), '');
eq('a bare name is recognised', hl.languageFor('Makefile'), 'shell');

function paint(source, lang) {
    const pre = new Node('code');
    pre.textContent = source;
    const did = hl.paint(pre, lang);
    return { node: pre, did };
}

const LUA = 'local n = 0x1F  -- count\nprint("hi\\n")\n--[[ block\nstill comment ]]\nreturn n';
const lua = paint(LUA, 'lua');
ok('lua is highlighted', lua.did);
eq('highlighting never loses or changes a byte', lua.node.textContent, LUA);

const classes = lua.node.childNodes.filter((c) => c.className).map((c) => c.className);
ok('keywords are marked', classes.indexOf('tok-keyword') >= 0);
ok('strings are marked', classes.indexOf('tok-string') >= 0);
ok('numbers are marked', classes.indexOf('tok-number') >= 0);
eq('a long comment is one comment, not a line comment plus code',
    lua.node.childNodes.filter((c) => c.className === 'tok-comment' && c.textContent.indexOf('still') >= 0).length, 1);

const JS = 'const s = `a ${b} c`; // done\n/* off */ let n = 1.5e3;';
const js = paint(JS, 'javascript');
eq('javascript round-trips too', js.node.textContent, JS);

const UNKNOWN = paint('whatever\n', 'brainfuck');
ok('an unknown language is left alone', UNKNOWN.did === false);
eq('and its text is untouched', UNKNOWN.node.textContent, 'whatever\n');

const HUGE = paint('x'.repeat(500 * 1024), 'javascript');
ok('an oversized file is not highlighted at all', HUGE.did === false);

// An unterminated string must not swallow the rest of the file.
const UNTERMINATED = 'local s = "oops\nlocal t = 1\n';
const un = paint(UNTERMINATED, 'lua');
eq('an unterminated string stops at the line end', un.node.textContent, UNTERMINATED);
ok('and the line after it is still code',
    un.node.childNodes.some((c) => c.className === 'tok-number'));

// ---------------------------------------------------------------------------

if (failures.length) {
    failures.forEach((f) => process.stdout.write('FAIL ' + f + '\n'));
    process.stdout.write('[webjs] ' + passed + ' passed, ' + failures.length + ' failed\n');
    process.exit(1);
}
process.stdout.write('[webjs] ' + passed + ' passed, 0 failed\n');
