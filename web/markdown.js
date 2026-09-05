// web/markdown.js -- Markdown to DOM, for the files people actually read.
//
// Exposes: window.glMarkdown.render(text, options) -> DocumentFragment
//
// WHY THIS IS OURS RATHER THAN TWO LIBRARIES
//
// A README is written by whoever pushed the repository and read by anyone who
// can see it, on a page that is holding the reader's access token. That is the
// textbook cross-site scripting setup. The usual answer -- a Markdown library
// plus a sanitiser -- means committing two minified blobs into a repository
// with no package manager, no build step and no way to ship a patch on the day
// one of them has a bypass. The runtime underneath vendors its C dependencies
// as readable source for exactly that reason; a minified bundle here would be
// the only unreviewable thing in the tree.
//
// So the safety is structural rather than filtered: NOTHING in this file ever
// builds an HTML string. Every element comes from createElement and every piece
// of text arrives through textContent, so there is no markup for a README to
// inject into and no sanitiser with a list of tags to get wrong. The only place
// untrusted input reaches an attribute is a URL, and safeUrl() below is the
// whole of that surface.
//
// It is worth being exact about how safeUrl is safe, because the obvious
// reading overstates it. There are two layers, and the second is the strong
// one: an address only becomes an href if it names a scheme this file allows,
// and ANYTHING ELSE -- including something malformed enough that the scheme
// test does not recognise it at all -- falls through to the relative branch,
// where it is a path rather than a URL and the caller decides what it means.
// So the first layer, the normalising and the scheme test, is not what stands
// between a README and a `javascript:` link. What it does is make the scheme
// test see what the BROWSER would see, so a dangerous address is recognised and
// refused rather than quietly reclassified as a file name -- which matters
// because the caller's resolveLink is then the thing deciding, and the contract
// on it (see render) is that it must never hand a path back as a raw href.
//
// Raw HTML in the source is not rendered. GitHub allows a subset; we allow
// none, because "which tags are safe" is the question with no stable answer,
// and a git host for one operator does not need <details>.
//
// What is supported is what READMEs are actually made of: headings (ATX and
// setext), paragraphs, fenced and indented code, blockquotes, ordered and
// unordered lists including task lists and nesting, GFM tables, thematic
// breaks, inline code, emphasis, strikethrough, links (inline, reference and
// bare), images, hard line breaks and character entities.

