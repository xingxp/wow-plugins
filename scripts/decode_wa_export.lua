local inputPath = assert(arg[1], "usage: lua decode_wa_export.lua <wa-export-file>")

strmatch = string.match
strsub = string.sub
strlen = string.len
gsub = string.gsub
gmatch = string.gmatch
tinsert = table.insert
tremove = table.remove
unpack = table.unpack
wipe = function(tbl)
  for key in pairs(tbl) do
    tbl[key] = nil
  end
end

local function decodeB64(str)
  local bytetoB64 = {
    a =  0,  b =  1,  c =  2,  d =  3,  e =  4,  f =  5,  g =  6,  h =  7,
    i =  8,  j =  9,  k = 10,  l = 11,  m = 12,  n = 13,  o = 14,  p = 15,
    q = 16,  r = 17,  s = 18,  t = 19,  u = 20,  v = 21,  w = 22,  x = 23,
    y = 24,  z = 25,  A = 26,  B = 27,  C = 28,  D = 29,  E = 30,  F = 31,
    G = 32,  H = 33,  I = 34,  J = 35,  K = 36,  L = 37,  M = 38,  N = 39,
    O = 40,  P = 41,  Q = 42,  R = 43,  S = 44,  T = 45,  U = 46,  V = 47,
    W = 48,  X = 49,  Y = 50,  Z = 51, ["0"] = 52, ["1"] = 53, ["2"] = 54, ["3"] = 55,
    ["4"] = 56, ["5"] = 57, ["6"] = 58, ["7"] = 59, ["8"] = 60, ["9"] = 61, ["("] = 62, [")"] = 63,
  }

  local out = {}
  local decodedSize = 0
  local bitfieldLen = 0
  local bitfield = 0
  local i = 1
  local length = #str

  while true do
    if bitfieldLen >= 8 then
      decodedSize = decodedSize + 1
      out[decodedSize] = string.char(bitfield % 256)
      bitfield = math.floor(bitfield / 256)
      bitfieldLen = bitfieldLen - 8
    end

    local ch = bytetoB64[str:sub(i, i)] or 0
    bitfield = bitfield + ch * (2 ^ bitfieldLen)
    bitfieldLen = bitfieldLen + 6

    if i > length then
      break
    end

    i = i + 1
  end

  return table.concat(out, "", 1, decodedSize)
end

package.path =
  "/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/WeakAuras/Libs/?.lua;" ..
  "/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/WeakAuras/Libs/?/?.lua;" ..
  package.path

dofile("/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/WeakAuras/Libs/LibStub/LibStub.lua")
local LibDeflate = dofile("/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/WeakAuras/Libs/LibDeflate/LibDeflate.lua")
dofile("/Volumes/DATA/blizzard/World of Warcraft/_classic_titan_/Interface/AddOns/WeakAuras/Libs/LibSerialize/LibSerialize.lua")
local LibSerialize = LibStub("LibSerialize")

local handle = assert(io.open(inputPath, "rb"))
local contents = handle:read("*a")
handle:close()

contents = contents:gsub("%s+", "")
local encoded = contents:match("^!WA:%d+!(.+)$") or error("not a WA export")
local decoded = LibDeflate:DecodeForPrint(encoded) or error("decode failed")
local decompressed = LibDeflate:DecompressDeflate(decoded) or error("decompress failed")
local ok, data = LibSerialize:Deserialize(decompressed)
assert(ok, data)

local function writeValue(value, indent, visited)
  indent = indent or 0
  visited = visited or {}
  local t = type(value)

  if t == "table" then
    if visited[value] then
      io.write("<cycle>")
      return
    end
    visited[value] = true
    io.write("{\n")
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then
        return tostring(a) < tostring(b)
      end
      return type(a) < type(b)
    end)
    for _, key in ipairs(keys) do
      io.write(string.rep(" ", indent + 2))
      if type(key) == "string" and key:match("^[_%a][_%w]*$") then
        io.write(key, " = ")
      else
        io.write("[")
        writeValue(key, indent + 2, visited)
        io.write("] = ")
      end
      writeValue(value[key], indent + 2, visited)
      io.write(",\n")
    end
    io.write(string.rep(" ", indent), "}")
    visited[value] = nil
  elseif t == "string" then
    io.write(string.format("%q", value))
  else
    io.write(tostring(value))
  end
end

writeValue(data, 0, {})
io.write("\n")
