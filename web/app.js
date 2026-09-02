(function () {
  'use strict';

  var state = {
    repos: [],
    repo: null,
    branch: '',
    path: '',
    commits: [],
    username: '',
    password: '',
    toastTimer: null,
  };

  var $ = function (id) { return document.getElementById(id); };
  var $$ = function (selector) { return Array.prototype.slice.call(document.querySelectorAll(selector)); };

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
      state.password = sessionStorage.getItem('gitloom.password') || '';
    } catch (_) {
      state.username = '';
      state.password = '';
    }
  }

  function saveCredentials(username, password) {
    state.username = username;
    state.password = password;
    try {
      sessionStorage.setItem('gitloom.username', username);
      sessionStorage.setItem('gitloom.password', password);
    } catch (_) {}
  }

  function clearCredentials() {
    state.username = '';
    state.password = '';
    try {
      sessionStorage.removeItem('gitloom.username');
      sessionStorage.removeItem('gitloom.password');
    } catch (_) {}
  }

  function authHeaders() {
    var headers = { Accept: 'application/json' };
    if (state.username) {
      headers.Authorization = 'Basic ' + window.btoa(unescape(encodeURIComponent(state.username + ':' + state.password)));
    }
    return headers;
  }

  function parseError(response) {
    return response.text().then(function (raw) {
      try {
        var data = JSON.parse(raw);
        return data.error || data.message || ('请求失败（' + response.status + '）');
      } catch (_) {
        return raw || ('请求失败（' + response.status + '）');
      }
    });
  }

  function api(path, options) {
    var opts = options || {};
    opts.headers = Object.assign({}, authHeaders(), opts.headers || {});
    return fetch(path, opts).then(function (response) {
      if (response.ok) return response;
      if (response.status === 401 && state.username) {
        clearCredentials();
        updateAuthButton();
      }
      return parseError(response).then(function (message) {
        var error = new Error(message);
        error.status = response.status;
        throw error;
      });
    });
  }

  function json(path) {
    return api(path).then(function (response) { return response.json(); });
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
    setConnection('', '正在读取');
    setLoading($('repo-list'), '正在读取仓库…');
    return json('/api/v1/repos').then(function (data) {
      state.repos = Array.isArray(data.repos) ? data.repos : [];
      setConnection('ok', state.username ? '已登录' : '在线');
      renderRepos();
      if (state.repo) {
        var current = state.repos.find(function (repo) { return repo.full_name === state.repo.full_name; });
        if (current) state.repo = current;
      }
      return state.repos;
    }).catch(function (error) {
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

  function selectRepo(repo) {
    state.repo = repo;
    state.branch = repo.default_branch || 'main';
    state.path = '';
    $('empty-state').hidden = true;
    $('repo-view').hidden = false;
    $('repo-title').textContent = repo.full_name;
    $('repo-description').textContent = repo.description || '暂无描述';
    $('repo-crumbs').innerHTML = '<span>workspace</span> / ' + repo.owner + ' / ' + repo.name;
    var visibility = $('repo-visibility');
    visibility.textContent = repo.private ? '私有' : '公开';
    visibility.className = 'visibility-pill' + (repo.private ? ' private' : '');
    $('repo-default-branch').textContent = '默认分支 · ' + (repo.default_branch || 'main');
    renderRepos();
    loadBranches().then(function () { return loadTree(); });
    loadCommits();
    showView('code');
  }

  function loadBranches() {
    var select = $('branch-select');
    select.textContent = '';
    select.disabled = true;
    return json(repoPath('/branches')).then(function (data) {
      var branches = Array.isArray(data.branches) ? data.branches : [];
      if (!branches.length) {
        var empty = document.createElement('option');
        empty.textContent = '暂无分支';
        empty.value = state.branch;
        select.appendChild(empty);
      } else {
        var preferred = branches.some(function (branch) { return branch.name === state.branch; });
        if (!preferred) state.branch = branches[0].name;
        branches.forEach(function (branch) {
          var option = document.createElement('option');
          option.value = branch.name;
          option.textContent = branch.name;
          option.selected = branch.name === state.branch;
          select.appendChild(option);
        });
      }
      select.disabled = branches.length < 2;
      return branches;
    }).catch(function () {
      var option = document.createElement('option');
      option.value = state.branch;
      option.textContent = state.branch || 'main';
      select.appendChild(option);
      return [];
    });
  }

  function loadTree() {
    var list = $('tree-list');
    var path = encodePath(state.path);
    var suffix = '/tree/' + encodeRef(state.branch) + (path ? '/' + path : '');
    setLoading(list, '正在读取文件树…');
    $('current-path').textContent = '/' + (state.path || '');
    $('up-directory').hidden = !state.path;
    return json(repoPath(suffix)).then(function (data) {
      var entries = Array.isArray(data.entries) ? data.entries : [];
      $('tree-caption').textContent = state.path ? state.path : '文件';
      $('tree-count').textContent = entries.length + ' 项';
      list.textContent = '';
      if (!entries.length) {
        setError(list, '这个目录是空的');
        return entries;
      }
      entries.forEach(renderTreeEntry);
      return entries;
    }).catch(function (error) {
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

  function renderTreeEntry(entry) {
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
        state.path = entry.path;
        hideFile();
        loadTree();
      } else {
        loadFile(entry.path);
      }
    });
    $('tree-list').appendChild(row);
  }

  function loadFile(path) {
    var panel = $('file-panel');
    panel.hidden = false;
    $('file-title').textContent = path;
    $('file-content').textContent = '正在读取…';
    var suffix = '/raw/' + encodeRef(state.branch) + '/' + encodePath(path);
    api(repoPath(suffix)).then(function (response) { return response.text(); }).then(function (body) {
      $('file-content').textContent = body;
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (error) {
      $('file-content').textContent = error.message;
    });
  }

  function hideFile() { $('file-panel').hidden = true; }

  function loadCommits() {
    var list = $('commit-list');
    setLoading(list, '正在读取提交记录…');
    return json(repoPath('/commits?ref=' + encodeURIComponent(state.branch) + '&limit=50')).then(function (data) {
      state.commits = Array.isArray(data.commits) ? data.commits : [];
      $('commit-count').textContent = state.commits.length + ' 条';
      list.textContent = '';
      if (!state.commits.length) {
        setError(list, '这个分支还没有提交');
        return [];
      }
      state.commits.forEach(renderCommit);
      return state.commits;
    }).catch(function (error) {
      $('commit-count').textContent = '';
      setError(list, error.message);
      return [];
    });
  }

  function renderCommit(commit) {
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
    $('commit-list').appendChild(row);
  }

  function formatDate(value) {
    if (!value) return '';
    var date = new Date(value);
    return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
  }

  function loadDiff(commit) {
    var panel = $('diff-panel');
    panel.hidden = false;
    $('diff-title').textContent = commit.subject || commit.short || commit.oid;
    $('diff-meta').textContent = (commit.author && commit.author.name ? commit.author.name : 'unknown') +
      ' · ' + formatDate(commit.author && commit.author.date) + ' · ' + (commit.oid || '');
    $('diff-content').textContent = '正在生成 diff…';
    var suffix = '/commits/' + encodeURIComponent(commit.oid) + '/diff';
    json(repoPath(suffix)).then(function (data) {
      renderDiff(String(data.diff || ''));
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }).catch(function (error) {
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

  function showView(view) {
    $$('.view-tab').forEach(function (tab) { tab.classList.toggle('active', tab.dataset.view === view); });
    $('code-view').hidden = view !== 'code';
    $('commits-view').hidden = view !== 'commits';
  }

  function openAuth() {
    $('auth-message').textContent = '';
    $('auth-user').value = state.username;
    $('auth-password').value = '';
    $('auth-dialog').showModal();
    $('auth-user').focus();
  }

  function logout() {
    clearCredentials();
    state.repo = null;
    $('repo-view').hidden = true;
    $('empty-state').hidden = false;
    updateAuthButton();
    loadRepos().catch(function () {});
    showToast('已退出登录');
  }

  $('repo-search').addEventListener('input', renderRepos);
  $('refresh-repos').addEventListener('click', function () { loadRepos().catch(function () {}); });
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
    saveCredentials(username, password);
    loadRepos().then(function () {
      $('auth-dialog').close();
      updateAuthButton();
      showToast('登录成功');
    }).catch(function (error) {
      clearCredentials();
      $('auth-message').textContent = error.message || '登录失败';
    }).finally(function () { $('auth-submit').disabled = false; });
  });
  $('branch-select').addEventListener('change', function (event) {
    state.branch = event.target.value;
    state.path = '';
    hideFile();
    loadTree();
    loadCommits();
  });
  $('up-directory').addEventListener('click', function () {
    var parts = state.path.split('/');
    parts.pop();
    state.path = parts.join('/');
    hideFile();
    loadTree();
  });
  $('close-file').addEventListener('click', hideFile);
  $('close-diff').addEventListener('click', function () { $('diff-panel').hidden = true; });
  $$('.view-tab').forEach(function (tab) { tab.addEventListener('click', function () { showView(tab.dataset.view); }); });

  loadCredentials();
  updateAuthButton();
  loadRepos().catch(function () {});
})();
