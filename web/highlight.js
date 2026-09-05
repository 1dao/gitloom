// web/highlight.js -- enough syntax colouring to read code by.
//
// Exposes: window.glHighlight.paint(element, language)
//          window.glHighlight.languageFor(filename)
//
// Same rule as markdown.js, and for the same reason: no HTML strings. paint()
// reads the element's textContent, and every token it puts back is a span whose
// text went in through textContent. A file in a repository is untrusted input,
// and a highlighter that assembled markup would be a second place to get
// escaping wrong -- on a page that is holding the reader's token.
//
// This is four token classes (comment, string, number, keyword) and not the
// two hundred a real highlighter carries, because those four are what makes
// code readable at a glance and the rest is decoration. Everything is driven by
// one table per language, so adding a language is data rather than code, and a
// language nobody taught it renders as plain text -- which is honest, and is
// what the file looked like before this existed.

(function (global) {
  'use strict';

  // A minified bundle or a generated data file will be megabytes on one line.
  // Colouring it helps nobody and freezes the tab, so past this it stays text.
  var MAX_BYTES = 400 * 1024;

  var C_LIKE_NUMBER = /^(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?|\.\d[\d_]*)[uUlLfFdD]*/;

  function words(list) {
    var set = Object.create(null);
    list.split(/\s+/).forEach(function (word) { if (word) set[word] = true; });
    return set;
  }

  var DQ = { open: '"', close: '"', escape: true };
  var SQ = { open: "'", close: "'", escape: true };

  var C_FAMILY = {
    line: ['//'],
    block: [['/*', '*/']],
    strings: [DQ, SQ],
    number: C_LIKE_NUMBER
  };

  function derive(base, extra) {
    var out = {};
    Object.keys(base).forEach(function (k) { out[k] = base[k]; });
    Object.keys(extra).forEach(function (k) { out[k] = extra[k]; });
    return out;
  }

  var LANGUAGES = {
    lua: {
      // The long-bracket forms have to be tried before `--`, or every block
      // comment reads as a line comment and the rest of it turns to code.
      line: ['--'],
      block: [['--[[', ']]'], ['--[=[', ']=]']],
      strings: [DQ, SQ, { open: '[[', close: ']]', escape: false, multiline: true }],
      number: C_LIKE_NUMBER,
      keywords: words('and break do else elseif end false for function goto if in ' +
        'local nil not or repeat return then true until while self ' +
        'require pairs ipairs type tostring tonumber pcall xpcall error assert print')
    },

    javascript: derive(C_FAMILY, {
      strings: [DQ, SQ, { open: '`', close: '`', escape: true, multiline: true }],
      keywords: words('async await break case catch class const continue debugger default ' +
        'delete do else export extends finally for from function get if import in ' +
        'instanceof let new of return set static super switch this throw try typeof ' +
        'var void while with yield true false null undefined NaN Infinity')
    }),

    typescript: derive(C_FAMILY, {
      strings: [DQ, SQ, { open: '`', close: '`', escape: true, multiline: true }],
      keywords: words('abstract any as async await boolean break case catch class const ' +
        'continue declare default delete do else enum export extends finally for from ' +
        'function if implements import in instanceof interface keyof let namespace never ' +
        'new number of private protected public readonly return static string super switch ' +
        'this throw try type typeof undefined union unknown var void while yield true false null')
    }),

    c: derive(C_FAMILY, {
      meta: /^[ \t]*#[ \t]*[a-z_]+/,
      keywords: words('auto break case char const continue default do double else enum extern ' +
        'float for goto if inline int long register restrict return short signed sizeof ' +
        'static struct switch typedef union unsigned void volatile while ' +
        'bool true false NULL size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t ' +
        'int32_t int64_t class namespace template typename public private protected virtual ' +
        'new delete this nullptr using operator friend explicit constexpr noexcept')
    }),

    python: {
      line: ['#'],
      block: [],
      strings: [
        { open: '"""', close: '"""', escape: true, multiline: true },
        { open: "'''", close: "'''", escape: true, multiline: true },
        DQ, SQ
      ],
      number: C_LIKE_NUMBER,
      keywords: words('and as assert async await break class continue def del elif else except ' +
        'finally for from global if import in is lambda None nonlocal not or pass raise ' +
        'return True False try while with yield self print len range str int float dict list')
    },

    shell: {
      line: ['#'],
      block: [],
      strings: [DQ, SQ],
      number: C_LIKE_NUMBER,
      keywords: words('if then elif else fi for while until do done case esac in function ' +
        'return local export readonly declare shift exit set unset trap source echo printf ' +
        'cd test true false break continue')
    },

    json: {
      line: [],
      block: [],
      strings: [DQ],
      number: C_LIKE_NUMBER,
      keywords: words('true false null')
    },

    css: {
      line: [],
      block: [['/*', '*/']],
      strings: [DQ, SQ],
      number: /^-?(?:\d[\d_]*(?:\.\d+)?|\.\d+)(?:px|em|rem|vh|vw|%|s|ms|deg|fr|ch|pt)?/,
      keywords: words('important inherit initial unset none auto flex grid block inline ' +
        'absolute relative fixed sticky hidden visible solid dashed dotted transparent')
    },

    go: derive(C_FAMILY, {
      strings: [DQ, SQ, { open: '`', close: '`', escape: false, multiline: true }],
      keywords: words('break case chan const continue default defer else fallthrough for func ' +
        'go goto if import interface map package range return select struct switch type var ' +
        'nil true false iota make new len cap append copy delete panic recover error string ' +
        'int int64 uint byte rune bool float64')
    }),

    rust: derive(C_FAMILY, {
      keywords: words('as async await break const continue crate dyn else enum extern false fn ' +
        'for if impl in let loop match mod move mut pub ref return self Self static struct ' +
        'super trait true type unsafe use where while Some None Ok Err String Vec Option Result ' +
        'i8 i16 i32 i64 u8 u16 u32 u64 usize isize f32 f64 bool str')
    }),

    java: derive(C_FAMILY, {
      keywords: words('abstract assert boolean break byte case catch char class const continue ' +
        'default do double else enum extends final finally float for goto if implements import ' +
        'instanceof int interface long native new package private protected public return short ' +
        'static strictfp super switch synchronized this throw throws transient try void volatile ' +
        'while true false null var record sealed')
    }),

    sql: {
      line: ['--'],
      block: [['/*', '*/']],
      strings: [SQ, { open: '`', close: '`', escape: false }],
      number: C_LIKE_NUMBER,
      keywords: words('SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ' +
        'ALTER DROP INDEX PRIMARY KEY FOREIGN REFERENCES NOT NULL DEFAULT AND OR IN IS LIKE ' +
        'JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER LIMIT OFFSET HAVING AS DISTINCT UNION ' +
        'select from where insert into values update set delete create table alter drop index ' +
        'primary key foreign references not null default and or in is like join left right ' +
        'inner outer on group by order limit offset having as distinct union')
    },

    yaml: {
      line: ['#'],
      block: [],
      strings: [DQ, SQ],
      number: C_LIKE_NUMBER,
      keywords: words('true false null yes no on off')
    },

    toml: {
      line: ['#'],
      block: [],
      strings: [{ open: '"""', close: '"""', escape: true, multiline: true }, DQ, SQ],
      number: C_LIKE_NUMBER,
      keywords: words('true false')
    },

    ini: {
      line: ['#', ';'],
      block: [],
      strings: [DQ, SQ],
      number: C_LIKE_NUMBER,
      keywords: words('true false on off yes no')
    },

    xml: {
      line: [],
      block: [['<!--', '-->']],
      strings: [DQ, SQ],
      number: C_LIKE_NUMBER,
      keywords: Object.create(null)
    }
  };

  var BY_EXTENSION = {
    lua: 'lua',
    js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript',
    ts: 'typescript', tsx: 'typescript',
    c: 'c', h: 'c', cc: 'c', cpp: 'c', cxx: 'c', hpp: 'c', hh: 'c',
    py: 'python', pyw: 'python',
    sh: 'shell', bash: 'shell', zsh: 'shell', ksh: 'shell',
    json: 'json', jsonc: 'json',
    css: 'css', scss: 'css', less: 'css',
    go: 'go', rs: 'rust', java: 'java',
    sql: 'sql',
    yml: 'yaml', yaml: 'yaml',
    toml: 'toml',
    ini: 'ini', cfg: 'ini', conf: 'ini', properties: 'ini',
    html: 'xml', htm: 'xml', xml: 'xml', svg: 'xml', vue: 'xml'
  };

  var BY_NAME = {
    makefile: 'shell', dockerfile: 'shell', 'cmakelists.txt': 'shell',
    '.bashrc': 'shell', '.profile': 'shell', '.gitconfig': 'ini'
  };

  // What Markdown's info string says, mapped onto the tables above.
  var ALIAS = {
    sh: 'shell', bash: 'shell', zsh: 'shell', console: 'shell', shell: 'shell',
    js: 'javascript', javascript: 'javascript', node: 'javascript',
    ts: 'typescript', typescript: 'typescript',
    py: 'python', python: 'python',
    'c++': 'c', cpp: 'c', h: 'c', c: 'c', objc: 'c',
    rs: 'rust', golang: 'go', htm: 'xml', html: 'xml', vue: 'xml', svg: 'xml',
    yml: 'yaml', conf: 'ini', cfg: 'ini', config: 'ini'
  };

  function languageFor(filename) {
    var name = String(filename || '').split('/').pop().toLowerCase();
    if (Object.prototype.hasOwnProperty.call(BY_NAME, name)) return BY_NAME[name];
    var dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    var ext = name.slice(dot + 1);
    return Object.prototype.hasOwnProperty.call(BY_EXTENSION, ext) ? BY_EXTENSION[ext] : '';
  }

  function resolve(language) {
    var key = String(language || '').toLowerCase();
    if (Object.prototype.hasOwnProperty.call(LANGUAGES, key)) return LANGUAGES[key];
    if (Object.prototype.hasOwnProperty.call(ALIAS, key)) return LANGUAGES[ALIAS[key]];
    return null;
  }

  // Longest opener first, so `--[[` is seen before `--` and `"""` before `"`.
  function byLength(a, b) { return b.length - a.length; }
  function openerLength(a, b) { return b.open.length - a.open.length; }

  function starts(src, i, token) {
    return src.substr(i, token.length) === token;
  }

  function scanString(src, i, rule) {
    var j = i + rule.open.length;
    while (j < src.length) {
      var c = src.charAt(j);
      if (rule.escape && c === '\\') { j += 2; continue; }
      if (!rule.multiline && c === '\n') return j;      // unterminated: stop at the line
      if (starts(src, j, rule.close)) return j + rule.close.length;
      j += 1;
    }
    return src.length;
  }

  function tokenize(src, lang) {
    var out = [];
    var plain = '';
    var lines = lang.line.slice().sort(byLength);
    var blocks = lang.block.slice().sort(function (a, b) { return b[0].length - a[0].length; });
    var strings = lang.strings.slice().sort(openerLength);
    var keywords = lang.keywords || Object.create(null);
    var i = 0;

    function emit(cls, text) {
      if (!text) return;
      if (plain) { out.push(['', plain]); plain = ''; }
      out.push([cls, text]);
    }

    while (i < src.length) {
      var c = src.charAt(i);
      var handled = false;
      var k;

      for (k = 0; k < blocks.length; k += 1) {
        if (starts(src, i, blocks[k][0])) {
          var shut = src.indexOf(blocks[k][1], i + blocks[k][0].length);
          var stop = shut < 0 ? src.length : shut + blocks[k][1].length;
          emit('tok-comment', src.slice(i, stop));
          i = stop;
          handled = true;
          break;
        }
      }
      if (handled) continue;

      for (k = 0; k < lines.length; k += 1) {
        if (starts(src, i, lines[k])) {
          var nl = src.indexOf('\n', i);
          if (nl < 0) nl = src.length;
          emit('tok-comment', src.slice(i, nl));
          i = nl;
          handled = true;
          break;
        }
      }
      if (handled) continue;

      for (k = 0; k < strings.length; k += 1) {
        if (starts(src, i, strings[k].open)) {
          var end = scanString(src, i, strings[k]);
          emit('tok-string', src.slice(i, end));
          i = end;
          handled = true;
          break;
        }
      }
      if (handled) continue;

      if (lang.meta && (i === 0 || src.charAt(i - 1) === '\n')) {
        var meta = lang.meta.exec(src.slice(i));
        if (meta) { emit('tok-keyword', meta[0]); i += meta[0].length; continue; }
      }

      if (c >= '0' && c <= '9') {
        var num = lang.number.exec(src.slice(i));
        if (num) { emit('tok-number', num[0]); i += num[0].length; continue; }
      }

      if (/[A-Za-z_$]/.test(c)) {
        var word = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(src.slice(i))[0];
        if (keywords[word]) emit('tok-keyword', word);
        else plain += word;
        i += word.length;
        continue;
      }

      plain += c;
      i += 1;
    }

    if (plain) out.push(['', plain]);
    return out;
  }

  // Replaces the element's contents with the same text, in spans. The source is
  // read back out of the DOM rather than passed in, so what gets coloured is
  // exactly what was displayed.
  function paint(element, language) {
    if (!element) return false;
    var lang = resolve(language);
    if (!lang) return false;

    var src = element.textContent;
    if (!src || src.length > MAX_BYTES) return false;

    var tokens;
    try {
      tokens = tokenize(src, lang);
    } catch (e) {
      return false;                    // a highlighter must never cost a reader the file
    }

    var holder = document.createDocumentFragment();
    tokens.forEach(function (token) {
      if (!token[0]) {
        holder.appendChild(document.createTextNode(token[1]));
        return;
      }
      var span = document.createElement('span');
      span.className = token[0];
      span.textContent = token[1];
      holder.appendChild(span);
    });

    element.textContent = '';
    element.appendChild(holder);
    return true;
  }

  global.glHighlight = { paint: paint, languageFor: languageFor };
}(window));
