local config = require("rest-nvim.config")

local random = math.random
math.randomseed(os.time())

local M = {}

M.binary_content_types = {
  "octet-stream",
}

M.is_binary_content_type = function(content_type)
  return vim.tbl_contains(M.binary_content_types, content_type)
end

-- move_cursor moves the cursor to the desired position in the provided buffer
-- @param bufnr Buffer number, a.k.a id
-- @param line the desired line
-- @param column the desired column, defaults to 1
M.move_cursor = function(bufnr, line, column)
  column = column or 1
  vim.api.nvim_buf_call(bufnr, function()
    vim.fn.cursor(line, column)
  end)
end

M.set_env = function(key, value)
  local variables = M.get_env_variables()
  variables[key] = value
  M.write_env_file(variables)
end

M.write_env_file = function(variables)
  local env_file = "/" .. (config.get("env_file") or ".env")

  -- Directories to search for env files
  local env_file_paths = {
    -- current working directory
    vim.fn.getcwd() .. env_file,
    -- directory of the currently opened file
    vim.fn.expand("%:p:h") .. env_file,
  }

  -- If there's an env file in the current working dir
  for _, env_file_path in ipairs(env_file_paths) do
    if M.file_exists(env_file_path) then
      local file = io.open(env_file_path, "w+")
      if file ~= nil then
        if string.match(env_file_path, "(.-)%.json$") then
          file:write(vim.fn.json_encode(variables))
        else
          for key, value in pairs(variables) do
            file:write(key .. "=" .. value .. "\n")
          end
        end
        file:close()
      end
    end
  end
end

M.uuid = function()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
    return string.format("%x", v)
  end)
end

-- file_exists checks if the provided file exists and returns a boolean
-- @param file File to check
M.file_exists = function(file)
  return vim.fn.filereadable(file) == 1
end

-- read_file Reads all lines from a file and returns the content as a table
-- returns empty table if file does not exist
M.read_file = function(file)
  if not M.file_exists(file) then
    return {}
  end
  local lines = {}
  for line in io.lines(file) do
    lines[#lines + 1] = line
  end
  return lines
end

-- reads the variables contained in the current file
M.get_file_variables = function()
  local variables = {}

  -- If there is a line at the beginning with @ first
  if vim.fn.search("^@", "cn") > 0 then
    -- Read all lines of the file
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)

    -- For each line
    for _, line in pairs(lines) do
      -- Get the name and value form lines that starts with @
      local name, val = line:match("^@([%w!@#$%^&*-_+?~]+)%s*=%s*([^=]+)")
      if name then
        -- Add to variables
        variables[name] = val
      end
    end
  end
  return variables
end
-- Gets the variables from the currently selected env_file
M.get_env_variables = function()
  local variables = {}
  local env_file = "/" .. (config.get("env_file") or ".env")

  -- Directories to search for env files
  local env_file_paths = {
    -- current working directory
    vim.fn.getcwd() .. env_file,
    -- directory of the currently opened file
    vim.fn.expand("%:p:h") .. env_file,
  }

  -- If there's an env file in the current working dir
  for _, env_file_path in ipairs(env_file_paths) do
    if M.file_exists(env_file_path) then
      if string.match(env_file_path, "(.-)%.json$") then
        local f = io.open(env_file_path, "r")
        if f ~= nil then
          local json_vars = f:read("*all")
          variables = vim.fn.json_decode(json_vars)
          f:close()
        end
      else
        for line in io.lines(env_file_path) do
          local vars = M.split(line, "%s*=%s*", 1)
          variables[vars[1]] = vars[2]
        end
      end
    end
  end
  return variables
end

