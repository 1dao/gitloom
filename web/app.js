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
    collaborators: [],
    username: '',
    token: '',
    toastTimer: null,
    fileBlobUrl: '',   // released in releaseFileBlob; see loadFile
    // Which view is showing and which file is open used to live only in the
    // DOM. The address bar has to be able to say both, so they live here now.
    view: 'code',
    file: '',
  };

  // Every navigation takes a ticket. A response whose ticket is no longer the
  // current one belongs to a repository, branch or directory the user has
  // already left, and rendering it would show them the wrong tree — which is
  // not theoretical on a server where each listing forks a git process, so a
  // slow response really does arrive after a fast one issued later.
  var seq = { repos: 0, view: 0, file: 0, diff: 0, commits: 0, access: 0, issues: 0, issue: 0 };
  var COMMIT_PAGE_SIZE = 25;

  var $ = function (id) { return document.getElementById(id); };
  var $$ = function (selector) { return Array.prototype.slice.call(document.querySelectorAll(selector)); };

  function beginView() {
    seq.view += 1;
    seq.file += 1;   // a panel opened under the old view must not land either
    seq.diff += 1;
    seq.commits += 1;
    seq.issues += 1;
    seq.issue += 1;
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

  function setConnection(kind, label) {
    var dot = $('connection-dot');
    var text = $('connection-label');
    dot.className = 'connection-dot' + (kind ? ' ' + kind : '');
    text.textContent = label;
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
    syncWriteActions();
  }

  // The browser currently knows the signed-in username, but not an administrator
  // capability. Show owner-only write actions; administrators can still use the
  // API until a capability field is exposed to the browser.
  function syncWriteActions() {
    var signedIn = !!state.username;
    $('new-repo').hidden = !signedIn;
    $('new-issue').hidden = !signedIn || !state.repo;
    var canManage = signedIn && state.repo && state.repo.owner === state.username;
    $('edit-repo').hidden = !canManage;
    $('manage-access').hidden = !canManage;
    $('delete-repo').hidden = !canManage;
  }

  function renderRepos() {
    var list = $('repo-list');
    var query = ($('repo-search').value || '').trim().toLowerCase();
    list.textContent = '';
    var visible = state.repos.filter(function (repo) {
      var haystack = (repo.owner + '/' + repo.name + ' ' + (repo.description || '')).toLowerCase();
      return !query || haystack.indexOf(query) !== -1;
    });
    $('repo-count').textContent = state.repos.length + ' 个仓库';
    if (!visible.length) {
      setError(list, query ? '没有匹配的仓库' : '暂无可见仓库');
      return;
    }
    visible.forEach(function (repo) {
      var item = document.createElement('button');
      item.type = 'button';
      item.className = 'repo-item' + (state.repo && state.repo.full_name === repo.full_name ? ' active' : '');
      item.dataset.repo = repo.full_name;

      var title = document.createElement('span');
      title.className = 'repo-item-title';
      var owner = document.createElement('span');
      owner.className = 'repo-owner';
      owner.textContent = repo.owner + '/';
      var name = document.createElement('span');
      name.className = 'repo-name';
      name.textContent = repo.name;
      title.appendChild(owner);
      title.appendChild(name);
      if (repo.private) {
        var lock = document.createElement('span');
        lock.className = 'repo-lock';
        lock.textContent = '◆';
        lock.title = '私有仓库';
        title.appendChild(lock);
      }
      item.appendChild(title);
      if (repo.description) {
        var description = document.createElement('span');
        description.className = 'repo-item-desc';
        description.textContent = repo.description;
        item.appendChild(description);
      }
      item.addEventListener('click', function () { selectRepo(repo); });
      list.appendChild(item);
    });
  }

  function loadRepos() {
    var ticket = (seq.repos += 1);
    setConnection('', '正在读取');
    setLoading($('repo-list'), '正在读取仓库…');
    return json('/api/v1/repos').then(function (data) {
      if (ticket !== seq.repos) return state.repos;
      state.repos = Array.isArray(data.repos) ? data.repos : [];
      setConnection('ok', state.username ? '已登录' : '在线');
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
      if (error.status === 401) {
        setConnection('', '需要登录');
        setError($('repo-list'), '登录后查看仓库');
      } else {
        setConnection('error', '连接失败');
        setError($('repo-list'), error.message);
      }
      state.repos = [];
      $('repo-count').textContent = '0 个仓库';
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
    $('edit-description').value = state.repo.description || '';
    $('edit-private').checked = !!state.repo.private;
    $('edit-dialog').showModal();
    $('edit-description').focus();
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

  function updateRepo(repo, description, isPrivate) {
    // The server owns the byte limit for descriptions. Keeping no duplicated
    // maxlength here means a future config change cannot leave this form with
    // a stale client-side ceiling.
    return api('/api/v1/repos/' + encodeURIComponent(repo.owner) + '/' +
      encodeURIComponent(repo.name), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ description: description, private: isPrivate }),
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

  function renderIssue(issue) {
    $('issue-detail-title').textContent = '#' + issue.number + ' ' + issue.title;
    $('issue-detail-meta').textContent = issue.author + ' · ' + formatDate(issue.created_at);
    $('issue-detail-body').textContent = issue.body || '没有描述';
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
      body.className = 'issue-comment-body';
      body.textContent = comment.body;
      item.appendChild(body);
      comments.appendChild(item);
    });
    var canEdit = !!state.username &&
      (state.username === issue.author || (state.repo && state.repo.owner === state.username));
    var toggle = $('issue-toggle-state');
    toggle.hidden = !canEdit;
    toggle.textContent = issue.state === 'open' ? '关闭 Issue' : '重新打开';
    $('issue-comment-form').hidden = !state.username;
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

  function updateIssue(repo, number, stateValue) {
    return api(issuesPath(repo, '/' + encodeURIComponent(number)), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ state: stateValue }),
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
    state.repo = null;
    state.collaborators = [];
    state.issues = [];
    state.issue = null;
    if ($('access-dialog').open) $('access-dialog').close();
    $('repo-view').hidden = true;
    $('empty-state').hidden = false;
    syncWriteActions();
    routeWrite();
  }

  // `<span>workspace</span> / owner / name`, built rather than assembled as
  // markup: repository and account names are constrained server-side, but this
  // is the one place that would turn a slip in that constraint into script.
  function renderCrumbs(repo) {
    var crumbs = $('repo-crumbs');
    crumbs.textContent = '';
    var workspace = document.createElement('span');
    workspace.textContent = 'workspace';
    crumbs.appendChild(workspace);
    crumbs.appendChild(document.createTextNode(' / ' + repo.owner + ' / ' + repo.name));
  }

  function renderCloneUrl(repo) {
    var row = $('clone-row');
    var input = $('clone-url');
    input.value = repo.clone_url || '';
    row.hidden = !input.value;
  }

  function renderRepoMeta(repo) {
    $('repo-title').textContent = repo.full_name;
    $('repo-description').textContent = repo.description || '暂无描述';
    renderCrumbs(repo);
    renderCloneUrl(repo);
    var visibility = $('repo-visibility');
    visibility.textContent = repo.private ? '私有' : '公开';
    visibility.className = 'visibility-pill' + (repo.private ? ' private' : '');
    $('repo-default-branch').textContent = '默认分支 · ' + (repo.default_branch || 'main');
  }

  function setFirstPush(repo, empty) {
    var panel = $('first-push');
    var browser = $('tree-browser');
    panel.hidden = !empty;
    browser.hidden = !!empty;
    if (empty && repo) {
      var branch = repo.default_branch || state.branch || 'main';
      $('first-push-commands').textContent =
        'git remote add origin ' + (repo.clone_url || '') + '\n' +
        'git push -u origin ' + branch;
    }
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
    state.path = target.path || '';
    state.commitSkip = 0;
    state.commitHasMore = false;
    resetCommits();
    $('empty-state').hidden = true;
    $('repo-view').hidden = false;
    renderRepoMeta(repo);
    setFirstPush(repo, false);
    syncWriteActions();
    hideFile();          // clears state.file; the file itself is fetched below
    // A blob URL names a file, and the listing behind it has to be the
    // directory that file sits in — that is what the click path leaves on
    // screen, so it is what a link back to the same place has to reproduce.
    if (target.file) {
      state.file = target.file;
      state.path = target.file.replace(/\/?[^\/]*$/, '');
    }
    $('diff-panel').hidden = true;
    renderRepos();
    showView(target.view || 'code');
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
      if (target.file) loadFile(target.file);
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

  function refGroup(select, label, names) {
    if (!names.length) return;
    var group = document.createElement('optgroup');
    group.label = label;
    names.forEach(function (name) {
      var option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      option.selected = name === state.branch;
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
        refGroup(select, '分支', names);
        refGroup(select, '标签', tagNames);
        select.disabled = names.length + tagNames.length < 2;
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

  function loadTree(view) {
    var list = $('tree-list');
    var path = encodePath(state.path);
    var suffix = '/tree/' + encodeRef(state.branch) + (path ? '/' + path : '');
    setLoading(list, '正在读取文件树…');
    $('current-path').textContent = '/' + (state.path || '');
    $('up-directory').hidden = !state.path;
    return json(repoPath(suffix)).then(function (data) {
      if (!viewIsCurrent(view)) return [];
      var entries = Array.isArray(data.entries) ? data.entries : [];
      $('tree-caption').textContent = state.path ? state.path : '文件';
      $('tree-count').textContent = entries.length + ' 项';
      list.textContent = '';
      if (!entries.length) {
        setError(list, '这个目录是空的');
        return entries;
      }
      entries.forEach(function (entry) { renderTreeEntry(entry, list); });
      return entries;
    }).catch(function (error) {
      if (!viewIsCurrent(view)) return [];
      $('tree-count').textContent = '';
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

  function renderTreeEntry(entry, list) {
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'tree-row ' + (entry.type === 'tree' ? 'directory' : 'file');
    var icon = document.createElement('span');
    icon.className = 'tree-icon';
    icon.textContent = entry.type === 'tree' ? '▱' : '·';
    row.appendChild(icon);
    var name = document.createElement('span');
    name.className = 'tree-name';
    var strong = document.createElement('strong');
    strong.textContent = entry.name;
    name.appendChild(strong);
    row.appendChild(name);
    var size = document.createElement('span');
    size.className = 'tree-size';
    size.textContent = entry.type === 'blob' ? formatBytes(entry.size) : '';
    row.appendChild(size);
    var chevron = document.createElement('span');
    chevron.className = 'tree-chevron';
    chevron.textContent = entry.type === 'tree' ? '›' : '';
    row.appendChild(chevron);
    row.addEventListener('click', function () {
      if (entry.type === 'tree') {
        var view = beginView();
        state.path = entry.path;
        hideFile();
        loadTree(view);
      } else {
        loadFile(entry.path);
      }
      routeWrite();
    });
    list.appendChild(row);
  }

  // An object URL is a document-lifetime reference to the bytes behind it, so
  // one has to be released or every file opened in a session is still in memory
  // when the tab closes.
  function releaseFileBlob() {
    if (!state.fileBlobUrl) return;
    URL.revokeObjectURL(state.fileBlobUrl);
    state.fileBlobUrl = '';
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
  function loadFile(path) {
    var ticket = (seq.file += 1);
    var panel = $('file-panel');
    var text = $('file-content');
    var wrap = $('file-image-wrap');
    var link = $('download-file');

    state.file = path;
    panel.hidden = false;
    wrap.hidden = true;
    link.hidden = true;
    text.hidden = false;
    $('file-title').textContent = path;
    text.textContent = '正在读取…';

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
        panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
        return;
      }
      return got.blob.text().then(function (body) {
        if (ticket !== seq.file) return;
        text.textContent = looksBinary(body)
          ? '这是二进制文件，没法在这里显示。用上面的「下载」取回原始内容。'
          : body;
        panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    }).catch(function (error) {
      if (ticket !== seq.file) return;
      text.hidden = false;
      wrap.hidden = true;
      text.textContent = error.message;
    });
  }

  function hideFile() {
    seq.file += 1;   // whatever is in flight no longer has a panel to land in
    state.file = '';
    releaseFileBlob();
    $('file-image').removeAttribute('src');
    $('file-panel').hidden = true;
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
    return json(repoPath('/commits?ref=' + encodeURIComponent(state.branch) +
      '&limit=' + COMMIT_PAGE_SIZE + '&skip=' + requestedSkip)).then(function (data) {
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
        setError(list, '这个分支还没有提交');
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
      setError(list, error.status === 404 ? '这个分支还没有提交' : error.message);
      return [];
    });
  }

  function renderCommit(commit, list) {
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
    row.addEventListener('click', function () { loadDiff(commit); });
    list.appendChild(row);
  }

  function formatDate(value) {
    if (!value) return '';
    var date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
  }

  function loadDiff(commit) {
    var ticket = (seq.diff += 1);
    var panel = $('diff-panel');
    panel.hidden = false;
    $('diff-title').textContent = commit.subject || commit.short || commit.oid;
    $('diff-meta').textContent = (commit.author && commit.author.name ? commit.author.name : 'unknown') +
      ' · ' + formatDate(commit.author && commit.author.date) + ' · ' + (commit.oid || '');
    $('diff-content').textContent = '正在生成 diff…';
    var suffix = '/commits/' + encodeURIComponent(commit.oid) + '/diff';
    json(repoPath(suffix)).then(function (data) {
      if (ticket !== seq.diff) return;
      renderDiff(String(data.diff || ''));
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (error) {
      if (ticket !== seq.diff) return;
      $('diff-content').textContent = error.message;
    });
  }

  function renderDiff(text) {
    var pre = $('diff-content');
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
      return base + '/commits/' + encodeRef(state.branch);
    }
    var target = state.file || state.path;
    return base + (state.file ? '/blob/' : '/tree/') + encodeRef(state.branch) +
           (target ? '/' + encodePath(target) : '');
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
  function routeApply() {
    var raw = (location.hash || '').replace(/^#\/?/, '');
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
    } else if (kind === 'tree' || kind === 'blob') {
      target.ref = parts[3];
      var rest = parts.slice(4).join('/');
      if (kind === 'blob') target.file = rest; else target.path = rest;
    }
    selectRepo(repo, target);
  }

  function showView(view) {
    state.view = view;
    $$('.view-tab').forEach(function (tab) { tab.classList.toggle('active', tab.dataset.view === view); });
    $('code-view').hidden = view !== 'code';
    $('commits-view').hidden = view !== 'commits';
    $('issues-view').hidden = view !== 'issues';
    if (view === 'issues' && state.repo) loadIssues(seq.view);
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
    $('edit-submit').disabled = true;
    updateRepo(repo, $('edit-description').value.trim(), $('edit-private').checked)
      .then(function (updated) {
        $('edit-dialog').close();
        state.repo = updated;
        state.repos = state.repos.map(function (item) {
          return item.full_name === updated.full_name ? updated : item;
        });
        renderRepoMeta(updated);
        syncWriteActions();
        renderRepos();
        showToast('仓库设置已保存');
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
    updateIssue(state.repo, issue.number, nextState)
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
  $('copy-clone').addEventListener('click', copyCloneUrl);
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
  $('up-directory').addEventListener('click', function () {
    var view = beginView();
    var parts = state.path.split('/');
    parts.pop();
    state.path = parts.join('/');
    hideFile();
    routeWrite();
    loadTree(view);
  });
  $('close-file').addEventListener('click', function () { hideFile(); routeWrite(); });
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
  // The address bar can only be applied once the repository list is in: it names
  // a repository by owner/name, and the record behind it is what selectRepo
  // needs. A failed load leaves the page on the empty state, which is what it
  // showed before any of this existed.
  loadRepos().then(function () {
    if ((location.hash || '').length > 2) routeApply();
  }).catch(function () {});
})();
