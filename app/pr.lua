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