-- get_variables Reads the environment variables found in the env_file option
-- (default: .env) specified in configuration or from the files being read
-- with variables beginning with @ and returns a table with the variables
M.get_variables = function()
  local variables = {}
  local file_variables = M.get_file_variables()
  local env_variables = M.get_env_variables()

  for k, v in pairs(file_variables) do
    variables[k] = v
  end

  for k, v in pairs(env_variables) do
    variables[k] = v
  end

  -- For each variable name
  for name, _ in pairs(variables) do
    -- For each pair of variables
    for oname, ovalue in pairs(variables) do
      -- If a variable contains another variable
      if variables[name]:match(oname) then
        -- Add that into the variable
        -- I.E if @url={{path}}:{{port}}/{{source}}
        -- Substitue in path, port and source
        variables[name] = variables[name]:gsub("{{" .. oname .. "}}", ovalue)
      end
    end
  end

  return variables
end

M.read_dynamic_variables = function()
  local from_config = config.get("custom_dynamic_variables") or {}
  local dynamic_variables = {
    ["$uuid"] = M.uuid,
    ["$timestamp"] = os.time,
    ["$randomInt"] = function()
      return math.random(0, 1000)
    end,
  }
  for k, v in pairs(from_config) do
    dynamic_variables[k] = v
  end
  return dynamic_variables
end

M.get_node_value = function(node, bufnr)
  local start_row, start_col, _, end_col = node:range()
  local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
  return line and string.sub(line, start_col + 1, end_col):gsub("^[\"'](.*)[\"']$", "%1") or nil
end

M.read_document_variables = function()
  local variables = {}
  local bufnr = vim.api.nvim_get_current_buf()
  local parser = vim.treesitter.get_parser(bufnr)
  if not parser then
    return variables
  end

  local first_tree = parser:trees()[1]
  if not first_tree then
    return variables
  end

  local root = first_tree:root()
  if not root then
    return variables
  end

  for node in root:iter_children() do
    local type = node:type()
    if type == "header" then
      local name = node:named_child(0)
      local value = node:named_child(1)
      variables[M.get_node_value(name, bufnr)] = M.get_node_value(value, bufnr)
    elseif type ~= "comment" then
      break
    end
  end
  return variables
end

M.read_variables = function()
  local first = M.get_variables()
  local second = M.read_dynamic_variables()
  local third = M.read_document_variables()

  return vim.tbl_extend("force", first, second, third)
end

-- replace_vars replaces the env variables fields in the provided string
-- with the env variable value
-- @param str Where replace the placers for the env variables
M.replace_vars = function(str, vars)
  if vars == nil then
    vars = M.read_variables()
  end
  -- remove $dotenv tags, which are used by the vscode rest client for cross compatibility
  str = str:gsub("%$dotenv ", ""):gsub("%$DOTENV ", "")

  for var in string.gmatch(str, "{{[^}]+}}") do
    var = var:gsub("{", ""):gsub("}", "")
    -- If the env variable wasn't found in the `.env` file or in the dynamic variables then search it
    -- in the OS environment variables
    if M.has_key(vars, var) then
      str = type(vars[var]) == "function" and str:gsub("{{" .. var .. "}}", vars[var]())
        or str:gsub("{{" .. var .. "}}", vars[var])
    else
      if os.getenv(var) then
        str = str:gsub("{{" .. var .. "}}", os.getenv(var))
      else
        error(string.format("Environment variable '%s' was not found.", var))
      end
    end
  end
  return str
end

-- has_key checks if the provided table contains the provided key using a regex
-- @param tbl Table to iterate over
-- @param key The key to be searched in the table
M.has_key = function(tbl, key)
  for tbl_key, _ in pairs(tbl) do
    if string.find(key, tbl_key) then
      return true
    end
  end
  return false
end

-- has_value checks if the provided table contains the provided string using a regex
-- @param tbl Table to iterate over
-- @param str String to search in the table
M.has_value = function(tbl, str)
  for _, element in ipairs(tbl) do
    if string.find(str, element) then
      return true
    end
  end
  return false
end

