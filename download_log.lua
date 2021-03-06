local json  = require "cjson.safe"
local mysql = require "resty.mysql"
local conf  = require "comm/conf"
local util  = require "comm/util"
local webhdfs  = require "comm/webhdfs"
local shell = require "resty/shell"
local resty_string = require "resty/string"

local req_method = ngx.req.get_method()
if req_method ~= 'GET' then
	ngx.log(ngx.DEBUG, "req_method not GET: ", req_method)
	return
end

local request_uri = ngx.var.request_uri
local document_root = ngx.var.document_root
ngx.log(ngx.DEBUG, "request_uri: ", request_uri, "document_root: ", document_root)

if not request_uri then
	ngx.exit(ngx.HTTP_BAD_REQUEST)
end

local http_status = util.http_head_check_local()

--本地不存在就proxy_pass
if http_status ~= 200 then
	http_status = util.http_head_check()
	if http_status == 200 then
		ngx.log(ngx.DEBUG, "this file is found in another ip")
		return ngx.exec(request_uri.."_proxy_pass")
	end
end

--/logs/20161122/dh3.kimg.cn/small_2016112216_access.log.gz
--/logs/20161122/dh3.kimg.cn/small_2016112216_access.log.seg000.gz

local seg = nil
local regex_expr = [=[^(.*_access\.log)(\.seg[0-9]{3})?\.gz$]=]
local m = ngx.re.match(request_uri, regex_expr, "o")
if not m then
	ngx.log(ngx.ERR, "request_uri not match regex: ", regex_expr, "request_uri: ", request_uri)
	return
end

ngx.log(ngx.DEBUG, "m[1]: ", m[1], ", m[2]: ", m[2])

local hdfs_path = m[1]

if type(m[2]) == "string" then
	seg = tonumber(string.sub(m[2], -3, -1))
end
ngx.log(ngx.DEBUG, "hdfs_path: ", hdfs_path, ", seg: ", seg)

if not seg then
	--全文件下载不用这个接口
    return
end

local gz_log_path = document_root..request_uri
local log_path = string.sub(gz_log_path, 1, -4)
ngx.log(ngx.DEBUG, "log_path: ", log_path, ", gz_log_path: ", gz_log_path)

--检查文件是否存在
local file_size = webhdfs.get_file_size(hdfs_path)
if file_size <= 0 then
	ngx.log(ngx.ERR, hdfs_path, " not found in hadoop")
	ngx.exit(ngx.HTTP_NOT_FOUND)
end

local max_seg = math.ceil(file_size/conf.segment_size) - 1
ngx.log(ngx.DEBUG, "file_size: ", file_size, ", max_seg: ", max_seg)

if seg then
	if seg > max_seg then
		ngx.log(ngx.ERR, "seg exceeds max_seg: ", seg, " > ", max_seg)
		ngx.exit(ngx.HTTP_NOT_FOUND)
	end
end

--[[
--检查是否正在打包或下载 方法就是看.log文件是否存在
local cmd = string.format("stat %s", log_path)
local args = {socket = "unix:/tmp/shell.sock", timeout = 10000}
local status, out, err = shell.execute(cmd, args)
ngx.log(ngx.DEBUG, "cmd: ", cmd, "status: ", status, ", out: ", out, ", err: ", err)

if status == 0 then
	ngx.log(ngx.ERR, "cmd: ", cmd, "status: ", status, ", out: ", out, ", err: ", err)
	ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end
--]]

--curl --silent 'http://106.75.31.237:50070/webhdfs/v1/logs/20161123/api.dmzj.com/small_2016112308_access.log?op=OPEN' -L -o aa.log
local cmd = string.format("[ ! -f %s ] && mkdir -p `dirname %s`"
						.." && curl --silent 'http://10.9.101.54:50070/webhdfs/v1%s?op=OPEN' -L"
						.." | gzip --fast > %s",
						gz_log_path,
						gz_log_path,
						hdfs_path,
						gz_log_path)

if seg then
	local offset = seg*conf.segment_size
	local length = conf.segment_size
	cmd = string.format("[ ! -f %s ] && mkdir -p `dirname %s`"
						.." && curl --silent 'http://10.9.101.54:50070/webhdfs/v1%s?op=OPEN&offset=%d&length=%d' -L"
						.." | gzip --fast > %s",
						gz_log_path,
						gz_log_path,
						hdfs_path,
						offset,
						length,
						gz_log_path)
end

ngx.log(ngx.DEBUG, "cmd: ", cmd)

local args = {socket = "unix:/tmp/shell.sock", timeout = 60000}
local status, out, err = shell.execute(cmd, args)
if status ~= 0 and status ~= 256 then
	ngx.log(ngx.ERR, "cmd: ", cmd, "status: ", status, ", out: ", out, ", err: ", err)
	ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

local function remove_file(premature, file_name)
	local args = {socket = "unix:/tmp/shell.sock", timeout = 10000}
	local cmd = string.format("rm -f %s", file_name)
	ngx.log(ngx.DEBUG, "removing files: ", cmd)
	local status, out, err = shell.execute(cmd, args)
	if status ~= 0 then
		ngx.log(ngx.ERR, "cmd: ", cmd, "status: ", status, ", out: ", out, ", err: ", err)
	end	
end

--确定是否是最后一个片段 最后一个片段不应该保留
--[[
if seg == max_seg then
	ngx.log(ngx.DEBUG, "this last segment needs removing: ", max_seg)
	local ok, err = ngx.timer.at(600, remove_file, gz_log_path)
	if not ok then
	 ngx.log(ngx.ERR, "failed to create timer: ", err)
	 return
	end
end
--]]
