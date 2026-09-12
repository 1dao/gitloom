(function () {
  'use strict';

  // The password is exchanged for a token that expires on its own, and only the
  // token is ever stored. What sessionStorage holds is then a bounded, revocable
  // credential rather than the account password behind it.
  var SESSION_HOURS = 12;

  var state = {
    repos: [],
    repo: null,
    branch: '',
    path: '',
    commits: [],
    commitSkip: 0,
    commitHasMore: false,
    issues: [],
    issue: null,
    issueState: 'open',
    // The ref lists loadBranches already fetched, kept so the compare view can
    // fill two more selects without asking for them a second time.
    refNames: { branches: [], tags: [] },
    compareBase: '',
    compareHead: '',
    collaborators: [],
    username: '',
    token: '',
    // Never read from storage and never inferred from the credential: the
    // server answers it on every load. See loadSelf.
    admin: false,
    toastTimer: null,
    fileBlobUrl: '',   // released in releaseFileBlob; see loadFile
    fileText: '',      // the open file's source, so the raw/rendered toggle is free
    fileRaw: false,    // Markdown opens rendered; this is the toggle's state
    // Which view is showing and which file is open used to live only in the
    // DOM. The address bar has to be able to say both, so they live here now.
    view: 'code',
    file: '',
    // The line a blob URL names, and the path a commit list is filtered to.
    // Both are route state rather than panel state, which is the whole point of
    // them: a line worth pointing at is a line worth linking to.
    fileLine: 0,
    commitPath: '',
    searchKind: 'content',
  };

  // Every navigation takes a ticket. A response whose ticket is no longer the
  // current one belongs to a repository, branch or directory the user has
  // already left, and rendering it would show them the wrong tree — which is
  // not theoretical on a server where each listing forks a git process, so a
  // slow response really does arrive after a fast one issued later.
  var seq = { repos: 0, view: 0, file: 0, diff: 0, commits: 0, access: 0, issues: 0, issue: 0, readme: 0,
              compare: 0, comparediff: 0 };
  var COMMIT_PAGE_SIZE = 25;

  // The two cells of each file row that the last-commit walk fills in, by entry
  // name. Replaced wholesale by every listing rather than emptied, so a response
  // still in flight can tell by identity that its rows are gone.
  var treeCells = Object.create(null);

  // Assets are stamped with a content digest and served immutable, but the page
  // itself is no-cache and a STALE digest still returns the CURRENT script. So a
  // tab left open across a deploy can end up running new code against old
  // markup, and an element added in that deploy is then null. Anything that
  // reaches for a node this file did not always have checks for it: a control
  // that has not shipped to that tab yet should cost its own feature, not the
  // file listing it happens to be rendered next to.
  var $ = function (id) { return document.getElementById(id); };
  var $$ = function (selector) { return Array.prototype.slice.call(document.querySelectorAll(selector)); };

  // Keep the preference local to this browser and apply it before the first
  // network render so the page does not flash between palettes.
  function applyTheme(theme) {
    var light = theme === 'light';
    document.documentElement.dataset.theme = light ? 'light' : 'dark';
    var toggle = $('theme-toggle');
    if (toggle) {
      toggle.textContent = light ? '☾' : '☀︎';
      toggle.title = light ? '切换到深色主题' : '切换到浅色主题';
      toggle.setAttribute('aria-label', toggle.title);
    }
  }
  var initialTheme = 'dark';
  try { initialTheme = localStorage.getItem('gitloom-theme') || 'dark'; } catch (_) {}
  applyTheme(initialTheme);
  if ($('theme-toggle')) $('theme-toggle').addEventListener('click', function () {
    var next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    try { localStorage.setItem('gitloom-theme', next); } catch (_) {}
    applyTheme(next);
  });

  function beginView() {
    seq.view += 1;
    seq.file += 1;   // a panel opened under the old view must not land either
    seq.diff += 1;
    seq.commits += 1;
    seq.issues += 1;
    seq.issue += 1;
    seq.readme += 1;
    return seq.view;
  }

  function viewIsCurrent(ticket) { return ticket === seq.view; }

  // The API answers in English — its error text is also what git clients read —
  // so the status is what gets translated here. The server's own wording is
  // kept only as the fallback for a status we have nothing better for, rather
  // than being pasted into the middle of a Chinese interface.
  var STATUS_TEXT = {
    400: '请求无效',
    401: '需要登录',
    403: '没有访问权限',
    404: '没有找到内容',
    413: '内容超出服务器允许的大小',
    429: '尝试过于频繁，请稍后再试',
    500: '服务器内部错误',
    502: '服务器暂时无法响应',
    503: '服务暂时不可用',
  };

  function statusMessage(status, fallback) {
    return STATUS_TEXT[status] || fallback || ('请求失败（' + status + '）');
  }

  // The rule above — render the status, not the server's English — is right for
  // a panel, where the status IS the news. It is wrong for a form, where the
  // difference between "that name is taken" and "that name is not allowed" is
  // the entire message and both are a 400. So the handful of answers a create
  // or a delete can produce are translated, and everything else still falls
  // back to the status.
  var DETAIL_TEXT = [
    ['repository already exists', '同名仓库已存在'],
    ['bad repository name', '仓库名不合法：首字符只能是字母、数字或下划线，其后可用字母、数字、点、下划线、连字符'],
    ['bad owner name', '账号名不合法'],
    ['bad default branch name', '默认分支名不合法'],
    ['only the owner or an administrator may delete', '只有仓库所有者或管理员可以删除'],
    ['only the owner or an administrator may update', '只有仓库所有者或管理员可以编辑'],
    ['description must be a string', '描述必须是文字'],
    ['private must be a boolean', '私有设置必须是布尔值'],
    ['no repository fields to update', '没有需要保存的修改'],
    ['the repository index is unavailable', '仓库索引暂时读不到，请稍后再试'],
    ['no such repository', '仓库不存在，可能已经被删除'],
    ['cannot create a repository under another account', '不能在别人的账号下建仓库'],
    ['a repository with that name already exists', '这个名字已经被另一个仓库占用了'],
    ['bad new repository name', '新仓库名不合法：首字符只能是字母、数字或下划线，其后可用字母、数字、点、下划线、连字符'],
    // The usual cause on Windows is a clone or push still holding the
    // directory open, and "try again in a moment" is the actionable half.
    ['could not rename the repository directory', '仓库目录暂时无法移动（可能有克隆或推送正在进行），稍后再试'],
    ['repository renamed, but its issues could not be moved', '仓库已改名，但 issue 没有跟着迁移，请检查服务端日志'],
    ['name must be a string', '仓库名必须是文字'],
    ['no such token', '这个令牌不存在，可能已经被吊销'],
    ['a token id is required', '缺少令牌标识'],
    ['a search string is required', '请输入要搜索的内容'],
    ['search string is too long', '搜索内容太长了'],
    ['search failed', '搜索没能完成，请检查服务端日志'],
  ];

  function detailMessage(error) {
    var detail = (error && error.detail) || '';
    var descriptionLimit = detail.match(/description must be at most (\d+) bytes/);
    if (descriptionLimit) return '描述太长了（最多 ' + descriptionLimit[1] + ' 字节）';
    for (var i = 0; i < DETAIL_TEXT.length; i += 1) {
      if (detail.indexOf(DETAIL_TEXT[i][0]) !== -1) return DETAIL_TEXT[i][1];
    }
    return (error && error.message) || '操作失败';
  }

  function showToast(message) {
    var toast = $('toast');
    toast.textContent = message || '';
    toast.classList.add('show');
    if (state.toastTimer) window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(function () { toast.classList.remove('show'); }, 3200);
  }

  function setLoading(container, message) {
    container.textContent = '';
    var row = document.createElement('div');
    row.className = 'loading-row';
    row.textContent = message || '正在加载…';
    container.appendChild(row);
  }

  function setError(container, message) {
    container.textContent = '';
    var row = document.createElement('div');
    row.className = 'empty-row';
    row.textContent = message || '暂时无法读取数据';
    container.appendChild(row);
  }

  function loadCredentials() {
    try {
      state.username = sessionStorage.getItem('gitloom.username') || '';
      state.token = sessionStorage.getItem('gitloom.token') || '';
    } catch (_) {
      state.username = '';
      state.token = '';
    }
    if (!state.token) state.username = '';
  }

  function saveCredentials(username, token) {
    state.username = username;
    state.token = token;
    try {
      sessionStorage.setItem('gitloom.username', username);
      sessionStorage.setItem('gitloom.token', token);
    } catch (_) {}
  }

  function clearCredentials() {
    state.username = '';
    state.token = '';
    state.admin = false;
    try {
      sessionStorage.removeItem('gitloom.username');
      sessionStorage.removeItem('gitloom.token');
      sessionStorage.removeItem('gitloom.password');   // written by older builds
    } catch (_) {}
  }

  function encodeBasic(username, secret) {
    return window.btoa(unescape(encodeURIComponent(username + ':' + secret)));
  }

  function authHeaders() {
    var headers = { Accept: 'application/json' };
    if (state.username && state.token) {
      headers.Authorization = 'Basic ' + encodeBasic(state.username, state.token);
    }
    return headers;
  }

  function serverText(response) {
    return response.text().then(function (raw) {
      try {
        var data = JSON.parse(raw);
        return data.error || data.message || '';
      } catch (_) {
        return raw || '';
      }
    }, function () { return ''; });
  }

  function failure(response) {
    return serverText(response).then(function (detail) {
      var error = new Error(statusMessage(response.status, detail));
      error.status = response.status;
      error.detail = detail;   // for the console; never rendered on its own
      throw error;
    });
  }

  function api(path, options) {
    var opts = options || {};
    // Keep the credential that signed this request. A slow response from an
    // older account must not invalidate a newer login in the same tab.
    var requestToken = state.token;
    opts.headers = Object.assign({}, authHeaders(), opts.headers || {});
    return fetch(path, opts).then(function (response) {
      if (response.ok) return response;
      if (response.status === 401 && requestToken && state.token === requestToken) {
        // The token has expired or been revoked. Say so once, here, rather than
        // letting every panel report "需要登录" on its own.
        clearCredentials();
        closeRepoView();
        updateAuthButton();
        showToast('登录已过期，请重新登录');
      }
      return failure(response);
    });
  }

  function json(path) {
    return api(path).then(function (response) { return response.json(); });
  }

  // Exchange the password for a short-lived token. The password never reaches
  // storage: it is used for exactly this one request and then dropped.
  function login(username, password) {
    return fetch('/api/v1/user/tokens', {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: 'Basic ' + encodeBasic(username, password),
      },
      body: JSON.stringify({ label: 'web browser', ttl_seconds: SESSION_HOURS * 3600 }),
    }).then(function (response) {
      if (!response.ok) return failure(response);
      return response.json();
    }).then(function (data) {
      if (!data || !data.token) throw new Error('服务器没有返回访问令牌');
      saveCredentials(username, data.token);
    });
  }

  // Who the server says we are. The administrator bit cannot come from the
  // credential this page is holding: storing it beside the token would be
  // repeating a claim nobody checked, and it would go on being true in this tab
  // after the account lost the bit — which draws controls whose every request
  // then 403s with no explanation. So it is asked for, on load and after a
  // login, and dropped by clearCredentials.
  //
  // api() turns a 401 here into the ordinary "session expired" path, which
  // makes this also the moment a stored token that has expired is found —
  // rather than whichever panel happened to load first.
  function loadSelf() {
    if (!state.username || !state.token) {
      state.admin = false;
      updateAuthButton();
      return Promise.resolve();
    }
    return json('/api/v1/user').then(function (me) {
      state.admin = !!(me && me.admin);
    }).catch(function () {
      state.admin = false;
    }).then(function () { updateAuthButton(); });
  }

  function encodeRef(ref) {
    return encodeURIComponent(ref || 'main');
  }

  function encodePath(path) {
    return (path || '').split('/').filter(Boolean).map(encodeURIComponent).join('/');
  }

  function repoPath(suffix) {
    if (!state.repo) return '';
    return '/api/v1/repos/' + encodeURIComponent(state.repo.owner) + '/' +
      encodeURIComponent(state.repo.name) + suffix;
  }

  function updateAuthButton() {
    var button = $('auth-toggle');
    button.textContent = state.username ? state.username + ' · 退出' : '登录';
    // Tokens belong to an account, so the control only means anything once
    // there is one signed in.
    $('manage-tokens').hidden = !state.username;
    // Administrator-only, and the flag is the server's answer rather than
    // anything this page stored — see loadSelf. Guarded because a tab left open
    // across the deploy that added it is running this file against markup that
    // has no such button.
    var users = $('manage-users');
    if (users) users.hidden = !state.admin;
    renderProfile();
    syncWriteActions();
  }

  // The head of the landing page. Signed out it still says something true --
  // this is the instance, and what is on it is what anybody may read -- rather
  // than going blank until somebody logs in.
  function renderProfile() {
    var name = state.username || 'gitloom';
    $('profile-name').textContent = name;
    $('profile-handle').textContent = state.username
      ? (state.admin ? '已登录 · 管理员' : '已登录')
      : '未登录 · 只列出公开仓库';
    // An account has no avatar to serve, so its initial stands in. Upper-cased
    // for the Latin case and left alone for everything else, which is what
    // toUpperCase already does for a CJK name.
    $('profile-avatar').textContent = name.slice(0, 1).toUpperCase();
  }

  // Owner-only actions, plus the administrator. The server has always allowed
  // both — `rec.owner ~= user.username and not user.admin` guards update and
  // delete alike — so hiding these from an administrator never protected
  // anything; it only meant the button had to be a curl.
  function syncWriteActions() {
    var signedIn = !!state.username;
    $('new-repo').hidden = !signedIn;
    $('new-issue').hidden = !signedIn || !state.repo;
    var canManage = signedIn && state.repo &&
      (state.repo.owner === state.username || state.admin);
    $('edit-repo').hidden = !canManage;
    $('manage-access').hidden = !canManage;
    $('delete-repo').hidden = !canManage;
    syncIssueActions();
  }

  // The repository-shaped glyph the cards and the page header share. Inlined
  // per call rather than cloned from one node: an SVG in the DOM is a node like
  // any other, and two cards cannot hold the same one.
  function repoIcon() {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'repo-icon');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('aria-hidden', 'true');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M2.5 2.8A1.8 1.8 0 0 1 4.3 1H13.4v10.2H4.3a1.8 1.8 0 0 0 0 3.6h9.1v-3.6');
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '1.4');
    path.setAttribute('stroke-linejoin', 'round');
    svg.appendChild(path);
    return svg;
  }

  function renderRepos() {
    var grid = $('repo-grid');
    var query = ($('repo-search').value || '').trim().toLowerCase();
    grid.textContent = '';
    var visible = state.repos.filter(function (repo) {
      var haystack = (repo.owner + '/' + repo.name + ' ' + (repo.description || '')).toLowerCase();
      return !query || haystack.indexOf(query) !== -1;
    });
    $('repo-count').textContent = String(state.repos.length);
    $('owned-count').textContent = String(state.repos.filter(function (repo) {
      return state.username && repo.owner === state.username;
    }).length);
    if (!visible.length) {
      setError(grid, query ? '没有匹配的仓库' : '暂无可见仓库');
      return;
    }
    visible.forEach(function (repo) {
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'repo-card';
      card.dataset.repo = repo.full_name;

      var title = document.createElement('span');
      title.className = 'repo-card-title';
      title.appendChild(repoIcon());
      var name = document.createElement('span');
      name.className = 'repo-name';
      // owner/name, because one instance can hold the same name under two
      // accounts and the card is the only place that disambiguates them.
      name.textContent = repo.owner + '/' + repo.name;
      title.appendChild(name);
      var badge = document.createElement('span');
      badge.className = 'repo-badge' + (repo.private ? ' private' : '');
      badge.textContent = repo.private ? '私有' : '公开';
      title.appendChild(badge);
      card.appendChild(title);

      var description = document.createElement('p');
      description.className = 'repo-card-desc';
      description.textContent = repo.description || '';
      card.appendChild(description);

      var foot = document.createElement('span');
      foot.className = 'repo-card-foot';
      var branch = document.createElement('code');
      branch.textContent = repo.default_branch || 'main';
      foot.appendChild(branch);
      // The push, when there has been one: the cards are in push order, so a
      // card dated by its creation would be sitting in a sequence its own text
      // contradicts. A repository nobody has pushed to still says when it was
      // made, because that is the only date it has and it is the one deciding
      // where the card sits.
      var stamp = repo.pushed_at ? { at: repo.pushed_at, label: '推送于 ' }
                                 : (repo.created_at ? { at: repo.created_at, label: '建于 ' } : null);
      if (stamp) {
        var when = document.createElement('span');
        when.textContent = stamp.label + relativeTime(stamp.at);
        when.title = formatDate(stamp.at);
        foot.appendChild(when);
      }
      card.appendChild(foot);

      card.addEventListener('click', function () { selectRepo(repo); });
      grid.appendChild(card);
    });
  }

  function loadRepos() {
    var ticket = (seq.repos += 1);
    setLoading($('repo-grid'), '正在读取仓库…');
    return json('/api/v1/repos').then(function (data) {
      if (ticket !== seq.repos) return state.repos;
      state.repos = Array.isArray(data.repos) ? data.repos : [];
      if (state.repo) {
        var current = state.repos.find(function (repo) { return repo.full_name === state.repo.full_name; });
        if (current) {
          state.repo = current;
          renderRepoMeta(current);
        } else {
          // The selected repository may have been deleted or become invisible
          // after a credential/account change. Do not leave its old contents on
          // screen when the fresh listing no longer contains it.
          closeRepoView();
        }
      }
      renderRepos();
      return state.repos;
    }).catch(function (error) {
      if (ticket !== seq.repos) throw error;
      // The grid is where the reader is already looking, and it carries the
      // actual reason -- which is why there is no separate status light saying
      // the same thing in fewer words.
      setError($('repo-grid'), error.status === 401 ? '登录后查看仓库' : error.message);
      state.repos = [];
      $('repo-count').textContent = '0';
      $('owned-count').textContent = '0';
      throw error;
    });
  }

  function openCreate() {
    $('create-message').textContent = '';
    $('create-name').value = '';
    $('create-description').value = '';
    $('create-private').checked = false;
    $('create-dialog').showModal();
    $('create-name').focus();
  }

  function openDelete() {
    if (!state.repo) return;
    $('delete-message').textContent = '';
    $('delete-confirm').value = '';
    $('delete-expect').textContent = state.repo.name;
    $('delete-dialog').showModal();
    $('delete-confirm').focus();
  }

  function openEdit() {
    if (!state.repo) return;
    $('edit-message').textContent = '';
    $('edit-name').value = state.repo.name;
    $('edit-description').value = state.repo.description || '';
    $('edit-private').checked = !!state.repo.private;
    $('edit-dialog').showModal();
    $('edit-name').focus();
  }

  // `owner` is left to the server, which defaults it to whoever is signed in.
  // Sending it would only introduce a way for the page to be wrong about who
  // that is.
  function createRepo(name, description, isPrivate) {
    return api('/api/v1/repos', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name, description: description, private: isPrivate }),
    }).then(function (response) { return response.json(); });
  }

  function deleteRepo(repo) {
    return api('/api/v1/repos/' + encodeURIComponent(repo.owner) + '/' +
      encodeURIComponent(repo.name), { method: 'DELETE' });
  }

  function updateRepo(repo, changes) {
    // The server owns the byte limit for descriptions and the rules a name has
    // to satisfy. Keeping no duplicated maxlength or pattern here means a
    // future config change cannot leave this form with a stale ceiling, and a
    // name this page thought was fine still gets the server's reason.
    return api('/api/v1/repos/' + encodeURIComponent(repo.owner) + '/' +
      encodeURIComponent(repo.name), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(changes),
      }).then(function (response) { return response.json(); });
  }

  function collaboratorsPath(repo) {
    return '/api/v1/repos/' + encodeURIComponent(repo.owner) + '/' +
      encodeURIComponent(repo.name) + '/collaborators';
  }

  function loadCollaborators(repo) {
    var ticket = (seq.access += 1);
    var list = $('collaborator-list');
    setLoading(list, '正在读取协作者…');
    return json(collaboratorsPath(repo)).then(function (data) {
      if (ticket !== seq.access || !state.repo || state.repo.full_name !== repo.full_name) return [];
      state.collaborators = Array.isArray(data.collaborators) ? data.collaborators : [];
      renderCollaborators();
      return state.collaborators;
    }).catch(function (error) {
      if (ticket !== seq.access) return [];
      state.collaborators = [];
      setError(list, error.message);
      throw error;
    });
  }

  function putCollaborator(repo, username, permission) {
    return api(collaboratorsPath(repo) + '/' + encodeURIComponent(username), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ permission: permission }),
    }).then(function (response) { return response.json(); });
  }

  function removeCollaborator(repo, username) {
    return api(collaboratorsPath(repo) + '/' + encodeURIComponent(username), {
      method: 'DELETE',
    });
  }

  function collaboratorError(error) {
    var detail = (error && error.detail) || '';
    var known = [
      ['no such user', '账号不存在'],
      ['permission must be read or write', '权限只能是只读或可写'],
      ['the repository owner already has full access', '仓库所有者不需要添加为协作者'],
      ['account is not a collaborator', '这个账号不是协作者'],
      ['only the owner or an administrator may manage collaborators', '只有仓库所有者或管理员可以管理协作者'],
    ];
    for (var i = 0; i < known.length; i += 1) {
      if (detail.indexOf(known[i][0]) !== -1) return known[i][1];
    }
    return detailMessage(error);
  }

  function renderCollaborators() {
    var list = $('collaborator-list');
    list.textContent = '';
    if (!state.collaborators.length) {
      setError(list, '还没有协作者');
      return;
    }
    state.collaborators.forEach(function (item) {
      var row = document.createElement('div');
      row.className = 'collaborator-row';
      var name = document.createElement('strong');
      name.className = 'collaborator-name';
      name.textContent = item.username;
      row.appendChild(name);
      var permission = document.createElement('select');
      permission.className = 'collaborator-permission';
      permission.setAttribute('aria-label', item.username + ' 的权限');
      [['read', '只读'], ['write', '可写']].forEach(function (optionData) {
        var option = document.createElement('option');
        option.value = optionData[0];
        option.textContent = optionData[1];
        option.selected = item.permission === optionData[0];
        permission.appendChild(option);
      });
      row.appendChild(permission);
      var save = document.createElement('button');
      save.type = 'button';
      save.className = 'button button-quiet';
      save.textContent = '保存';
      save.addEventListener('click', function () {
        save.disabled = true;
        putCollaborator(state.repo, item.username, permission.value)
          .then(function () { showToast('协作者权限已更新'); return loadCollaborators(state.repo); })
          .catch(function (error) { $('collaborator-message').textContent = collaboratorError(error); })
          .finally(function () { save.disabled = false; });
      });
      row.appendChild(save);
      var remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-danger';
      remove.textContent = '移除';
      remove.addEventListener('click', function () {
        remove.disabled = true;
        removeCollaborator(state.repo, item.username)
          .then(function () { showToast('已移除协作者'); return loadCollaborators(state.repo); })
          .catch(function (error) { $('collaborator-message').textContent = collaboratorError(error); })
          .finally(function () { remove.disabled = false; });
      });
      row.appendChild(remove);
      list.appendChild(row);
    });
  }

  function openCollaborators() {
    if (!state.repo) return;
    $('collaborator-message').textContent = '';
    $('collaborator-user').value = '';
    $('collaborator-permission').value = 'read';
    $('access-dialog').showModal();
    $('collaborator-user').focus();
    loadCollaborators(state.repo).catch(function () {});
  }

  function issuesPath(repo, suffix) {
    return '/api/v1/repos/' + encodeURIComponent(repo.owner) + '/' +
      encodeURIComponent(repo.name) + '/issues' + (suffix || '');
  }

  function issueError(error) {
    var detail = (error && error.detail) || '';
    var known = [
      ['issue title is required', '请输入 Issue 标题'],
      ['issue title must be at most', 'Issue 标题太长了'],
      ['issue body must be at most', 'Issue 描述太长了'],
      ['issue state must be open, closed or all', 'Issue 状态不正确'],
      ['issue state must be open or closed', 'Issue 状态不正确'],
      ['comment body is required', '请输入评论内容'],
      ['only the issue author, a collaborator with write access, or an administrator may update', '只有作者、可写协作者或管理员可以修改 Issue'],
      ['no such issue', 'Issue 不存在'],
    ];
    for (var i = 0; i < known.length; i += 1) {
      if (detail.indexOf(known[i][0]) !== -1) return known[i][1];
    }
    return detailMessage(error);
  }

  // The count on the Issues tab. Open issues only -- a closed one is not
  // something the tab is asking you to look at.
  function setIssueBadge(count) {
    var badge = $('issue-count-badge');
    if (!badge) return;
    var n = Number(count);
    if (!Number.isFinite(n) || n <= 0) {
      badge.hidden = true;
      badge.textContent = '';
      return;
    }
    badge.textContent = String(n);
    badge.hidden = false;
  }

  // Cheap enough to ask for on its own: the list endpoint reports its own count
  // and this one never touches git. Called when a repository opens, and again
  // whenever the list is reloaded under a filter that cannot supply the number.
  function loadIssueBadge(repo) {
    if (!repo) return Promise.resolve();
    return json(issuesPath(repo, '?state=open')).then(function (data) {
      if (!state.repo || state.repo.full_name !== repo.full_name) return;
      setIssueBadge(data && data.count);
    }).catch(function () {});
  }

  function loadIssues(view) {
    if (!state.repo) return Promise.resolve([]);
    var repo = state.repo;
    var ticket = (seq.issues += 1);
    var list = $('issue-list');
    $('issue-detail').hidden = true;
    setLoading(list, '正在读取 Issues…');
    return json(issuesPath(repo, '?state=' + encodeURIComponent(state.issueState))).then(function (data) {
      if (!viewIsCurrent(view) || ticket !== seq.issues || !state.repo || state.repo.full_name !== repo.full_name) return [];
      state.issues = Array.isArray(data.issues) ? data.issues : [];
      // This list IS the open list, so it already carries the number; under any
      // other filter it does not, and the badge has to go and ask.
      if (state.issueState === 'open') setIssueBadge(data.count);
      else loadIssueBadge(repo);
      renderIssues();
      return state.issues;
    }).catch(function (error) {
      if (!viewIsCurrent(view) || ticket !== seq.issues) return [];
      state.issues = [];
      setError(list, error.message);
      return [];
    });
  }

  function renderIssues() {
    var list = $('issue-list');
    list.textContent = '';
    if (!state.issues.length) {
      setError(list, state.issueState === 'open' ? '还没有开放的 Issue' : '没有符合条件的 Issue');
      return;
    }
    state.issues.forEach(function (issue) {
      var row = document.createElement('button');
      row.type = 'button';
      row.className = 'issue-row' + (state.issue && state.issue.number === issue.number ? ' active' : '');
      var number = document.createElement('span');
      number.className = 'issue-number';
      number.textContent = '#' + issue.number;
      row.appendChild(number);
      var copy = document.createElement('span');
      copy.className = 'issue-row-copy';
      var title = document.createElement('strong');
      title.className = 'issue-row-title';
      title.textContent = issue.title;
      copy.appendChild(title);
      var meta = document.createElement('span');
      meta.className = 'issue-row-meta';
      meta.textContent = issue.author + ' · ' + formatDate(issue.updated_at) + ' · ' + (issue.comment_count || 0) + ' 条评论';
      copy.appendChild(meta);
      row.appendChild(copy);
      var statePill = document.createElement('span');
      statePill.className = 'issue-state-pill' + (issue.state === 'closed' ? ' closed' : '');
      statePill.textContent = issue.state === 'closed' ? '已关闭' : '开放';
      row.appendChild(statePill);
      row.addEventListener('click', function () { loadIssue(issue.number); });
      list.appendChild(row);
    });
  }

  function loadIssue(number) {
    if (!state.repo) return;
    var repo = state.repo;
    var ticket = (seq.issue += 1);
    var detail = $('issue-detail');
    detail.hidden = false;
    $('issue-detail-title').textContent = '正在读取…';
    releaseIssueMarkdown();
    $('issue-detail-body').textContent = '';
    $('issue-comments').textContent = '';
    $('issue-comment-form').hidden = true;
    return json(issuesPath(repo, '/' + encodeURIComponent(number))).then(function (issue) {
      if (ticket !== seq.issue || !state.repo || state.repo.full_name !== repo.full_name) return null;
      state.issue = issue;
      routeWrite();
      renderIssue(issue);
      renderIssues();
      detail.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return issue;
    }).catch(function (error) {
      if (ticket !== seq.issue) return null;
      state.issue = null;
      detail.hidden = true;
      setError($('issue-list'), issueError(error));
      return null;
    });
  }

  // Every Markdown target keeps its own object URLs (see releaseMarkdownBlobs),
  // and the issue panel is the one place those targets are DISCARDED rather
  // than re-rendered: the comment list is rebuilt from scratch every time an
  // issue is opened. Releasing the old bodies before dropping them is what
  // keeps an issue that shows a committed image from holding those bytes for
  // the life of the tab.
  function releaseIssueMarkdown() {
    releaseMarkdownBlobs($('issue-detail-body'));
    var bodies = $('issue-comments').querySelectorAll('.issue-comment-body');
    for (var i = 0; i < bodies.length; i++) releaseMarkdownBlobs(bodies[i]);
  }

  // Markdown, through the same parser the README goes through.
  //
  // An issue body is user-written text about code, so it is written the way
  // that is written: fenced blocks, lists, links. It was rendered as
  // textContent, which turned a stack trace into one long line and a checklist
  // into literal hyphens.
  //
  // Safe for the same reason the README is safe rather than for a new one —
  // glMarkdown never builds an HTML string, so there is nothing here to
  // sanitise and nothing an author can inject. Both are untrusted input; the
  // README is arguably the more hostile of the two, since anyone who can push
  // can write it.
  function renderIssueText(target, source, fallback) {
    if (!source) {
      releaseMarkdownBlobs(target);
      target.textContent = fallback || '';
      return;
    }
    renderMarkdownInto(target, source, '');
  }

  function renderIssue(issue) {
    $('issue-detail-title').textContent = '#' + issue.number + ' ' + issue.title;
    $('issue-detail-meta').textContent = issue.author + ' · ' + formatDate(issue.created_at);
    releaseIssueMarkdown();
    renderIssueText($('issue-detail-body'), issue.body, '没有描述');
    $('issue-comment-count').textContent = (issue.comments || []).length + ' 条';
    var comments = $('issue-comments');
    comments.textContent = '';
    (issue.comments || []).forEach(function (comment) {
      var item = document.createElement('article');
      item.className = 'issue-comment';
      var meta = document.createElement('div');
      meta.className = 'issue-comment-meta';
      meta.textContent = comment.author + ' · ' + formatDate(comment.created_at);
      item.appendChild(meta);
      var body = document.createElement('div');
      body.className = 'issue-comment-body md';
      item.appendChild(body);
      renderIssueText(body, comment.body, '');
      comments.appendChild(item);
    });
    syncIssueActions();
  }

  // Who may act on the OPEN issue.
  //
  // Split out of renderIssue because the answer changes when the CREDENTIAL
  // changes and not only when the issue does. Only a render ever set these, so
  // signing in while looking at an issue left it with no controls at all — no
  // edit, no close, no comment box — until it was clicked a second time.
  // syncWriteActions asks the same question one level up and now asks this one
  // with it.
  //
  // The rule the server enforces is issue_can_edit: the author, a write
  // collaborator, or an administrator. The administrator was missing here while
  // the same page already draws every other owner-only control from
  // `state.admin`. A write collaborator still misses out — the page is not told
  // its own permission on a repository — and that is the safe direction to be
  // wrong in: a hidden button, rather than one that 403s.
  function syncIssueActions() {
    var issue = state.issue;
    var canEdit = !!issue && !!state.username &&
      (state.username === issue.author || state.admin ||
       (state.repo && state.repo.owner === state.username));
    $('issue-edit').hidden = !canEdit;
    var toggle = $('issue-toggle-state');
    toggle.hidden = !canEdit;
    if (issue) toggle.textContent = issue.state === 'open' ? '关闭 Issue' : '重新打开';
    $('issue-comment-form').hidden = !issue || !state.username;
  }

  // Filled from the issue in hand rather than re-fetched: `state.issue` is what
  // the panel underneath is already showing, so the form and the page cannot
  // disagree about what is being edited.
  function openIssueEditDialog() {
    if (!state.repo || !state.issue) return;
    $('issue-edit-message').textContent = '';
    $('issue-edit-title').value = state.issue.title || '';
    $('issue-edit-body').value = state.issue.body || '';
    $('issue-edit-dialog').showModal();
    $('issue-edit-title').focus();
  }

  function openIssueDialog() {
    if (!state.repo || !state.username) return;
    $('issue-message').textContent = '';
    $('issue-title').value = '';
    $('issue-body').value = '';
    $('issue-dialog').showModal();
    $('issue-title').focus();
  }

  function createIssue(repo, title, body) {
    return api(issuesPath(repo), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: title, body: body }),
    }).then(function (response) { return response.json(); });
  }

  // `fields` is whatever of {title, body, state} is being changed. It took a
  // bare state string while closing an issue was the only thing the page could
  // do to one, which is also why editing the text meant a curl.
  //
  // The edit form sends title AND body every time, unchanged half included:
  // issue_update compares before it writes and returns the issue untouched when
  // nothing differs, so resending a field costs nothing and does not move
  // updated_at. Sending only the changed one would mean diffing here against a
  // copy that may already be stale.
  function updateIssue(repo, number, fields) {
    return api(issuesPath(repo, '/' + encodeURIComponent(number)), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(fields),
    }).then(function (response) { return response.json(); });
  }

  function createIssueComment(repo, number, body) {
    return api(issuesPath(repo, '/' + encodeURIComponent(number) + '/comments'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ body: body }),
    }).then(function (response) { return response.json(); });
  }

  function closeRepoView() {
    beginView();
    // Also releases the object URL behind an open file. beginView already
    // cancels anything in flight, but a blob is a document-lifetime reference
    // to those bytes and nothing else would ever let go of it -- and this is
    // the path a token expiring takes, which is not a rare one.
    hideFile();
    // Same argument for the README's own images, which hideFile does not reach
    // -- and for an open issue's, which are rendered through the same parser.
    releaseMarkdownBlobs($('readme-body'));
    releaseIssueMarkdown();
    $('readme-body').textContent = '';
    $('readme-panel').hidden = true;
    state.repo = null;
    state.collaborators = [];
    state.issues = [];
    state.issue = null;
    setIssueBadge(0);
    if ($('access-dialog').open) $('access-dialog').close();
    renderTopbarCrumbs(null);
    $('repo-view').hidden = true;
    $('overview').hidden = false;
    // The cards carry no selected state, but the counts and the search filter
    // are rendered from state that closing may have changed.
    renderRepos();
    syncWriteActions();
    routeWrite();
  }

  // `owner / name` in the top bar, with the owner a way back to the listing.
  // Built rather than assembled as markup: repository and account names are
  // constrained server-side, but this is the one place that would turn a slip in
  // that constraint into script.
  function renderTopbarCrumbs(repo) {
    var crumbs = $('topbar-crumbs');
    if (!crumbs) return;
    crumbs.textContent = '';
    if (!repo) {
      crumbs.hidden = true;
      return;
    }
    var owner = document.createElement('button');
    owner.type = 'button';
    owner.textContent = repo.owner;
    owner.addEventListener('click', closeRepoView);
    crumbs.appendChild(owner);
    var separator = document.createElement('span');
    separator.className = 'crumb-sep';
    separator.textContent = '/';
    crumbs.appendChild(separator);
    var name = document.createElement('strong');
    name.textContent = repo.name;
    crumbs.appendChild(name);
    crumbs.hidden = false;
  }

  function renderCloneUrl(repo) {
    var block = $('clone-block');
    var input = $('clone-url');
    input.value = repo.clone_url || '';
    if (block) block.hidden = !input.value;
  }

  // Owner and name are in the top bar and nowhere else: a page heading that
  // repeated them, with the repository's three actions hanging off it, was a
  // whole band of chrome saying what the breadcrumb already said. What is left
  // is the panel that actually describes the repository.
  function renderRepoMeta(repo) {
    $('repo-description').textContent = repo.description || '暂无描述';
    renderTopbarCrumbs(repo);
    renderCloneUrl(repo);
    var note = $('repo-visibility-note');
    if (note) note.textContent = repo.private ? '私有' : '公开';
    $('repo-default-branch').textContent = repo.default_branch || 'main';
  }

  function setFirstPush(repo, empty) {
    var panel = $('first-push');
    panel.hidden = !empty;
    // There is nothing to pack in a repository with no commits, and the
    // endpoint says so with a 404. Offering the button anyway would make the
    // page ask a question it already knows the answer to.
    var archive = $('archive-row');
    if (archive) archive.hidden = !!empty;
    if (empty && repo) {
      var branch = repo.default_branch || state.branch || 'main';
      $('first-push-commands').textContent =
        'git remote add origin ' + (repo.clone_url || '') + '\n' +
        'git push -u origin ' + branch;
    }
    // Whether the listing belongs on screen is part of the same decision.
    syncCodeLayout();
  }

  // The strip above the list, which exists only while there is a filter to
  // describe. The path is shown whole: a commit list filtered to a file is only
  // legible if you can see WHICH file, and truncating it in the middle is how
  // two files in different directories start looking like the same one.
  function renderCommitFilter() {
    var strip = $('commit-filter');
    if (!strip) return;
    strip.hidden = !state.commitPath;
    $('commit-filter-path').textContent = state.commitPath || '';
  }

  // "Show me this file's history" -- the commit list, walked for one path.
  //
  // The API has taken ?path= since the browsing endpoints shipped and nothing
  // ever sent it, so this is a button rather than a feature: the same list, the
  // same pagination, one parameter.
  function openPathHistory(path) {
    if (!state.repo || !path) return;
    state.commitPath = path;
    state.commitSkip = 0;
    showView('commits');
    routeWrite();
    loadCommits(seq.view);
    $('commits-view').scrollIntoView({ block: 'start' });
  }

  function clearPathHistory() {
    if (!state.commitPath) return;
    state.commitPath = '';
    state.commitSkip = 0;
    routeWrite();
    loadCommits(seq.view);
  }

  function resetCommits(message) {
    state.commits = [];
    state.commitHasMore = false;
    $('commit-count').textContent = '';
    $('commit-list').textContent = '';
    $('commit-pagination').hidden = true;
    $('commit-prev').disabled = true;
    $('commit-next').disabled = true;
    $('commit-page').textContent = '';
    if (message) setError($('commit-list'), message);
  }

  function copyText(text, message) {
    if (!text) return;
    function fallback() {
      var area = document.createElement('textarea');
      area.className = 'copy-source';
      area.value = text;
      document.body.appendChild(area);
      area.focus();
      area.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
      area.remove();
      showToast(ok ? message : '复制失败，请手动选择');
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        showToast(message);
      }, fallback);
    } else {
      fallback();
    }
  }

  function copyCloneUrl() {
    var input = $('clone-url');
    if (!input.value) return;
    input.focus();
    input.setSelectionRange(0, input.value.length);

    function fallback() {
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
      showToast(ok ? '已复制克隆地址' : '复制失败，请手动选择');
    }

    // navigator.clipboard exists only in a secure context, and this server is
    // routinely reached over plain HTTP on a LAN address — so the selection
    // fallback is the common path, not the exotic one.
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(input.value).then(function () {
        showToast('已复制克隆地址');
      }, fallback);
    } else {
      fallback();
    }
  }

  // `target` restores a place the address bar named: a ref, a directory or file
  // under it, a view, an issue. Absent — every call that is a person clicking a
  // repository — it means the default branch at the root, which is what this
  // always did.
  function selectRepo(repo, target) {
    // Restoring means the address bar is the source rather than the result, and
    // that inverts who writes it — see the two routeWrite calls below.
    var restoring = !!target;
    target = target || {};
    var view = beginView();
    state.repo = repo;
    state.collaborators = [];
    state.issues = [];
    state.issue = null;
    state.issueState = 'open';
    $('issue-state').value = 'open';
    state.branch = target.ref || repo.default_branch || 'main';
    // Cleared rather than carried: these name refs in the repository being left.
    // fillCompareSelects corrects both against the lists once they arrive.
    state.refNames = { branches: [], tags: [] };
    state.compareBase = target.compareBase || repo.default_branch || 'main';
    state.compareHead = target.compareHead || state.branch;
    state.path = target.path || '';
    state.fileLine = target.line || 0;
    state.commitPath = target.commitPath || '';
    state.commitSkip = 0;
    state.commitHasMore = false;
    resetCommits();
    $('overview').hidden = true;
    $('repo-view').hidden = false;
    renderRepoMeta(repo);
    syncWriteActions();
    closeSearch();       // results belong to the repository being left
    hideFile();          // clears state.file; the file itself is fetched below
    // A blob URL names a file, and the listing behind it has to be the
    // directory that file sits in — that is what the click path leaves on
    // screen, so it is what a link back to the same place has to reproduce.
    if (target.file) {
      state.file = target.file;
      state.path = target.file.replace(/\/?[^\/]*$/, '');
    }
    setFirstPush(repo, false);
    $('diff-panel').hidden = true;
    var comparePanel = $('compare-diff-panel');
    if (comparePanel) comparePanel.hidden = true;
    renderRepos();
    setIssueBadge(0);
    showView(target.view || 'code');
    // showView already loaded the list when it opened on Issues, and that sets
    // the badge itself; asking again here would be the same number twice.
    if (state.view !== 'issues') loadIssueBadge(repo);
    // A click is what puts the address bar somewhere new, so it writes here,
    // before the network. A restore must NOT: at this point the file has not
    // been fetched and the issue has not been read, so encoding the state now
    // would overwrite the very deep link being restored with the repository
    // root. It writes at the end instead.
    if (!restoring) routeWrite();

    // Whatever the address bar named beyond the repository itself, applied once
    // the ref it hangs off is settled. Every path through the chain below ends
    // here, including the one where the branch listing failed: a file named in
    // a URL should still open, and dropping it silently is worse than a panel
    // that reports its own error.
    function applyTarget(done) {
      if (target.file) loadFile(target.file, target.line);
      if (target.issue) loadIssue(target.issue);
      // Now the URL can be written, and with replace(): the state may differ
      // from what was asked for — loadBranches falls back when the ref is gone,
      // and an issue number that does not exist stays null — and a correction
      // is not somewhere the person should have to press Back through.
      if (restoring) routeWrite(true);
      return done;
    }

    // Branches first: loadBranches can correct state.branch when the recorded
    // default is not in the list, and a commit list fetched before that lands
    // is a commit list for a branch the select is no longer showing.
    return loadBranches(view).then(function (branches) {
      if (!viewIsCurrent(view)) return null;
      // loadBranches may correct state.branch when the ref in the URL is in
      // neither list — a bookmark to a deleted branch, or a tag since removed.
      // An empty list is a repository with no commits at all: there is no tree
      // to read, and no file a URL could name inside one.
      if (branches && !branches.length) return applyTarget([]);
      return Promise.all([loadTree(view), loadCommits(view)]).then(function (done) {
        if (!viewIsCurrent(view)) return done;
        return applyTarget(done);
      });
    });
  }

  // `selected` is a parameter rather than always state.branch, because the
  // compare view has two selects and neither of them is the branch the tree is
  // showing.
  function refGroup(select, label, names, selected) {
    if (!names.length) return;
    var group = document.createElement('optgroup');
    group.label = label;
    names.forEach(function (name) {
      var option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      option.selected = name === selected;
      group.appendChild(option);
    });
    select.appendChild(group);
  }

  // Branches AND tags, in one control with two groups.
  //
  // Every endpoint behind this takes a `ref` and resolves it the way git does,
  // so a tag has always worked — there was simply no way to pick one, and a
  // release somebody had tagged and pushed was invisible in the browser while
  // /api/v1/repos/:owner/:name/tags answered perfectly well.
  //
  // The two requests go out together rather than in sequence: they are
  // independent, and a repository with many refs forks a git process for each.
  // A repository with no tags is the common case and answers with an empty
  // list, so nothing here treats that as a failure.
  function loadBranches(view) {
    var select = $('branch-select');
    select.textContent = '';
    select.disabled = true;
    return Promise.all([
      json(repoPath('/branches')),
      // A tag listing that fails must not take the branch listing down with it:
      // the tree and the commit log both key off the branch, and losing them
      // because a tag could not be read would be the wrong trade.
      json(repoPath('/tags')).catch(function () { return { tags: [] }; }),
    ]).then(function (answers) {
      if (!viewIsCurrent(view)) return [];
      var data = answers[0] || {};
      var branches = Array.isArray(data.branches) ? data.branches : [];
      var tags = Array.isArray((answers[1] || {}).tags) ? answers[1].tags : [];

      if (!branches.length) {
        setFirstPush(state.repo, true);
        resetCommits('这个分支还没有提交');
        var empty = document.createElement('option');
        empty.textContent = '暂无分支';
        empty.value = state.branch;
        select.appendChild(empty);
      } else {
        setFirstPush(state.repo, false);
        var names = branches.map(function (branch) { return branch.name; });
        var tagNames = tags.map(function (tag) { return tag.name; });
        // Fall back to the first branch only when the selected ref is in
        // NEITHER list. Checking the branches alone would throw away a tag
        // every time this ran — today selectRepo always resets to the default
        // branch first, so it would not fire, but that is a property of one
        // caller rather than of this function.
        if (names.indexOf(state.branch) === -1 && tagNames.indexOf(state.branch) === -1) {
          state.branch = names[0];
        }
        refGroup(select, '分支', names, state.branch);
        refGroup(select, '标签', tagNames, state.branch);
        select.disabled = names.length + tagNames.length < 2;
        state.refNames = { branches: names, tags: tagNames };
        fillCompareSelects();
        // The restore path: showView opened the comparison before there was
        // anything to compare with, so this is where it actually starts.
        if (state.view === 'compare') loadCompare(view);
      }
      return branches;
    }).catch(function () {
      if (!viewIsCurrent(view)) return [];
      setFirstPush(state.repo, false);
      var option = document.createElement('option');
      option.value = state.branch;
      option.textContent = state.branch || 'main';
      select.appendChild(option);
      return null;
    });
  }

  // Move the listing to a directory. Every way of getting there -- a row, a
  // breadcrumb, the `..` row -- is the same three steps, and they were drifting
  // apart when each caller spelled them out.
  function openDirectory(path) {
    var view = beginView();
    state.path = path || '';
    hideFile();
    routeWrite();
    loadTree(view);
  }

  // `<repo> / dir / subdir`, the last segment plain text because it is where
  // you already are. Built rather than assembled as markup for the same reason
  // renderTopbarCrumbs is: these are path segments out of somebody's repository.
  function renderPathCrumbs() {
    var nav = $('path-crumbs');
    if (!nav) return;
    nav.textContent = '';
    if (!state.repo) return;
    var segments = (state.path || '').split('/').filter(Boolean);

    function crumb(label, path, current) {
      var node = document.createElement(current ? 'span' : 'button');
      node.className = 'crumb' + (current ? ' current' : '');
      node.textContent = label;
      if (!current) {
        node.type = 'button';
        node.addEventListener('click', function () { openDirectory(path); });
      }
      nav.appendChild(node);
    }

    crumb(state.repo.name, '', segments.length === 0);
    segments.forEach(function (name, index) {
      var separator = document.createElement('span');
      separator.className = 'crumb-sep';
      separator.textContent = '/';
      nav.appendChild(separator);
      crumb(name, segments.slice(0, index + 1).join('/'), index === segments.length - 1);
    });
  }

  // ---------------------------------------------------------------------------
  // The file tree beside the listing
  //
  // The repository root is a page in its own right -- a listing with the README
  // under it -- so it keeps the plain single column. Stepping into a directory
  // or opening a file is where somebody starts moving BETWEEN files, and that is
  // where the view splits: the tree on the left, whatever was clicked on the
  // right.
  //
  // Only directories somebody opened are ever fetched. A repository is
  // arbitrarily deep and every listing forks an `ls-tree` on the server, so
  // walking the whole of one up front would cost a process per directory to draw
  // rows nobody asked to see.
  // ---------------------------------------------------------------------------

  var sideOpen = Object.create(null);   // path -> true, the directories showing their contents
  // path -> { entries } once its listing is in, { pending: true } while it is on
  // the way. A directory can hold something called `__proto__`, so neither map
  // has a prototype for it to collide with.
  var sideNodes = Object.create(null);
  // Every path in those two is relative to one repository at one ref, so both
  // are dropped wholesale when either changes rather than invalidated entry by
  // entry. The generation is what a reply still in flight is checked against.
  var sideKey = '';
  var sideGen = 0;
  var sideHidden = false;               // the toolbar's collapse toggle

  function sideKeep() {
    var key = state.repo ? (state.repo.full_name + '\n' + state.branch) : '';
    if (key === sideKey) return;
    sideKey = key;
    sideGen += 1;
    sideOpen = Object.create(null);
    sideNodes = Object.create(null);
  }

  // Marked before the request goes out, so the panel and the listing never ask
  // the server for the same directory twice -- see the call in loadTree.
  function sideMark(path) {
    sideKeep();
    if (!sideNodes[path]) sideNodes[path] = { pending: true };
  }

  function sideStore(path, entries, gen) {
    if (gen !== sideGen) return;
    sideNodes[path] = { entries: entries };
    sideRender();
  }

  // A failure leaves NO entry rather than an empty one: an empty listing is a
  // claim about the repository, and the next navigation should try again.
  function sideFail(path, gen) {
    if (gen !== sideGen) return;
    delete sideNodes[path];
    sideRender();
  }

  function sideLoad(path) {
    sideKeep();
    if (sideNodes[path]) return;        // in hand, or already on the way
    var gen = sideGen;
    sideNodes[path] = { pending: true };
    var suffix = '/tree/' + encodeRef(state.branch) + (path ? '/' + encodePath(path) : '');
    json(repoPath(suffix)).then(function (data) {
      sideStore(path, Array.isArray(data.entries) ? data.entries : [], gen);
    }).catch(function () {
      sideFail(path, gen);
    });
  }

  function sideToggle(path) {
    if (sideOpen[path]) {
      delete sideOpen[path];
    } else {
      sideOpen[path] = true;
      sideLoad(path);
    }
    sideRender();
  }

  function sideNote(text, depth) {
    var note = document.createElement('div');
    note.className = 'side-note';
    note.style.paddingLeft = (10 + depth * 13) + 'px';
    note.textContent = text;
    return note;
  }

  function sideRow(entry, depth) {
    var dir = entry.type === 'tree';
    var open = dir && !!sideOpen[entry.path];
    var here = dir ? (!state.file && state.path === entry.path) : (state.file === entry.path);
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'side-row ' + (dir ? 'dir' : 'file') +
      (open ? ' open' : '') + (here ? ' current' : '');
    row.style.paddingLeft = (10 + depth * 13) + 'px';
    row.title = entry.name;

    var chevron = document.createElement('span');
    chevron.className = 'side-chevron';
    if (dir) {
      chevron.textContent = '›';
      // The chevron opens and closes, the name navigates: looking into a
      // directory should not cost somebody the file they are reading.
      chevron.addEventListener('click', function (event) {
        event.stopPropagation();
        sideToggle(entry.path);
      });
    }
    row.appendChild(chevron);

    var icon = document.createElement('span');
    icon.className = 'side-icon';
    icon.textContent = dir ? '▱' : '·';
    row.appendChild(icon);

    // textContent, like everywhere else a repository's own names are drawn.
    var name = document.createElement('span');
    name.className = 'side-name';
    name.textContent = entry.name;
    row.appendChild(name);

    row.addEventListener('click', function () {
      if (dir) {
        sideOpen[entry.path] = true;
        sideLoad(entry.path);
        openDirectory(entry.path);
      } else {
        loadFile(entry.path);
        routeWrite();
      }
    });
    return row;
  }

  // Flat rows carrying their depth as padding rather than nested lists: the
  // panel is rebuilt from the cache whenever anything lands, and one walk of the
  // open directories is the whole of it.
  function sideBranch(host, path, depth) {
    var node = sideNodes[path];
    if (!node || !node.entries) {
      if (node) host.appendChild(sideNote('读取中…', depth));
      return;
    }
    if (!node.entries.length) {
      host.appendChild(sideNote('空目录', depth));
      return;
    }
    node.entries.forEach(function (entry) {
      host.appendChild(sideRow(entry, depth));
      if (entry.type === 'tree' && sideOpen[entry.path]) sideBranch(host, entry.path, depth + 1);
    });
  }

  function sideRender() {
    var host = $('side-tree');
    if (!host) return;
    host.textContent = '';
    sideBranch(host, '', 0);
    // `nearest` so a row already in view moves nothing: this runs again for
    // every listing that lands, and scrolling on each one would be a panel that
    // will not sit still.
    var current = host.querySelector('.side-row.current');
    if (current) current.scrollIntoView({ block: 'nearest' });
  }

  // Open the tree at wherever the reader is standing and ask for what that
  // needs. A file is standing in its own directory.
  function sideSync() {
    if (!state.repo) return;
    sideKeep();
    var here = state.file ? state.file.replace(/\/?[^\/]*$/, '') : (state.path || '');
    var path = '';
    sideOpen[''] = true;
    sideLoad('');
    (here ? here.split('/') : []).forEach(function (name) {
      path = path ? path + '/' + name : name;
      sideOpen[path] = true;
      sideLoad(path);
    });
    sideRender();
  }

  // Which shape the code view is in, decided in one place because the tree, the
  // listing and the About panel all hang off the same two facts: where we are,
  // and whether a file is open.
  function syncCodeLayout() {
    var code = state.view === 'code';
    var empty = !$('first-push').hidden;         // a repository with no commits
    var split = code && !!state.repo && !empty && !!(state.path || state.file);

    var layout = $('code-layout');
    if (layout) {
      // The class is what draws the two columns, so a collapsed tree has to
      // drop it: a grid still holding a 268px first column puts the content in
      // it and the file comes out the width of the panel that is not there.
      layout.classList.toggle('split', split && !sideHidden);
      layout.classList.toggle('file', split && !!state.file);
    }
    var aside = $('code-sidebar');
    if (aside) aside.hidden = !split || sideHidden;
    var toggle = $('side-toggle');
    if (toggle) {
      toggle.hidden = !split;
      toggle.classList.toggle('off', sideHidden);
      var label = sideHidden ? '展开文件树' : '收起文件树';
      toggle.title = label;
      toggle.setAttribute('aria-label', label);
    }
    // A file REPLACES the listing rather than sitting under it: with the tree on
    // the left nothing is lost by taking it away, and two long scrolling panels
    // stacked is what made a file hard to read.
    var browser = $('tree-browser');
    if (browser) browser.hidden = empty || (split && !!state.file);
    // About and Clone describe the repository, not the file being read -- on a
    // split screen they are a third column nobody asked for. The grid has to
    // give the column back, not just empty it, or the rest stays squeezed.
    var side = $('repo-side');
    if (side) {
      var show = code && !split;
      side.hidden = !show;
      side.parentNode.classList.toggle('no-side', !show);
    }
    if (split && !sideHidden) sideSync();
  }

  function loadTree(view) {
    var list = $('tree-list');
    var here = state.path;
    var path = encodePath(here);
    var suffix = '/tree/' + encodeRef(state.branch) + (path ? '/' + path : '');
    setLoading(list, '正在读取文件树…');
    renderPathCrumbs();
    // Cells belonging to the directory being left; the last-commit response for
    // it must not land in the rows of the one being entered.
    treeCells = Object.create(null);
    renderTreeLatest(null);
    // The tree panel wants this same directory, so it is told the request is
    // already out and handed the answer below -- marked BEFORE syncCodeLayout,
    // or the two of them ask the server for it twice.
    sideMark(here);
    var gen = sideGen;
    // Laid out here rather than by the callers because this is the one place
    // that runs with the ref settled: loadBranches can correct the branch after
    // selectRepo has already arranged the view for a different one.
    syncCodeLayout();
    return json(repoPath(suffix)).then(function (data) {
      var entries = Array.isArray(data.entries) ? data.entries : [];
      // Before the ticket check: a listing of a directory is right whichever
      // one the reader has moved on to, and the panel can still use it.
      sideStore(here, entries, gen);
      if (!viewIsCurrent(view)) return [];
      $('tree-caption').textContent = state.path ? state.path : '文件';
      $('tree-count').textContent = entries.length + ' 项';
      list.textContent = '';
      if (!entries.length) {
        setError(list, '这个目录是空的');
        return entries;
      }
      if (state.path) renderParentRow(list);
      entries.forEach(function (entry) { renderTreeEntry(entry, list); });
      // Neither of these is waited on: the listing is already readable, and both
      // only add to it.
      loadLastCommits(view);
      // Whatever directory is on screen, its own README goes under it -- which
      // is the whole point for the repository root, and costs nothing anywhere
      // else. Not waited on: the listing should not sit blank behind it.
      loadReadme(view, entries);
      return entries;
    }).catch(function (error) {
      sideFail(here, gen);
      if (!viewIsCurrent(view)) return [];
      $('tree-count').textContent = '';
      $('readme-panel').hidden = true;
      setError(list, error.status === 404 ? '这个分支还没有可浏览的文件' : error.message);
      return [];
    });
  }

  function formatBytes(bytes) {
    var n = Number(bytes);
    if (!Number.isFinite(n) || n < 0) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
    return (n / 1024 / 1024 / 1024).toFixed(1) + ' GB';
  }

  // The row above the listing, one level up. The breadcrumb reaches any
  // ancestor, but the step people actually take is the one back, and having it
  // in the list means the pointer does not have to leave it.
  function renderParentRow(list) {
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'tree-row parent';
    var icon = document.createElement('span');
    icon.className = 'tree-icon';
    icon.textContent = '↰';
    row.appendChild(icon);
    var name = document.createElement('span');
    name.className = 'tree-name';
    name.textContent = '..';
    row.appendChild(name);
    row.addEventListener('click', function () {
      openDirectory(state.path.replace(/\/?[^\/]*$/, ''));
    });
    list.appendChild(row);
  }

  // A row asks two questions -- what is this, and what last changed it -- and
  // they lead two different places, so the row is no longer one button over the
  // lot. The name opens the file or the directory; the commit message opens the
  // commit. The age stays text: it is the same link as the message, and a second
  // control onto one target is noise for anything reading the row aloud.
  function renderTreeEntry(entry, list) {
    var row = document.createElement('div');
    row.className = 'tree-row entry ' + (entry.type === 'tree' ? 'directory' : 'file');

    var cell = document.createElement('button');
    cell.type = 'button';
    cell.className = 'tree-entry-name';
    var icon = document.createElement('span');
    icon.className = 'tree-icon';
    icon.textContent = entry.type === 'tree' ? '▱' : '·';
    cell.appendChild(icon);
    var name = document.createElement('span');
    name.className = 'tree-name';
    var strong = document.createElement('strong');
    strong.textContent = entry.name;
    name.appendChild(strong);
    cell.appendChild(name);
    var size = document.createElement('span');
    size.className = 'tree-size';
    size.textContent = entry.type === 'blob' ? formatBytes(entry.size) : '';
    cell.appendChild(size);
    cell.addEventListener('click', function () {
      if (entry.type === 'tree') {
        openDirectory(entry.path);
      } else {
        loadFile(entry.path);
        routeWrite();
      }
    });
    row.appendChild(cell);

    // Both columns start empty and are filled by loadLastCommits. They stay
    // empty if it fails, and also if it ran but did not reach far enough back to
    // find this entry -- see the cap in browse_last_commits. Blank is the honest
    // answer for both, and neither is worth failing a listing over. Disabled
    // until then, because there is no commit to open yet.
    var message = document.createElement('button');
    message.type = 'button';
    message.className = 'tree-entry-commit pending';
    message.disabled = true;
    message.textContent = '…';
    row.appendChild(message);
    var age = document.createElement('span');
    age.className = 'tree-entry-age pending';
    row.appendChild(age);
    // A directory can hold a file called `__proto__`, so this map has no
    // prototype to collide with.
    treeCells[entry.name] = { message: message, age: age };
    list.appendChild(row);
  }

  // Clear whatever is still showing the placeholder: either the walk did not
  // reach these entries or it never arrived at all.
  function settlePendingCells() {
    Object.keys(treeCells).forEach(function (key) {
      var cells = treeCells[key];
      if (cells.message.className.indexOf('pending') === -1) return;
      cells.message.className = 'tree-entry-commit';
      cells.message.textContent = '';
      cells.message.disabled = true;
      cells.age.className = 'tree-entry-age';
    });
  }

  // The column has room for a subject and a commit message is not a subject:
  // the first line says what changed and the rest says why, which is the half
  // somebody hovering it is usually after.
  function commitTooltip(commit) {
    var subject = commit.subject || '';
    var body = (commit.body || '').replace(/\s+$/, '');
    return body ? (subject + '\n\n' + body) : subject;
  }

  // Where the commit column leads: the log, with this commit's diff open under
  // it. browse_last_commits does not return the shape the log's own rows have
  // -- an author is a name here and an object there -- so it is converted at
  // the one call site rather than teaching loadDiff a second shape.
  function openCommit(commit) {
    if (!commit || !commit.oid) return;
    showView('commits');
    routeWrite();
    loadDiff({
      oid: commit.oid,
      short: commit.short,
      subject: commit.subject,
      body: commit.body,
      author: { name: commit.author, date: commit.date },
    });
  }

  // The strip's own commit, so the listener wired once at the bottom of this
  // file has something to open. Re-registering it on every listing would stack
  // a handler per directory visited.
  var latestCommit = null;

  function renderTreeLatest(commit) {
    var strip = $('tree-latest');
    if (!strip) return;
    latestCommit = commit || null;
    if (!commit) {
      strip.hidden = true;
      return;
    }
    $('tree-latest-author').textContent = commit.author || '';
    var subject = $('tree-latest-subject');
    subject.textContent = commit.subject || '';
    subject.title = commitTooltip(commit);
    var age = $('tree-latest-age');
    age.textContent = relativeTime(commit.date);
    age.title = formatDate(commit.date);
    strip.hidden = false;
  }

  // The other half of a file listing: what last changed each entry. Its own
  // request because on the server it is a history walk and the listing is not --
  // the names are on screen before this is even asked for. A failure here fills
  // nothing in; it does not take the directory down with it.
  function loadLastCommits(view) {
    var path = encodePath(state.path);
    var suffix = '/lastcommits/' + encodeRef(state.branch) + (path ? '/' + path : '');
    var cells = treeCells;
    return json(repoPath(suffix)).then(function (data) {
      // Both tests: the ticket catches a directory left behind, and the identity
      // check catches a listing reloaded in place under the same one.
      if (!viewIsCurrent(view) || cells !== treeCells) return;
      var entries = Array.isArray(data.entries) ? data.entries : [];
      entries.forEach(function (item) {
        if (!item || !item.commit) return;
        var target = Object.prototype.hasOwnProperty.call(cells, item.name) ? cells[item.name] : null;
        if (!target) return;
        target.message.className = 'tree-entry-commit';
        target.message.textContent = item.commit.subject || '';
        target.message.title = commitTooltip(item.commit);
        target.message.disabled = !item.commit.oid;
        target.message.addEventListener('click', (function (commit) {
          return function () { openCommit(commit); };
        }(item.commit)));
        target.age.className = 'tree-entry-age';
        target.age.textContent = relativeTime(item.commit.date);
        target.age.title = formatDate(item.commit.date);
      });
      settlePendingCells();
      renderTreeLatest(data.latest);
    }).catch(function () {
      if (!viewIsCurrent(view) || cells !== treeCells) return;
      settlePendingCells();
    });
  }

  // ---------------------------------------------------------------------------
  // Search
  //
  // One revision, fixed-string, server-bounded. The endpoint resolves the ref to
  // an object id and runs `git grep -F`, so what is typed here is never a
  // pattern and never reaches a command line as one.
  // ---------------------------------------------------------------------------

  function renderSearchHit(hit, list) {
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'tree-row file search-hit';

    var where = document.createElement('span');
    where.className = 'tree-name';
    var path = document.createElement('strong');
    path.textContent = hit.path;
    where.appendChild(path);
    var at = document.createElement('span');
    at.className = 'muted';
    at.textContent = ' : ' + hit.line;
    where.appendChild(at);
    row.appendChild(where);

    // textContent, like everything else that shows repository content: this is
    // a line out of a file somebody pushed.
    var text = document.createElement('code');
    text.className = 'search-line';
    text.textContent = hit.text;
    row.appendChild(text);

    row.addEventListener('click', function () {
      // A hit can be anywhere in the revision, and the listing behind an open
      // file has to be the directory that file sits in -- otherwise closing it
      // lands in whichever directory the search happened to start from. Not
      // openDirectory: that writes the address bar, and the file below is about
      // to write it again.
      var dir = hit.path.replace(/\/?[^\/]*$/, '');
      if (dir !== state.path) {
        var view = beginView();
        state.path = dir;
        loadTree(view);
      }
      loadFile(hit.path, hit.line);
      routeWrite();
    });
    list.appendChild(row);
  }

  // A row naming a file, and nothing else to say about it: the answer to "where
  // is it" is the path, so the path is the whole row.
  function renderPathHit(path, list) {
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'tree-row file search-hit';
    var where = document.createElement('span');
    where.className = 'tree-name';
    var dir = path.replace(/\/?[^\/]*$/, '');
    if (dir) {
      var lead = document.createElement('span');
      lead.className = 'muted';
      lead.textContent = dir + '/';
      where.appendChild(lead);
    }
    var name = document.createElement('strong');
    name.textContent = path.split('/').pop();
    where.appendChild(name);
    row.appendChild(where);
    row.addEventListener('click', function () {
      // Same argument as a content hit: the listing behind an open file has to
      // be the directory that file sits in.
      if (dir !== state.path) {
        var view = beginView();
        state.path = dir;
        loadTree(view);
      }
      loadFile(path);
      routeWrite();
    });
    list.appendChild(row);
  }

  // The file finder. Content search asks what is IN the files; this asks what
  // they are CALLED, which on any repository past a few directories is the more
  // common question -- the tree loads one level at a time, so reaching a file
  // means already knowing where it lives.
  function runPathSearch(query, view, list) {
    var suffix = '/paths/' + encodeRef(state.branch) + '?q=' + encodeURIComponent(query);
    json(repoPath(suffix)).then(function (data) {
      if (!viewIsCurrent(view)) return;
      var paths = Array.isArray(data.paths) ? data.paths : [];
      list.textContent = '';
      if (!paths.length) {
        setError(list, '没有匹配的文件名');
        return;
      }
      paths.forEach(function (path) { renderPathHit(path, list); });
      $('search-caption').textContent = '文件名 “' + query + '” · ' + paths.length + ' 个' +
        (data.truncated ? '（结果已截断）' : '');
    }).catch(function (error) {
      if (!viewIsCurrent(view)) return;
      setError(list, detailMessage(error));
    });
  }

  function runSearch(query) {
    if (!state.repo) return;
    var view = beginView();
    var panel = $('search-panel');
    var list = $('search-results');
    panel.hidden = false;
    setLoading(list, '正在搜索…');
    $('search-caption').textContent = '搜索 “' + query + '”';

    if (state.searchKind === 'path') return runPathSearch(query, view, list);

    var suffix = '/search?q=' + encodeURIComponent(query) +
                 '&ref=' + encodeRef(state.branch);
    json(repoPath(suffix)).then(function (data) {
      if (!viewIsCurrent(view)) return;
      var hits = Array.isArray(data.results) ? data.results : [];
      list.textContent = '';
      if (!hits.length) {
        setError(list, '没有找到匹配的内容');
        return;
      }
      hits.forEach(function (hit) { renderSearchHit(hit, list); });
      $('search-caption').textContent = '搜索 “' + query + '” · ' + hits.length + ' 处' +
        (data.truncated ? '（结果已截断）' : '');
    }).catch(function (error) {
      if (!viewIsCurrent(view)) return;
      setError(list, detailMessage(error));
    });
  }

  function closeSearch() {
    $('search-panel').hidden = true;
    $('search-results').textContent = '';
    $('search-input').value = '';
  }

  // ---------------------------------------------------------------------------
  // Markdown and code, rendered
  //
  // Both parsers live in their own files and both keep the same rule: they build
  // DOM nodes and never HTML strings, so repository content cannot become markup
  // on a page that is holding the reader's token. What is here is only the part
  // that needs to know about this application -- what a relative link inside a
  // README points at, and where an image in one comes from.
  // ---------------------------------------------------------------------------

  var MARKDOWN_FILE = /\.(md|markdown|mdown|mkd|mdwn)$/i;
  var README_FILE = /^readme(\.(md|markdown|mdown|mkd|mdwn|txt))?$/i;

  // The same guard highlight.js keeps, for the same reason and at the same
  // scale: rendering is linear but it builds a DOM node per construct, and a
  // generated file that happens to end in .md would build millions of them. A
  // README this size is not a README, and the source is still right there.
  var MAX_RENDER_BYTES = 512 * 1024;

  function isMarkdown(path) { return MARKDOWN_FILE.test(path || ''); }

  // Through window rather than the bare name, and checked rather than assumed:
  // if markdown.js failed to deploy, the file view still has to show files.
  // Rendering is a feature of this page; reading a repository is the point of
  // it, and losing the second because the first is missing is the wrong trade.
  function renderable(source) {
    return !!window.glMarkdown && source.length <= MAX_RENDER_BYTES;
  }
  function highlightInto(code, language) {
    if (window.glHighlight) window.glHighlight.paint(code, language);
  }

  // `docs/a.md` + `../img/x.png` -> `img/x.png`, the way git would read it.
  function resolveRepoPath(dir, rel) {
    var parts = rel.charAt(0) === '/' || !dir ? [] : dir.split('/');
    rel.split('/').forEach(function (piece) {
      if (piece === '' || piece === '.') return;
      if (piece === '..') { parts.pop(); return; }
      parts.push(piece);
    });
    return parts.join('/');
  }

  function repoRelative(dir, rel) {
    // A fragment or query on a link into a repository means nothing here, and
    // carrying it would only produce a path that does not exist. Split on the
    // literal characters first: a `#` that is part of a FILE name is written
    // `%23` precisely so it is not a fragment, and decoding before this would
    // turn it back into one.
    var clean = String(rel || '').split('#')[0].split('?')[0];
    if (!clean) return '';
    // A destination is a URL, not a path, so `my%20docs/a.md` names
    // `my docs/a.md` -- and that is the ordinary way to write a link to a file
    // with a space in it. Re-encoding it without decoding first yields
    // `my%2520docs`, which cannot exist. decodeURIComponent throws on a stray
    // `%`, which a hand-written README will have sooner or later, and the text
    // as written is the better guess then.
    try { clean = decodeURIComponent(clean); } catch (e) { /* as written */ }
    return resolveRepoPath(dir, clean);
  }

  // A link in a README becomes a route into this same browser rather than a
  // request the server would answer with a 404: /admin/site/docs/x.md is the git
  // transport's path space, not ours.
  function markdownLink(dir, rel) {
    if (!state.repo) return null;
    var target = repoRelative(dir, rel);
    if (!target) return null;
    // Nothing says whether a path is a file or a directory, and the URL has to
    // pick one. A trailing slash or a name with no extension reads as a
    // directory, which is right far more often than it is wrong.
    var last = target.split('/').pop();
    var kind = (rel.charAt(rel.length - 1) === '/' || last.indexOf('.') < 0) ? '/tree/' : '/blob/';
    return '#/' + encodeURIComponent(state.repo.owner) + '/' + encodeURIComponent(state.repo.name) +
           kind + encodeRef(state.branch) + '/' + encodePath(target);
  }

  // Same reason the file view fetches images as blobs: the raw endpoint needs an
  // Authorization header, and an <img src> cannot send one, so a private
  // repository's own logo would 401.
  function markdownImage(dir, rel, img, bin) {
    if (!state.repo) return;
    var target = repoRelative(dir, rel);
    if (!target) return;
    var ticket = seq.view;
    var suffix = '/raw/' + encodeRef(state.branch) + '/' + encodePath(target);
    api(repoPath(suffix)).then(function (response) {
      return response.blob();
    }).then(function (blob) {
      if (!viewIsCurrent(ticket)) return;
      var url = URL.createObjectURL(blob);
      bin.push(url);
      img.src = url;
    }).catch(function () {
      // A README that names an image it did not commit is a flaw in the README.
      // The alt text is already there; an error banner would be noise.
    });
  }

  // Object URLs are held on the element that shows them rather than in one list
  // on state: the README panel and an open Markdown file can each have images,
  // and re-rendering one must not revoke the other's.
  function releaseMarkdownBlobs(target) {
    (target.mdBlobUrls || []).forEach(function (url) { URL.revokeObjectURL(url); });
    target.mdBlobUrls = [];
  }

  // `fromPath` is the file the Markdown came OUT of, and relative links in it
  // resolve against that file's directory. Three states, not two: a path is a
  // file, '' is the repository root, and leaving it out means "wherever the
  // browser currently is". An issue is the '' case — its text belongs to the
  // repository rather than to any directory in it, and inheriting whatever
  // directory happened to be open would make the same link mean two things.
  function renderMarkdownInto(target, source, fromPath) {
    var dir = fromPath == null ? (state.path || '') : fromPath.replace(/\/?[^\/]*$/, '');
    releaseMarkdownBlobs(target);
    var bin = target.mdBlobUrls;
    target.textContent = '';
    target.appendChild(window.glMarkdown.render(source, {
      resolveLink: function (rel) { return markdownLink(dir, rel); },
      resolveImage: function (rel, img) { markdownImage(dir, rel, img, bin); },
      highlight: highlightInto,
    }));
  }

  // The README under whatever directory is being browsed, the way a repository
  // page is expected to read. It is not shown while a file is open: two
  // documents on one screen is worse than either.
  function loadReadme(view, entries) {
    var panel = $('readme-panel');
    var found = null;
    (entries || []).forEach(function (entry) {
      if (!found && entry.type === 'blob' && README_FILE.test(entry.name)) found = entry;
    });
    if (!found) {
      releaseMarkdownBlobs($('readme-body'));
      $('readme-body').textContent = '';
      panel.hidden = true;
      return Promise.resolve();
    }

    var ticket = (seq.readme += 1);
    var suffix = '/raw/' + encodeRef(state.branch) + '/' + encodePath(found.path);
    return api(repoPath(suffix)).then(function (response) {
      return response.text();
    }).then(function (body) {
      if (ticket !== seq.readme || !viewIsCurrent(view)) return;
      $('readme-name').textContent = found.name;
      if (isMarkdown(found.name) && renderable(body)) {
        renderMarkdownInto($('readme-body'), body, found.path);
      } else {
        // README with no extension, or README.txt: it is not Markdown and
        // guessing that it is turns plain text into wrong headings.
        var pre = document.createElement('pre');
        pre.className = 'code-block';
        pre.textContent = body;
        $('readme-body').textContent = '';
        $('readme-body').appendChild(pre);
      }
      panel.hidden = !$('file-panel').hidden;
    }).catch(function () {
      if (ticket !== seq.readme) return;
      panel.hidden = true;
    });
  }

  // Text is shown one of three ways: rendered Markdown, coloured source, or
  // plain. The toggle only exists for the first, and flipping it costs nothing
  // because the source is already in hand.
  function showFileText(body, path) {
    var pre = $('file-content');
    var code = $('file-code');
    var rendered = $('file-render');

    state.fileText = body;
    // Whatever the previous file left behind. numberLines puts them back when
    // this one is source and short enough to number.
    code.classList.remove('numbered');
    pre.classList.remove('numbered-block');

    if (looksBinary(body)) {
      $('toggle-render').hidden = true;
      rendered.hidden = true;
      pre.hidden = false;
      code.textContent = '这是二进制文件，没法在这里显示。用上面的「下载」取回原始内容。';
      return;
    }

    var markdown = isMarkdown(path) && renderable(body);
    $('toggle-render').hidden = !markdown;
    $('toggle-render').textContent = state.fileRaw ? '渲染显示' : '查看源码';

    if (markdown && !state.fileRaw) {
      renderMarkdownInto(rendered, body, path);
      rendered.hidden = false;
      pre.hidden = true;
      return;
    }

    rendered.hidden = true;
    pre.hidden = false;
    code.textContent = body;
    highlightInto(code, window.glHighlight && window.glHighlight.languageFor(path));
    numberLines(code);
    if (state.fileLine) markLine(state.fileLine, true);
  }

  // How many lines still get a gutter. Past this the block is left as one run
  // of text: the numbering is one element per line and a file with a hundred
  // thousand of them is a page that stops responding, which costs more than the
  // numbers are worth. The highlighter has its own ceiling for the same reason.
  var LINE_LIMIT = 5000;

  // Split the ALREADY HIGHLIGHTED block into one row per line.
  //
  // After, not instead of: the highlighter is stateful across lines -- a block
  // comment or a multi-line string is one token -- so colouring line by line
  // would break exactly the constructs that span lines. paint() leaves a flat
  // list of text nodes and single-level spans, so the split walks that list and
  // clones a span whenever its text crosses a newline, which keeps the class on
  // both halves.
  //
  // The number sits in its own cell, sticky to the left so it survives a
  // horizontal scroll, and user-select: none so copying the file does not come
  // with a column of digits down the side.
  function numberLines(code) {
    var source = code.textContent;
    if (!source) return;
    var total = source.split('\n').length;
    if (total > LINE_LIMIT) return;

    var rows = document.createDocumentFragment();
    var row = startRow(rows, 1);
    var line = 1;

    Array.prototype.slice.call(code.childNodes).forEach(function (node) {
      var cls = node.nodeType === 1 ? node.className : '';
      var pieces = (node.textContent || '').split('\n');
      pieces.forEach(function (piece, i) {
        if (i > 0) {
          line += 1;
          row = startRow(rows, line);
        }
        if (piece === '') return;
        if (cls) {
          var span = document.createElement('span');
          span.className = cls;
          span.textContent = piece;
          row.appendChild(span);
        } else {
          row.appendChild(document.createTextNode(piece));
        }
      });
    });

    code.textContent = '';
    code.appendChild(rows);
    code.classList.add('numbered');
    if (code.parentNode && code.parentNode.classList) code.parentNode.classList.add('numbered-block');
  }

  // One row: the number cell, then the text cell the tokens go into.
  function startRow(parent, number) {
    var wrap = document.createElement('div');
    wrap.className = 'code-row';
    wrap.dataset.line = String(number);
    var num = document.createElement('button');
    num.type = 'button';
    num.className = 'code-num';
    num.textContent = String(number);
    num.title = '链接到第 ' + number + ' 行';
    wrap.appendChild(num);
    var text = document.createElement('span');
    text.className = 'code-text';
    wrap.appendChild(text);
    parent.appendChild(wrap);
    return text;
  }

  // Mark a line as the one being pointed at, and optionally bring it on screen.
  // Called both from a click and from a restored URL, which is why the scroll
  // is a parameter: clicking a line you are already looking at should not move
  // the page under you.
  function markLine(number, scroll) {
    var code = $('file-code');
    var rows = code.querySelectorAll('.code-row');
    var target = null;
    for (var i = 0; i < rows.length; i += 1) {
      var on = Number(rows[i].dataset.line) === number;
      rows[i].classList.toggle('active', on);
      if (on) target = rows[i];
    }
    if (target && scroll) target.scrollIntoView({ block: 'center' });
  }

  // An object URL is a document-lifetime reference to the bytes behind it, so
  // one has to be released or every file opened in a session is still in memory
  // when the tab closes.
  function releaseFileBlob() {
    if (!state.fileBlobUrl) return;
    URL.revokeObjectURL(state.fileBlobUrl);
    state.fileBlobUrl = '';
  }

  // The name the server put on the archive, out of its Content-Disposition.
  //
  // Read back rather than rebuilt here: the server names the file after the
  // resolved object id, which is the whole point of the name — two downloads a
  // week apart are two different trees — and this side does not know that id.
  function filenameFrom(header) {
    var match = /filename="([^"]+)"/.exec(header || '');
    return match ? match[1] : '';
  }

  // A snapshot of the selected ref, as one file.
  //
  // Fetched rather than linked to, for the reason the images ran into first:
  // the URL needs an Authorization header, which an <a href> cannot send, so a
  // plain link would 401 on every private repository. The bytes come back
  // here and the anchor is synthesised around them.
  function downloadArchive(format) {
    if (!state.repo || !state.branch) return;
    var suffix = '/archive/' + encodeRef(state.branch) + '?format=' + encodeURIComponent(format);
    showToast('正在打包 ' + state.branch + '…');
    return api(repoPath(suffix)).then(function (response) {
      var name = filenameFrom(response.headers.get('content-disposition'));
      return response.blob().then(function (blob) {
        var url = URL.createObjectURL(blob);
        var link = document.createElement('a');
        link.href = url;
        link.download = name || (state.repo.name + '.' + format);
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        // Not revoked in this turn: the click starts the save asynchronously,
        // and pulling the URL out from under it cancels the download. A minute
        // is far longer than a save needs to begin, and the tab is the only
        // thing holding the bytes until then.
        window.setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
        showToast('已下载 ' + link.download);
      });
    }).catch(function (error) {
      showToast(error && error.message ? error.message : '打包失败');
    });
  }

  // Does this decode to something worth putting in a <pre>?
  //
  // A NUL byte does not occur in text, and a decoder emits U+FFFD for every
  // byte sequence it could not make sense of — a handful is a mis-encoded file
  // worth showing anyway, a body full of them is a zip.
  function looksBinary(text) {
    if (text.indexOf('\u0000') !== -1) return true;
    var bad = (text.match(/�/g) || []).length;
    return bad > 8 && bad > text.length / 64;
  }

  // Fetched as BYTES, then decided on.
  //
  // The old version read every file with response.text() and put the result in
  // a <pre>, so a PNG — which most repositories have — was a screen of
  // replacement characters. The server has been serving image/png correctly the
  // whole time; nothing here ever looked.
  //
  // Branching on the response's Content-Type rather than on the extension keeps
  // this in step with the server's INLINE_TYPES allowlist by construction. That
  // list is a security decision (an .html or .svg served inline would be script
  // on our own origin), and duplicating it here as a second list is how the two
  // drift apart.
  //
  // Through api() and a blob rather than pointing <img src> at the raw URL: the
  // URL needs an Authorization header, which an <img> cannot send, so a private
  // repository's images would 401.
  function loadFile(path, line) {
    var ticket = (seq.file += 1);
    // A click opens a file at no line in particular; a restored URL opens it at
    // the one it names. Passed in rather than read from state, so the one code
    // path that HAS a line to honour is the one that says so.
    state.fileLine = Math.max(0, Math.floor(Number(line)) || 0);
    var panel = $('file-panel');
    var text = $('file-content');
    var wrap = $('file-image-wrap');
    var link = $('download-file');

    state.file = path;
    state.fileRaw = false;         // a Markdown file opens rendered
    panel.hidden = false;
    syncCodeLayout();
    $('readme-panel').hidden = true;
    wrap.hidden = true;
    link.hidden = true;
    text.hidden = false;
    $('file-render').hidden = true;
    $('toggle-render').hidden = true;
    $('file-title').textContent = path;
    $('file-code').textContent = '正在读取…';

    var suffix = '/raw/' + encodeRef(state.branch) + '/' + encodePath(path);
    api(repoPath(suffix)).then(function (response) {
      var type = (response.headers.get('content-type') || '').toLowerCase();
      return response.blob().then(function (blob) { return { type: type, blob: blob }; });
    }).then(function (got) {
      if (ticket !== seq.file) return;
      releaseFileBlob();
      state.fileBlobUrl = URL.createObjectURL(got.blob);

      link.href = state.fileBlobUrl;
      link.download = path.split('/').pop() || 'file';
      link.hidden = false;

      if (got.type.indexOf('image/') === 0) {
        $('file-image').src = state.fileBlobUrl;
        text.hidden = true;
        wrap.hidden = false;
        panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        return;
      }
      return got.blob.text().then(function (body) {
        if (ticket !== seq.file) return;
        showFileText(body, path);
        panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      });
    }).catch(function (error) {
      if (ticket !== seq.file) return;
      text.hidden = false;
      wrap.hidden = true;
      $('file-render').hidden = true;
      $('toggle-render').hidden = true;
      $('file-code').textContent = error.message;
    });
  }

  function hideFile() {
    seq.file += 1;   // whatever is in flight no longer has a panel to land in
    state.file = '';
    state.fileLine = 0;
    state.fileText = '';
    state.fileRaw = false;
    releaseFileBlob();
    $('file-image').removeAttribute('src');
    releaseMarkdownBlobs($('file-render'));
    $('file-render').textContent = '';
    $('file-render').hidden = true;
    $('toggle-render').hidden = true;
    $('file-panel').hidden = true;
    // The README goes back under the listing now that nothing covers it, but
    // only if there was one: an empty card is worse than no card.
    $('readme-panel').hidden = $('readme-body').childNodes.length === 0;
  }

  function updateCommitPagination() {
    var pagination = $('commit-pagination');
    var prev = $('commit-prev');
    var next = $('commit-next');
    var hasRows = state.commits.length > 0;
    pagination.hidden = !hasRows || (state.commitSkip === 0 && !state.commitHasMore);
    prev.disabled = state.commitSkip === 0;
    next.disabled = !state.commitHasMore;
    $('commit-page').textContent = '第 ' + (Math.floor(state.commitSkip / COMMIT_PAGE_SIZE) + 1) + ' 页';
  }

  function loadCommits(view, skip) {
    var ticket = (seq.commits += 1);
    var requestedSkip = Math.max(Number.isFinite(Number(skip)) ? Number(skip) : 0, 0);
    requestedSkip = Math.floor(requestedSkip / COMMIT_PAGE_SIZE) * COMMIT_PAGE_SIZE;
    var list = $('commit-list');
    $('commit-pagination').hidden = true;
    setLoading(list, '正在读取提交记录…');
    renderCommitFilter();
    // The path filter is the server's, not a filter over what came back: git
    // walks the history OF that path, so a file touched once in a thousand
    // commits still answers in one page instead of being looked for across
    // forty of them.
    var query = '/commits?ref=' + encodeURIComponent(state.branch) +
      '&limit=' + COMMIT_PAGE_SIZE + '&skip=' + requestedSkip +
      (state.commitPath ? '&path=' + encodeURIComponent(state.commitPath) : '');
    return json(repoPath(query)).then(function (data) {
      if (!viewIsCurrent(view) || ticket !== seq.commits) return [];
      state.commits = Array.isArray(data.commits) ? data.commits : [];
      state.commitSkip = Number.isFinite(Number(data.skip)) ? Number(data.skip) : requestedSkip;
      state.commitHasMore = !!data.has_more;
      var first = state.commits.length ? state.commitSkip + 1 : state.commitSkip;
      var last = state.commitSkip + state.commits.length;
      $('commit-count').textContent = state.commits.length ? first + '–' + last + ' 条' : '0 条';
      list.textContent = '';
      if (!state.commits.length) {
        updateCommitPagination();
        // Two different nothings: a branch with no commits at all, and a path
        // this branch never touched. Saying the first about the second sends
        // somebody looking for a bug in the repository.
        setError(list, state.commitPath ? '这个分支上没有改动过它' : '这个分支还没有提交');
        return [];
      }
      state.commits.forEach(function (commit) { renderCommit(commit, list); });
      updateCommitPagination();
      return state.commits;
    }).catch(function (error) {
      if (!viewIsCurrent(view) || ticket !== seq.commits) return [];
      $('commit-count').textContent = '';
      state.commits = [];
      state.commitHasMore = false;
      updateCommitPagination();
      // A repository with no commits has no `main` to resolve either, so the
      // server answers 404 — which as a bare status reads "没有找到内容", about
      // a repository the user is looking straight at. It is the first thing
      // they see after creating one, so say what is actually true. The tree
      // panel above says the same for the same reason.
      setError(list, error.status === 404
        ? (state.commitPath ? '这个分支上没有改动过它' : '这个分支还没有提交')
        : error.message);
      return [];
    });
  }

  // `onClick` is a parameter because the same row appears in two places: in the
  // commit log it opens that commit's patch in the log's own panel, and in a
  // comparison it opens it in the comparison's.
  function renderCommit(commit, list, onClick) {
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'commit-row';
    var dot = document.createElement('span');
    dot.className = 'commit-dot';
    row.appendChild(dot);
    var copy = document.createElement('span');
    var subject = document.createElement('span');
    subject.className = 'commit-subject';
    subject.textContent = commit.subject || '(无提交说明)';
    copy.appendChild(subject);
    var meta = document.createElement('span');
    meta.className = 'commit-meta';
    meta.textContent = (commit.author && commit.author.name ? commit.author.name : 'unknown') + ' · ';
    var code = document.createElement('code');
    code.textContent = (commit.short || commit.oid || '').slice(0, 10);
    meta.appendChild(code);
    copy.appendChild(meta);
    row.appendChild(copy);
    var date = document.createElement('span');
    date.className = 'commit-date';
    date.textContent = formatDate(commit.author && commit.author.date);
    row.appendChild(date);
    row.title = commitTooltip(commit);
    row.addEventListener('click', onClick || function () { loadDiff(commit); });
    list.appendChild(row);
  }

  function formatDate(value) {
    if (!value) return '';
    // The API sends two shapes and they are not interchangeable: an ISO string
    // for anything that came out of git, and a Unix time in SECONDS for
    // anything this server stamped itself -- an issue, a token. new Date(n)
    // reads MILLISECONDS, so a raw stamp landed in January 1970, which is what
    // every issue in the list has been dated until now.
    var date = typeof value === 'number' ? new Date(value * 1000) : new Date(value);
    return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleString();
  }

  // "3 天前" rather than a timestamp, for the columns where the question is how
  // stale something is and not exactly when it happened. The exact time is on
  // the title attribute of every one of them, because sometimes it is.
  //
  // Rounded DOWN at every step: "1 天前" for something 23 hours old reads as a
  // day of staleness that has not happened yet.
  function relativeTime(value) {
    if (!value) return '';
    var date = typeof value === 'number' ? new Date(value * 1000) : new Date(value);
    if (Number.isNaN(date.getTime())) return '';
    // A commit stamped in the future is a committer's clock, not an error, and
    // is not worth a special case beyond not printing a negative number.
    var seconds = Math.floor((Date.now() - date.getTime()) / 1000);
    if (seconds < 60) return '刚刚';
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + ' 分钟前';
    var hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + ' 小时前';
    var days = Math.floor(hours / 24);
    if (days < 30) return days + ' 天前';
    var months = Math.floor(days / 30);
    if (months < 12) return months + ' 个月前';
    return Math.floor(months / 12) + ' 年前';
  }

  function loadDiff(commit) {
    var ticket = (seq.diff += 1);
    var panel = $('diff-panel');
    panel.hidden = false;
    $('diff-title').textContent = commit.subject || commit.short || commit.oid;
    var message = $('diff-message');
    if (message) {
      var body = (commit.body || '').replace(/\s+$/, '');
      message.textContent = body;
      message.hidden = body === '';
    }
    $('diff-meta').textContent = (commit.author && commit.author.name ? commit.author.name : 'unknown') +
      ' · ' + formatDate(commit.author && commit.author.date) + ' · ' + (commit.oid || '');
    $('diff-content').textContent = '正在生成 diff…';
    var suffix = '/commits/' + encodeURIComponent(commit.oid) + '/diff';
    json(repoPath(suffix)).then(function (data) {
      if (ticket !== seq.diff) return;
      renderDiff(String(data.diff || ''), $('diff-content'));
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (error) {
      if (ticket !== seq.diff) return;
      $('diff-content').textContent = error.message;
    });
  }

  // `pre` is a parameter because a comparison has a patch of its own, rendered
  // into its own panel. The colouring is the same colouring.
  function renderDiff(text, pre) {
    pre.textContent = '';
    var fragment = document.createDocumentFragment();
    text.split('\n').forEach(function (line, index, lines) {
      var span = document.createElement('span');
      if (line.indexOf('+++ ') === 0 || line.indexOf('--- ') === 0 || line.indexOf('diff --git ') === 0) {
        span.className = 'diff-file';
      } else if (line.indexOf('@@') === 0) {
        span.className = 'diff-hunk';
      } else if (line.indexOf('+') === 0) {
        span.className = 'diff-add';
      } else if (line.indexOf('-') === 0) {
        span.className = 'diff-del';
      }
      span.textContent = line;
      fragment.appendChild(span);
      if (index < lines.length - 1) fragment.appendChild(document.createTextNode('\n'));
    });
    pre.appendChild(fragment);
  }

  // ---------------------------------------------------------------------------
  // Comparing two revisions
  //
  // The reading half of a pull request, and useful before there is one: what
  // has this branch got that the trunk has not. The server does the thinking —
  // see the three-dot note at the top of app/browse.lua — and this view is two
  // selects, a summary, and the two lists that answer follow from them.
  //
  // Listeners here go through on() rather than addEventListener directly. A
  // node this file did not always have is null in a tab left open across the
  // deploy that added it, and addEventListener on null throws at PARSE time,
  // taking every listener registered after it down with it — which is a worse
  // failure than the missing feature.
  // ---------------------------------------------------------------------------

  function on(id, event, handler) {
    var node = $(id);
    if (node) node.addEventListener(event, handler);
  }

  function comparePath(suffix) {
    return repoPath('/compare/' + encodeRef(state.compareBase) + '/' +
                    encodeRef(state.compareHead) + (suffix || ''));
  }

  function statusLabel(letter) {
    return ({ A: '新增', M: '修改', D: '删除', R: '重命名', C: '复制', T: '类型变化' })[letter] ||
           letter || '?';
  }

  // Both ends have to name something that exists, and they are asked for in a
  // URL that may have outlived either. base falls back to the recorded default
  // branch and head to whatever the tree is showing; comparing a ref with
  // itself is a legal, empty answer, which is what the summary then says.
  function fillCompareSelects() {
    var baseSelect = $('compare-base');
    var headSelect = $('compare-head');
    if (!baseSelect || !headSelect) return;

    var names = state.refNames.branches || [];
    var tags = state.refNames.tags || [];
    function pick(want, fallback) {
      if (names.indexOf(want) !== -1 || tags.indexOf(want) !== -1) return want;
      if (names.indexOf(fallback) !== -1) return fallback;
      return names[0] || '';
    }
    state.compareBase = pick(state.compareBase, (state.repo && state.repo.default_branch) || '');
    state.compareHead = pick(state.compareHead, state.branch);

    [[baseSelect, state.compareBase], [headSelect, state.compareHead]].forEach(function (pair) {
      pair[0].textContent = '';
      refGroup(pair[0], '分支', names, pair[1]);
      refGroup(pair[0], '标签', tags, pair[1]);
      pair[0].disabled = names.length + tags.length < 2;
    });
  }

  // One patch, into the compare panel. The path is built by the caller because
  // the three things worth looking at here come from two different endpoints:
  // the whole comparison, one file of it, and one commit inside it.
  function loadComparePatch(title, meta, path) {
    var ticket = (seq.comparediff += 1);
    var panel = $('compare-diff-panel');
    if (!panel) return;
    panel.hidden = false;
    $('compare-diff-title').textContent = title;
    $('compare-diff-meta').textContent = meta;
    $('compare-diff-content').textContent = '正在生成 diff…';
    json(path).then(function (data) {
      if (ticket !== seq.comparediff) return;
      var patch = String(data.diff || '');
      if (!patch) {
        $('compare-diff-content').textContent = '没有文本改动可以显示。';
        return;
      }
      renderDiff(patch, $('compare-diff-content'));
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (error) {
      if (ticket !== seq.comparediff) return;
      // A comparison is a far easier way to ask for an enormous patch than any
      // single commit is, so MAX_DIFF_MB is an ordinary outcome here rather
      // than a fault — and the answer to it is on screen already, one file at
      // a time.
      $('compare-diff-content').textContent = error.status === 413
        ? '这次比较的 diff 超过了服务器的 MAX_DIFF_MB 上限，请逐个文件查看。'
        : error.message;
    });
  }

  function renderCompare(data) {
    var summary = $('compare-summary');
    var fileList = $('compare-files');
    var commitList = $('compare-commits');
    var files = Array.isArray(data.files) ? data.files : [];
    var commits = Array.isArray(data.commits) ? data.commits : [];
    var ahead = Number(data.ahead) || 0;
    var behind = Number(data.behind) || 0;

    fileList.textContent = '';
    commitList.textContent = '';
    fileList.hidden = !files.length;
    $('compare-full-diff').hidden = !files.length;

    if (!ahead && !files.length) {
      summary.textContent = state.compareBase === state.compareHead
        ? '两端是同一个引用，没有可比较的内容。'
        : '没有可以合并进 ' + state.compareBase + ' 的内容' +
          (behind ? '，它落后 ' + behind + ' 个提交。' : '。');
      setError(commitList, '没有提交');
      return;
    }

    var parts = [];
    // Not a footnote. Without a common ancestor the answer below is a different
    // comparison from the one that was asked for, and saying so is the whole
    // reason the server reports `unrelated` separately.
    if (data.unrelated) {
      parts.push('这两条历史没有共同祖先，下面直接对比 ' + state.compareBase + ' 的末端');
    }
    parts.push('领先 ' + ahead + ' 个提交');
    parts.push('落后 ' + behind + ' 个提交');
    parts.push(files.length + ' 个文件有变化');
    summary.textContent = parts.join(' · ');

    files.forEach(function (file) {
      var row = document.createElement('button');
      row.type = 'button';
      row.className = 'access-row compare-file';
      var left = document.createElement('div');
      var badge = document.createElement('span');
      badge.className = 'pill status-pill status-' + (file.status || '');
      badge.textContent = statusLabel(file.status);
      left.appendChild(badge);
      left.appendChild(document.createTextNode(' '));
      var name = document.createElement('code');
      name.textContent = file.from ? (file.from + ' → ' + file.path) : file.path;
      left.appendChild(name);
      row.appendChild(left);
      var hint = document.createElement('span');
      hint.className = 'commit-meta';
      hint.textContent = '查看改动';
      row.appendChild(hint);
      row.addEventListener('click', function () {
        loadComparePatch(file.path,
          statusLabel(file.status) + ' · ' + state.compareBase + ' ← ' + state.compareHead,
          comparePath('/diff?path=' + encodeURIComponent(file.path)));
      });
      fileList.appendChild(row);
    });

    if (!commits.length) {
      setError(commitList, '没有提交');
      return;
    }
    commits.forEach(function (commit) {
      renderCommit(commit, commitList, function () {
        loadComparePatch(commit.subject || commit.short || commit.oid,
          (commit.author && commit.author.name ? commit.author.name : 'unknown') +
            ' · ' + formatDate(commit.author && commit.author.date),
          repoPath('/commits/' + encodeURIComponent(commit.oid) + '/diff'));
      });
    });
    // The list is capped by the same page size the commit log uses, so a branch
    // that is hundreds ahead says so rather than quietly showing a prefix.
    if (data.has_more) {
      var more = document.createElement('div');
      more.className = 'empty-row';
      more.textContent = '只列出了最近 ' + commits.length + ' 个提交，共 ' + ahead + ' 个。';
      commitList.appendChild(more);
    }
  }

  function loadCompare(view) {
    var ticket = (seq.compare += 1);
    // A patch still in flight belongs to the pair being left.
    seq.comparediff += 1;
    $('compare-diff-panel').hidden = true;
    $('compare-summary').textContent = '正在比较…';
    $('compare-files').textContent = '';
    $('compare-files').hidden = true;
    $('compare-full-diff').hidden = true;
    setLoading($('compare-commits'), '正在读取…');
    return json(comparePath('')).then(function (data) {
      if (!viewIsCurrent(view) || ticket !== seq.compare) return;
      renderCompare(data);
    }).catch(function (error) {
      if (!viewIsCurrent(view) || ticket !== seq.compare) return;
      $('compare-summary').textContent = '';
      $('compare-files').hidden = true;
      setError($('compare-commits'), error.message);
    });
  }

  function compareEndChanged(which, value) {
    if (which === 'base') state.compareBase = value; else state.compareHead = value;
    routeWrite();
    loadCompare(seq.view);
  }

  on('compare-base', 'change', function (event) { compareEndChanged('base', event.target.value); });
  on('compare-head', 'change', function (event) { compareEndChanged('head', event.target.value); });
  on('compare-full-diff', 'click', function () {
    loadComparePatch('完整改动', state.compareBase + ' ← ' + state.compareHead,
                     comparePath('/diff'));
  });
  on('compare-diff-close', 'click', function () {
    seq.comparediff += 1;
    $('compare-diff-panel').hidden = true;
  });

  // ── the address bar ────────────────────────────────────────────────────────
  //
  // The page had no URL state at all: whatever you were looking at, the address
  // was the bare origin. Refreshing put you back on the empty page, nothing
  // could be bookmarked or pasted into your own notes, and Back left the
  // application entirely.
  //
  // A HASH rather than a path, and not for the usual "no server config" reason —
  // the paths are already taken. `/<owner>/<name>.git/...` is the git transport
  // and `/<owner>/<name>` is the API's, so serving index.html for arbitrary
  // paths would shadow both and turn every real 404 into the page. Behind the
  // hash nothing on the server has to know this exists.
  //
  // The shape follows the one people already have in their fingers:
  //
  //   #/                                     nothing selected
  //   #/<owner>/<name>                       the repository, code view
  //   #/<owner>/<name>/tree/<ref>/<dir>      a directory at a ref
  //   #/<owner>/<name>/blob/<ref>/<file>     a file at a ref
  //   #/<owner>/<name>/commits/<ref>
  //   #/<owner>/<name>/compare/<base>/<head>
  //   #/<owner>/<name>/issues[/<number>]
  //
  // tree vs blob because the URL cannot otherwise say which one a path is, and
  // guessing means a reload of a file URL lands in a directory listing.
  function routeEncode() {
    if (!state.repo) return '#/';
    var base = '#/' + encodeURIComponent(state.repo.owner) + '/' +
               encodeURIComponent(state.repo.name);
    if (state.view === 'issues') {
      return base + '/issues' + (state.issue ? '/' + state.issue.number : '');
    }
    if (state.view === 'commits') {
      return base + '/commits/' + encodeRef(state.branch) +
             (state.commitPath ? '?path=' + encodeURIComponent(state.commitPath) : '');
    }
    if (state.view === 'compare') {
      return base + '/compare/' + encodeRef(state.compareBase) + '/' +
             encodeRef(state.compareHead);
    }
    var target = state.file || state.path;
    return base + (state.file ? '/blob/' : '/tree/') + encodeRef(state.branch) +
           (target ? '/' + encodePath(target) : '') +
           (state.file && state.fileLine ? '?line=' + state.fileLine : '');
  }

  // Write the current state to the address bar. `replace` is for the first
  // paint, which should not leave an entry to go Back to.
  function routeWrite(replace) {
    var next = routeEncode();
    if (next === (location.hash || '#/')) return;
    if (replace) location.replace(location.pathname + location.search + next);
    else location.hash = next;
  }

  // Apply whatever the address bar says. Returns nothing; the panels load
  // themselves through selectRepo.
  //
  // The repository has to be found in a list that is already loaded, so the
  // first call waits for loadRepos — see the bottom of this file.
  // Everything a route needs to say that is NOT a path segment: which line of a
  // file, which path a commit list is filtered to.
  //
  // A query string rather than more segments, because the last segment of a
  // blob route is a file path and swallows everything after it -- there is no
  // segment left to be a marker, and a repository may contain a directory
  // called anything a marker could be. A raw '?' cannot be part of the path
  // either: encodePath is encodeURIComponent per segment, which writes a '?' in
  // a real file name as %3F. So the first raw '?' is unambiguously this.
  function routeQuery(raw) {
    var out = {};
    tostr(raw).split('&').forEach(function (pair) {
      if (!pair) return;
      var eq = pair.indexOf('=');
      var key = eq === -1 ? pair : pair.slice(0, eq);
      var value = eq === -1 ? '' : pair.slice(eq + 1);
      try { out[decodeURIComponent(key)] = decodeURIComponent(value); } catch (e) { /* keep the rest */ }
    });
    return out;
  }

  function tostr(v) { return v == null ? '' : String(v); }

  function routeApply() {
    var raw = (location.hash || '').replace(/^#\/?/, '');
    var query = {};
    var mark = raw.indexOf('?');
    if (mark !== -1) {
      query = routeQuery(raw.slice(mark + 1));
      raw = raw.slice(0, mark);
    }
    var parts = [];
    raw.split('/').forEach(function (piece) {
      if (piece !== '') parts.push(decodeURIComponent(piece));
    });
    if (parts.length < 2) {
      if (state.repo) closeRepoView();
      return;
    }

    var full = parts[0] + '/' + parts[1];
    var repo = state.repos.find(function (r) { return r.full_name === full; });
    if (!repo) {
      // Renamed, deleted, or not visible to whoever is signed in. Saying so
      // beats a silent empty page, because the usual way to arrive here is a
      // bookmark that has outlived the repository.
      closeRepoView();
      showToast('找不到仓库 ' + full);
      return;
    }

    var kind = parts[2];
    var target = { view: 'code' };
    if (kind === 'issues') {
      target.view = 'issues';
      target.issue = parts[3] ? Number(parts[3]) : null;
    } else if (kind === 'commits') {
      target.view = 'commits';
      target.ref = parts[3];
      target.commitPath = query.path || '';
    } else if (kind === 'compare') {
      target.view = 'compare';
      target.compareBase = parts[3];
      target.compareHead = parts[4];
    } else if (kind === 'tree' || kind === 'blob') {
      target.ref = parts[3];
      var rest = parts.slice(4).join('/');
      if (kind === 'blob') {
        target.file = rest;
        target.line = Math.max(0, Math.floor(Number(query.line)) || 0);
      } else {
        target.path = rest;
      }
    }
    selectRepo(repo, target);
  }

  function showView(view) {
    state.view = view;
    $$('.view-tab').forEach(function (tab) { tab.classList.toggle('active', tab.dataset.view === view); });
    $('code-view').hidden = view !== 'code';
    $('commits-view').hidden = view !== 'commits';
    var compare = $('compare-view');
    if (compare) compare.hidden = view !== 'compare';
    $('issues-view').hidden = view !== 'issues';
    syncCodeLayout();
    if (view === 'issues' && state.repo) loadIssues(seq.view);
    // Only once the ref lists are in. On a tab click they already are; on a
    // restore from the address bar showView runs before loadBranches has
    // answered, and loadBranches starts the comparison itself when it lands —
    // otherwise this would ask the server to compare two empty refs.
    if (view === 'compare' && state.repo && state.refNames.branches.length) {
      fillCompareSelects();
      loadCompare(seq.view);
    }
  }

  function openAuth() {
    $('auth-message').textContent = '';
    $('auth-user').value = state.username;
    $('auth-password').value = '';
    $('auth-dialog').showModal();
    $('auth-user').focus();
  }

  function logout() {
    // Best effort, and deliberately before the credential is dropped: the token
    // is gone from this tab either way, but leaving it valid on the server is
    // exactly what issuing a revocable token was for.
    if (state.token) {
      fetch('/api/v1/user/tokens', { method: 'DELETE', headers: authHeaders() })
        .catch(function () {});
    }
    clearCredentials();
    closeRepoView();
    updateAuthButton();
    loadRepos().catch(function () {});
    showToast('已退出登录');
  }

  // Public registration returns a recovery code once. Keep the dialog open
  // while the request is pending so its response cannot disappear unseen.
  var registering = false;
  var registrationLoggedIn = false;

  function openRegister() {
    if (state.username || !$('register-dialog')) return;
    if ($('auth-dialog').open) $('auth-dialog').close();
    $('register-form').reset();
    $('register-message').textContent = '';
    registrationLoggedIn = false;
    $('register-form').hidden = false;
    $('register-success').hidden = true;
    $('register-recovery-code').textContent = '';
    $('register-dialog').showModal();
    $('register-user').focus();
  }

  function registerLogin() {
    if (registrationLoggedIn) {
      $('register-dialog').close();
      return;
    }
    var username = $('register-success').hidden
      ? $('register-user').value.trim() : $('register-created-name').textContent;
    $('register-dialog').close();
    openAuth();
    $('auth-user').value = username;
    if (username) $('auth-password').focus();
  }

  // The top bar carries one account control, so registration is reached from
  // under the login form rather than from a second button beside it.
  if ($('auth-register')) $('auth-register').addEventListener('click', openRegister);
  if ($('register-form')) {
    $('register-login').addEventListener('click', registerLogin);
    $('register-done').addEventListener('click', registerLogin);
    $('register-copy').addEventListener('click', function () {
      copyText($('register-recovery-code').textContent, '已复制恢复码');
    });
    $('register-dialog').addEventListener('cancel', function (event) {
      if (registering) event.preventDefault();
    });
    $('register-dialog').addEventListener('close', function () {
      $('register-form').reset();
      $('register-recovery-code').textContent = '';
      $('register-created-name').textContent = '';
    });
    $('register-form').addEventListener('submit', function (event) {
      event.preventDefault();
      if (registering) return;
      var username = $('register-user').value.trim();
      var password = $('register-password').value;
      if (!username || !password) {
        $('register-message').textContent = '请输入用户名和密码';
        return;
      }
      if (password !== $('register-confirm').value) {
        $('register-message').textContent = '两次输入的密码不一致';
        $('register-confirm').focus();
        return;
      }
      var payload = { username: username, password: password };
      var email = $('register-email').value.trim();
      if (email) payload.email = email;
      registering = true;
      $('register-message').textContent = '';
      $$('#register-dialog button').forEach(function (button) { button.disabled = true; });
      $('register-submit').textContent = '正在创建…';
      // This endpoint is anonymous, even if another request updates the
      // session while registration is in progress.
      fetch('/api/v1/user/register', {
        method: 'POST',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      }).then(function (response) {
        if (!response.ok) return failure(response);
        return response.json();
      }).then(function (created) {
        $('register-form').reset();
        $('register-created-name').textContent = created.username || username;
        $('register-recovery-code').textContent = created.recovery_code || '未能生成恢复码，请联系管理员。';
        $('register-copy').hidden = !created.recovery_code;
        $('register-form').hidden = true;
        $('register-success').hidden = false;
        // The password is still only in this function's memory. Exchange it
        // immediately for the normal short-lived token so registration does
        // not force a second login step.
        return login(created.username || username, password).then(function () {
          registrationLoggedIn = true;
          updateAuthButton();
          loadSelf();
          loadRepos().catch(function () {});
          showToast('注册成功，已自动登录');
          $('register-done').textContent = '已保存，进入 Gitloom';
        }).catch(function () {
          registrationLoggedIn = false;
          $('register-message').textContent = '账号已创建，请点击下方按钮登录';
          $('register-done').textContent = '去登录';
        });
      }).catch(function (error) {
        $('register-message').textContent = error.status === 403
          ? '本站暂未开放注册，请联系管理员创建账号。'
          : error.status === 429 ? '注册尝试次数过多，请稍后再试。' : userError(error);
      }).finally(function () {
        registering = false;
        $$('#register-dialog button').forEach(function (button) { button.disabled = false; });
        $('register-submit').textContent = '创建账号';
        if (!$('register-success').hidden) $('register-done').focus();
      });
    });
  }

  $('repo-search').addEventListener('input', renderRepos);
  $('refresh-repos').addEventListener('click', function () { loadRepos().catch(function () {}); });
  $$('[data-dialog-close]').forEach(function (button) {
    button.addEventListener('click', function () {
      var dialog = $(button.dataset.dialogClose);
      if (dialog) dialog.close();
    });
  });
  $('new-repo').addEventListener('click', openCreate);
  $('edit-repo').addEventListener('click', openEdit);
  $('manage-access').addEventListener('click', openCollaborators);
  $('new-issue').addEventListener('click', openIssueDialog);
  $('delete-repo').addEventListener('click', openDelete);
  $('create-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var name = $('create-name').value.trim();
    if (!name) {
      $('create-message').textContent = '请输入仓库名';
      return;
    }
    $('create-submit').disabled = true;
    createRepo(name, $('create-description').value.trim(), $('create-private').checked)
      .then(function (repo) {
        $('create-dialog').close();
        showToast('已创建 ' + repo.full_name);
        return loadRepos().then(function () {
          // Select the record the LISTING returned rather than the one the
          // create answered with, so what is on screen is what the server will
          // keep answering with.
          var made = state.repos.find(function (r) { return r.full_name === repo.full_name; });
          if (made) selectRepo(made);
        });
      })
      .catch(function (error) { $('create-message').textContent = detailMessage(error); })
      .finally(function () { $('create-submit').disabled = false; });
  });
  $('delete-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var repo = state.repo;
    if (!repo) { $('delete-dialog').close(); return; }
    // Typing the name is the whole safety here. repo_delete is a recursive
    // delete of the git objects with nothing behind it, so a misplaced click
    // has to cost more than a click.
    if ($('delete-confirm').value.trim() !== repo.name) {
      $('delete-message').textContent = '输入的仓库名和这个仓库对不上';
      return;
    }
    $('delete-submit').disabled = true;
    deleteRepo(repo)
      .then(function () {
        $('delete-dialog').close();
        closeRepoView();
        showToast('已删除 ' + repo.full_name);
        return loadRepos().catch(function () {});
      })
      .catch(function (error) { $('delete-message').textContent = detailMessage(error); })
      .finally(function () { $('delete-submit').disabled = false; });
  });
  $('edit-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var repo = state.repo;
    if (!repo) { $('edit-dialog').close(); return; }
    var wanted = $('edit-name').value.trim();
    var renaming = wanted !== '' && wanted !== repo.name;
    var changes = {
      description: $('edit-description').value.trim(),
      private: $('edit-private').checked,
    };
    // Only sent when it actually changed. A PATCH that names the name it
    // already has is a no-op the server would still have to move a directory
    // for, and this page has no business asking for that.
    if (renaming) changes.name = wanted;

    $('edit-submit').disabled = true;
    updateRepo(repo, changes)
      .then(function (updated) {
        $('edit-dialog').close();
        var was = repo.full_name;
        state.repo = updated;
        state.repos = state.repos.map(function (item) {
          return item.full_name === was ? updated : item;
        });
        renderRepoMeta(updated);
        syncWriteActions();
        renderRepos();
        if (renaming) {
          // The address bar still says the old name, and a reload of it would
          // now find nothing. Written with replace() so Back does not lead to a
          // URL that has stopped existing.
          routeWrite(true);
          showToast('已改名为 ' + updated.full_name + '；旧的克隆地址已失效');
        } else {
          showToast('仓库设置已保存');
        }
      })
      .catch(function (error) { $('edit-message').textContent = detailMessage(error); })
      .finally(function () { $('edit-submit').disabled = false; });
  });
  $('collaborator-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var repo = state.repo;
    var username = $('collaborator-user').value.trim();
    if (!repo || !username) return;
    $('collaborator-submit').disabled = true;
    $('collaborator-message').textContent = '';
    putCollaborator(repo, username, $('collaborator-permission').value)
      .then(function () {
        $('collaborator-user').value = '';
        showToast('已添加协作者');
        return loadCollaborators(repo);
      })
      .catch(function (error) { $('collaborator-message').textContent = collaboratorError(error); })
      .finally(function () { $('collaborator-submit').disabled = false; });
  });
  $('access-dialog').addEventListener('close', function () { seq.access += 1; });
  $('issue-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var repo = state.repo;
    var title = $('issue-title').value.trim();
    if (!repo || !title) {
      $('issue-message').textContent = '请输入 Issue 标题';
      return;
    }
    $('issue-submit').disabled = true;
    $('issue-message').textContent = '';
    createIssue(repo, title, $('issue-body').value)
      .then(function (issue) {
        $('issue-dialog').close();
        state.issueState = 'open';
        $('issue-state').value = 'open';
        showToast('已创建 Issue #' + issue.number);
        return loadIssues(seq.view).then(function () { return loadIssue(issue.number); });
      })
      .catch(function (error) { $('issue-message').textContent = issueError(error); })
      .finally(function () { $('issue-submit').disabled = false; });
  });
  $('issue-edit').addEventListener('click', openIssueEditDialog);
  $('issue-edit-form').addEventListener('submit', function (event) {
    event.preventDefault();
    if (!state.repo || !state.issue) return;
    var repo = state.repo;
    var number = state.issue.number;
    var title = $('issue-edit-title').value.trim();
    if (!title) {
      $('issue-edit-message').textContent = '请输入 Issue 标题';
      return;
    }
    $('issue-edit-submit').disabled = true;
    $('issue-edit-message').textContent = '';
    updateIssue(repo, number, { title: title, body: $('issue-edit-body').value })
      .then(function (updated) {
        $('issue-edit-dialog').close();
        // The row in the list carries the title and the timestamp, so the panel
        // alone is half the update.
        if (state.repo && state.repo.full_name === repo.full_name &&
            state.issue && state.issue.number === number) {
          state.issue = updated;
          renderIssue(updated);
        }
        showToast('Issue #' + number + ' 已保存');
        return loadIssues(seq.view);
      })
      .catch(function (error) { $('issue-edit-message').textContent = issueError(error); })
      .finally(function () { $('issue-edit-submit').disabled = false; });
  });
  $('issue-state').addEventListener('change', function (event) {
    state.issueState = event.target.value;
    state.issue = null;
    $('issue-detail').hidden = true;
    routeWrite();
    if (state.repo) loadIssues(seq.view);
  });
  $('issue-toggle-state').addEventListener('click', function () {
    if (!state.repo || !state.issue) return;
    var issue = state.issue;
    var nextState = issue.state === 'open' ? 'closed' : 'open';
    $('issue-toggle-state').disabled = true;
    updateIssue(state.repo, issue.number, { state: nextState })
      .then(function (updated) {
        state.issue = updated;
        renderIssue(updated);
        showToast(nextState === 'open' ? 'Issue 已重新打开' : 'Issue 已关闭');
        return loadIssues(seq.view);
      })
      .catch(function (error) { $('issue-detail-meta').textContent = issueError(error); })
      .finally(function () { $('issue-toggle-state').disabled = false; });
  });
  $('issue-comment-form').addEventListener('submit', function (event) {
    event.preventDefault();
    if (!state.repo || !state.issue) return;
    var body = $('issue-comment-body').value.trim();
    if (!body) return;
    var repo = state.repo;
    var number = state.issue.number;
    var submit = event.target.querySelector('button[type="submit"]');
    submit.disabled = true;
    createIssueComment(repo, number, body)
      .then(function () {
        $('issue-comment-body').value = '';
        showToast('评论已发布');
        return loadIssue(number);
      })
      .catch(function (error) { $('issue-detail-meta').textContent = issueError(error); })
      .finally(function () { submit.disabled = false; });
  });
  $('search-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var query = $('search-input').value.trim();
    if (!query) { closeSearch(); return; }
    runSearch(query);
  });
  $('search-close').addEventListener('click', closeSearch);
  // Changing what the box means re-asks the question that is already typed in
  // it, rather than leaving the old answer on screen under a new label.
  $('search-kind').addEventListener('change', function (event) {
    state.searchKind = event.target.value === 'path' ? 'path' : 'content';
    $('search-input').placeholder = state.searchKind === 'path'
      ? '按文件名查找' : '在这个版本里查找';
    var query = $('search-input').value.trim();
    if (query && !$('search-panel').hidden) runSearch(query);
  });

  $('file-history').addEventListener('click', function () {
    if (state.file) openPathHistory(state.file);
  });
  $('commit-filter-clear').addEventListener('click', clearPathHistory);

  // Delegated, because the rows are rebuilt for every file: one listener on the
  // block outlives them all, and a listener per line on a five-thousand-line
  // file is five thousand of them.
  $('file-code').addEventListener('click', function (event) {
    var button = event.target.closest ? event.target.closest('.code-num') : null;
    if (!button) return;
    var row = button.parentNode;
    var line = Number(row && row.dataset ? row.dataset.line : 0);
    if (!line) return;
    // Clicking the line you are already pointing at clears it, which is the
    // only way back to a URL without one short of editing the address bar.
    state.fileLine = state.fileLine === line ? 0 : line;
    markLine(state.fileLine, false);
    routeWrite();
  });

  // ---------------------------------------------------------------------------
  // Accounts
  //
  // Creating an account is administrator-only and was API-only until now, which
  // left the browser unable to do the one thing every other multi-account
  // feature needs first. Collaborators, private repositories and issue
  // authorship all assume a second account exists, and there was no way to make
  // one without a terminal — the same gap the repository create button closed,
  // one level up.
  //
  // Listing and creating, and deliberately not deleting: an account owns
  // repositories and has signed its name to issues, and where those go has to
  // be decided before a button can do it.
  // ---------------------------------------------------------------------------

  function userError(error) {
    var detail = (error && error.detail) || '';
    // The server owns the minimum length, so it is read back out of the message
    // rather than duplicated here — a change to AUTH_MIN_PASSWORD cannot leave
    // this form quoting a number nothing enforces.
    var short = detail.match(/password must be at least (\d+)/);
    if (short) return '密码至少需要 ' + short[1] + ' 个字符';
    var known = [
      ['user already exists', '这个用户名已经有人用了'],
      ['username must match', '用户名要以字母、数字或下划线开头，之后可以有 . - _'],
      ['email must be at most', '邮箱太长'],
      ['the account store is unavailable', '账号存储暂时不可用'],
      ['administrator', '只有管理员可以管理账号'],
    ];
    for (var i = 0; i < known.length; i += 1) {
      if (detail.indexOf(known[i][0]) !== -1) return known[i][1];
    }
    return detailMessage(error);
  }

  function renderUsers(users) {
    var list = $('users-list');
    list.textContent = '';
    if (!users.length) {
      setError(list, '还没有任何账号');
      return;
    }
    users.forEach(function (user) {
      var row = document.createElement('div');
      row.className = 'access-row';

      var who = document.createElement('div');
      var name = document.createElement('strong');
      name.textContent = user.username;
      who.appendChild(name);
      if (user.admin) {
        var badge = document.createElement('span');
        badge.className = 'pill';
        badge.textContent = '管理员';
        who.appendChild(document.createTextNode(' '));
        who.appendChild(badge);
      }
      if (user.username === state.username) {
        var self = document.createElement('span');
        self.className = 'pill';
        self.textContent = '这是你';
        who.appendChild(document.createTextNode(' '));
        who.appendChild(self);
      }

      var meta = document.createElement('div');
      meta.className = 'commit-meta';
      var parts = [];
      if (user.email) parts.push(user.email);
      parts.push('创建于 ' + formatDate(user.created_at));
      parts.push((user.token_count || 0) + ' 个有效令牌');
      meta.textContent = parts.join(' · ');
      who.appendChild(meta);

      row.appendChild(who);
      list.appendChild(row);
    });
  }

  function loadUsers() {
    var list = $('users-list');
    setLoading(list, '正在读取…');
    return json('/api/v1/users').then(function (data) {
      renderUsers(Array.isArray(data.users) ? data.users : []);
    }).catch(function (error) {
      setError(list, detailMessage(error));
    });
  }

  // The create response is the only copy of the recovery code that will ever
  // exist — the server stores its hash and has no endpoint that could answer
  // with it again. So it goes on screen and STAYS there while the listing
  // reloads underneath it, which is why it is not part of #users-list.
  function showRecovery(username, code) {
    $('user-created-name').textContent = username;
    $('user-created-code').textContent = code || '（服务器没有返回恢复码）';
    $('user-created').hidden = false;
  }

  function hideRecovery() {
    $('user-created').hidden = true;
    $('user-created-code').textContent = '';
  }

  $('user-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var username = $('user-name').value.trim();
    var password = $('user-password').value;
    if (!username || !password) {
      $('users-message').textContent = '请输入用户名和初始密码';
      return;
    }
    var payload = { username: username, password: password, admin: $('user-admin').checked };
    var email = $('user-email').value.trim();
    if (email) payload.email = email;

    $('user-submit').disabled = true;
    $('users-message').textContent = '';
    api('/api/v1/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).then(function (response) { return response.json(); })
      .then(function (created) {
        // Clear the form before anything else: the password field is the one
        // thing here that must not sit in the DOM waiting for whoever looks at
        // this screen next.
        $('user-form').reset();
        showRecovery(created.username || username, created.recovery_code);
        showToast('账号 ' + (created.username || username) + ' 已创建');
        return loadUsers();
      })
      .catch(function (error) {
        $('users-message').textContent = userError(error);
      })
      .then(function () { $('user-submit').disabled = false; });
  });

  $('copy-recovery').addEventListener('click', function () {
    copyText($('user-created-code').textContent, '已复制恢复码');
  });
  $('dismiss-recovery').addEventListener('click', hideRecovery);

  $('manage-users').addEventListener('click', function () {
    if (!state.admin) return;
    $('users-message').textContent = '';
    // Shown once means shown once. Reopening the panel is not that once, and a
    // code left on screen from an earlier account would read as this one's.
    hideRecovery();
    $('users-dialog').showModal();
    loadUsers();
  });

  // ---------------------------------------------------------------------------
  // Access tokens
  //
  // The listing carries no token value and cannot: only the digest is stored,
  // so there is nothing on the server that could answer with one.
  // ---------------------------------------------------------------------------

  function renderTokens(tokens) {
    var list = $('tokens-list');
    list.textContent = '';
    if (!tokens.length) {
      setError(list, '这个账号还没有令牌');
      return;
    }
    tokens.forEach(function (token) {
      var row = document.createElement('div');
      row.className = 'access-row';

      var who = document.createElement('div');
      var label = document.createElement('strong');
      label.textContent = token.label || 'token';
      who.appendChild(label);
      if (token.current) {
        var badge = document.createElement('span');
        badge.className = 'pill';
        badge.textContent = '当前会话';
        who.appendChild(document.createTextNode(' '));
        who.appendChild(badge);
      }
      var when = document.createElement('div');
      when.className = 'commit-meta';
      when.textContent = '创建于 ' + formatDate(token.created_at) +
        (token.expires_at ? ' · 到期 ' + formatDate(token.expires_at) : ' · 长期有效');
      who.appendChild(when);
      row.appendChild(who);

      var revoke = document.createElement('button');
      revoke.type = 'button';
      revoke.className = 'button button-quiet';
      revoke.textContent = token.current ? '吊销并退出' : '吊销';
      revoke.addEventListener('click', function () {
        revoke.disabled = true;
        $('tokens-message').textContent = '';
        api('/api/v1/user/tokens/' + encodeURIComponent(token.id), { method: 'DELETE' })
          .then(function (response) { return response.json(); })
          .then(function (result) {
            // Revoking the credential this tab is holding is a logout, and the
            // server has already made it so. Carrying on as if signed in would
            // mean every later request 401s with no explanation.
            if (result.was_current) {
              $('tokens-dialog').close();
              logout();
              showToast('当前令牌已吊销，已退出登录');
              return;
            }
            showToast('令牌已吊销');
            return loadTokens();
          })
          .catch(function (error) {
            revoke.disabled = false;
            $('tokens-message').textContent = detailMessage(error);
          });
      });
      row.appendChild(revoke);
      list.appendChild(row);
    });
  }

  function loadTokens() {
    var list = $('tokens-list');
    setLoading(list, '正在读取…');
    return json('/api/v1/user/tokens').then(function (data) {
      renderTokens(Array.isArray(data.tokens) ? data.tokens : []);
    }).catch(function (error) {
      setError(list, detailMessage(error));
    });
  }

  $('manage-tokens').addEventListener('click', function () {
    if (!state.username) { openAuth(); return; }
    $('tokens-message').textContent = '';
    $('tokens-dialog').showModal();
    loadTokens();
  });

  $('copy-clone').addEventListener('click', copyCloneUrl);
  $('download-zip').addEventListener('click', function () { downloadArchive('zip'); });
  $('download-tgz').addEventListener('click', function () { downloadArchive('tar.gz'); });
  $('copy-push').addEventListener('click', function () {
    copyText($('first-push-commands').textContent, '已复制推送命令');
  });
  $('refresh-empty').addEventListener('click', function () {
    if (!state.repo) return;
    var fullName = state.repo.full_name;
    loadRepos().then(function () {
      var current = state.repos.find(function (repo) { return repo.full_name === fullName; });
      if (current) selectRepo(current);
    }).catch(function () {});
  });
  $('auth-toggle').addEventListener('click', function () {
    if (state.username) logout(); else openAuth();
  });
  $('auth-form').addEventListener('submit', function (event) {
    event.preventDefault();
    var username = $('auth-user').value.trim();
    var password = $('auth-password').value;
    if (!username || !password) {
      $('auth-message').textContent = '请输入用户名和密码';
      return;
    }
    $('auth-submit').disabled = true;
    login(username, password).then(function () {
      $('auth-password').value = '';
      $('auth-dialog').close();
      updateAuthButton();
      showToast('登录成功');
      // Two requests, not one: the token says who signed in, and only the
      // server can say what they may do. loadSelf calls updateAuthButton again
      // when it lands, so the administrator controls appear a beat later rather
      // than not at all.
      loadSelf();
      return loadRepos().catch(function () {});
    }).catch(function (error) {
      clearCredentials();
      updateAuthButton();
      $('auth-message').textContent = error.status === 401
        ? '用户名或密码不正确' : (error.message || '登录失败');
    }).finally(function () { $('auth-submit').disabled = false; });
  });
  $('branch-select').addEventListener('change', function (event) {
    var view = beginView();
    state.branch = event.target.value;
    state.path = '';
    closeSearch();       // the hits were line numbers in a different revision
    state.commitSkip = 0;
    state.commitHasMore = false;
    hideFile();
    routeWrite();
    loadTree(view);
    loadCommits(view);
  });
  $('commit-prev').addEventListener('click', function () {
    if (!state.repo || state.commitSkip === 0) return;
    seq.diff += 1;
    $('diff-panel').hidden = true;
    loadCommits(seq.view, state.commitSkip - COMMIT_PAGE_SIZE);
  });
  $('commit-next').addEventListener('click', function () {
    if (!state.repo || !state.commitHasMore) return;
    seq.diff += 1;
    $('diff-panel').hidden = true;
    loadCommits(seq.view, state.commitSkip + COMMIT_PAGE_SIZE);
  });
  $('close-file').addEventListener('click', function () {
    hideFile();
    routeWrite();
    syncCodeLayout();
  });
  // Collapsing the tree is the only way to give a file the whole width, which
  // is worth having the moment one of its lines is long.
  if ($('side-toggle')) $('side-toggle').addEventListener('click', function () {
    sideHidden = !sideHidden;
    syncCodeLayout();
  });
  // The source is already in hand, so this is a re-render rather than a fetch.
  // Deliberately not in the URL: a link to a file should open the way the
  // repository reads, and how one reader prefers to look at it is not state
  // anybody wants to share.
  $('toggle-render').addEventListener('click', function () {
    if (!state.file) return;
    state.fileRaw = !state.fileRaw;
    showFileText(state.fileText, state.file);
  });
  on('tree-latest-subject', 'click', function () { openCommit(latestCommit); });
  $('close-diff').addEventListener('click', function () {
    seq.diff += 1;
    $('diff-panel').hidden = true;
  });
  $$('.view-tab').forEach(function (tab) {
    tab.addEventListener('click', function () { showView(tab.dataset.view); routeWrite(); });
  });

  // Back and Forward, and somebody editing the address by hand. A write of our
  // own also fires this, so compare against what the current state would encode
  // and do nothing when they already agree — which is cheaper and more reliable
  // than tracking the last value we wrote.
  window.addEventListener('hashchange', function () {
    if ((location.hash || '#/') === routeEncode()) return;
    routeApply();
  });

  loadCredentials();
  updateAuthButton();
  // The browser starts in an authenticated workflow: visitors can dismiss the
  // dialog to browse public repositories, while the login link remains in the
  // top bar for anyone who wants to come back to it.
  if (!state.username) openAuth();
  loadSelf();
  // The address bar can only be applied once the repository list is in: it names
  // a repository by owner/name, and the record behind it is what selectRepo
  // needs. A failed load leaves the page on the empty state, which is what it
  // showed before any of this existed.
  loadRepos().then(function () {
    if ((location.hash || '').length > 2) routeApply();
  }).catch(function () {});
})();