-- tbl_to_str recursively converts the provided table into a json string
-- @param tbl Table to convert into a String
-- @param json If the string should use a key:value syntax
M.tbl_to_str = function(tbl, json)
  if not json then
    json = false
  end
  local result = "{"
  for k, v in pairs(tbl) do
    -- Check the key type (ignore any numerical keys - assume its an array)
    if type(k) == "string" then
      result = result .. '"' .. k .. '"' .. ":"
    end
    -- Check the value type
    if type(v) == "table" then
      result = result .. M.tbl_to_str(v)
    elseif type(v) == "boolean" then
      result = result .. tostring(v)
    elseif type(v) == "number" then
      result = result .. v
    else
      result = result .. '"' .. v .. '"'
    end
    if json then
      result = result .. ":"
    else
      result = result .. ","
    end
  end
  -- Remove leading commas from the result
  if result ~= "" then
    result = result:sub(1, result:len() - 1)
  end
  return result .. "}"
end

-- Just a split function because Lua does not have this, nothing more
-- @param str String to split
-- @param sep Separator
-- @param max_splits Number of times to split the string (optional)
M.split = function(str, sep, max_splits)
  if sep == nil then
    sep = "%s"
  end
  max_splits = max_splits or -1

  local str_tbl = {}
  local nField, nStart = 1, 1
  local nFirst, nLast = str:find(sep, nStart)
  while nFirst and max_splits ~= 0 do
    str_tbl[nField] = str:sub(nStart, nFirst - 1)
    nField = nField + 1
    nStart = nLast + 1
    nFirst, nLast = str:find(sep, nStart)
    max_splits = max_splits - 1
  end
  str_tbl[nField] = str:sub(nStart)

  return str_tbl
end

-- iter_lines returns an iterator
-- @param str String to iterate over
M.iter_lines = function(str)
  -- If the string does not have a newline at the end then add it manually
  if str:sub(-1) ~= "\n" then
    str = str .. "\n"
  end

  return str:gmatch("(.-)\n")
end

-- char_to_hex returns the provided character as its hex value, e.g., "[" is
-- converted to "%5B"
-- @param char The character to convert
M.char_to_hex = function(char)
  return string.format("%%%02X", string.byte(char))
end

-- encode_url encodes the given URL
-- @param url The URL to encode
M.encode_url = function(url)
  if url == nil then
    error("You must need to provide an URL to encode")
  end

  url = url:gsub("\n", "\r\n")
  -- Encode characters but exclude `.`, `_`, `-`, `:`, `/`, `?`, `&`, `=`, `~`, `@`
  url = string.gsub(url, "([^%w _ %- . : / ? & = ~ @])", M.char_to_hex)
  url = url:gsub(" ", "+")
  return url
end

-- contains_comments checks if the given string contains comments characters
-- @param str The string that should be checked
-- @return number
M.contains_comments = function(str)
  return str:find("^#") or str:find("^%s+#")
end