(function (global) {
  'use strict';

  // -------------------------------------------------------------------------
  // Text
  // -------------------------------------------------------------------------

  // Enough named entities to cover what turns up in a README. Anything else is
  // left as written, which is the honest failure: the reader sees the source
  // rather than a wrong character.
  var NAMED = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
    hellip: '…', mdash: '—', ndash: '–', copy: '©',
    reg: '®', trade: '™', laquo: '«', raquo: '»',
    middot: '·', bull: '•', deg: '°', plusmn: '±',
    times: '×', divide: '÷', larr: '←', rarr: '→',
    harr: '↔', uarr: '↑', darr: '↓', check: '✓',
    ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’'
  };

  var ENTITY = /&(#\d{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/g;

  function decodeEntities(text) {
    if (text.indexOf('&') < 0) return text;
    return text.replace(ENTITY, function (whole, body) {
      if (body.charAt(0) === '#') {
        var hex = body.charAt(1) === 'x' || body.charAt(1) === 'X';
        var cp = hex ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
        if (!isFinite(cp) || cp <= 0 || cp > 0x10ffff) return whole;
        try { return String.fromCodePoint(cp); } catch (e) { return whole; }
      }
      // hasOwnProperty rather than a bare lookup: `&constructor;` would
      // otherwise find something on the prototype and put it in the document.
      return Object.prototype.hasOwnProperty.call(NAMED, body) ? NAMED[body] : whole;
    });
  }

  // -------------------------------------------------------------------------
  // The one attribute surface
  // -------------------------------------------------------------------------

  var SCHEME = /^([A-Za-z][A-Za-z0-9+.\-]*):/;
  var LINK_SCHEME = /^(https?|mailto)$/i;
  var DATA_IMAGE = /^data:image\/(png|jpeg|gif|webp|avif|bmp);base64,[A-Za-z0-9+/=\s]*$/i;

  // Returns a description of where a URL points, or null for "do not link this
  // at all". Never returns a string to be dropped into href unexamined.
  //
  //   { href }   an absolute address safe to navigate to
  //   { path }   relative -- it means something inside the repository, and only
  //              the caller knows what
  //   { anchor } a fragment, which must NOT become a real href: the page keeps
  //              its own state in location.hash and an in-page link would wipe
  //              the route
  function safeUrl(raw, forImage) {
    // Entities first, then whitespace, then the scheme test. Any other order
    // leaves a way through.
    //
    // The whitespace rule copies what a browser does to a URL, because that is
    // what decides whether a payload runs. It DELETES tab, newline and carriage
    // return wherever they appear -- which is what makes `java<tab>script:` a
    // working address and so something that has to be caught here -- and it
    // trims leading and trailing spaces, which is what makes ` javascript:`
    // one too. It does NOT delete an interior space: the browser keeps it, a
    // space cannot hold a scheme together, and stripping it silently turns a
    // link to `<my docs/a.md>` into a link to a file that does not exist.
    var url = decodeEntities(String(raw == null ? '' : raw));
    url = url.replace(/[\x00-\x1f\x7f]/g, '').replace(/^ +| +$/g, '');
    if (!url) return null;

    var scheme = SCHEME.exec(url);
    if (scheme) {
      if (LINK_SCHEME.test(scheme[1])) return { href: url, external: true };
      // A data: image cannot run script in an <img>, and img-src already allows
      // it. A data: href can and does, so this is only ever reached for images.
      if (forImage && DATA_IMAGE.test(url)) return { href: url, external: true };
      return null;
    }
    if (url.charAt(0) === '#') return { anchor: url.slice(1) };
    // Protocol-relative is absolute and cross-origin; naming the scheme makes
    // that visible instead of inheriting ours.
    if (url.slice(0, 2) === '//') return { href: 'https:' + url, external: true };
    return { path: url };
  }

  // -------------------------------------------------------------------------
  // Small DOM helpers -- the only way anything gets built
  // -------------------------------------------------------------------------

  function el(tag, cls) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    return node;
  }

  function textNode(text) {
    return document.createTextNode(text);
  }

  function slugify(text) {
    var slug = String(text).toLowerCase()
      .replace(/[^0-9A-Za-z\u4e00-\u9fff\u3040-\u30ff]+/g, '-')
      .replace(/^-+|-+$/g, '');
    return slug || 'section';
  }

  // -------------------------------------------------------------------------
  // Inline
  // -------------------------------------------------------------------------

  var PUNCT = /[!-\/:-@\[-`{-~]/;

  // *x*, **x**, ***x***. Full CommonMark emphasis is a delimiter-stack
  // algorithm; this is the common-case version, and when it cannot find a
  // closer it emits the delimiter literally rather than guessing.
  function emphasisAt(text, i, ch) {
    var n = 0;
    while (text.charAt(i + n) === ch) n += 1;
    var use = n >= 3 ? 3 : (n >= 2 ? 2 : 1);

    // snake_case is not emphasis. An underscore only opens at a word boundary.
    if (ch === '_' && i > 0 && /[0-9A-Za-z]/.test(text.charAt(i - 1))) return null;
    var after = text.charAt(i + n);
    if (!after || /\s/.test(after)) return null;

    var j = i + n;
    while (j < text.length) {
      var c = text.charAt(j);
      if (c === '\\') { j += 2; continue; }
      if (c !== ch) { j += 1; continue; }
      var m = 0;
      while (text.charAt(j + m) === ch) m += 1;
      var closes = m >= use && !/\s/.test(text.charAt(j - 1));
      if (closes && ch === '_' && /[0-9A-Za-z]/.test(text.charAt(j + m))) closes = false;
      if (closes) return { content: text.slice(i + n, j), end: j + use, use: use };
      j += m;
    }
    return null;
  }

  // `code`, ``code with a ` in it``
  function codeSpanAt(text, i) {
    var n = 0;
    while (text.charAt(i + n) === '`') n += 1;
    var fence = text.slice(i, i + n);
    var close = text.indexOf(fence, i + n);
    while (close >= 0 && text.charAt(close + n) === '`') {
      close = text.indexOf(fence, close + n + 1);
    }
    if (close < 0) return null;
    var body = text.slice(i + n, close);
    // One space either side is stripping room for a literal backtick, not
    // content: `` ` `` is a backtick.
    if (body.length > 1 && body.charAt(0) === ' ' && body.charAt(body.length - 1) === ' ') {
      body = body.slice(1, -1);
    }
    return { content: body, end: close + n };
  }

  // The label of [text](...) or ![alt](...), honouring nesting and escapes.
  function labelEnd(text, open) {
    var depth = 0;
    for (var i = open; i < text.length; i += 1) {
      var c = text.charAt(i);
      if (c === '\\') { i += 1; continue; }
      if (c === '[') depth += 1;
      else if (c === ']') { depth -= 1; if (depth === 0) return i; }
    }
    return -1;
  }

  // (url) or (url "title"), with balanced parens in the url.
  function destinationAt(text, open) {
    var i = open + 1;
    var url = '';
    if (text.charAt(i) === '<') {
      var shut = text.indexOf('>', i + 1);
      if (shut < 0) return null;
      url = text.slice(i + 1, shut);
      i = shut + 1;
    } else {
      var depth = 0;
      var from = i;
      while (i < text.length) {
        var c = text.charAt(i);
        if (c === '\\') { i += 2; continue; }
        if (c === '(') depth += 1;
        else if (c === ')') { if (depth === 0) break; depth -= 1; }
        else if (/\s/.test(c)) break;
        i += 1;
      }
      url = text.slice(from, i);
    }
    while (/\s/.test(text.charAt(i))) i += 1;
    var title = '';
    var quote = text.charAt(i);
    if (quote === '"' || quote === "'") {
      var endQuote = text.indexOf(quote, i + 1);
      if (endQuote < 0) return null;
      title = text.slice(i + 1, endQuote);
      i = endQuote + 1;
      while (/\s/.test(text.charAt(i))) i += 1;
    }
    if (text.charAt(i) !== ')') return null;
    return { url: url.replace(/\\(.)/g, '$1'), title: title, end: i + 1 };
  }

  function appendLink(parent, target, title, fill, ctx) {
    var anchor = el('a', 'md-link');
    if (title) anchor.title = title;

    if (target.anchor) {
      // Deliberately no href. The page's own state lives in location.hash, and
      // a real in-page link would overwrite the route with a section name.
      anchor.setAttribute('role', 'link');
      anchor.tabIndex = 0;
      var jump = function (event) {
        event.preventDefault();
        var found = ctx.root.querySelector('[data-md-slug="' + CSS.escape(target.anchor) + '"]');
        if (found) found.scrollIntoView({ behavior: 'smooth', block: 'start' });
      };
      anchor.addEventListener('click', jump);
      anchor.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') jump(event);
      });
    } else if (target.href) {
      anchor.href = target.href;
      // noreferrer as much for privacy as for security: a README author should
      // not learn the address of a private instance from a click.
      anchor.target = '_blank';
      anchor.rel = 'noreferrer noopener';
    } else {
      var resolved = ctx.resolveLink ? ctx.resolveLink(target.path) : null;
      if (resolved) anchor.href = resolved;
      else anchor.setAttribute('role', 'link');
    }
    fill(anchor);
    parent.appendChild(anchor);
  }

  function appendImage(parent, target, alt, title, ctx) {
    // An external image is blocked by img-src anyway, and widening that policy
    // would let any README author log every reader's address. It becomes a link
    // instead, which says what it is and goes nowhere on its own.
    if (target.href && target.href.slice(0, 5) !== 'data:') {
      appendLink(parent, target, title, function (anchor) {
        anchor.appendChild(textNode(alt || target.href));
      }, ctx);
      return;
    }

    var img = el('img', 'md-image');
    img.alt = alt || '';
    if (title) img.title = title;
    if (target.href) {
      img.src = target.href;                 // data: image, already shape-checked
    } else if (ctx.resolveImage) {
      ctx.resolveImage(target.path, img);    // fetched through the API, as a blob
    } else {
      parent.appendChild(textNode(alt || ''));
      return;
    }
    parent.appendChild(img);
  }

  function inline(parent, text, ctx) {
    var i = 0;
    var from = 0;

    function flush(to) {
      if (to > from) parent.appendChild(textNode(decodeEntities(text.slice(from, to))));
    }
    function took(end) { i = end; from = end; }

    while (i < text.length) {
      var c = text.charAt(i);

      if (c === '\\' && PUNCT.test(text.charAt(i + 1))) {
        flush(i);
        parent.appendChild(textNode(text.charAt(i + 1)));
        took(i + 2);
        continue;
      }

      if (c === '`') {
        var code = codeSpanAt(text, i);
        if (code) {
          flush(i);
          var span = el('code', 'md-code');
          span.textContent = code.content;
          parent.appendChild(span);
          took(code.end);
          continue;
        }
      }

      if (c === '<') {
        // <https://example.com> and <a@b.c>. Everything else that looks like a
        // tag is left as text, which is the no-raw-HTML policy in one line.
        var shut = text.indexOf('>', i + 1);
        var body = shut > 0 ? text.slice(i + 1, shut) : '';
        if (body && !/[\s<]/.test(body) && (SCHEME.test(body) || body.indexOf('@') > 0)) {
          var auto = safeUrl(body.indexOf('@') > 0 && !SCHEME.test(body) ? 'mailto:' + body : body);
          if (auto) {
            flush(i);
            appendLink(parent, auto, '', function (a) { a.appendChild(textNode(body)); }, ctx);
            took(shut + 1);
            continue;
          }
        }
      }

      if (c === '!' && text.charAt(i + 1) === '[') {
        var altEnd = labelEnd(text, i + 1);
        if (altEnd > 0) {
          var dest = text.charAt(altEnd + 1) === '(' ? destinationAt(text, altEnd + 1) : null;
          var ref = dest ? null : referenceAt(text, altEnd, text.slice(i + 2, altEnd), ctx);
          var found = dest || ref;
          if (found) {
            var it = safeUrl(found.url, true);
            flush(i);
            if (it) appendImage(parent, it, text.slice(i + 2, altEnd), found.title, ctx);
            else parent.appendChild(textNode(text.slice(i + 2, altEnd)));
            took(found.end);
            continue;
          }
        }
      }

      if (c === '[') {
        var end = labelEnd(text, i);
        if (end > 0) {
          var d = text.charAt(end + 1) === '(' ? destinationAt(text, end + 1) : null;
          var r = d ? null : referenceAt(text, end, text.slice(i + 1, end), ctx);
          var hit = d || r;
          if (hit) {
            var to = safeUrl(hit.url);
            var label = text.slice(i + 1, end);
            flush(i);
            if (to) {
              appendLink(parent, to, hit.title, function (a) { inline(a, label, ctx); }, ctx);
            } else {
              inline(parent, label, ctx);
            }
            took(hit.end);
            continue;
          }
        }
      }

      if (c === '~' && text.charAt(i + 1) === '~') {
        var strike = text.indexOf('~~', i + 2);
        if (strike > 0) {
          flush(i);
          var del = el('del', 'md-strike');
          inline(del, text.slice(i + 2, strike), ctx);
          parent.appendChild(del);
          took(strike + 2);
          continue;
        }
      }

      if (c === '*' || c === '_') {
        var em = emphasisAt(text, i, c);
        if (em) {
          flush(i);
          var outer = el(em.use === 2 ? 'strong' : 'em');
          var inner = outer;
          if (em.use === 3) { inner = el('strong'); outer.appendChild(inner); }
          inline(inner, em.content, ctx);
          parent.appendChild(outer);
          took(em.end);
          continue;
        }
      }

      if ((c === 'h' || c === 'w') && /^(https?:\/\/|www\.)/.test(text.slice(i))) {
        var bare = /^(?:https?:\/\/|www\.)[^\s<]*[^\s<!-.:-@\[-`{-~]/.exec(text.slice(i));
        if (bare) {
          var raw = bare[0];
          var url = safeUrl(raw.slice(0, 4) === 'www.' ? 'https://' + raw : raw);
          if (url) {
            flush(i);
            appendLink(parent, url, '', function (a) { a.appendChild(textNode(raw)); }, ctx);
            took(i + raw.length);
            continue;
          }
        }
      }

      i += 1;
    }
    flush(text.length);
  }

  // [text][label], [text][] and [text]
  function referenceAt(text, labelClose, label, ctx) {
    var key, end;
    if (text.charAt(labelClose + 1) === '[') {
      var shut = text.indexOf(']', labelClose + 2);
      if (shut < 0) return null;
      key = text.slice(labelClose + 2, shut) || label;
      end = shut + 1;
    } else {
      key = label;
      end = labelClose + 1;
    }
    var def = ctx.refs[key.toLowerCase().replace(/\s+/g, ' ').trim()];
    if (!def) return null;
    return { url: def.url, title: def.title, end: end };
  }

  // -------------------------------------------------------------------------
  // Blocks
  // -------------------------------------------------------------------------

  var FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^`]*)$/;
  var ATX = /^ {0,3}(#{1,6})(?:\s+(.*?))?\s*$/;
  var RULE = /^ {0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$/;
  var BULLET = /^(\s*)([-*+])(\s+)(.*)$/;
  var ORDERED = /^(\s*)(\d{1,9})([.)])(\s+)(.*)$/;
  var QUOTE = /^ {0,3}>\s?(.*)$/;
  var SETEXT = /^ {0,3}(=+|-+)\s*$/;
  var TABLE_RULE = /^ {0,3}\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;

  function isBlank(line) { return /^\s*$/.test(line); }

  function startsBlock(line) {
    return isBlank(line) || FENCE.test(line) || ATX.test(line) || RULE.test(line) ||
           BULLET.test(line) || ORDERED.test(line) || QUOTE.test(line);
  }

  // A row of a GFM table, honouring \| inside a cell.
  function tableCells(line) {
    var cells = [];
    var cell = '';
    var text = line.trim();
    if (text.charAt(0) === '|') text = text.slice(1);
    if (text.charAt(text.length - 1) === '|' && text.charAt(text.length - 2) !== '\\') {
      text = text.slice(0, -1);
    }
    for (var i = 0; i < text.length; i += 1) {
      var c = text.charAt(i);
      if (c === '\\' && text.charAt(i + 1) === '|') { cell += '|'; i += 1; continue; }
      if (c === '|') { cells.push(cell.trim()); cell = ''; continue; }
      cell += c;
    }
    cells.push(cell.trim());
    return cells;
  }

  function blocks(parent, lines, ctx) {
    var i = 0;

    while (i < lines.length) {
      var line = lines[i];

      if (isBlank(line)) { i += 1; continue; }

      var fence = FENCE.exec(line);
      if (fence) {
        var mark = fence[1].charAt(0);
        var body = [];
        i += 1;
        while (i < lines.length && !new RegExp('^ {0,3}' + mark + '{' + fence[1].length + ',}\\s*$').test(lines[i])) {
          body.push(lines[i]);
          i += 1;
        }
        i += 1;                                   // the closing fence, if there was one
        appendCode(parent, body.join('\n'), (fence[2] || '').trim().split(/\s+/)[0], ctx);
        continue;
      }

      var atx = ATX.exec(line);
      if (atx) {
        appendHeading(parent, atx[1].length, (atx[2] || '').replace(/\s+#+\s*$/, ''), ctx);
        i += 1;
        continue;
      }

      if (RULE.test(line)) { parent.appendChild(el('hr', 'md-rule')); i += 1; continue; }

      if (QUOTE.test(line)) {
        var quoted = [];
        while (i < lines.length && !isBlank(lines[i])) {
          var q = QUOTE.exec(lines[i]);
          // A lazy continuation line belongs to the quote's paragraph.
          if (!q && startsBlock(lines[i])) break;
          quoted.push(q ? q[1] : lines[i]);
          i += 1;
        }
        var quote = el('blockquote', 'md-quote');
        blocks(quote, quoted, ctx);
        parent.appendChild(quote);
        continue;
      }

      if (BULLET.test(line) || ORDERED.test(line)) {
        i = appendList(parent, lines, i, ctx);
        continue;
      }

      // A table is a header row only if the line under it is the delimiter.
      if (line.indexOf('|') >= 0 && i + 1 < lines.length &&
          TABLE_RULE.test(lines[i + 1]) && lines[i + 1].indexOf('-') >= 0) {
        i = appendTable(parent, lines, i, ctx);
        continue;
      }

      if (/^ {4,}\S/.test(line)) {
        var indented = [];
        while (i < lines.length && (/^ {4,}/.test(lines[i]) || isBlank(lines[i]))) {
          indented.push(lines[i].slice(4));
          i += 1;
        }
        while (indented.length && isBlank(indented[indented.length - 1])) indented.pop();
        appendCode(parent, indented.join('\n'), '', ctx);
        continue;
      }

      // Paragraph, unless the next line underlines it into a heading.
      var para = [];
      while (i < lines.length && !isBlank(lines[i])) {
        if (para.length && startsBlock(lines[i])) break;
        if (para.length && SETEXT.test(lines[i]) && !RULE.test(lines[i])) {
          appendHeading(parent, lines[i].trim().charAt(0) === '=' ? 1 : 2, para.join(' '), ctx);
          para = null;
          i += 1;
          break;
        }
        para.push(lines[i].replace(/^\s+/, ''));
        i += 1;
      }
      if (!para) continue;
      if (para.length) appendParagraph(parent, para, ctx);
    }
  }

  function appendParagraph(parent, lines, ctx) {
    var p = el('p', 'md-paragraph');
    for (var i = 0; i < lines.length; i += 1) {
      // Two trailing spaces, or a trailing backslash, is a hard break.
      var line = lines[i];
      var hard = /( {2,}|\\)$/.test(line);
      inline(p, line.replace(/( +|\\)$/, ''), ctx);
      if (i < lines.length - 1) p.appendChild(hard ? el('br') : textNode(' '));
    }
    parent.appendChild(p);
  }

  function appendHeading(parent, level, text, ctx) {
    var h = el('h' + level, 'md-heading');
    inline(h, text, ctx);
    var slug = slugify(h.textContent);
    var seen = ctx.slugs[slug] || 0;
    ctx.slugs[slug] = seen + 1;
    h.setAttribute('data-md-slug', seen ? slug + '-' + seen : slug);
    parent.appendChild(h);
  }

  function appendCode(parent, source, lang, ctx) {
    var pre = el('pre', 'md-pre code-block');
    var code = el('code');
    code.textContent = source;
    pre.appendChild(code);
    parent.appendChild(pre);
    if (lang && ctx.highlight) ctx.highlight(code, lang);
  }

  function appendList(parent, lines, start, ctx) {
    var first = BULLET.exec(lines[start]) || ORDERED.exec(lines[start]);
    var ordered = !BULLET.test(lines[start]);
    var list = el(ordered ? 'ol' : 'ul', 'md-list');
    if (ordered && first[2] !== '1') list.start = Number(first[2]);

    var baseIndent = first[1].length;
    var i = start;
    var loose = false;

    while (i < lines.length) {
      var m = BULLET.exec(lines[i]) || ORDERED.exec(lines[i]);
      if (!m || m[1].length < baseIndent) break;
      // A deeper marker belongs to the item above, not to this list.
      if (m[1].length > baseIndent) break;
      if (ordered !== !BULLET.test(lines[i])) break;

      var markerWidth = m[1].length + (ordered ? m[2].length + 1 : 1) + (ordered ? m[4] : m[3]).length;
      var content = [ordered ? m[5] : m[4]];
      i += 1;

      while (i < lines.length) {
        if (isBlank(lines[i])) {
          // A blank line ends the item unless something indented follows it.
          var next = i + 1;
          if (next < lines.length && /^\s*\S/.test(lines[next]) &&
              lines[next].search(/\S/) >= markerWidth) {
            loose = true;
            content.push('');
            i += 1;
            continue;
          }
          break;
        }
        if (lines[i].search(/\S/) >= markerWidth) {
          content.push(lines[i].slice(markerWidth));
          i += 1;
          continue;
        }
        // Lazy continuation of the item's paragraph.
        if (!startsBlock(lines[i])) { content.push(lines[i].replace(/^\s+/, '')); i += 1; continue; }
        break;
      }

      list.appendChild(makeItem(content, ctx));
    }

    if (loose) list.classList.add('md-list-loose');
    parent.appendChild(list);
    return i;
  }

  function makeItem(content, ctx) {
    var item = el('li', 'md-item');

    // - [ ] and - [x], which READMEs use as checklists. The box is disabled:
    // it reports state, it does not collect any.
    var task = /^\[([ xX])\]\s+(.*)$/.exec(content[0] || '');
    if (task) {
      var box = el('input', 'md-task');
      box.type = 'checkbox';
      box.disabled = true;
      box.checked = task[1] !== ' ';
      item.appendChild(box);
      content = content.slice();
      content[0] = task[2];
      item.classList.add('md-item-task');
    }

    var holder = document.createDocumentFragment();
    blocks(holder, content, ctx);
    // A tight item is a bare paragraph: unwrap it so the bullet sits on the
    // text rather than above a block.
    if (holder.childNodes.length === 1 && holder.firstChild.nodeName === 'P') {
      while (holder.firstChild.firstChild) item.appendChild(holder.firstChild.firstChild);
    } else {
      item.appendChild(holder);
    }
    return item;
  }

  function appendTable(parent, lines, start, ctx) {
    var header = tableCells(lines[start]);
    var align = tableCells(lines[start + 1]).map(function (spec) {
      var left = spec.charAt(0) === ':';
      var right = spec.charAt(spec.length - 1) === ':';
      if (left && right) return 'center';
      if (right) return 'right';
      if (left) return 'left';
      return '';
    });

    var table = el('table', 'md-table');
    var thead = el('thead');
    var hrow = el('tr');
    header.forEach(function (cell, n) {
      var th = el('th');
      if (align[n]) th.style.textAlign = align[n];
      inline(th, cell, ctx);
      hrow.appendChild(th);
    });
    thead.appendChild(hrow);
    table.appendChild(thead);

    var tbody = el('tbody');
    var i = start + 2;
    while (i < lines.length && !isBlank(lines[i]) && lines[i].indexOf('|') >= 0) {
      var row = el('tr');
      tableCells(lines[i]).forEach(function (cell, n) {
        var td = el('td');
        if (align[n]) td.style.textAlign = align[n];
        inline(td, cell, ctx);
        row.appendChild(td);
      });
      tbody.appendChild(row);
      i += 1;
    }
    table.appendChild(tbody);

    var scroll = el('div', 'md-table-scroll');
    scroll.appendChild(table);
    parent.appendChild(scroll);
    return i;
  }

  // -------------------------------------------------------------------------

  var DEFINITION = /^ {0,3}\[([^\]]+)\]:\s*(\S+)(?:\s+["'(](.*)["')])?\s*$/;

  // options:
  //   resolveLink(path)        -> href for a path inside the repository, or
  //                               null for "render the text, link nothing".
  //                               THE CONTRACT: whatever comes back is used as
  //                               an href unexamined, so it must be built by
  //                               the caller -- a route, an API address -- and
  //                               must never be `path` handed straight back.
  //                               safeUrl has already refused every scheme it
  //                               recognises as dangerous, but a path is
  //                               exactly what it could not classify.
  //   resolveImage(path, img)  -> fill in img.src, however the caller fetches.
  //   highlight(codeEl, lang)  -> colour a fenced block, or do nothing.
  function render(source, options) {
    var opts = options || {};
    var root = el('div', 'md');
    var ctx = {
      root: root,
      refs: {},
      slugs: {},
      resolveLink: opts.resolveLink,
      resolveImage: opts.resolveImage,
      highlight: opts.highlight
    };

    var text = String(source == null ? '' : source).replace(/\r\n?/g, '\n');
    // Leading tabs only: indentation is structure, a tab inside a line is data.
    var lines = text.split('\n').map(function (line) {
      return line.replace(/^\t+/, function (tabs) { return new Array(tabs.length * 4 + 1).join(' '); });
    });

    // Reference definitions are collected first and removed, so [x][y] resolves
    // no matter which order the two appear in.
    var body = [];
    var inFence = false;
    lines.forEach(function (line) {
      if (FENCE.test(line)) inFence = !inFence;
      var def = !inFence && DEFINITION.exec(line);
      if (def) {
        ctx.refs[def[1].toLowerCase().replace(/\s+/g, ' ').trim()] = { url: def[2], title: def[3] || '' };
        return;
      }
      body.push(line);
    });

    blocks(root, body, ctx);
    return root;
  }

  global.glMarkdown = { render: render, safeUrl: safeUrl, slugify: slugify };
}(window));
