local prs, path
local function load()
 if prs then return end; path=util_path_join(cfg_get('DATA_DIR','data'),'pull_requests.json'); local r=util_file_read(path); prs=(r and r~='' and xutils.json_unpack(r)) or {}; if type(prs)~='table' then prs={} end
end
local function save() return util_file_write_atomic(path,xutils.json_pack(prs)) end
local function key(o,n) return o..'/'..n end
function g_exports.pr_list(o,n,state) load(); local a={}; for _,p in pairs(prs[key(o,n)] or {}) do if not state or p.state==state then a[#a+1]=p end end; table.sort(a,function(x,y)return x.number<y.number end); return a end
function g_exports.pr_get(o,n,num) load(); return (prs[key(o,n)] or {})[tonumber(num)] end
function g_exports.pr_create(o,n,u,b) load(); local m=prs[key(o,n)] or {}; prs[key(o,n)]=m; local num=0; for k in pairs(m) do if tonumber(k)>num then num=tonumber(k) end end; num=num+1; local p={number=num,title=b.title,body=b.body or '',base=b.base,head=b.head,author=u,state='open',created_at=os.time(),updated_at=os.time()}; if type(p.title)~='string' or p.title=='' or type(p.base)~='string' or type(p.head)~='string' then return nil,'title, base and head are required',400 end; m[num]=p; local ok,e=save(); if not ok then m[num]=nil; return nil,e,500 end; return p end
function g_exports.pr_update(o,n,num,b) load(); local p=g_exports.pr_get(o,n,num); if not p then return nil,'no such pull request',404 end; if b.state and b.state~='open' and b.state~='closed' and b.state~='merged' then return nil,'invalid state',400 end; for _,k in ipairs({'title','body','state'}) do if b[k]~=nil then p[k]=b[k] end end; p.updated_at=os.time(); local ok,e=save(); if not ok then return nil,e,500 end; return p end
function g_exports.pr_merge(o,n,num,method)
 load(); local p=g_exports.pr_get(o,n,num); if not p then return nil,'no such pull request',404 end; if p.state~='open' then return nil,'pull request is not open',409 end
 local d=repo_dir(o,n); local chk=git_exec({'merge-tree','--write-tree',p.base,p.head},{cwd=d}); if not chk.ok then return nil,'merge conflict',409 end
 local args={'merge',p.head}; if method=='squash' then args={'merge','--squash',p.head} elseif method=='rebase' then args={'rebase',p.head} end
 local r=git_exec(args,{cwd=d}); if not r.ok then return nil,'merge failed',409 end; p.state='merged'; p.merge_method=method or 'merge'; p.updated_at=os.time(); save(); return p
end
function g_exports.pr_comment(o,n,num,u,body) load(); local p=g_exports.pr_get(o,n,num); if not p then return nil,'no such pull request',404 end; if type(body)~='string' or body=='' then return nil,'comment body is required',400 end; p.comments=p.comments or {}; p.comments[#p.comments+1]={author=u,body=body,created_at=os.time()}; p.updated_at=os.time(); local ok,e=save(); if not ok then return nil,e,500 end; return p.comments[#p.comments] end
function g_exports.pr_review(o,n,num,u,state,body) load(); local p=g_exports.pr_get(o,n,num); if not p then return nil,'no such pull request',404 end; if state~='approve' and state~='request_changes' and state~='comment' then return nil,'invalid review state',400 end; p.reviews=p.reviews or {}; p.reviews[#p.reviews+1]={author=u,state=state,body=body or '',created_at=os.time()}; p.updated_at=os.time(); local ok,e=save(); if not ok then return nil,e,500 end; return p.reviews[#p.reviews] end