-- http_status returns the status code and the meaning, e.g. 200 OK
-- see https://httpstatuses.com/ for reference
-- @param code The request status code
M.http_status = function(code)
  -- NOTE: this table does not cover all the statuses _yet_
  local status_meaning = {
    -- 1xx codes (Informational)
    [100] = "Continue",
    [101] = "Switching Protocols",
    [102] = "Processing",

    -- 2xx codes (Success)
    [200] = "OK",
    [201] = "Created",
    [202] = "Accepted",
    [203] = "Non-authoritative Information",
    [204] = "No Content",
    [205] = "Reset Content",
    [206] = "Partial Content",
    [207] = "Multi-Status",
    [208] = "Already Reported",
    [226] = "IM Used",

    -- 3xx codes (Redirection)
    [300] = "Multiple Choices",
    [301] = "Moved Permanently",
    [302] = "Found",
    [303] = "See Other",
    [304] = "Not Modified",
    [305] = "Use Proxy",
    [307] = "Temporary Redirect",
    [308] = "Permanent Redirect",

    -- 4xx codes (Client Error)
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [406] = "Not Acceptable",
    [407] = "Proxy Authentication Required",
    [408] = "Request Timeout",
    [409] = "Conflict",
    [410] = "Gone",
    [411] = "Length Required",
    [412] = "Precondition Failed",
    [413] = "Payload Too Large",
    [414] = "Request-URI Too Long",
    [415] = "Unsupported Media Type",
    [416] = "Requested Range Not Satisfiable",
    [417] = "Expectation Failed",
    [418] = "I'm a teapot",
    [421] = "Misdirected Request",
    [422] = "Unprocessable Entity",
    [423] = "Locked",
    [424] = "Failed Dependency",
    [426] = "Upgrade Required",
    [428] = "Precondition Required",
    [429] = "Too Many Requests",
    [431] = "Request Header Fields Too Large",
    [444] = "Connection Closed Without Response",
    [451] = "Unavailable For Legal Reasons",
    [499] = "Client Closed Request",

    -- 5xx codes (Server Error)
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
    [502] = "Bad Gateway",
    [503] = "Service Unavailable",
    [504] = "Gateway Timeout",
    [505] = "HTTP Version Not Supported",
    [506] = "Variant Also Negotiates",
    [507] = "Insufficient Storage",
    [508] = "Loop Detected",
    [510] = "Not Extended",
    [511] = "Network Authentication Required",
    [599] = "Network Connect Timeout Error",
  }

  -- If the code is covered in the status_meaning table
  if status_meaning[code] ~= nil then
    return tostring(code) .. " " .. status_meaning[code]
  end

  return tostring(code) .. " Unknown Status Meaning"
end

-- curl_error returns the status code and the meaning of an curl error
-- see man curl for reference
-- @param code The exit code of curl
M.curl_error = function(code)
  local curl_error_dictionary = {
    [1] = "Unsupported protocol. This build of curl has no support for this protocol.",
    [2] = "Failed to initialize.",
    [3] = "URL malformed. The syntax was not correct.",
    [4] = "A feature or option that was needed to perform the desired request was not enabled or was explicitly disabled at build-time."
      .. "To make curl able to do this, you probably need another build of libcurl!",
    [5] = "Couldn't resolve proxy. The given proxy host could not be resolved.",
    [6] = "Couldn't resolve host. The given remote host was not resolved.",
    [7] = "Failed to connect to host.",
    [8] = "Weird server reply. The server sent data curl couldn't parse.",
    [9] = "FTP access denied. The server denied login or denied access to the particular resource or directory you wanted to reach. Most often you tried to change to a directory that doesn't exist on the server.",
    [10] = "FTP accept failed. While waiting for the server to connect back when an active FTP session is used, an error code was sent over the control connection or similar.",
    [11] = "FTP weird PASS reply. Curl couldn't parse the reply sent to the PASS request.",
    [12] = "During an active FTP session while waiting for the server to connect back to curl, the timeout expired.",
    [13] = "FTP weird PASV reply, Curl couldn't parse the reply sent to the PASV request.",
    [14] = "FTP weird 227 format. Curl couldn't parse the 227-line the server sent.",
    [15] = "FTP can't get host. Couldn't resolve the host IP we got in the 227-line.",
    [16] = "HTTP/2 error. A problem was detected in the HTTP2 framing layer. This is somewhat generic and can be one out of several problems, see the error message for details.",
    [17] = "FTP couldn't set binary. Couldn't change transfer method to binary.",
    [18] = "Partial file. Only a part of the file was transferred.",
    [19] = "FTP couldn't download/access the given file, the RETR (or similar) command failed.",
    [21] = "FTP quote error. A quote command returned error from the server.",
    [22] = "HTTP page not retrieved. The requested url was not found or returned another error with the HTTP error code being 400 or above. This return code only appears if -f, --fail is used.",
    [23] = "Write error. Curl couldn't write data to a local filesystem or similar.",
    [25] = "FTP couldn't STOR file. The server denied the STOR operation, used for FTP uploading.",
    [26] = "Read error. Various reading problems.",
    [27] = "Out of memory. A memory allocation request failed.",
    [28] = "Operation timeout. The specified time-out period was reached according to the conditions.",
    [30] = "FTP PORT failed. The PORT command failed. Not all FTP servers support the PORT command, try doing a transfer using PASV instead!",
    [31] = "FTP couldn't use REST. The REST command failed. This command is used for resumed FTP transfers.",
    [33] = 'HTTP range error. The range "command" didn\'t work.',
    [34] = "HTTP post error. Internal post-request generation error.",
    [35] = "SSL connect error. The SSL handshaking failed.",
    [36] = "Bad download resume. Couldn't continue an earlier aborted download.",
    [37] = "FILE couldn't read file. Failed to open the file. Permissions?",
    [38] = "LDAP cannot bind. LDAP bind operation failed.",
    [39] = "LDAP search failed.",
    [41] = "Function not found. A required LDAP function was not found.",
    [42] = "Aborted by callback. An application told curl to abort the operation.",
    [43] = "Internal error. A function was called with a bad parameter.",
    [45] = "Interface error. A specified outgoing interface could not be used.",
    [47] = "Too many redirects. When following redirects, curl hit the maximum amount.",
    [48] = "Unknown option specified to libcurl. This indicates that you passed a weird option to curl that was passed on to libcurl and rejected. Read up in the manual!",
    [49] = "Malformed telnet option.",
    [51] = "The peer's SSL certificate or SSH MD5 fingerprint was not OK.",
    [52] = "The server didn't reply anything, which here is considered an error.",
    [53] = "SSL crypto engine not found.",
    [54] = "Cannot set SSL crypto engine as default.",
    [55] = "Failed sending network data.",
    [56] = "Failure in receiving network data.",
    [58] = "Problem with the local certificate.",
    [59] = "Couldn't use specified SSL cipher.",
    [60] = "Peer certificate cannot be authenticated with known CA certificates.",
    [61] = "Unrecognized transfer encoding.",
    [62] = "Invalid LDAP URL.",
    [63] = "Maximum file size exceeded.",
    [64] = "Requested FTP SSL level failed.",
    [65] = "Sending the data requires a rewind that failed.",
    [66] = "Failed to initialize SSL Engine.",
    [67] = "The user name, password, or similar was not accepted and curl failed to log in.",
    [68] = "File not found on TFTP server.",
    [69] = "Permission problem on TFTP server.",
    [70] = "Out of disk space on TFTP server.",
    [71] = "Illegal TFTP operation.",
    [72] = "Unknown TFTP transfer ID.",
    [73] = "File already exists (TFTP).",
    [74] = "No such user (TFTP).",
    [75] = "Character conversion failed.",
    [76] = "Character conversion functions required.",
    [77] = "Problem with reading the SSL CA cert (path? access rights?).",
    [78] = "The resource referenced in the URL does not exist.",
    [79] = "An unspecified error occurred during the SSH session.",
    [80] = "Failed to shut down the SSL connection.",
    [82] = "Could not load CRL file, missing or wrong format (added in 7.19.0).",
    [83] = "Issuer check failed (added in 7.19.0).",
    [84] = "The FTP PRET command failed",
    [85] = "RTSP: mismatch of CSeq numbers",
    [86] = "RTSP: mismatch of Session Identifiers",
    [87] = "unable to parse FTP file list",
    [88] = "FTP chunk callback reported error",
    [89] = "No connection available, the session will be queued",
    [90] = "SSL public key does not matched pinned public key",
    [91] = "Invalid SSL certificate status.",
    [92] = "Stream error in HTTP/2 framing layer.",
  }

  if curl_error_dictionary[code] ~= nil then
    return "curl error " .. tostring(code) .. ": " .. curl_error_dictionary[code]
  end

  return "curl error " .. tostring(code) .. ": unknown curl error"
end

return M
