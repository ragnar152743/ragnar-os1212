-- SecureClickOS for ComputerCraft / CC:Tweaked
-- Copy this file to /startup.lua on a ComputerCraft computer.
-- Everything important is clickable. Text fields still use the keyboard.

local OS_NAME = "SecureClickOS"
local VERSION = "1.16.2"
local ROOT = "/secureos"
local STARTUP_PATH = "/startup.lua"
local RECOVERY_DIR = "/.secureclickos"
local STARTUP_BACKUP_FILE = RECOVERY_DIR .. "/startup.bak"
local RECOVERY_MANIFEST_FILE = RECOVERY_DIR .. "/manifest.db"
local USERS_FILE = ROOT .. "/users.db"
local MAIL_FILE = ROOT .. "/mail.db"
local CONFIG_FILE = ROOT .. "/config.db"
local INTEGRITY_FILE = ROOT .. "/integrity.db"
local FILE_QUEUE_FILE = ROOT .. "/filequeue.db"
local AUDIT_FILE = ROOT .. "/audit.log"
local FILES_DIR = ROOT .. "/files"
local PROTOCOL = "SecureClickOS.Mail.v1"
local FILE_PROTOCOL = "SecureClickOS.File.v1"
local LEGACY_FILE_MAGIC = "SCOS1:" -- ancien format refuse: pas de MAC anti-modification

local HASH_ROUNDS = 350
local FILE_KDF_ROUNDS = HASH_ROUNDS * 2
local FAILED_LIMIT = 5
local LOCK_SECONDS = 60
local MAX_FIELD_LEN = 96
local MAX_PASSWORD_LEN = 128
local MAX_PASTE_LEN = 512
local MAX_TEXT_LEN = 4096
local MAX_TRANSFER_FILE_LEN = 4096
local MAX_FILE_QUEUE = 20
local DISK_SCAN_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local MAINT = {
  DEBUG_HOLD_SECONDS = 3,
  DEBUG_CODE_HASH = "b1aecdefd961c1512252e88ce482b3bd1d932af5af1f41a01367462b4aa30ccf",
  AUDIT_PROTOCOL = "SecureClickOS.Audit.v1",
  UPDATE_MAGIC = "SecureClickOS.Update.v1",
  UPDATE_SOURCE_FILE = "secureclickos_update.lua",
  UPDATE_MANIFEST_FILE = "secureclickos_update.db",
  UPDATE_README_FILE = "SECURECLICKOS_UPDATE.txt",
  GITHUB_UPDATE_URL = "https://raw.githubusercontent.com/ragnar152743/ragnar-os1212/refs/heads/main/startup.lua",
  STARTUP_UPDATE_BACKUP_FILE = "/startup.lua.before_update",
  CRASH_FILE = ROOT .. "/crash.db",
  CRASH_LIMIT = 3,
  RUNTIME_ERROR_LIMIT = 3,
  STARTUP_CHECK_SECONDS = 20,
  DISK_CHECK_SECONDS = 5,
  HARDEN_SECONDS = 30,
  ENTROPY_BATCH = 8,
  ENTROPY_SECONDS = 2,
  PASSWORD_MIN = 10,
  INTEGRITY_MIN = 10
}
local RUNNER = {
  ROOT = ROOT .. "/sandbox",
  MAX_SOURCE_LEN = 131072,
  MAX_SAVE_LEN = 65536,
  MAX_STEPS = 5000000,
  TRUSTED_MAX_STEPS = 20000000,
  APP_CACHE_MAX = 6,
  APP_LIST_CACHE_SECONDS = 2
}
local SERVER = {
  ROOT = "/server",
  CONFIRM = "SERVEUR",
  MAX_SOURCE_LEN = 262144,
  MAX_SAVE_LEN = 262144,
  MAX_TEXT_LEN = 262144,
  MAX_STEPS = 100000000
}
local BANK = {
  FILE = ROOT .. "/bank.db",
  PROTOCOL = "SecureClickOS.Bank.v1",
  DISCOVER_SECONDS = 2,
  REPLY_SECONDS = 5,
  DEFAULT_BALANCE = 100,
  MAX_AMOUNT = 1000000,
  MAX_CASHOUT = 100000
}
local APPS = {
  CHAT_PROTOCOL = "SecureClickOS.AppChat.v1",
  DICE_PROTOCOL = "SecureClickOS.DiceDuel.v1",
  DISCOVER_SECONDS = 2
}
local STORAGE = {
  MAGIC = "SecureClickOS.Storage.v1",
  DIR = "secureclickos_storage",
  MARKER = "marker.db",
  AUDIT_MAX = 12288,
  AUDIT_KEEP = 6144,
  MIN_FREE = 8192
}

local unpack = table.unpack or unpack
local w, h = term.getSize()

local theme = {
  bg = colors.black,
  panel = colors.gray,
  panel2 = colors.lightGray,
  top = colors.blue,
  topText = colors.white,
  text = colors.white,
  muted = colors.lightGray,
  good = colors.green,
  bad = colors.red,
  warn = colors.orange,
  action = colors.cyan,
  actionText = colors.black,
  field = colors.white,
  fieldText = colors.black,
  selected = colors.lime,
  app = colors.lightBlue
}

local users = {}
local mail = {}
local fileQueue = {}
local config = {}
local currentUser = nil
local currentFileKey = nil
local sessionNonce = nil
local sessionToken = nil
local lastActivity = 0
local timerId = nil
local buttons = {}
local rednetReady = false
local statusLine = ""
local integrity = {}
local integrityLocked = false
local updateDataIntegrity = nil
local cleanFieldChunk = nil
local entropyPool = ""
local entropyCounter = 0

local function setStatus(text)
  statusLine = text or ""
end

local function now()
  if os.epoch then
    return math.floor(os.epoch("utc") / 1000)
  end
  return math.floor(os.time() * 3600)
end

local function safeCollectGarbage()
  if type(collectgarbage) == "function" then
    pcall(collectgarbage)
  end
end

local function randomSeed()
  local seed = now() + os.getComputerID() * 1009
  if os.clock then seed = seed + math.floor(os.clock() * 100000) end
  math.randomseed(seed)
  entropyPool = tostring(seed) .. "|" .. tostring({}) .. "|" .. tostring(w) .. "x" .. tostring(h)
end

local function ensureDir(path)
  if not fs.exists(path) then fs.makeDir(path) end
end

local function loadTable(path, default)
  if not fs.exists(path) then return default end
  local f = fs.open(path, "r")
  if not f then return default end
  local data = f.readAll()
  f.close()
  local ok, value = pcall(textutils.unserialize, data)
  if ok and type(value) == "table" then return value end
  return default
end

local function saveTable(path, value)
  local tmp = path .. ".tmp"
  local data = textutils.serialize(value)
  for attempt = 1, 2 do
    if STORAGE and STORAGE.beforeWrite then pcall(STORAGE.beforeWrite, path, #data) end
    local f = fs.open(tmp, "w")
    if f then
      local ok = pcall(function()
        f.write(data)
        f.close()
      end)
      if ok then
        if fs.exists(path) then fs.delete(path) end
        fs.move(tmp, path)
        return true
      end
      pcall(function() f.close() end)
    end
    if fs.exists(tmp) then pcall(fs.delete, tmp) end
    if STORAGE and STORAGE.emergencyCleanup then pcall(STORAGE.emergencyCleanup, "saveTable", #data) end
  end
  return false
end

function STORAGE.free(path)
  if fs.getFreeSpace then
    local ok, n = pcall(fs.getFreeSpace, path or "/")
    if ok and type(n) == "number" then return n end
  end
  return 1048576
end

function STORAGE.size(path)
  if fs.exists(path) then
    local ok, n = pcall(fs.getSize, path)
    if ok and type(n) == "number" then return n end
  end
  return 0
end

function STORAGE.capacity(path)
  if fs.getCapacity then
    local ok, n = pcall(fs.getCapacity, path or "/")
    if ok and type(n) == "number" then return n end
  end
  return nil
end

function STORAGE.used(path)
  local cap = STORAGE.capacity(path)
  if not cap then return nil end
  return math.max(0, cap - STORAGE.free(path))
end

function STORAGE.formatBytes(value)
  local n = tonumber(value) or 0
  if n >= 1048576 then return string.format("%.1f Mo", n / 1048576) end
  if n >= 1024 then return tostring(math.floor(n / 1024)) .. " Ko" end
  return tostring(n) .. " o"
end

function STORAGE.rootFor(mount)
  return tostring(mount or "") .. "/" .. STORAGE.DIR
end

function STORAGE.markerPath(mount)
  return STORAGE.rootFor(mount) .. "/" .. STORAGE.MARKER
end

function STORAGE.isTrustedMount(mount)
  if not mount or not fs.exists(STORAGE.markerPath(mount)) then return false end
  local data = loadTable(STORAGE.markerPath(mount), {})
  return type(data) == "table"
    and data.magic == STORAGE.MAGIC
    and tonumber(data.computerId) == os.getComputerID()
end

function STORAGE.findExternal()
  if not disk then return nil, nil end
  for _, side in ipairs(DISK_SCAN_SIDES) do
    if peripheral.getType(side) == "drive" and disk.isPresent(side) and disk.hasData(side) then
      local mount = disk.getMountPath(side)
      if STORAGE.isTrustedMount(mount) then return STORAGE.rootFor(mount), side, mount end
    end
  end
  return nil, nil, nil
end

function STORAGE.dataPath(name, localPath)
  if type(config) == "table" and config.externalStorage then
    local root = STORAGE.findExternal()
    if root then
      ensureDir(root)
      local external = root .. "/" .. name
      if fs.exists(localPath) and not fs.exists(external) then
        local copied = pcall(fs.copy, localPath, external)
        if not copied and not fs.exists(external) then return localPath end
      end
      return external
    end
  end
  return localPath
end

function STORAGE.pruneAudit(force)
  if not fs.exists(AUDIT_FILE) then return end
  local size = STORAGE.size(AUDIT_FILE)
  if not force and size <= STORAGE.AUDIT_MAX and STORAGE.free("/") >= STORAGE.MIN_FREE then return end
  local f = fs.open(AUDIT_FILE, "r")
  if not f then return end
  local data = f.readAll() or ""
  f.close()
  local root = STORAGE.findExternal()
  if root and data ~= "" then
    ensureDir(root)
    local af = fs.open(root .. "/audit_archive.log", "a")
    if af then
      pcall(function()
        af.write(data)
        if data:sub(-1) ~= "\n" then af.write("\n") end
        af.close()
      end)
    end
  end
  local keep = data:sub(math.max(1, #data - STORAGE.AUDIT_KEEP + 1))
  local wf = fs.open(AUDIT_FILE, "w")
  if wf then
    pcall(function()
      wf.write(keep)
      wf.close()
    end)
  end
end

function STORAGE.cleanTmp(dir)
  if not fs.exists(dir) or not fs.isDir(dir) then return end
  for _, name in ipairs(fs.list(dir)) do
    local path = dir .. "/" .. name
    if fs.isDir(path) then
      STORAGE.cleanTmp(path)
    elseif name:match("%.tmp$") or name == "startup.lua.update" then
      pcall(fs.delete, path)
    end
  end
end

function STORAGE.emergencyCleanup(reason, needBytes)
  pcall(STORAGE.pruneAudit, true)
  pcall(STORAGE.cleanTmp, ROOT)
  pcall(STORAGE.cleanTmp, RECOVERY_DIR)
  if STORAGE.free("/") < (tonumber(needBytes) or 0) + STORAGE.MIN_FREE then
    if fs.exists(MAINT.STARTUP_UPDATE_BACKUP_FILE) then pcall(fs.delete, MAINT.STARTUP_UPDATE_BACKUP_FILE) end
  end
end

function STORAGE.beforeWrite(path, bytes)
  if STORAGE.free(path or "/") < (tonumber(bytes) or 0) + STORAGE.MIN_FREE then
    STORAGE.emergencyCleanup("low-space", bytes)
  end
end

local function appendAudit(message)
  ensureDir(ROOT)
  if STORAGE and STORAGE.pruneAudit then pcall(STORAGE.pruneAudit, false) end
  local f = fs.open(AUDIT_FILE, "a")
  if not f then return end
  local who = currentUser and currentUser.name or "system"
  local stamp = now()
  local ok = pcall(function()
    f.writeLine("[" .. tostring(stamp) .. "] " .. who .. ": " .. message)
    f.close()
  end)
  if not ok then
    pcall(function() f.close() end)
    if STORAGE and STORAGE.emergencyCleanup then pcall(STORAGE.emergencyCleanup, "audit", 1024) end
  end
  if STORAGE and STORAGE.pruneAudit then pcall(STORAGE.pruneAudit, false) end
  if MAINT.mirrorAudit then pcall(MAINT.mirrorAudit, stamp, who, message) end
end

local function hardenCraftOSSettings()
  if not settings then return end
  local ok, current = pcall(settings.get, "shell.allow_disk_startup")
  if ok and current == false then return end
  pcall(settings.set, "shell.allow_disk_startup", false)
  if settings.save then pcall(settings.save) end
end

local function restoreCraftOSDiskStartup()
  if not settings then return end
  pcall(settings.set, "shell.allow_disk_startup", true)
  if settings.save then pcall(settings.save) end
end

local function initStorage()
  ensureDir(ROOT)
  ensureDir(FILES_DIR)
  config = loadTable(CONFIG_FILE, {
    networkMail = false,
    networkKey = "",
    lockAfter = 180,
    autoRepairStartup = true,
    diskGuard = true,
    strictDiskGuard = true,
    autoEjectBootDisks = true,
    auditMirrorId = "",
    hiddenLuaApps = {},
    serverMode = false,
    serverActivatedAt = nil,
    serverActivatedBy = "",
    bankPayProfile = nil,
    bankCashoutProfiles = {},
    externalStorage = true,
    githubAutoUpdate = true,
    githubUpdateUrl = MAINT.GITHUB_UPDATE_URL,
    showTips = true
  })
  if config.externalStorage == nil then config.externalStorage = true end
  if config.autoRepairStartup == nil then config.autoRepairStartup = true end
  if config.diskGuard == nil then config.diskGuard = true end
  if config.strictDiskGuard == nil then config.strictDiskGuard = true end
  if config.autoEjectBootDisks == nil then config.autoEjectBootDisks = true end
  if config.auditMirrorId == nil then config.auditMirrorId = "" end
  if type(config.hiddenLuaApps) ~= "table" then config.hiddenLuaApps = {} end
  if config.serverMode == nil then config.serverMode = false end
  if config.serverActivatedBy == nil then config.serverActivatedBy = "" end
  if type(config.bankPayProfile) ~= "table" then config.bankPayProfile = nil end
  if type(config.bankCashoutProfiles) ~= "table" then config.bankCashoutProfiles = {} end
  if config.githubAutoUpdate == nil then config.githubAutoUpdate = true end
  if type(config.githubUpdateUrl) ~= "string" or config.githubUpdateUrl == "" then config.githubUpdateUrl = MAINT.GITHUB_UPDATE_URL end
  users = loadTable(USERS_FILE, {})
  mail = loadTable(STORAGE.dataPath("mail.db", MAIL_FILE), { nextId = 1, boxes = {} })
  fileQueue = loadTable(STORAGE.dataPath("filequeue.db", FILE_QUEUE_FILE), { boxes = {} })
  if type(mail.boxes) ~= "table" then mail.boxes = {} end
  if type(mail.nextId) ~= "number" then mail.nextId = 1 end
  if type(fileQueue.boxes) ~= "table" then fileQueue.boxes = {} end
end

local function saveUsers()
  saveTable(USERS_FILE, users)
  if updateDataIntegrity then updateDataIntegrity("users") end
end
local function saveMail() saveTable(STORAGE.dataPath("mail.db", MAIL_FILE), mail) end
local function saveFileQueue() saveTable(STORAGE.dataPath("filequeue.db", FILE_QUEUE_FILE), fileQueue) end
local function saveConfig()
  saveTable(CONFIG_FILE, config)
  if updateDataIntegrity then updateDataIntegrity("config") end
end

-- SHA-256, implemented locally so the password database does not store plaintext.
local bitlib = bit32
if not bitlib then error("SecureClickOS needs bit32. Use CC:Tweaked or a recent ComputerCraft.") end

local band = bitlib.band
local bor = bitlib.bor
local bxor = bitlib.bxor
local bnot = bitlib.bnot
local rshift = bitlib.rshift
local lshift = bitlib.lshift
local rrotate = bitlib.rrotate or function(x, n)
  return bor(rshift(x, n), lshift(x, 32 - n))
end

local MOD = 4294967296
local function add32(...)
  local s = 0
  for i = 1, select("#", ...) do
    s = (s + select(i, ...)) % MOD
  end
  return s
end

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256(input)
  local bytes = { string.byte(input, 1, #input) }
  local bitLen = #bytes * 8
  bytes[#bytes + 1] = 0x80
  while (#bytes % 64) ~= 56 do bytes[#bytes + 1] = 0 end
  local high = math.floor(bitLen / MOD)
  local low = bitLen % MOD
  for shift = 24, 0, -8 do bytes[#bytes + 1] = band(rshift(high, shift), 0xff) end
  for shift = 24, 0, -8 do bytes[#bytes + 1] = band(rshift(low, shift), 0xff) end

  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  for chunk = 1, #bytes, 64 do
    local words = {}
    for i = 0, 15 do
      local j = chunk + i * 4
      words[i + 1] = add32(lshift(bytes[j], 24), lshift(bytes[j + 1], 16), lshift(bytes[j + 2], 8), bytes[j + 3])
    end
    for i = 17, 64 do
      local s0 = bxor(rrotate(words[i - 15], 7), rrotate(words[i - 15], 18), rshift(words[i - 15], 3))
      local s1 = bxor(rrotate(words[i - 2], 17), rrotate(words[i - 2], 19), rshift(words[i - 2], 10))
      words[i] = add32(words[i - 16], s0, words[i - 7], s1)
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, hh = h4, h5, h6, h7

    for i = 1, 64 do
      local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = add32(hh, s1, ch, K[i], words[i])
      local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = add32(s0, maj)

      hh = g
      g = f
      f = e
      e = add32(d, temp1)
      d = c
      c = b
      b = a
      a = add32(temp1, temp2)
    end

    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
    h5 = add32(h5, f)
    h6 = add32(h6, g)
    h7 = add32(h7, hh)
  end

  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function mixEntropy(value)
  entropyCounter = entropyCounter + 1
  entropyPool = sha256(table.concat({
    entropyPool,
    tostring(value or ""),
    tostring(now()),
    tostring(os.clock and os.clock() or ""),
    tostring(os.getComputerID()),
    tostring(entropyCounter),
    tostring(math.random(0, 2147483647))
  }, "|"))
end

local function secureRandomHex(bytes)
  if MAINT.entropyBuffer and MAINT.entropyBuffer ~= "" then
    mixEntropy(MAINT.entropyBuffer)
    MAINT.entropyBuffer = ""
    MAINT.entropyEvents = 0
  end
  local out = {}
  while #table.concat(out) < bytes * 2 do
    mixEntropy("random:" .. tostring(#out))
    local objectJitter = tostring({})
    out[#out + 1] = sha256(table.concat({
      entropyPool,
      tostring(now()),
      tostring(os.clock and os.clock() or ""),
      tostring(math.random(0, 2147483647)),
      objectJitter
    }, "|"))
  end
  return table.concat(out):sub(1, bytes * 2)
end

function MAINT.mixInputEntropy(kind, a, b, c)
  MAINT.entropyBuffer = tostring(MAINT.entropyBuffer or "") .. "|" .. table.concat({
    tostring(kind or ""),
    tostring(a or ""),
    tostring(b or ""),
    tostring(c or ""),
    tostring(now()),
    tostring(os.clock and os.clock() or "")
  }, ":")
  MAINT.entropyEvents = (tonumber(MAINT.entropyEvents or 0) or 0) + 1
  local t = now()
  if MAINT.entropyEvents >= MAINT.ENTROPY_BATCH or not MAINT.nextEntropyMixAt or t >= MAINT.nextEntropyMixAt then
    mixEntropy(MAINT.entropyBuffer)
    MAINT.entropyBuffer = ""
    MAINT.entropyEvents = 0
    MAINT.nextEntropyMixAt = t + MAINT.ENTROPY_SECONDS
  end
end

local function makeSalt()
  return secureRandomHex(16)
end

local function hashPassword(password, salt, rounds)
  local hash = sha256(salt .. ":" .. password)
  for i = 1, rounds do
    hash = sha256(hash .. ":" .. salt .. ":" .. password .. ":" .. tostring(i))
  end
  return hash
end

local function toHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function fromHex(hex)
  return (tostring(hex or ""):gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

local function constantTimeEquals(a, b)
  a = tostring(a or "")
  b = tostring(b or "")
  local diff = bxor(#a, #b)
  local maxLen = math.max(#a, #b)
  for i = 1, maxLen do
    diff = bor(diff, bxor(string.byte(a, i) or 0, string.byte(b, i) or 0))
  end
  return diff == 0
end

function MAINT.verifyDebugCode(code)
  return constantTimeEquals(sha256(tostring(code or "")), MAINT.DEBUG_CODE_HASH)
end

function MAINT.parseSourceVersion(source)
  return tostring(source or ""):match('local%s+VERSION%s*=%s*"([^"]+)"') or ""
end

function MAINT.compareVersions(a, b)
  local pa, pb = {}, {}
  for n in tostring(a or ""):gmatch("(%d+)") do pa[#pa + 1] = tonumber(n) or 0 end
  for n in tostring(b or ""):gmatch("(%d+)") do pb[#pb + 1] = tonumber(n) or 0 end
  local maxLen = math.max(#pa, #pb, 1)
  for i = 1, maxLen do
    local av = pa[i] or 0
    local bv = pb[i] or 0
    if av > bv then return 1 end
    if av < bv then return -1 end
  end
  return 0
end

function MAINT.validateSecureClickOSSource(source)
  source = tostring(source or "")
  if #source < 20000 then return false, "Fichier OS trop petit." end
  if not source:find('local OS_NAME = "SecureClickOS"', 1, true) then
    return false, "Nom SecureClickOS introuvable."
  end
  local version = MAINT.parseSourceVersion(source)
  if version == "" then return false, "Version introuvable." end
  local markers = {
    "SecureClickOS for ComputerCraft",
    "local function integrityGate",
    "local function hardenCraftOSSettings"
  }
  for _, marker in ipairs(markers) do
    if not source:find(marker, 1, true) then
      return false, "Marqueur OS manquant: " .. marker
    end
  end
  if not source:find("local function main()", 1, true) and not source:find("function main()", 1, true) then
    return false, "Marqueur OS manquant: main()"
  end
  return true, version
end

function MAINT.validSourceVersion(source)
  local ok, versionOrErr = MAINT.validateSecureClickOSSource(source)
  if ok then return true, versionOrErr end
  return false, versionOrErr
end

function MAINT.refuseBackupDowngrade(backup, current)
  local backupOk, backupVersion = MAINT.validSourceVersion(backup)
  if not backupOk then
    return true, "backup invalide: " .. tostring(backupVersion)
  end
  if current == nil then return false, backupVersion end
  local currentOk, currentVersion = MAINT.validSourceVersion(current)
  if currentOk and MAINT.compareVersions(backupVersion, currentVersion) < 0 then
    return true, "backup " .. tostring(backupVersion) .. " plus vieux que startup " .. tostring(currentVersion)
  end
  return false, backupVersion
end

function MAINT.passwordPolicy(password)
  password = tostring(password or "")
  if #password < MAINT.PASSWORD_MIN then
    return false, "Mot de passe: minimum " .. tostring(MAINT.PASSWORD_MIN) .. " caracteres."
  end
  local score = 0
  if password:match("%l") then score = score + 1 end
  if password:match("%u") then score = score + 1 end
  if password:match("%d") then score = score + 1 end
  if password:match("[^%w]") then score = score + 1 end
  if score < 3 then
    return false, "Mot de passe: utilise 3 types: min/MAJ/chiffre/symbole."
  end
  return true
end

local function xorByteString(s, byte)
  local out = {}
  for i = 1, #s do
    out[i] = string.char(bxor(string.byte(s, i), byte))
  end
  return table.concat(out)
end

local function hmacSha256(key, message)
  key = tostring(key or "")
  message = tostring(message or "")
  if #key > 64 then key = fromHex(sha256(key)) end
  if #key < 64 then key = key .. string.rep("\0", 64 - #key) end
  local inner = xorByteString(key, 0x36)
  local outer = xorByteString(key, 0x5c)
  return sha256(outer .. fromHex(sha256(inner .. message)))
end

local function rawRead(path)
  if not fs.exists(path) then return "" end
  local f = fs.open(path, "r")
  if not f then return "" end
  local data = f.readAll() or ""
  f.close()
  return data
end

local function rawWrite(path, data)
  data = tostring(data or "")
  for attempt = 1, 2 do
    if STORAGE and STORAGE.beforeWrite then pcall(STORAGE.beforeWrite, path, #data) end
    local f = fs.open(path, "w")
    if f then
      local ok = pcall(function()
        f.write(data)
        f.close()
      end)
      if ok then return true end
      pcall(function() f.close() end)
    end
    if STORAGE and STORAGE.emergencyCleanup then pcall(STORAGE.emergencyCleanup, "rawWrite", #data) end
  end
  return false
end

local function selfPath()
  if shell and shell.getRunningProgram then
    local running = shell.getRunningProgram()
    if running and running ~= "" then
      if shell.resolve then return shell.resolve(running) end
      return running
    end
  end
  return "/startup.lua"
end

local function currentStartupHash()
  local path = selfPath()
  return sha256(rawRead(path)), path
end

local function readRunningStartup()
  local path = selfPath()
  local source = rawRead(path)
  if source ~= "" then return source, path end
  return rawRead(STARTUP_PATH), STARTUP_PATH
end

local function installSelfRecovery(force)
  local source, path = readRunningStartup()
  if source == "" then return false, "startup source introuvable" end
  local sourceOk, sourceVersion = MAINT.validSourceVersion(source)
  if not sourceOk then return false, sourceVersion end
  ensureDir(RECOVERY_DIR)
  local hash = sha256(source)
  local manifest = loadTable(RECOVERY_MANIFEST_FILE, {})
  local backupPath = STARTUP_BACKUP_FILE
  local externalRoot = STORAGE.findExternal and STORAGE.findExternal()
  if externalRoot and STORAGE.free(externalRoot) >= #source + STORAGE.MIN_FREE then
    backupPath = externalRoot .. "/startup.bak"
  end
  local backup = rawRead(backupPath)
  if backup ~= "" then
    local backupOk, backupVersion = MAINT.validSourceVersion(backup)
    if backupOk and MAINT.compareVersions(sourceVersion, backupVersion) < 0 then
      appendAudit("startup recovery backup kept: installed " .. tostring(sourceVersion) .. " older than backup " .. tostring(backupVersion))
      return true
    end
  end
  if force or backup == "" or manifest.startupHash ~= hash or sha256(backup) ~= hash then
    if backupPath == STARTUP_BACKUP_FILE and STORAGE.free("/") < #source + STORAGE.MIN_FREE then
      saveTable(RECOVERY_MANIFEST_FILE, {
        startupHash = hash,
        path = STARTUP_PATH,
        sourcePath = path,
        backupSkipped = true,
        backupReason = "low-space",
        version = sourceVersion,
        updatedAt = now(),
        computerId = os.getComputerID()
      })
      appendAudit("startup recovery backup skipped: low space")
      return true
    end
    if not rawWrite(backupPath, source) then
      return false, "backup impossible"
    end
    saveTable(RECOVERY_MANIFEST_FILE, {
      startupHash = hash,
      path = STARTUP_PATH,
      sourcePath = path,
      backupPath = backupPath,
      backupExternal = backupPath ~= STARTUP_BACKUP_FILE,
      version = sourceVersion,
      updatedAt = now(),
      computerId = os.getComputerID()
    })
    appendAudit("startup recovery backup updated")
  end
  return true
end

local function repairStartupFile(reason)
  if not config.autoRepairStartup then return false end
  local manifest = loadTable(RECOVERY_MANIFEST_FILE, {})
  local backupPath = manifest.backupPath or STARTUP_BACKUP_FILE
  local backup = rawRead(backupPath)
  if backup == "" and backupPath ~= STARTUP_BACKUP_FILE then
    backup = rawRead(STARTUP_BACKUP_FILE)
    backupPath = STARTUP_BACKUP_FILE
  end
  if backup == "" then return false end
  local current = rawRead(STARTUP_PATH)
  local downgrade, downgradeReason = MAINT.refuseBackupDowngrade(backup, current)
  if downgrade then
    appendAudit("startup repair refused: " .. tostring(downgradeReason))
    local currentOk = MAINT.validSourceVersion(current)
    if currentOk then pcall(installSelfRecovery, false) end
    return false
  end
  local backupHash = sha256(backup)
  if manifest.startupHash and manifest.startupHash ~= backupHash then
    appendAudit("startup repair refused: backup hash mismatch")
    return false
  end
  if not rawWrite(STARTUP_PATH, backup) then
    appendAudit("startup repair failed: write refused")
    return false
  end
  setStatus("startup.lua restaure automatiquement.")
  appendAudit("startup.lua repaired: " .. tostring(reason or "unknown"))
  return true
end

local function protectStartupFile()
  if not config.autoRepairStartup then return end
  local manifest = loadTable(RECOVERY_MANIFEST_FILE, {})
  if not manifest.startupHash then return end
  local current = rawRead(STARTUP_PATH)
  if current == "" then
    repairStartupFile("missing")
  elseif sha256(current) ~= manifest.startupHash then
    local currentOk, currentVersion = MAINT.validSourceVersion(current)
    if currentOk and manifest.version and MAINT.compareVersions(currentVersion, manifest.version) > 0 then
      appendAudit("startup protect: newer valid startup detected, refreshing backup " .. tostring(currentVersion))
      installSelfRecovery(true)
      return
    end
    repairStartupFile("modified")
  end
end

local function diskHasSuspiciousCode(mount)
  if not mount then return false, "unknown" end
  local names = {
    "startup",
    "startup.lua",
    "install",
    "install.lua",
    "autorun",
    "autorun.lua",
    "hack",
    "hack.lua"
  }
  for _, name in ipairs(names) do
    if fs.exists(mount .. "/" .. name) then return true, name end
  end
  return false, ""
end

local function scanDiskThreats(emergency)
  if not emergency and (not config.diskGuard) then return end
  if not disk then return end
  for _, side in ipairs(DISK_SCAN_SIDES) do
    if peripheral.getType(side) == "drive" and disk.isPresent(side) and disk.hasData(side) then
      local mount = disk.getMountPath(side)
      local suspicious, hit = diskHasSuspiciousCode(mount)
      local trustedStorage = STORAGE.isTrustedMount and STORAGE.isTrustedMount(mount)
      local strictDataBlock = config.strictDiskGuard and not config.externalStorage
      local mustBlock = (not trustedStorage or suspicious) and (emergency or suspicious or strictDataBlock)
      if mustBlock then
        setStatus("Disque bloque sur " .. side .. ".")
        appendAudit("disk blocked on " .. side .. ": " .. tostring(mount) .. " " .. tostring(hit))
        if (emergency or config.autoEjectBootDisks) and disk.eject then
          pcall(disk.eject, side)
          appendAudit("disk ejected from " .. side)
        end
      elseif trustedStorage then
        setStatus("Stockage externe OK sur " .. side .. ".")
      end
    end
  end
end

function MAINT.periodicSecurity(force)
  local t = now()
  if force or not MAINT.nextHardenAt or t >= MAINT.nextHardenAt then
    pcall(hardenCraftOSSettings)
    MAINT.nextHardenAt = t + MAINT.HARDEN_SECONDS
  end
  if force or not MAINT.nextStartupCheckAt or t >= MAINT.nextStartupCheckAt then
    pcall(protectStartupFile)
    MAINT.nextStartupCheckAt = t + MAINT.STARTUP_CHECK_SECONDS
  end
  if force or not MAINT.nextDiskScanAt or t >= MAINT.nextDiskScanAt then
    pcall(scanDiskThreats, force == true)
    MAINT.nextDiskScanAt = t + MAINT.DISK_CHECK_SECONDS
  end
end

local function securityDataHash(startupHash)
  return sha256(table.concat({
    startupHash or "",
    rawRead(USERS_FILE),
    rawRead(CONFIG_FILE)
  }, "|"))
end

local function integrityPayload(startupHash, usersHash, configHash)
  return table.concat({
    "SCOS-INTEGRITY-v2",
    tostring(os.getComputerID()),
    tostring(startupHash or ""),
    tostring(usersHash or ""),
    tostring(configHash or "")
  }, "|")
end

local function deriveIntegrityKey(secret, salt)
  return hashPassword(tostring(secret or ""), "integrity|" .. tostring(salt or "") .. "|" .. tostring(os.getComputerID()), FILE_KDF_ROUNDS)
end

local function makeIntegrityMac(secret, salt, startupHash, usersHash, configHash)
  return hmacSha256(deriveIntegrityKey(secret, salt), integrityPayload(startupHash, usersHash, configHash))
end

local function sealSystem(reason, adminName, integritySecret)
  local startupHash, path = currentStartupHash()
  local usersHash = sha256(rawRead(USERS_FILE))
  local configHash = sha256(rawRead(CONFIG_FILE))
  local sealSalt = (type(integrity) == "table" and integrity.sealSalt) or makeSalt()
  if #tostring(integritySecret or "") < MAINT.INTEGRITY_MIN then
    return false, "Code integrite: minimum " .. tostring(MAINT.INTEGRITY_MIN) .. " caracteres."
  end
  integrity = {
    startupHash = startupHash,
    usersHash = usersHash,
    configHash = configHash,
    dataHash = securityDataHash(startupHash),
    sealSalt = sealSalt,
    sealMac = makeIntegrityMac(integritySecret, sealSalt, startupHash, usersHash, configHash),
    path = path,
    sealedAt = now(),
    sealedBy = adminName or "system",
    reason = reason or "manual",
    computerId = os.getComputerID()
  }
  integrityLocked = false
  saveTable(INTEGRITY_FILE, integrity)
  appendAudit("integrity sealed: " .. tostring(reason or "manual"))
  return true
end

updateDataIntegrity = function(reason)
  if integrityLocked then return end
  if type(integrity) ~= "table" or not integrity.startupHash then return end
  integrity.pendingReseal = reason or "data"
  integrity.pendingAt = now()
  saveTable(INTEGRITY_FILE, integrity)
end

local function isStrongUserRecord(u)
  if type(u) ~= "table" then return false end
  if type(u.name) ~= "string" then return false end
  local normalized = u.name:lower():gsub("%s+", ""):gsub("[^a-z0-9_%-]", "")
  if normalized ~= u.name then return false end
  if u.role ~= "admin" and u.role ~= "user" then return false end
  if type(u.salt) ~= "string" or #u.salt < 16 then return false end
  if type(u.hash) ~= "string" or not u.hash:match("^[0-9a-f]+$") or #u.hash ~= 64 then return false end
  if type(u.rounds) ~= "number" or u.rounds < HASH_ROUNDS then return false end
  return true
end

local function xorStream(data, key)
  data = tostring(data or "")
  key = tostring(key or "")
  if key == "" then return data end
  local out = {}
  local block = ""
  local pos = 1
  local counter = 0
  for i = 1, #data do
    if pos > #block then
      counter = counter + 1
      block = sha256(key .. ":" .. tostring(counter))
      pos = 1
    end
    local mask = tonumber(block:sub(pos, pos + 1), 16) or 0
    pos = pos + 2
    out[i] = string.char(bxor(string.byte(data, i), mask))
  end
  return table.concat(out)
end

local function deriveFileKey(user, password)
  return hashPassword(
    tostring(password or ""),
    "files|" .. tostring(user.name) .. "|" .. tostring(user.salt),
    FILE_KDF_ROUNDS
  )
end

local function decryptPrivateData(raw, key)
  raw = tostring(raw or "")
  if raw:sub(1, 6) == "SCOS2:" then
    local rest = raw:sub(7)
    local nonce, tag, cipherHex = rest:match("^([^:]+):([^:]+):(.+)$")
    if not nonce or not tag or not cipherHex then return "[FICHIER CORROMPU]" end
    local encKey = hmacSha256(key, "enc|" .. nonce)
    local macKey = hmacSha256(key, "mac|" .. nonce)
    local expected = hmacSha256(macKey, nonce .. "|" .. cipherHex)
    if not constantTimeEquals(tag, expected) then
      appendAudit("private file MAC failed")
      return "[FICHIER MODIFIE OU MAUVAIS MOT DE PASSE]"
    end
    return xorStream(fromHex(cipherHex), encKey)
  end
  if raw:sub(1, #LEGACY_FILE_MAGIC) ~= LEGACY_FILE_MAGIC then return raw end
  appendAudit("blocked legacy SCOS1 private file")
  return "[FICHIER SCOS1 REFUSE: ancien format sans MAC]"
end

local function encryptPrivateData(data, key)
  local nonce = secureRandomHex(16)
  local encKey = hmacSha256(key, "enc|" .. nonce)
  local macKey = hmacSha256(key, "mac|" .. nonce)
  local cipherHex = toHex(xorStream(tostring(data or ""), encKey))
  local tag = hmacSha256(macKey, nonce .. "|" .. cipherHex)
  return "SCOS2:" .. nonce .. ":" .. tag .. ":" .. cipherHex
end

local function userCount()
  local n = 0
  for _ in pairs(users) do n = n + 1 end
  return n
end

local function adminCount()
  local n = 0
  for _, u in pairs(users) do
    if u.role == "admin" then n = n + 1 end
  end
  return n
end

local function cleanName(name)
  name = tostring(name or ""):lower()
  name = name:gsub("%s+", "")
  name = name:gsub("[^a-z0-9_%-]", "")
  return name
end

local function createUser(name, password, role)
  name = cleanName(name)
  if name == "" or #name < 3 then return false, "Nom trop court." end
  if users[name] then return false, "Utilisateur deja existant." end
  local strong, msg = MAINT.passwordPolicy(password)
  if not strong then return false, msg end
  local salt = makeSalt()
  users[name] = {
    name = name,
    role = role or "user",
    salt = salt,
    rounds = HASH_ROUNDS,
    hash = hashPassword(password, salt, HASH_ROUNDS),
    failed = 0,
    lockedUntil = 0,
    created = now()
  }
  ensureDir(FILES_DIR .. "/" .. name)
  if not mail.boxes[name] then mail.boxes[name] = { inbox = {}, sent = {} } end
  saveUsers()
  saveMail()
  appendAudit("user created: " .. name)
  return true
end

local function verifyPassword(name, password)
  name = cleanName(name)
  password = tostring(password or "")
  local u = users[name]
  if not u then return false, "Utilisateur inconnu." end
  if not isStrongUserRecord(u) then
    u.lockedUntil = now() + LOCK_SECONDS * 10
    saveUsers()
    appendAudit("weak or modified user record rejected: " .. name)
    return false, "Compte refuse: donnees utilisateur modifiees ou trop faibles."
  end
  if (u.lockedUntil or 0) > now() then
    return false, "Compte verrouille encore " .. tostring(u.lockedUntil - now()) .. "s."
  end
  local hpass = hashPassword(password, u.salt, u.rounds or HASH_ROUNDS)
  if constantTimeEquals(hpass, u.hash) then
    local dirty = (u.failed or 0) ~= 0 or (u.lockedUntil or 0) ~= 0
    u.failed = 0
    u.lockedUntil = 0
    if dirty then saveUsers() end
    return true, u
  end
  u.failed = (u.failed or 0) + 1
  if u.failed >= FAILED_LIMIT then
    u.lockedUntil = now() + LOCK_SECONDS
    u.failed = 0
    appendAudit("account locked after failed logins: " .. name)
  end
  saveUsers()
  return false, "Mot de passe incorrect."
end

local function setPassword(name, password)
  local u = users[name]
  if not u then return false, "Utilisateur absent." end
  local strong, msg = MAINT.passwordPolicy(password)
  if not strong then return false, msg end
  local salt = makeSalt()
  u.salt = salt
  u.rounds = HASH_ROUNDS
  u.hash = hashPassword(password, salt, HASH_ROUNDS)
  u.failed = 0
  u.lockedUntil = 0
  saveUsers()
  appendAudit("password changed for: " .. name)
  return true
end

local function createSession(user, password)
  sessionNonce = secureRandomHex(24)
  currentUser = {
    name = user.name,
    role = user.role
  }
  currentFileKey = deriveFileKey(user, password)
  sessionToken = sha256(table.concat({
    "session",
    tostring(os.getComputerID()),
    user.name,
    user.role,
    user.hash,
    sessionNonce
  }, "|"))
end

function MAINT.createGuestSession()
  sessionNonce = secureRandomHex(24)
  currentUser = {
    name = "invite",
    role = "guest",
    guest = true
  }
  currentFileKey = nil
  sessionToken = sha256(table.concat({
    "guest-session",
    tostring(os.getComputerID()),
    sessionNonce
  }, "|"))
end

local function isValidSession()
  if not currentUser or not sessionToken or not sessionNonce then return false end
  if currentUser.guest then
    local expectedGuest = sha256(table.concat({
      "guest-session",
      tostring(os.getComputerID()),
      sessionNonce
    }, "|"))
    return constantTimeEquals(expectedGuest, sessionToken)
  end
  local u = users[currentUser.name]
  if not isStrongUserRecord(u) then return false end
  if u.role ~= currentUser.role then return false end
  local expected = sha256(table.concat({
    "session",
    tostring(os.getComputerID()),
    u.name,
    u.role,
    u.hash,
    sessionNonce
  }, "|"))
  return constantTimeEquals(expected, sessionToken)
end

local function isAdmin()
  return isValidSession() and currentUser.role == "admin"
end

local function touchActivity()
  lastActivity = now()
end

local function startTimer()
  timerId = os.startTimer(1)
end

local function truncate(s, maxLen)
  s = tostring(s or "")
  if #s <= maxLen then return s end
  if maxLen <= 3 then return s:sub(1, maxLen) end
  return s:sub(1, maxLen - 3) .. "..."
end

local function setColors(fg, bg)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
end

local function clearScreen(bg)
  w, h = term.getSize()
  setColors(theme.text, bg or theme.bg)
  term.clear()
  term.setCursorPos(1, 1)
end

local function writeAt(x, y, text, fg, bg)
  if x < 1 or y < 1 or x > w or y > h then return end
  setColors(fg or theme.text, bg or theme.bg)
  term.setCursorPos(x, y)
  term.write(truncate(text, w - x + 1))
end

local function fill(x, y, width, height, bg)
  if width <= 0 or height <= 0 then return end
  setColors(theme.text, bg)
  local line = string.rep(" ", math.max(0, width))
  for yy = y, y + height - 1 do
    if yy >= 1 and yy <= h then
      term.setCursorPos(math.max(1, x), yy)
      term.write(line:sub(1, w - math.max(1, x) + 1))
    end
  end
end

local function centerAt(y, text, fg, bg)
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(x, y, text, fg, bg)
end

local function resetButtons()
  buttons = {}
end

local function addButton(id, x, y, width, height, label, bg, fg)
  width = math.max(1, width)
  height = math.max(1, height or 1)
  buttons[#buttons + 1] = { id = id, x = x, y = y, w = width, h = height, label = label }
  fill(x, y, width, height, bg or theme.action)
  local labelY = y + math.floor((height - 1) / 2)
  local labelText = truncate(label, width - 2)
  local labelX = x + math.max(0, math.floor((width - #labelText) / 2))
  writeAt(labelX, labelY, labelText, fg or theme.actionText, bg or theme.action)
end

local function buttonAt(x, y)
  for i = #buttons, 1, -1 do
    local b = buttons[i]
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
      return b.id
    end
  end
  return nil
end

local function drawTop(title)
  clearScreen(theme.bg)
  fill(1, 1, w, 1, theme.top)
  writeAt(2, 1, OS_NAME .. " " .. VERSION, theme.topText, theme.top)
  local right = currentUser and (currentUser.name .. " [" .. currentUser.role .. "]") or "locked"
  writeAt(math.max(1, w - #right), 1, right, theme.topText, theme.top)
  centerAt(2, title or "", theme.text, theme.bg)
  if statusLine ~= "" then
    writeAt(2, h, truncate(statusLine, w - 2), theme.warn, theme.bg)
  end
end

local function messageBox(title, lines, choices)
  choices = choices or { { id = "ok", label = "OK", color = theme.action } }
  if type(lines) == "string" then lines = { lines } end
  while true do
    resetButtons()
    drawTop(title)
    local boxW = math.min(w - 4, 44)
    local boxH = math.min(h - 4, #lines + 6)
    local x = math.floor((w - boxW) / 2) + 1
    local y = math.floor((h - boxH) / 2) + 1
    fill(x, y, boxW, boxH, theme.panel)
    centerAt(y + 1, title, theme.text, theme.panel)
    for i, line in ipairs(lines) do
      writeAt(x + 2, y + 2 + i, truncate(line, boxW - 4), theme.text, theme.panel)
    end
    local total = #choices * 12 + (#choices - 1)
    local bx = x + math.max(1, math.floor((boxW - total) / 2))
    for i, c in ipairs(choices) do
      addButton(c.id, bx + (i - 1) * 13, y + boxH - 2, 12, 1, c.label, c.color or theme.action, c.fg or theme.actionText)
    end
    local ev = { os.pullEventRaw() }
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id then touchActivity(); return id end
    elseif ev[1] == "key" and ev[2] == keys.enter then
      touchActivity()
      return choices[1].id
    elseif ev[1] == "terminate" then
      setStatus("Ctrl+T bloque par la protection.")
    end
  end
end

local function tryOpenRednet()
  if rednetReady then return true end
  if not rednet then return false end
  local sides = { "top", "bottom", "left", "right", "front", "back" }
  for _, side in ipairs(sides) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
      rednetReady = true
      return true
    end
  end
  return false
end

function MAINT.mirrorAudit(stamp, who, message)
  if type(config) ~= "table" then return end
  local target = tonumber(config.auditMirrorId or "")
  if not target or target <= 0 then return end
  if tostring(config.networkKey or "") == "" then return end
  if not tryOpenRednet() then return end
  local pkg = {
    magic = MAINT.AUDIT_PROTOCOL,
    time = tonumber(stamp) or now(),
    who = tostring(who or "system"),
    message = tostring(message or ""):sub(1, 192),
    senderId = os.getComputerID(),
    nonce = secureRandomHex(8)
  }
  local base = table.concat({
    tostring(pkg.magic),
    tostring(pkg.time),
    tostring(pkg.who),
    tostring(pkg.message),
    tostring(pkg.senderId),
    tostring(pkg.nonce)
  }, "|")
  pkg.sig = hmacSha256(config.networkKey, base)
  pcall(rednet.send, target, pkg, MAINT.AUDIT_PROTOCOL)
end

local function ensureMailbox(name)
  if not mail.boxes[name] then mail.boxes[name] = { inbox = {}, sent = {} } end
  if not mail.boxes[name].inbox then mail.boxes[name].inbox = {} end
  if not mail.boxes[name].sent then mail.boxes[name].sent = {} end
end

local function ensureFileQueue(name)
  name = cleanName(name)
  if not fileQueue.boxes[name] then fileQueue.boxes[name] = {} end
  return fileQueue.boxes[name]
end

local function transferFileName(name)
  name = tostring(name or "file.txt"):gsub("%s+", "_")
  name = name:gsub("[^A-Za-z0-9_%.%-]", "")
  if name == "" or name:sub(1, 1) == "." then return "file.txt" end
  return name:sub(1, 32)
end

local function nextMailId()
  local id = mail.nextId or 1
  mail.nextId = id + 1
  return id
end

local function addMail(to, box, item)
  ensureMailbox(to)
  item.id = item.id or nextMailId()
  item.time = item.time or now()
  table.insert(mail.boxes[to][box], 1, item)
  saveMail()
end

local function mailSignature(pkg, key)
  local base = table.concat({
    tostring(pkg.magic),
    tostring(pkg.from),
    tostring(pkg.to),
    tostring(pkg.subject),
    tostring(pkg.body),
    tostring(pkg.time),
    tostring(pkg.nonce),
    tostring(pkg.senderId)
  }, "|")
  return hmacSha256(tostring(key or ""), base)
end

local function fileTransferBase(pkg)
  return table.concat({
    tostring(pkg.magic),
    tostring(pkg.from),
    tostring(pkg.to),
    tostring(pkg.fileName),
    tostring(pkg.cipherHex),
    tostring(pkg.size),
    tostring(pkg.time),
    tostring(pkg.nonce),
    tostring(pkg.senderId),
    tostring(pkg.targetId or "")
  }, "|")
end

local function fileTransferSignature(pkg, key)
  return hmacSha256(tostring(key or ""), fileTransferBase(pkg))
end

local function encryptTransferContent(content, networkKey, nonce)
  local encKey = hmacSha256(networkKey, "file-transfer-enc|" .. tostring(nonce))
  return toHex(xorStream(tostring(content or ""), encKey))
end

local function decryptTransferContent(cipherHex, networkKey, nonce)
  local encKey = hmacSha256(networkKey, "file-transfer-enc|" .. tostring(nonce))
  return xorStream(fromHex(cipherHex), encKey)
end

local function receiveNetworkMail(sender, msg, protocol)
  if protocol ~= PROTOCOL then return end
  if type(msg) ~= "table" or msg.magic ~= PROTOCOL then return end
  if not config.networkMail or config.networkKey == "" then return end
  if tonumber(msg.senderId) ~= sender then
    appendAudit("rejected network mail with spoofed senderId")
    return
  end
  local to = cleanName(msg.to)
  if not users[to] then return end
  local expected = mailSignature(msg, config.networkKey)
  if not constantTimeEquals(msg.sig, expected) then
    appendAudit("rejected unsigned network mail from computer " .. tostring(sender))
    return
  end
  local claimedFrom = truncate(cleanFieldChunk(msg.from or "user"), 20)
  local senderLabel = "pc" .. tostring(sender) .. " (" .. claimedFrom .. ")"
  addMail(to, "inbox", {
    from = senderLabel,
    to = to,
    subject = truncate(cleanFieldChunk(msg.subject or "(sans sujet)"), 64),
    body = tostring(msg.body or ""):sub(1, MAX_TEXT_LEN),
    network = true,
    verified = true,
    read = false,
    senderId = sender,
    claimedFrom = claimedFrom,
    time = tonumber(msg.time) or now()
  })
  appendAudit("network mail received for " .. to .. " from pc" .. tostring(sender) .. " claim=" .. tostring(msg.from))
end

local function receiveNetworkFile(sender, msg, protocol)
  if protocol ~= FILE_PROTOCOL then return end
  if type(msg) ~= "table" or msg.magic ~= FILE_PROTOCOL then return end
  if not config.networkMail or config.networkKey == "" then return end
  if tonumber(msg.senderId) ~= sender then
    appendAudit("rejected file with spoofed senderId")
    return
  end
  if msg.targetId and tonumber(msg.targetId) ~= os.getComputerID() then return end

  local to = cleanName(msg.to)
  if not users[to] then return end
  local cipherHex = tostring(msg.cipherHex or "")
  local size = tonumber(msg.size) or 0
  if size < 0 or size > MAX_TRANSFER_FILE_LEN or #cipherHex > MAX_TRANSFER_FILE_LEN * 2 + 64 then
    appendAudit("rejected oversized file transfer")
    return
  end

  local expected = fileTransferSignature(msg, config.networkKey)
  if not constantTimeEquals(msg.sig, expected) then
    appendAudit("rejected unsigned file from computer " .. tostring(sender))
    return
  end

  local box = ensureFileQueue(to)
  if #box >= MAX_FILE_QUEUE then
    appendAudit("file queue full for " .. to)
    return
  end

  local claimedFrom = truncate(cleanFieldChunk(msg.from or "user"), 20)
  local senderLabel = "pc" .. tostring(sender) .. " (" .. claimedFrom .. ")"
  table.insert(box, 1, {
    from = senderLabel,
    rawFrom = tostring(msg.from or "user"),
    to = to,
    fileName = transferFileName(msg.fileName),
    signedFileName = tostring(msg.fileName or "file.txt"),
    cipherHex = cipherHex,
    size = size,
    nonce = tostring(msg.nonce or ""),
    time = tonumber(msg.time) or now(),
    targetId = msg.targetId,
    senderId = sender,
    claimedFrom = claimedFrom,
    sig = tostring(msg.sig or "")
  })
  saveFileQueue()
  addMail(to, "inbox", {
    from = "files@pc" .. tostring(sender),
    to = to,
    subject = "Fichier recu: " .. transferFileName(msg.fileName),
    body = "Un fichier chiffre attend dans Fichiers > Inbox.",
    read = false,
    network = true,
    verified = true,
    time = now()
  })
  appendAudit("network file queued for " .. to .. ": " .. transferFileName(msg.fileName))
end

local function pullSecureEvent()
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "timer" and ev[2] == timerId then
      startTimer()
      MAINT.periodicSecurity(false)
      if currentUser and config.lockAfter and config.lockAfter > 0 and now() - lastActivity >= config.lockAfter then
        appendAudit("auto lock")
        return "auto_lock"
      end
    elseif ev[1] == "rednet_message" then
      if ev[4] == BANK.PROTOCOL then
        if BANK.backgroundHandle and BANK.backgroundHandle(ev[2], ev[3]) then
          -- Service banque permanent: requete traitee en arriere-plan.
        else
          return unpack(ev)
        end
      elseif ev[4] == APPS.CHAT_PROTOCOL or ev[4] == APPS.DICE_PROTOCOL then
        return unpack(ev)
      end
      receiveNetworkMail(ev[2], ev[3], ev[4])
      receiveNetworkFile(ev[2], ev[3], ev[4])
    elseif ev[1] == "disk" then
      MAINT.nextDiskScanAt = 0
      scanDiskThreats(true)
    elseif ev[1] == "terminate" then
      setStatus("Ctrl+T bloque. Utilise le bouton Lock ou Power.")
    else
      if ev[1] == "mouse_click" or ev[1] == "key" or ev[1] == "char" or ev[1] == "paste" then
        MAINT.mixInputEntropy(ev[1], ev[2], ev[3], ev[4])
        touchActivity()
      end
      return unpack(ev)
    end
  end
end

local function drawField(x, y, width, label, value, active, mask)
  writeAt(x, y, label, theme.text, theme.bg)
  local display = tostring(value or "")
  if mask then display = string.rep("*", #display) end
  if #display > width - 2 then display = display:sub(#display - width + 3) end
  fill(x, y + 1, width, 1, active and theme.selected or theme.field)
  writeAt(x + 1, y + 1, display, theme.fieldText, active and theme.selected or theme.field)
end

local function fieldLimit(field)
  if field and type(field.maxLen) == "number" then return field.maxLen end
  if field and field.mask then return MAX_PASSWORD_LEN end
  return MAX_FIELD_LEN
end

function cleanFieldChunk(chunk)
  chunk = tostring(chunk or "")
  chunk = chunk:gsub("[%z\1-\31\127]", "")
  return chunk
end

local function appendFieldValue(field, chunk)
  chunk = cleanFieldChunk(chunk)
  local maxLen = fieldLimit(field)
  field.value = tostring(field.value or "")
  local room = maxLen - #field.value
  if room <= 0 then return end
  field.value = field.value .. chunk:sub(1, room)
end

local function inputForm(title, fields, actions)
  local active = 1
  for _, f in ipairs(fields) do
    f.value = cleanFieldChunk(f.value or ""):sub(1, fieldLimit(f))
  end
  actions = actions or { { id = "ok", label = "OK" }, { id = "cancel", label = "Cancel" } }

  while true do
    resetButtons()
    drawTop(title)
    local formW = math.min(w - 4, 42)
    local x = math.floor((w - formW) / 2) + 1
    local y = 4
    local rects = {}
    for i, f in ipairs(fields) do
      drawField(x, y + (i - 1) * 3, formW, f.label, f.value, i == active, f.mask)
      rects[i] = { x = x, y = y + (i - 1) * 3 + 1, w = formW, h = 1 }
    end
    local by = h - 2
    local total = #actions * 12 + (#actions - 1)
    local bx = math.floor((w - total) / 2) + 1
    for i, a in ipairs(actions) do
      addButton(a.id, bx + (i - 1) * 13, by, 12, 1, a.label, a.color or theme.action, a.fg or theme.actionText)
    end
    if pcall(term.setCursorBlink, true) then
      local f = fields[active]
      local r = rects[active]
      local displayLen = #tostring(f.value or "")
      term.setCursorPos(math.min(r.x + r.w - 1, r.x + 1 + displayLen), r.y)
    end
    local ev = { pullSecureEvent() }
    pcall(term.setCursorBlink, false)
    if ev[1] == "auto_lock" then return "auto_lock", fields end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id then return id, fields end
      for i, r in ipairs(rects) do
        if ev[3] >= r.x and ev[3] < r.x + r.w and ev[4] >= r.y and ev[4] < r.y + r.h then
          active = i
        end
      end
    elseif ev[1] == "char" then
      appendFieldValue(fields[active], ev[2])
    elseif ev[1] == "paste" then
      appendFieldValue(fields[active], tostring(ev[2] or ""):sub(1, MAX_PASTE_LEN))
    elseif ev[1] == "key" then
      local k = ev[2]
      if k == keys.backspace then
        fields[active].value = fields[active].value:sub(1, -2)
      elseif k == keys.tab or k == keys.down then
        active = active + 1
        if active > #fields then active = 1 end
      elseif k == keys.up then
        active = active - 1
        if active < 1 then active = #fields end
      elseif k == keys.enter then
        return actions[1].id, fields
      end
    end
  end
end

local function readMultiline(title, initial, maxLen)
  maxLen = tonumber(maxLen) or MAX_TEXT_LEN
  local text = tostring(initial or ""):sub(1, maxLen)
  local function appendText(chunk)
    chunk = tostring(chunk or ""):gsub("[%z\1-\8\11-\12\14-\31\127]", "")
    local room = maxLen - #text
    if room <= 0 then return end
    text = text .. chunk:sub(1, room)
  end
  while true do
    resetButtons()
    drawTop(title)
    writeAt(2, 3, "Zone de texte. Entree = nouvelle ligne.", theme.muted, theme.bg)
    local areaY = 5
    local areaH = h - 8
    fill(2, areaY, w - 2, areaH, theme.field)

    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if line == "" then
        lines[#lines + 1] = ""
      else
        while #line > w - 4 do
          lines[#lines + 1] = line:sub(1, w - 4)
          line = line:sub(w - 3)
        end
        lines[#lines + 1] = line
      end
    end
    local start = math.max(1, #lines - areaH + 1)
    for i = start, #lines do
      writeAt(3, areaY + i - start, truncate(lines[i], w - 4), theme.fieldText, theme.field)
    end

    addButton("save", 2, h - 2, 12, 1, "Save", theme.good, colors.black)
    addButton("cancel", 16, h - 2, 12, 1, "Cancel", theme.bad, colors.white)
    if pcall(term.setCursorBlink, true) then term.setCursorPos(w - 2, areaY + areaH - 1) end
    local ev = { pullSecureEvent() }
    pcall(term.setCursorBlink, false)
    if ev[1] == "auto_lock" then return "auto_lock", text end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "save" then return "save", text end
      if id == "cancel" then return "cancel", text end
    elseif ev[1] == "char" then
      appendText(ev[2])
    elseif ev[1] == "paste" then
      appendText(tostring(ev[2] or ""):sub(1, MAX_PASTE_LEN))
    elseif ev[1] == "key" then
      if ev[2] == keys.backspace then
        text = text:sub(1, -2)
      elseif ev[2] == keys.enter then
        appendText("\n")
      end
    end
  end
end

local function recoveryInstallerSource()
  return [[
-- SecureClickOS recovery installer
-- This installer asks before changing this computer.

local function println(text, color)
  if color and term and term.setTextColor then term.setTextColor(color) end
  print(text)
  if term and term.setTextColor then term.setTextColor(colors.white) end
end

local function findRecoveryDisk()
  local sides = { "top", "bottom", "left", "right", "front", "back" }
  for _, side in ipairs(sides) do
    if peripheral.getType(side) == "drive" and disk and disk.isPresent(side) and disk.hasData(side) then
      local mount = disk.getMountPath(side)
      if mount and fs.exists(mount .. "/secureclickos_startup.lua") then
        return mount, side
      end
    end
  end
  return nil
end

term.clear()
term.setCursorPos(1, 1)
println("SecureClickOS Recovery Disk", colors.cyan)
println("")
local mount, side = findRecoveryDisk()
if not mount then
  println("Erreur: secureclickos_startup.lua introuvable sur le disque.", colors.red)
  return
end

println("Ce disque peut installer SecureClickOS sur ce computer.", colors.yellow)
println("Ancien /startup.lua sera sauvegarde en /startup.lua.bak si possible.")
println("")
write("Tape OUI pour installer: ")
local answer = read()
if answer ~= "OUI" then
  println("Installation annulee.", colors.orange)
  return
end

if fs.exists("/startup.lua.bak") then fs.delete("/startup.lua.bak") end
if fs.exists("/startup.lua") then
  fs.move("/startup.lua", "/startup.lua.bak")
end
fs.copy(mount .. "/secureclickos_startup.lua", "/startup.lua")
if settings then
  pcall(settings.set, "shell.allow_disk_startup", false)
  if settings.save then pcall(settings.save) end
end

println("SecureClickOS installe.", colors.green)
println("Redemarrage dans 3 secondes.")
if sleep then sleep(3) end
os.reboot()
]]
end

local function findInsertedDisk()
  if not disk then return nil, nil end
  for _, side in ipairs(DISK_SCAN_SIDES) do
    if peripheral.getType(side) == "drive" and disk.isPresent(side) and disk.hasData(side) then
      local mount = disk.getMountPath(side)
      if mount then return mount, side end
    end
  end
  return nil, nil
end

local function waitForRecoveryDisk()
  while true do
    resetButtons()
    drawTop("Recovery Disk")
    centerAt(5, "Insere TON disque de recovery.", theme.text, theme.bg)
    centerAt(7, "Le disque sera ecrit apres confirmation.", theme.muted, theme.bg)
    addButton("use", 8, h - 2, 12, 1, "Use Disk", theme.good, colors.black)
    addButton("cancel", 24, h - 2, 12, 1, "Cancel", theme.bad, colors.white)
    local mount, side = findInsertedDisk()
    if mount then
      writeAt(2, 10, "Disque: " .. tostring(mount) .. " sur " .. tostring(side), theme.good, theme.bg)
    else
      writeAt(2, 10, "Aucun disque detecte.", theme.warn, theme.bg)
    end

    local ev = { os.pullEventRaw() }
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "cancel" then return nil, nil, "cancel" end
      if id == "use" then
        mount, side = findInsertedDisk()
        if mount then return mount, side, "use" end
      end
    elseif ev[1] == "disk" then
      -- redraw immediately
    elseif ev[1] == "terminate" then
      setStatus("Ctrl+T bloque.")
    elseif ev[1] == "timer" and ev[2] == timerId then
      startTimer()
      MAINT.periodicSecurity(false)
    end
  end
end

function MAINT.waitForUpdateDisk()
  while true do
    resetButtons()
    drawTop("Update Disk")
    centerAt(5, "Insere TON disque de mise a jour.", theme.text, theme.bg)
    centerAt(7, "Il sera utilise apres verification.", theme.muted, theme.bg)
    addButton("use", 8, h - 2, 12, 1, "Use Disk", theme.good, colors.black)
    addButton("cancel", 24, h - 2, 12, 1, "Cancel", theme.bad, colors.white)
    local mount, side = findInsertedDisk()
    if mount then
      writeAt(2, 10, "Disque: " .. tostring(mount) .. " sur " .. tostring(side), theme.good, theme.bg)
    else
      writeAt(2, 10, "Aucun disque detecte.", theme.warn, theme.bg)
    end

    local ev = { os.pullEventRaw() }
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "cancel" then return nil, nil, "cancel" end
      if id == "use" then
        mount, side = findInsertedDisk()
        if mount then return mount, side, "use" end
      end
    elseif ev[1] == "disk" then
      -- redraw immediately
    elseif ev[1] == "terminate" then
      setStatus("Ctrl+T bloque.")
    elseif ev[1] == "timer" and ev[2] == timerId then
      startTimer()
      MAINT.periodicSecurity(false)
    end
  end
end

local function makeRecoveryDisk()
  if not isAdmin() then messageBox("Refuse", { "Admin seulement." }); return end
  local ok = messageBox("Recovery Disk", {
    "Cette action ecrit sur TON disque.",
    "Elle remplace startup.lua sur le disque.",
    "L'installateur demandera OUI avant installation."
  }, {
    { id = "ok", label = "OK", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if ok ~= "ok" then return end

  local mount, side, action = waitForRecoveryDisk()
  if action ~= "use" or not mount then return end

  local source = rawRead(STARTUP_PATH)
  if source == "" then
    source = rawRead(selfPath())
  end
  if source == "" then
    messageBox("Erreur", { "Impossible de lire l'OS actuel." })
    return
  end

  if fs.exists(mount .. "/startup.lua") then
    local confirm = messageBox("Confirmer", {
      "Le disque contient deja startup.lua.",
      "Le remplacer par l'installateur ?"
    }, {
      { id = "yes", label = "Yes", color = theme.warn, fg = colors.black },
      { id = "no", label = "No", color = theme.bad, fg = colors.white }
    })
    if confirm ~= "yes" then return end
    fs.delete(mount .. "/startup.lua")
  end
  if fs.exists(mount .. "/secureclickos_startup.lua") then fs.delete(mount .. "/secureclickos_startup.lua") end
  if fs.exists(mount .. "/README.txt") then fs.delete(mount .. "/README.txt") end

  rawWrite(mount .. "/secureclickos_startup.lua", source)
  rawWrite(mount .. "/startup.lua", recoveryInstallerSource())
  rawWrite(mount .. "/README.txt", "SecureClickOS Recovery Disk\n\nBoot this disk and type OUI to install SecureClickOS.\nIt does not install without confirmation.\n")
  if disk and disk.setLabel then pcall(disk.setLabel, side, "SecureClickOS Recovery") end
  appendAudit("recovery disk written on " .. tostring(side))
  messageBox("OK", {
    "Disque recovery cree.",
    "Il demandera OUI avant installation."
  })
end

function MAINT.updateManifestPayload(manifest)
  return table.concat({
    tostring(manifest.magic or ""),
    tostring(manifest.osName or ""),
    tostring(manifest.version or ""),
    tostring(manifest.hash or ""),
    tostring(manifest.createdAt or ""),
    tostring(manifest.sourceComputerId or "")
  }, "|")
end

function MAINT.updateManifestSignature(manifest, debugCode)
  return hmacSha256(tostring(debugCode or ""), MAINT.updateManifestPayload(manifest))
end

function MAINT.makeUpdateDisk(debugCode)
  if not isAdmin() then messageBox("Refuse", { "Admin seulement." }); return end
  if not MAINT.verifyDebugCode(debugCode) then messageBox("Refuse", { "Code debug invalide." }); return end

  local source = rawRead(STARTUP_PATH)
  if source == "" then source = rawRead(selfPath()) end
  local valid, versionOrErr = MAINT.validateSecureClickOSSource(source)
  if not valid then
    messageBox("Erreur", { "OS actuel refuse.", versionOrErr })
    return
  end

  local ok = messageBox("Make Update", {
    "Cette action ecrit un package update.",
    "Le disque ne lance pas d'auto-install.",
    "Il servira a mettre a jour un OS plus vieux."
  }, {
    { id = "ok", label = "OK", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if ok ~= "ok" then return end

  local mount, side, action = MAINT.waitForUpdateDisk()
  if action ~= "use" or not mount then return end

  local manifest = {
    magic = MAINT.UPDATE_MAGIC,
    osName = OS_NAME,
    version = versionOrErr,
    hash = sha256(source),
    createdAt = now(),
    sourceComputerId = os.getComputerID()
  }
  manifest.sig = MAINT.updateManifestSignature(manifest, debugCode)

  local files = {
    MAINT.UPDATE_SOURCE_FILE,
    MAINT.UPDATE_MANIFEST_FILE,
    MAINT.UPDATE_README_FILE
  }
  for _, name in ipairs(files) do
    if fs.exists(mount .. "/" .. name) then fs.delete(mount .. "/" .. name) end
  end

  rawWrite(mount .. "/" .. MAINT.UPDATE_SOURCE_FILE, source)
  saveTable(mount .. "/" .. MAINT.UPDATE_MANIFEST_FILE, manifest)
  rawWrite(mount .. "/" .. MAINT.UPDATE_README_FILE,
    "SecureClickOS Update Disk\n\nVersion: " .. tostring(versionOrErr) ..
    "\nUse Debug > Update OS on the target computer.\nThe update preserves /secureos data.\n")
  if disk and disk.setLabel then pcall(disk.setLabel, side, "SCOS Update " .. tostring(versionOrErr)) end
  appendAudit("debug update disk written on " .. tostring(side) .. " version " .. tostring(versionOrErr))
  messageBox("OK", {
    "Disque update cree.",
    "Version: " .. tostring(versionOrErr)
  })
end

function MAINT.readVerifiedUpdatePackage(debugCode, selectedMount, selectedSide)
  if not MAINT.verifyDebugCode(debugCode) then return false, "Code debug invalide." end
  local mount, side = selectedMount, selectedSide
  if not mount then mount, side = findInsertedDisk() end
  if not mount then return false, "Aucun disque detecte." end

  local sourcePath = mount .. "/" .. MAINT.UPDATE_SOURCE_FILE
  local manifestPath = mount .. "/" .. MAINT.UPDATE_MANIFEST_FILE
  if not fs.exists(sourcePath) or not fs.exists(manifestPath) then
    return false, "Package update introuvable."
  end

  local source = rawRead(sourcePath)
  local manifest = loadTable(manifestPath, {})
  if type(manifest) ~= "table" or manifest.magic ~= MAINT.UPDATE_MAGIC or manifest.osName ~= OS_NAME then
    return false, "Manifest update invalide."
  end

  local valid, versionOrErr = MAINT.validateSecureClickOSSource(source)
  if not valid then return false, versionOrErr end
  if tostring(manifest.version or "") ~= tostring(versionOrErr) then
    return false, "Version manifest/source differente."
  end

  local hash = sha256(source)
  if not constantTimeEquals(hash, manifest.hash) then
    return false, "Hash source invalide."
  end

  local expectedSig = MAINT.updateManifestSignature(manifest, debugCode)
  if not constantTimeEquals(tostring(manifest.sig or ""), expectedSig) then
    return false, "Signature update invalide."
  end

  local currentVersion = VERSION
  local currentOk, installedVersion = MAINT.validSourceVersion(rawRead(STARTUP_PATH))
  if currentOk and MAINT.compareVersions(installedVersion, currentVersion) > 0 then
    currentVersion = installedVersion
  end
  if MAINT.compareVersions(versionOrErr, currentVersion) <= 0 then
    return false, "Version pas plus recente: " .. tostring(versionOrErr)
  end

  return true, {
    source = source,
    version = versionOrErr,
    hash = hash,
    mount = mount,
    side = side
  }
end

function MAINT.installUpdateFromDisk(debugCode)
  if not isAdmin() then messageBox("Refuse", { "Admin seulement." }); return end
  local mount, side, action = MAINT.waitForUpdateDisk()
  if action ~= "use" or not mount then return end
  local ok, pkgOrErr = MAINT.readVerifiedUpdatePackage(debugCode, mount, side)
  if not ok then
    messageBox("Update refusee", {
      tostring(pkgOrErr),
      "Rien n'a ete modifie."
    })
    return
  end
  local pkg = pkgOrErr

  local yes = messageBox("Update OS", {
    "Version actuelle: " .. VERSION,
    "Version disque: " .. tostring(pkg.version),
    "Les donnees /secureos seront gardees."
  }, {
    { id = "yes", label = "Update", color = theme.good, fg = colors.black },
    { id = "no", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if yes ~= "yes" then return end

  local tmp = STARTUP_PATH .. ".update"
  if fs.exists(tmp) then fs.delete(tmp) end
  if not rawWrite(tmp, pkg.source) then
    messageBox("Erreur", { "Ecriture temporaire impossible." })
    return
  end
  if not constantTimeEquals(sha256(rawRead(tmp)), pkg.hash) then
    if fs.exists(tmp) then fs.delete(tmp) end
    messageBox("Erreur", { "Verification apres ecriture refusee." })
    return
  end

  local updateBackup = MAINT.STARTUP_UPDATE_BACKUP_FILE
  local externalRoot = STORAGE.findExternal and STORAGE.findExternal()
  if externalRoot and STORAGE.free(externalRoot) >= STORAGE.size(STARTUP_PATH) + STORAGE.MIN_FREE then
    updateBackup = externalRoot .. "/startup.before_update"
  end
  if fs.exists(updateBackup) then fs.delete(updateBackup) end
  if fs.exists(STARTUP_PATH) and STORAGE.free(updateBackup) >= STORAGE.size(STARTUP_PATH) + STORAGE.MIN_FREE then
    pcall(fs.copy, STARTUP_PATH, updateBackup)
  else
    appendAudit("debug update backup skipped: low space")
  end
  if fs.exists(STARTUP_PATH) then fs.delete(STARTUP_PATH) end
  fs.move(tmp, STARTUP_PATH)
  installSelfRecovery(true)
  hardenCraftOSSettings()
  appendAudit("debug update installed version " .. tostring(pkg.version))

  pcall(term.setCursorBlink, false)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("SecureClickOS update installe.")
  print("Donnees /secureos conservees.")
  print("Au reboot, entre le code integrite pour re-signer.")
  print("Redemarrage dans 3 secondes.")
  if sleep then sleep(3) end
  os.reboot()
end

function MAINT.enableInternetAuto()
  if not settings then return false, "settings indisponible" end
  pcall(settings.set, "http.enabled", true)
  pcall(settings.set, "http.websocket_enabled", true)
  if settings.save then pcall(settings.save) end
  if http and type(http.get) == "function" then return true end
  return false, "HTTP indisponible; verifie la config serveur/modpack."
end

function MAINT.downloadGithubUpdate(url)
  if not http or type(http.get) ~= "function" then
    return false, "HTTP indisponible."
  end
  url = tostring(url or MAINT.GITHUB_UPDATE_URL)
  local ok, response = pcall(http.get, url)
  if not ok or not response then return false, "Telechargement GitHub impossible." end
  local body = response.readAll and response.readAll() or ""
  if response.close then response.close() end
  if tostring(body or "") == "" then return false, "GitHub a renvoye un fichier vide." end
  return true, body
end

function MAINT.installGithubSource(source, version, hash)
  local tmp = STARTUP_PATH .. ".github_update"
  if fs.exists(tmp) then fs.delete(tmp) end
  if not rawWrite(tmp, source) then return false, "Ecriture temporaire impossible." end
  if not constantTimeEquals(sha256(rawRead(tmp)), hash) then
    if fs.exists(tmp) then fs.delete(tmp) end
    return false, "Verification apres ecriture refusee."
  end

  local updateBackup = MAINT.STARTUP_UPDATE_BACKUP_FILE
  local externalRoot = STORAGE.findExternal and STORAGE.findExternal()
  if externalRoot and STORAGE.free(externalRoot) >= STORAGE.size(STARTUP_PATH) + STORAGE.MIN_FREE then
    updateBackup = externalRoot .. "/startup.before_github_update"
  end
  if fs.exists(updateBackup) then fs.delete(updateBackup) end
  if fs.exists(STARTUP_PATH) and STORAGE.free(updateBackup) >= STORAGE.size(STARTUP_PATH) + STORAGE.MIN_FREE then
    pcall(fs.copy, STARTUP_PATH, updateBackup)
  else
    appendAudit("github update backup skipped: low space")
  end
  if fs.exists(STARTUP_PATH) then fs.delete(STARTUP_PATH) end
  fs.move(tmp, STARTUP_PATH)
  installSelfRecovery(true)
  hardenCraftOSSettings()
  appendAudit("github update installed version " .. tostring(version))
  return true
end

function MAINT.checkGithubUpdateOnBoot()
  if type(config) ~= "table" or config.githubAutoUpdate == false then return false, "GitHub update OFF" end
  MAINT.enableInternetAuto()
  local ok, sourceOrErr = MAINT.downloadGithubUpdate(config.githubUpdateUrl or MAINT.GITHUB_UPDATE_URL)
  if not ok then
    appendAudit("github update skipped: " .. tostring(sourceOrErr))
    return false, sourceOrErr
  end
  local source = sourceOrErr
  local valid, versionOrErr = MAINT.validateSecureClickOSSource(source)
  if not valid then
    appendAudit("github update refused: " .. tostring(versionOrErr))
    return false, versionOrErr
  end
  local remoteHash = sha256(source)
  local currentSource = rawRead(STARTUP_PATH)
  if constantTimeEquals(remoteHash, sha256(currentSource)) then
    return false, "Deja a jour."
  end
  local currentVersion = VERSION
  local currentOk, installedVersion = MAINT.validSourceVersion(currentSource)
  if currentOk and MAINT.compareVersions(installedVersion, currentVersion) > 0 then
    currentVersion = installedVersion
  end
  if MAINT.compareVersions(versionOrErr, currentVersion) < 0 then
    appendAudit("github update refused: downgrade " .. tostring(versionOrErr) .. " < " .. tostring(currentVersion))
    return false, "Downgrade refuse."
  end
  local installed, err = MAINT.installGithubSource(source, versionOrErr, remoteHash)
  if not installed then
    appendAudit("github update failed: " .. tostring(err))
    return false, err
  end
  pcall(term.setCursorBlink, false)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Mise a jour GitHub installee.")
  print("Version: " .. tostring(versionOrErr))
  print("Redemarrage dans 3 secondes.")
  if sleep then sleep(3) end
  os.reboot()
  return true
end

function MAINT.uninstallSecureClickOS()
  if not isAdmin() then messageBox("Refuse", { "Admin seulement." }); return end
  local ok = messageBox("Debug uninstall", {
    "Cette action supprime SecureClickOS.",
    "/secureos et /.secureclickos seront effaces.",
    "/startup.lua.bak sera restaure si present."
  }, {
    { id = "yes", label = "Continue", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if ok ~= "yes" then return end

  local action, fields = inputForm("Confirmer uninstall", {
    { key = "confirm", label = "Tape DESINSTALLER", maxLen = 32 }
  }, {
    { id = "ok", label = "Uninstall", color = theme.bad, fg = colors.white },
    { id = "cancel", label = "Cancel", color = theme.action, fg = colors.black }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return end
  if tostring(fields[1].value or "") ~= "DESINSTALLER" then
    messageBox("Annule", { "Texte incorrect.", "Rien n'a ete supprime." })
    return
  end

  appendAudit("debug uninstall started")
  restoreCraftOSDiskStartup()

  local oldStartup = STARTUP_PATH .. ".bak"
  if fs.exists(oldStartup) then
    if fs.exists(STARTUP_PATH) then fs.delete(STARTUP_PATH) end
    fs.move(oldStartup, STARTUP_PATH)
  elseif fs.exists(STARTUP_PATH) then
    fs.delete(STARTUP_PATH)
  end
  if fs.exists(ROOT) then fs.delete(ROOT) end
  if fs.exists(RECOVERY_DIR) then fs.delete(RECOVERY_DIR) end

  pcall(term.setCursorBlink, false)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("SecureClickOS desinstalle.")
  print("Redemarrage dans 3 secondes.")
  if sleep then sleep(3) end
  os.reboot()
end

function MAINT.requestDebugAccess()
  if not isAdmin() then
    messageBox("Debug", { "Admin seulement." })
    return false
  end

  local action, fields = inputForm("Code debug", {
    { key = "code", label = "Code debug", mask = true, maxLen = 64 }
  }, {
    { id = "ok", label = "Open", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return false end

  local debugCode = fields[1].value
  local ok = MAINT.verifyDebugCode(debugCode)
  fields[1].value = ""
  safeCollectGarbage()
  if not ok then
    debugCode = nil
    appendAudit("debug access refused")
    messageBox("Refuse", { "Code debug invalide." })
    return false
  end

  appendAudit("debug access granted")
  return debugCode
end

function MAINT.appDebugMode()
  local debugCode = MAINT.requestDebugAccess()
  if debugCode == "auto_lock" then return "auto_lock" end
  if not debugCode then return end

  while true do
    if not isValidSession() then debugCode = nil; safeCollectGarbage(); return "auto_lock" end
    resetButtons()
    drawTop("Debug")
    writeAt(2, 5, "Mode maintenance admin.", theme.warn, theme.bg)
    writeAt(2, 7, "Make Update: prepare un disque de mise a jour.", theme.text, theme.bg)
    writeAt(2, 8, "Update OS: installe une version disque verifiee.", theme.text, theme.bg)
    writeAt(2, 9, "Recovery: disque installateur confirme.", theme.text, theme.bg)
    addButton("makeupdate", 3, 11, 18, 2, "Make Update", theme.good, colors.black)
    addButton("updateos", 25, 11, 18, 2, "Update OS", theme.action, colors.black)
    addButton("recovery", 3, 14, 18, 2, "Recovery", theme.warn, colors.black)
    addButton("uninstall", 25, 14, 18, 2, "Uninstall", theme.bad, colors.white)
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then debugCode = nil; safeCollectGarbage(); return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then debugCode = nil; safeCollectGarbage(); return end
      if id == "makeupdate" then
        MAINT.makeUpdateDisk(debugCode)
      elseif id == "updateos" then
        MAINT.installUpdateFromDisk(debugCode)
      elseif id == "recovery" then
        makeRecoveryDisk()
      elseif id == "uninstall" then
        local r = MAINT.uninstallSecureClickOS()
        if r == "auto_lock" then debugCode = nil; safeCollectGarbage(); return "auto_lock" end
      end
    end
  end
end

local function setupWizard()
  while userCount() == 0 do
    local action, fields = inputForm("Premier demarrage: compte admin", {
      { key = "user", label = "Nom admin", value = "admin", maxLen = 32 },
      { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "pass2", label = "Confirmer", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN }
    }, {
      { id = "create", label = "Create", color = theme.good, fg = colors.black },
      { id = "power", label = "Power", color = theme.bad, fg = colors.white }
    })
    if action == "power" then os.shutdown() end
    local name = fields[1].value
    local p1 = fields[2].value
    local p2 = fields[3].value
    local seal = fields[4].value
    if p1 ~= p2 then
      fields[2].value, fields[3].value, fields[4].value = "", "", ""
      p1, p2, seal = nil, nil, nil
      safeCollectGarbage()
      messageBox("Erreur", { "Les deux mots de passe ne sont pas pareils." })
    elseif #seal < MAINT.INTEGRITY_MIN then
      fields[2].value, fields[3].value, fields[4].value = "", "", ""
      p1, p2, seal = nil, nil, nil
      safeCollectGarbage()
      messageBox("Erreur", { "Code integrite: minimum " .. tostring(MAINT.INTEGRITY_MIN) .. " caracteres." })
    else
      local ok, err = createUser(name, p1, "admin")
      if ok then
        sealSystem("setup", cleanName(name), seal)
        fields[2].value, fields[3].value, fields[4].value = "", "", ""
        p1, p2, seal = nil, nil, nil
        safeCollectGarbage()
        messageBox("OK", {
          "Compte admin cree.",
          "Conseil: garde ce computer physiquement protege."
        })
      else
        fields[2].value, fields[3].value, fields[4].value = "", "", ""
        p1, p2, seal = nil, nil, nil
        safeCollectGarbage()
        messageBox("Erreur", { err })
      end
    end
  end
end

local function loginScreen()
  while true do
    local action, fields = inputForm("Connexion", {
      { key = "user", label = "Utilisateur", maxLen = 32 },
      { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN }
    }, {
      { id = "login", label = "Login", color = theme.good, fg = colors.black },
      { id = "guest", label = "Sans code", color = theme.warn, fg = colors.black },
      { id = "power", label = "Power", color = theme.bad, fg = colors.white }
    })
    if action == "power" then os.shutdown() end
    if action == "guest" then
      local warn = messageBox("Mode sans code", {
        "Avertissement serieux.",
        "Sans code = mode invite limite.",
        "Pas de Mail, Fichiers, Banque, Reglages.",
        "Les apps reseau restent publiques.",
        "N'utilise pas ce mode pour des secrets."
      }, {
        { id = "enter", label = "Entrer", color = theme.warn, fg = colors.black },
        { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
      })
      if warn == "enter" then
        MAINT.createGuestSession()
        touchActivity()
        startTimer()
        appendAudit("guest login")
        return
      end
    elseif action == "login" then
      local password = fields[2].value
      local ok, result = verifyPassword(fields[1].value, password)
      if ok then
        createSession(result, password)
        fields[2].value = ""
        password = nil
        safeCollectGarbage()
        ensureMailbox(currentUser.name)
        ensureDir(FILES_DIR .. "/" .. currentUser.name)
        touchActivity()
        startTimer()
        appendAudit("login")
        return
      end
      fields[2].value = ""
      password = nil
      safeCollectGarbage()
      appendAudit("failed login for " .. cleanName(fields[1].value))
      messageBox("Connexion refusee", { result })
    end
  end
end

local function integrityGate()
  integrity = loadTable(INTEGRITY_FILE, {})
  local startupHash = currentStartupHash()
  local usersHash = sha256(rawRead(USERS_FILE))
  local configHash = sha256(rawRead(CONFIG_FILE))
  local hasSeal = integrity.startupHash and integrity.sealSalt and integrity.sealMac
  local changed = hasSeal and (
    integrity.startupHash ~= startupHash
    or integrity.usersHash ~= usersHash
    or integrity.configHash ~= configHash
  )
  local pending = integrity.pendingReseal ~= nil
  if changed or pending or not hasSeal then
    appendAudit("integrity gate requires admin")
  end
  if changed or pending then integrityLocked = true end

  if hasSeal and integrity.usersHash ~= usersHash and not pending then
    while true do
      messageBox("ALERTE USERS", {
        "users.db a change sans demande OS.",
        "Je bloque pour eviter un faux admin.",
        "Restaure /secureos ou utilise une sauvegarde."
      }, {
        { id = "power", label = "Power", color = theme.bad, fg = colors.white }
      })
      os.shutdown()
    end
  end

  while true do
    local title = hasSeal and (changed and "ALERTE INTEGRITE" or "Code integrite") or "Creer sceau OS"
    local mainAction = (changed or pending or not hasSeal) and "reseal" or "unlock"
    local action, fields = inputForm(title, {
      { key = "user", label = "Admin", maxLen = 32 },
      { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN }
    }, {
      { id = mainAction, label = mainAction == "unlock" and "Unlock" or "Reseal", color = changed and theme.warn or theme.good, fg = colors.black },
      { id = "power", label = "Power", color = theme.bad, fg = colors.white }
    })
    if action == "power" then os.shutdown() end
    local ok, result = verifyPassword(fields[1].value, fields[2].value)
    local sealCode = fields[3].value
    if ok and result.role == "admin" and #sealCode >= MAINT.INTEGRITY_MIN then
      local trustedSeal = true
      if hasSeal then
        local oldMac = makeIntegrityMac(sealCode, integrity.sealSalt, integrity.startupHash, integrity.usersHash, integrity.configHash)
        trustedSeal = constantTimeEquals(oldMac, integrity.sealMac)
      end
      if trustedSeal then
        if changed or pending or not hasSeal then
          local sealed, err = sealSystem("admin reseal", result.name, sealCode)
          if not sealed then messageBox("Erreur", { err or "Sceau refuse." }) end
        end
        createSession(result, fields[2].value)
        fields[2].value, fields[3].value = "", ""
        sealCode = nil
        safeCollectGarbage()
        return
      end
    end
    fields[2].value, fields[3].value = "", ""
    sealCode = nil
    safeCollectGarbage()
    messageBox("Refuse", {
      "Admin, mot de passe ou code integrite invalide.",
      "Sans le code, integrity.db ne vaut rien."
    })
  end
end

local function unreadCount(name)
  ensureMailbox(name)
  local n = 0
  for _, m in ipairs(mail.boxes[name].inbox) do
    if not m.read then n = n + 1 end
  end
  return n
end

local function appDesktop()
  local debugHoldTimer = nil
  local debugHoldArmed = false
  local appsOpen = true
  while true do
    if not isValidSession() then return "lock" end
    resetButtons()
    drawTop("Bureau")
    local guestMode = currentUser and currentUser.guest
    local unread = (currentUser and not guestMode) and unreadCount(currentUser.name) or 0
    local luaApps = guestMode and {} or RUNNER.listLuaApps(currentUser.name)
    local menuItems = {}
    if guestMode then
      menuItems = {
        { header = "Systeme" },
        { id = "appcenter", label = "Apps/Jeux", color = colors.lime },
        { id = "help", label = "Aide", color = colors.yellow },
        { id = "lock", label = "Lock", color = colors.red }
      }
    else
      menuItems = {
        { header = "Systeme" },
        { id = "mail", label = "Mail" .. (unread > 0 and (" (" .. unread .. ")") or ""), color = colors.cyan },
        { id = "files", label = "Fichiers", color = colors.green },
        { id = "downloader", label = "Telechargeur", color = colors.lightBlue },
        { id = "appcenter", label = "Apps/Jeux", color = colors.lime },
        { id = "bank", label = "Banque", color = colors.green },
        { id = "server", label = config.serverMode and "Serveur ON" or "Serveur", color = config.serverMode and colors.lime or colors.orange },
        { id = "security", label = "Securite", color = colors.orange },
        { id = "settings", label = "Reglages", color = colors.lightBlue },
        { id = "help", label = "Aide", color = colors.yellow },
        { id = "lock", label = "Lock", color = colors.red }
      }
      if #luaApps > 0 then menuItems[#menuItems + 1] = { header = "Lua" } end
      for _, fileName in ipairs(luaApps) do
        menuItems[#menuItems + 1] = { id = "lua:" .. fileName, label = fileName, lua = fileName, color = theme.panel2 }
      end
    end
    local appButtonCount = 0
    for _, item in ipairs(menuItems) do
      if not item.header then appButtonCount = appButtonCount + 1 end
    end

    local menuY = 5
    local listW = math.min(w - 4, 42)
    addButton("apps_menu", 2, 3, listW, 1, appsOpen and ("Apps v (" .. tostring(appButtonCount) .. ")") or ("Apps > (" .. tostring(appButtonCount) .. ")"), theme.selected, colors.black)
    if appsOpen then
      local maxRows = math.min(#menuItems, math.max(1, h - menuY - 1))
      for i = 1, maxRows do
        local item = menuItems[i]
        if item.header then
          fill(2, menuY + i - 1, listW, 1, theme.bg)
          writeAt(3, menuY + i - 1, "[" .. item.header .. "]", theme.warn, theme.bg)
        else
          addButton("menuapp:" .. tostring(i), 2, menuY + i - 1, listW, 1, truncate(item.label, listW - 2), item.color or theme.panel2, colors.black)
        end
      end
    end
    writeAt(2, h - 1, guestMode and "Mode invite: menu Apps limite." or "Menu Apps: systeme + Lua. Clic droit sur Lua = options.", theme.muted, theme.bg)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "lock" end
    if ev[1] == "mouse_click" then
      local mouseButton = ev[2]
      local id = buttonAt(ev[3], ev[4])
      if id == "apps_menu" then
        appsOpen = not appsOpen
      elseif id and id:sub(1, 8) == "menuapp:" then
        local index = tonumber(id:sub(9)) or 0
        local item = menuItems[index]
        if item and item.lua then
          local r
          if mouseButton == 2 then
            r = RUNNER.appOptions(item.lua)
          else
            r = RUNNER.runLuaFile(item.lua)
          end
          if r == "auto_lock" then return "lock" end
        elseif item then
          return item.id
        end
      elseif id then
        return id
      end
    elseif ev[1] == "key" and ev[2] == keys.down then
      if not debugHoldTimer then
        debugHoldTimer = os.startTimer(MAINT.DEBUG_HOLD_SECONDS)
        debugHoldArmed = true
      end
    elseif ev[1] == "key_up" and ev[2] == keys.down then
      debugHoldTimer = nil
      debugHoldArmed = false
    elseif ev[1] == "timer" and ev[2] == debugHoldTimer then
      debugHoldTimer = nil
      if debugHoldArmed then
        debugHoldArmed = false
        local r = MAINT.appDebugMode()
        if r == "auto_lock" then return "lock" end
      end
    end
  end
end

local function composeMail()
  if not isValidSession() then return "lock" end
  local action, fields = inputForm("Nouveau mail", {
    { key = "to", label = "A", maxLen = 32 },
    { key = "subject", label = "Sujet", maxLen = 64 }
  }, {
    { id = "local", label = "Local", color = theme.good, fg = colors.black },
    { id = "network", label = "Network", color = theme.action, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action == "cancel" then return end
  local to = cleanName(fields[1].value)
  local subject = fields[2].value
  if to == "" then messageBox("Erreur", { "Destinataire vide." }); return end
  local editAction, body = readMultiline("Corps du mail", "")
  if editAction == "auto_lock" then return "auto_lock" end
  if editAction ~= "save" then return end

  if action == "local" then
    if not users[to] then messageBox("Erreur", { "Utilisateur local introuvable." }); return end
    local item = {
      from = currentUser.name,
      to = to,
      subject = subject ~= "" and subject or "(sans sujet)",
      body = body,
      read = false,
      network = false,
      time = now()
    }
    addMail(to, "inbox", item)
    addMail(currentUser.name, "sent", {
      from = currentUser.name,
      to = to,
      subject = item.subject,
      body = body,
      read = true,
      network = false,
      time = item.time
    })
    appendAudit("local mail sent to " .. to)
    messageBox("Envoye", { "Mail local envoye a " .. to .. "." })
  elseif action == "network" then
    if not config.networkMail then messageBox("Erreur", { "Mail reseau desactive dans Reglages." }); return end
    if config.networkKey == "" then messageBox("Erreur", { "Definis une cle reseau avant." }); return end
    if not tryOpenRednet() then messageBox("Erreur", { "Aucun modem rednet trouve." }); return end
    local pkg = {
      magic = PROTOCOL,
      from = currentUser.name,
      to = to,
      subject = subject ~= "" and subject or "(sans sujet)",
      body = body,
      time = now(),
      nonce = secureRandomHex(16),
      senderId = os.getComputerID()
    }
    pkg.sig = mailSignature(pkg, config.networkKey)
    rednet.broadcast(pkg, PROTOCOL)
    addMail(currentUser.name, "sent", {
      from = currentUser.name,
      to = to,
      subject = pkg.subject,
      body = body,
      read = true,
      network = true,
      verified = true,
      time = pkg.time
    })
    appendAudit("network mail broadcast to " .. to)
    messageBox("Envoye", { "Mail reseau diffuse.", "Il sera accepte seulement avec la meme cle." })
  end
end

local function viewMailMessage(box, index)
  if not isValidSession() then return "lock" end
  local list = mail.boxes[currentUser.name][box]
  local item = list[index]
  if not item then return end
  if box == "inbox" then
    item.read = true
    saveMail()
  end
  while true do
    resetButtons()
    drawTop("Mail")
    writeAt(2, 4, "De: " .. tostring(item.from), theme.text, theme.bg)
    writeAt(2, 5, "A: " .. tostring(item.to), theme.text, theme.bg)
    writeAt(2, 6, "Sujet: " .. truncate(item.subject, w - 9), theme.text, theme.bg)
    local tag = item.network and (item.verified and "[reseau signe]" or "[reseau non verifie]") or "[local]"
    writeAt(2, 7, tag, item.verified and theme.good or theme.muted, theme.bg)
    fill(2, 9, w - 2, h - 13, theme.field)
    local lines = {}
    for line in (tostring(item.body or "") .. "\n"):gmatch("(.-)\n") do
      if line == "" then
        lines[#lines + 1] = ""
      else
        while #line > w - 4 do
          lines[#lines + 1] = line:sub(1, w - 4)
          line = line:sub(w - 3)
        end
        lines[#lines + 1] = line
      end
    end
    for i = 1, math.min(#lines, h - 13) do
      writeAt(3, 8 + i, truncate(lines[i], w - 4), theme.fieldText, theme.field)
    end
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)
    addButton("delete", 14, h - 2, 10, 1, "Delete", theme.bad, colors.white)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "delete" then
        local yes = messageBox("Confirmer", { "Supprimer ce mail ?" }, {
          { id = "yes", label = "Yes", color = theme.bad, fg = colors.white },
          { id = "no", label = "No", color = theme.action, fg = colors.black }
        })
        if yes == "yes" then
          table.remove(list, index)
          saveMail()
          return
        end
      end
    end
  end
end

local function appMail()
  if not isValidSession() then return "lock" end
  ensureMailbox(currentUser.name)
  local box = "inbox"
  local selected = 1
  while true do
    resetButtons()
    drawTop("Mail")
    addButton("inbox", 2, 3, 10, 1, "Inbox", box == "inbox" and theme.selected or theme.action, colors.black)
    addButton("sent", 14, 3, 10, 1, "Sent", box == "sent" and theme.selected or theme.action, colors.black)
    addButton("compose", 26, 3, 12, 1, "Compose", theme.good, colors.black)
    addButton("back", w - 11, 3, 10, 1, "Back", theme.bad, colors.white)

    local list = mail.boxes[currentUser.name][box]
    local listY = 5
    local maxRows = h - 7
    if #list == 0 then
      centerAt(8, "Aucun mail.", theme.muted, theme.bg)
    end
    for i = 1, math.min(#list, maxRows) do
      local m = list[i]
      local bg = (i == selected) and theme.panel2 or theme.panel
      local unread = (box == "inbox" and not m.read) and "*" or " "
      fill(2, listY + i - 1, w - 3, 1, bg)
      writeAt(3, listY + i - 1, unread .. " " .. truncate(tostring(m.from or m.to), 10) .. " | " .. truncate(m.subject or "", w - 20), theme.fieldText, bg)
      buttons[#buttons + 1] = { id = "row:" .. i, x = 2, y = listY + i - 1, w = w - 3, h = 1 }
    end
    writeAt(2, h - 1, "Clique une ligne pour ouvrir.", theme.muted, theme.bg)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "inbox" then box = "inbox"; selected = 1 end
      if id == "sent" then box = "sent"; selected = 1 end
      if id == "compose" then
        local r = composeMail()
        if r == "auto_lock" then return "auto_lock" end
      end
      if id and id:sub(1, 4) == "row:" then
        selected = tonumber(id:sub(5)) or 1
        local r = viewMailMessage(box, selected)
        if r == "auto_lock" then return "auto_lock" end
      end
    end
  end
end

local function safeFileName(name)
  name = tostring(name or ""):gsub("%s+", "_")
  name = name:gsub("[^A-Za-z0-9_%.%-]", "")
  if name == "" then return nil end
  if name:sub(1, 1) == "." then return nil end
  return name
end

local function readFile(path)
  if not fs.exists(path) then return "" end
  local f = fs.open(path, "r")
  if not f then return "" end
  local data = f.readAll()
  f.close()
  return data or ""
end

local function writeFile(path, data)
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(data or "")
  f.close()
  return true
end

local function readPrivateFile(path)
  if not currentFileKey then return "" end
  return decryptPrivateData(readFile(path), currentFileKey)
end

local function writePrivateFile(path, data)
  if not currentFileKey then return false end
  local ok = writeFile(path, encryptPrivateData(data, currentFileKey))
  if ok and RUNNER then
    if RUNNER.clearCaches then
      RUNNER.clearCaches()
    else
      RUNNER.appCache = {}
      RUNNER.appListCache = {}
    end
  end
  return ok
end

local function reencryptUserFiles(name, oldKey, newKey)
  local dir = FILES_DIR .. "/" .. name
  if not fs.exists(dir) then return end
  for _, fileName in ipairs(fs.list(dir)) do
    local path = dir .. "/" .. fileName
    if not fs.isDir(path) then
      local raw = readFile(path)
      local plain = decryptPrivateData(raw, oldKey)
      writeFile(path, encryptPrivateData(plain, newKey))
    end
  end
end

function RUNNER.copyLib(src)
  local out = {}
  for k, v in pairs(src or {}) do
    if type(v) == "function" or type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
      out[k] = v
    end
  end
  return out
end

function RUNNER.clearCaches()
  RUNNER.appCache = {}
  RUNNER.appListCache = {}
end

function RUNNER.pruneAppCache()
  if type(RUNNER.appCache) ~= "table" then return end
  local entries = {}
  for key, item in pairs(RUNNER.appCache) do
    entries[#entries + 1] = { key = key, at = tonumber(item.at or 0) or 0 }
  end
  table.sort(entries, function(a, b) return a.at > b.at end)
  for i = RUNNER.APP_CACHE_MAX + 1, #entries do
    RUNNER.appCache[entries[i].key] = nil
  end
end

function RUNNER.cachedLuaApp(userName, fileName, path)
  local raw = readFile(path)
  if raw == "" then return nil, nil, nil, "Fichier vide ou illisible." end
  if type(RUNNER.appCache) ~= "table" then RUNNER.appCache = {} end
  local key = tostring(userName or "") .. "|" .. tostring(fileName or "") .. "|" .. tostring(path or "")
  local cached = RUNNER.appCache[key]
  if cached and cached.raw == raw and cached.fileKey == currentFileKey then
    cached.at = now()
    return cached.source, cached.chunk, cached.cashoutSellers
  end

  local source = decryptPrivateData(raw, currentFileKey)
  if source == "" then return nil, nil, nil, "Fichier vide ou illisible." end
  if #source > RUNNER.MAX_SOURCE_LEN then return nil, nil, nil, "Programme trop gros." end
  if source:sub(1, 4) == "\27Lua" then return nil, nil, nil, "Bytecode Lua refuse." end

  local chunk, err
  if loadstring then
    chunk, err = loadstring(source, "@" .. tostring(fileName))
  elseif load then
    chunk, err = load(source, "@" .. tostring(fileName), "t", {})
  else
    return nil, nil, nil, "loadstring indisponible."
  end
  if not chunk then return nil, nil, nil, tostring(err) end

  local cashoutSellers = BANK.cashoutSellersFromSource and BANK.cashoutSellersFromSource(source) or {}
  RUNNER.appCache[key] = {
    raw = raw,
    fileKey = currentFileKey,
    source = source,
    chunk = chunk,
    cashoutSellers = cashoutSellers,
    at = now()
  }
  RUNNER.pruneAppCache()
  return source, chunk, cashoutSellers
end

function RUNNER.blockedApi(name)
  return setmetatable({}, {
    __index = function(_, key)
      return function()
        appendAudit("sandbox blocked API: " .. tostring(name) .. "." .. tostring(key))
        error("API bloquee par SecureClickOS: " .. tostring(name) .. "." .. tostring(key), 2)
      end
    end,
    __newindex = function()
      error("API bloquee par SecureClickOS: " .. tostring(name), 2)
    end
  })
end

function RUNNER.safePath(base, path)
  path = tostring(path or ""):gsub("\\", "/")
  if path:sub(1, 1) == "/" then path = path:sub(2) end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then return nil end
    if part ~= "." and part ~= "" then
      part = part:gsub("[^A-Za-z0-9_%.%-]", "_")
      if part == "" or part == ".." then return nil end
      parts[#parts + 1] = part
    end
  end
  if #parts == 0 then return base end
  return base .. "/" .. table.concat(parts, "/")
end

function RUNNER.makeFs(base)
  ensureDir(base)
  local api = {}
  api.exists = function(path)
    local p = RUNNER.safePath(base, path)
    return p and fs.exists(p) or false
  end
  api.isDir = function(path)
    local p = RUNNER.safePath(base, path)
    return p and fs.isDir(p) or false
  end
  api.list = function(path)
    local p = RUNNER.safePath(base, path)
    if not p or not fs.exists(p) or not fs.isDir(p) then return {} end
    return fs.list(p)
  end
  api.makeDir = function(path)
    local p = RUNNER.safePath(base, path)
    if not p or p == base then return false end
    fs.makeDir(p)
    return true
  end
  api.delete = function(path)
    local p = RUNNER.safePath(base, path)
    if not p or p == base then return false end
    if fs.exists(p) then fs.delete(p) end
    return true
  end
  api.getSize = function(path)
    local p = RUNNER.safePath(base, path)
    if not p or not fs.exists(p) then return 0 end
    return fs.getSize(p)
  end
  api.combine = function(a, b) return fs.combine(tostring(a or ""), tostring(b or "")) end
  api.getName = function(path) return fs.getName(tostring(path or "")) end
  api.getDir = function(path) return fs.getDir(tostring(path or "")) end
  api.isReadOnly = function(path) return false end
  api.getDrive = function(path) return "sandbox" end
  api.getFreeSpace = function(path) return 1048576 end
  api.getCapacity = function(path) return 1048576 end
  api.attributes = function(path)
    local p = RUNNER.safePath(base, path)
    if not p or not fs.exists(p) then return nil end
    if fs.attributes then return fs.attributes(p) end
    return { size = fs.getSize(p), isDir = fs.isDir(p), isReadOnly = false }
  end
  api.copy = function(from, to)
    local src = RUNNER.safePath(base, from)
    local dst = RUNNER.safePath(base, to)
    if not src or not dst or src == base or dst == base then error("Chemin sandbox refuse.", 2) end
    if fs.isDir(src) then error("Copie dossier refusee.", 2) end
    local parent = fs.getDir(dst)
    if parent and parent ~= "" then ensureDir(parent) end
    fs.copy(src, dst)
    return true
  end
  api.move = function(from, to)
    api.copy(from, to)
    api.delete(from)
    return true
  end
  api.find = function(pattern)
    pattern = tostring(pattern or "*")
    if pattern:find("%.%.", 1, true) then return {} end
    local realPattern = RUNNER.safePath(base, pattern)
    if not realPattern or not fs.find then return {} end
    local found = fs.find(realPattern)
    local out = {}
    for _, p in ipairs(found) do
      if p:sub(1, #base) == base then
        local rel = p:sub(#base + 2)
        out[#out + 1] = rel ~= "" and rel or "."
      end
    end
    return out
  end
  api.open = function(path, mode)
    mode = tostring(mode or "r")
    if mode ~= "r" and mode ~= "w" and mode ~= "a" then error("Mode fs refuse.", 2) end
    local p = RUNNER.safePath(base, path)
    if not p or p == base then error("Chemin sandbox refuse.", 2) end
    if mode ~= "r" then
      local parent = fs.getDir(p)
      if parent and parent ~= "" then ensureDir(parent) end
    end
    local f = fs.open(p, mode)
    if not f then return nil end
    local written = mode == "a" and (fs.exists(p) and fs.getSize(p) or 0) or 0
    local handle = {}
    handle.close = function() return f.close() end
    handle.readAll = function() if f.readAll then return f.readAll() end return nil end
    handle.readLine = function() if f.readLine then return f.readLine() end return nil end
    handle.read = function(n) if f.read then return f.read(n) end return nil end
    handle.write = function(data)
      if mode == "r" then error("Fichier ouvert en lecture.", 2) end
      data = tostring(data or "")
      written = written + #data
      if written > RUNNER.MAX_SAVE_LEN then error("Sauvegarde sandbox trop grande.", 2) end
      return f.write(data)
    end
    handle.writeLine = function(data)
      if mode == "r" then error("Fichier ouvert en lecture.", 2) end
      data = tostring(data or "")
      written = written + #data + 1
      if written > RUNNER.MAX_SAVE_LEN then error("Sauvegarde sandbox trop grande.", 2) end
      return f.writeLine(data)
    end
    handle.flush = function() if f.flush then return f.flush() end end
    return handle
  end
  return api
end

function RUNNER.wrapTerm(t)
  local api = {}
  local names = {
    "write", "scroll", "clear", "clearLine", "getCursorPos", "setCursorPos",
    "setCursorBlink", "isColor", "isColour", "getSize", "blit",
    "setTextColor", "setTextColour", "getTextColor", "getTextColour",
    "setBackgroundColor", "setBackgroundColour", "getBackgroundColor", "getBackgroundColour",
    "getPaletteColor", "getPaletteColour", "setPaletteColor", "setPaletteColour"
  }
  for _, name in ipairs(names) do
    if type(t[name]) == "function" then
      api[name] = function(...) return t[name](...) end
    end
  end
  api.current = function() return t end
  api.native = function() return t end
  api.redirect = function(target)
    if target then t = target end
    return api
  end
  return api
end

function RUNNER.makeWindowApi(appTerm)
  local api = {}
  if not window or not window.create then return api end
  api.create = function(parent, x, y, width, height, visible)
    if parent ~= appTerm then parent = appTerm end
    return window.create(parent, x, y, width, height, visible ~= false)
  end
  if window.restoreCursor then api.restoreCursor = window.restoreCursor end
  return api
end

function RUNNER.makePeripheralApi()
  local api = {}
  if not peripheral then return RUNNER.blockedApi("peripheral") end
  local function allowed(name)
    local ptype = peripheral.getType(name)
    return ptype and ptype ~= "drive"
  end
  api.isPresent = function(name) return allowed(name) and peripheral.isPresent(name) or false end
  api.getType = function(name) if allowed(name) then return peripheral.getType(name) end return nil end
  api.getNames = function()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
      if allowed(name) then out[#out + 1] = name end
    end
    return out
  end
  api.wrap = function(name)
    if not allowed(name) then return nil end
    return peripheral.wrap(name)
  end
  api.call = function(name, method, ...)
    if not allowed(name) then error("Peripheral bloque par SecureClickOS.", 2) end
    return peripheral.call(name, method, ...)
  end
  api.find = function(ptype, filter)
    local out = {}
    for _, name in ipairs(api.getNames()) do
      if api.getType(name) == ptype then
        local wrapped = api.wrap(name)
        if not filter or filter(name, wrapped) then out[#out + 1] = wrapped end
      end
    end
    return unpack(out)
  end
  return api
end

function RUNNER.newLine(t)
  local _, y = t.getCursorPos()
  local _, th = t.getSize()
  if y >= th then
    t.scroll(1)
    t.setCursorPos(1, th)
  else
    t.setCursorPos(1, y + 1)
  end
end

function RUNNER.makeOs(watchdog)
  local api = {}
  api.clock = os.clock
  api.time = os.time
  api.day = os.day
  api.epoch = os.epoch
  api.startTimer = os.startTimer
  api.cancelTimer = os.cancelTimer
  api.queueEvent = os.queueEvent
  api.getComputerID = os.getComputerID
  api.getComputerLabel = os.getComputerLabel
  api.setComputerLabel = function() error("Label computer bloque par SecureClickOS.", 2) end
  api.version = os.version
  api.pullEvent = function(filter)
    while true do
      local ev = { os.pullEventRaw() }
      if ev[1] == "terminate" then error("Sandbox stoppe par Ctrl+T.", 2) end
      if ev[1] == "rednet_message" and ev[4] == BANK.PROTOCOL and BANK.backgroundHandle and BANK.backgroundHandle(ev[2], ev[3]) then
        if watchdog then watchdog.steps = 0 end
      else
        if watchdog then watchdog.steps = 0 end
        if not filter or ev[1] == filter then return unpack(ev) end
      end
    end
  end
  api.pullEventRaw = api.pullEvent
  api.reboot = function() error("Reboot bloque par SecureClickOS.", 2) end
  api.shutdown = function() error("Shutdown bloque par SecureClickOS.", 2) end
  return api
end

function RUNNER.makeBankApi(appName, watchdog, appCashoutSellers)
  local api = {}
  api.configured = function()
    return BANK.validPayProfile(config.bankPayProfile)
  end
  api.profile = function()
    if not BANK.validPayProfile(config.bankPayProfile) then return nil end
    return {
      bankId = tostring(config.bankPayProfile.bankId or ""),
      user = tostring(config.bankPayProfile.user or ""),
      auth = tostring(config.bankPayProfile.auth or ""),
      computerId = tonumber(config.bankPayProfile.computerId or 0)
    }
  end
  api.pay = function(to, amount, label)
    if watchdog then
      watchdog.suspended = true
      watchdog.steps = 0
    end
    local ok, result = pcall(BANK.sandboxPay, tostring(appName or "app"), to, amount, label)
    if watchdog then
      watchdog.suspended = false
      watchdog.steps = 0
    end
    if ok then return result end
    return { ok = false, error = tostring(result or "paiement bloque") }
  end
  api.cashout = function(fromAccount, amount, label)
    if watchdog then
      watchdog.suspended = true
      watchdog.steps = 0
    end
    local ok, result = pcall(BANK.sandboxCashout, tostring(appName or "app"), appCashoutSellers or {}, fromAccount, amount, label)
    if watchdog then
      watchdog.suspended = false
      watchdog.steps = 0
    end
    if ok then return result end
    return { ok = false, error = tostring(result or "cashout bloque") }
  end
  return api
end

function RUNNER.makeGpsApi(watchdog)
  local api = {}
  if not gps or type(gps.locate) ~= "function" then return RUNNER.blockedApi("gps") end
  api.CHANNEL_GPS = gps.CHANNEL_GPS
  api.locate = function(timeout, debugFlag)
    if watchdog then
      watchdog.suspended = true
      watchdog.steps = 0
    end
    local limit = tonumber(timeout) or 2
    if limit < 0 then limit = 0 end
    if limit > 10 then limit = 10 end
    local ok, x, y, z = pcall(gps.locate, limit, debugFlag == true)
    if watchdog then
      watchdog.suspended = false
      watchdog.steps = 0
    end
    if ok then return x, y, z end
    return nil
  end
  return api
end

function RUNNER.makeEnv(appTerm, appFs, watchdog, trusted, appName, appCashoutSellers)
  local termApi = RUNNER.wrapTerm(appTerm)
  local osApi = RUNNER.makeOs(watchdog)
  local env = {
    _VERSION = _VERSION,
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    unpack = unpack,
    coroutine = RUNNER.copyLib(coroutine),
    math = RUNNER.copyLib(math),
    string = RUNNER.copyLib(string),
    table = RUNNER.copyLib(table),
    bit32 = RUNNER.copyLib(bit32),
    colors = RUNNER.copyLib(colors),
    colours = RUNNER.copyLib(colours or colors),
    keys = RUNNER.copyLib(keys),
    term = termApi,
    fs = appFs,
    os = osApi,
    window = RUNNER.makeWindowApi(appTerm),
    bank = RUNNER.makeBankApi(appName, watchdog, appCashoutSellers),
    parallel = RUNNER.copyLib(parallel),
    paintutils = RUNNER.copyLib(paintutils),
    vector = RUNNER.copyLib(vector),
    shell = RUNNER.blockedApi("shell"),
    rednet = rednet and RUNNER.copyLib(rednet) or RUNNER.blockedApi("rednet"),
    http = (trusted and http) and RUNNER.copyLib(http) or RUNNER.blockedApi("http"),
    peripheral = trusted and RUNNER.makePeripheralApi() or RUNNER.blockedApi("peripheral"),
    disk = RUNNER.blockedApi("disk"),
    settings = RUNNER.blockedApi("settings"),
    gps = trusted and gps and RUNNER.copyLib(gps) or RUNNER.makeGpsApi(watchdog),
    commands = RUNNER.blockedApi("commands"),
    debug = RUNNER.blockedApi("debug"),
    io = RUNNER.blockedApi("io"),
    package = RUNNER.blockedApi("package")
  }
  env.require = function()
    appendAudit("sandbox blocked API: require")
    error("API bloquee par SecureClickOS: require", 2)
  end
  env.print = function(...)
    local out = {}
    for i = 1, select("#", ...) do out[#out + 1] = tostring(select(i, ...)) end
    termApi.write(table.concat(out, "\t"))
    RUNNER.newLine(termApi)
  end
  env.write = function(text) termApi.write(tostring(text or "")) end
  env.sleep = function(seconds)
    local id = osApi.startTimer(tonumber(seconds) or 0)
    while true do
      local ev, timerId = osApi.pullEvent("timer")
      if ev == "timer" and timerId == id then return end
    end
  end
  osApi.sleep = env.sleep
  env.loadstring = function(code, chunkName)
    if not loadstring then return nil, "loadstring indisponible" end
    code = tostring(code or "")
    if #code > RUNNER.MAX_SOURCE_LEN then return nil, "code trop gros" end
    local fn, err = loadstring(code, tostring(chunkName or "sandbox"))
    if not fn then return nil, err end
    if setfenv then setfenv(fn, env) end
    return fn
  end
  env.load = env.loadstring
  env.loadfile = function(path)
    local f = appFs.open(path, "r")
    if not f then return nil, "fichier introuvable" end
    local data = f.readAll() or ""
    f.close()
    return env.loadstring(data, "@" .. tostring(path))
  end
  env.dofile = function(path)
    local fn, err = env.loadfile(path)
    if not fn then error(err, 2) end
    return fn()
  end
  env.read = function()
    local text = ""
    while true do
      local ev, value = osApi.pullEvent()
      if ev == "char" then
        text = text .. tostring(value or "")
        termApi.write(tostring(value or ""))
      elseif ev == "key" and value == keys.backspace then
        if #text > 0 then
          local x, y = termApi.getCursorPos()
          text = text:sub(1, -2)
          termApi.setCursorPos(math.max(1, x - 1), y)
          termApi.write(" ")
          termApi.setCursorPos(math.max(1, x - 1), y)
        end
      elseif ev == "key" and value == keys.enter then
        RUNNER.newLine(termApi)
        return text
      end
    end
  end
  if textutils then
    env.textutils = {
      serialize = textutils.serialize,
      unserialize = textutils.unserialize,
      serialise = textutils.serialise,
      unserialise = textutils.unserialise,
      serializeJSON = textutils.serializeJSON,
      unserializeJSON = textutils.unserializeJSON,
      urlEncode = textutils.urlEncode,
      formatTime = textutils.formatTime
    }
  end
  env._G = env
  return env
end

function RUNNER.listLuaApps(userName)
  local dir = FILES_DIR .. "/" .. tostring(userName or "")
  local cacheKey = tostring(userName or "")
  if type(RUNNER.appListCache) ~= "table" then RUNNER.appListCache = {} end
  local cached = RUNNER.appListCache[cacheKey]
  if cached and now() - (tonumber(cached.at or 0) or 0) <= RUNNER.APP_LIST_CACHE_SECONDS then
    local copy = {}
    for i, name in ipairs(cached.apps or {}) do copy[i] = name end
    return copy
  end
  local out = {}
  local hidden = RUNNER.hiddenApps(userName)
  if not fs.exists(dir) then
    RUNNER.appListCache[cacheKey] = { at = now(), apps = out }
    return out
  end
  for _, name in ipairs(fs.list(dir)) do
    local path = dir .. "/" .. name
    if not fs.isDir(path) and tostring(name):lower():match("%.lua$") and not hidden[name] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  RUNNER.appListCache[cacheKey] = { at = now(), apps = out }
  return out
end

function RUNNER.hiddenApps(userName)
  userName = tostring(userName or "")
  if type(config.hiddenLuaApps) ~= "table" then config.hiddenLuaApps = {} end
  if type(config.hiddenLuaApps[userName]) ~= "table" then config.hiddenLuaApps[userName] = {} end
  return config.hiddenLuaApps[userName]
end

function RUNNER.hideLuaApp(userName, fileName)
  local hidden = RUNNER.hiddenApps(userName)
  hidden[tostring(fileName or "")] = true
  saveConfig()
  RUNNER.appListCache = {}
  appendAudit("app hidden from desktop: " .. tostring(fileName or ""))
end

function RUNNER.showLuaAppLocation(fileName)
  local privatePath = FILES_DIR .. "/" .. currentUser.name .. "/" .. tostring(fileName or "")
  local appName = safeFileName((tostring(fileName or ""):gsub("%.lua$", ""))) or "app"
  local dataPath = RUNNER.ROOT .. "/" .. currentUser.name .. "/" .. appName
  messageBox("Ou est le fichier", {
    "Nom: " .. tostring(fileName or ""),
    "Fichier prive:",
    privatePath,
    "Donnees app:",
    dataPath
  })
end

function RUNNER.requestTrustedAccess(fileName)
  if not isAdmin() then
    messageBox("Admin app", { "Admin seulement." })
    return false
  end
  local action, fields = inputForm("Admin: " .. truncate(fileName, 20), {
    { key = "debug", label = "Code debug", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "ok", label = "Launch", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return false end

  local debugCode = fields[1].value
  local sealCode = fields[2].value
  fields[1].value, fields[2].value = "", ""
  local debugOk = MAINT.verifyDebugCode(debugCode)
  local sealOk = false
  if type(integrity) == "table" and integrity.sealSalt and integrity.sealMac then
    local mac = makeIntegrityMac(sealCode, integrity.sealSalt, integrity.startupHash, integrity.usersHash, integrity.configHash)
    sealOk = constantTimeEquals(mac, integrity.sealMac)
  end
  debugCode, sealCode = nil, nil
  safeCollectGarbage()

  if not debugOk or not sealOk then
    appendAudit("trusted app refused: " .. tostring(fileName or ""))
    messageBox("Refuse", { "Code debug ou code integrite invalide." })
    return false
  end
  appendAudit("trusted app allowed: " .. tostring(fileName or ""))
  return true
end

function RUNNER.appOptions(fileName)
  while true do
    if not isValidSession() then return "auto_lock" end
    resetButtons()
    drawTop("App: " .. truncate(fileName, w - 8))
    writeAt(2, 5, "Options sandbox.", theme.text, theme.bg)
    writeAt(2, 7, "Admin demande code debug + code integrite.", theme.warn, theme.bg)
    addButton("admin", 3, 10, 18, 2, "Admin", theme.warn, colors.black)
    addButton("where", 25, 10, 18, 2, "Ou est", theme.action, colors.black)
    addButton("hide", 3, 14, 18, 2, "Enlever", theme.bad, colors.white)
    addButton("back", 25, 14, 18, 2, "Back", theme.panel2, colors.black)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "where" then
        RUNNER.showLuaAppLocation(fileName)
      elseif id == "hide" then
        RUNNER.hideLuaApp(currentUser.name, fileName)
        messageBox("Apps", { "Retire du menu principal.", "Le fichier reste dans Fichiers." })
        return
      elseif id == "admin" then
        local ok = RUNNER.requestTrustedAccess(fileName)
        if ok == "auto_lock" then return "auto_lock" end
        if ok then return RUNNER.runLuaFile(fileName, true) end
      end
    end
  end
end

function RUNNER.runLuaFile(fileName, trusted)
  if not isValidSession() then return "auto_lock" end
  trusted = trusted == true
  if not tostring(fileName or ""):lower():match("%.lua$") then
    messageBox("Sandbox", { "Selectionne un fichier .lua." })
    return
  end
  local dir = FILES_DIR .. "/" .. currentUser.name
  local path = dir .. "/" .. fileName
  local source, chunk, appCashoutSellers, err = RUNNER.cachedLuaApp(currentUser.name, fileName, path)
  if not source or not chunk then
    messageBox("Sandbox", { truncate(tostring(err or "Erreur Lua"), w - 4) })
    return
  end

  local appName = safeFileName((tostring(fileName):gsub("%.lua$", ""))) or "app"
  appCashoutSellers = appCashoutSellers or {}
  local appRoot = RUNNER.ROOT .. "/" .. currentUser.name .. "/" .. appName
  ensureDir(RUNNER.ROOT)
  ensureDir(RUNNER.ROOT .. "/" .. currentUser.name)
  ensureDir(appRoot)

  local appTerm = term
  if window and window.create and term.current then
    appTerm = window.create(term.current(), 1, 1, w, h, true)
  end
  if appTerm.setBackgroundColor then appTerm.setBackgroundColor(colors.black) end
  if appTerm.setTextColor then appTerm.setTextColor(colors.white) end
  appTerm.clear()
  appTerm.setCursorPos(1, 1)
  appTerm.write((trusted and "Sandbox admin: " or "Sandbox: ") .. tostring(fileName))
  RUNNER.newLine(appTerm)
  appTerm.write("Ctrl+T = quitter l'app")
  RUNNER.newLine(appTerm)
  RUNNER.newLine(appTerm)

  local watchdog = { steps = 0 }
  local env = RUNNER.makeEnv(appTerm, RUNNER.makeFs(appRoot), watchdog, trusted, fileName, appCashoutSellers)
  if setfenv then setfenv(chunk, env) end

  local hookEnabled = debug and debug.sethook
  if hookEnabled then
    pcall(debug.sethook, function()
      if watchdog.suspended then
        watchdog.steps = 0
        return
      end
      watchdog.steps = watchdog.steps + 1000
      local maxSteps = trusted and RUNNER.TRUSTED_MAX_STEPS or RUNNER.MAX_STEPS
      if watchdog.steps > maxSteps then error("Sandbox: trop d'instructions sans pause.", 2) end
    end, "", 1000)
  end
  appendAudit((trusted and "trusted sandbox start: " or "sandbox start: ") .. tostring(fileName))
  local ok, runErr = pcall(chunk)
  if hookEnabled then pcall(debug.sethook) end
  safeCollectGarbage()
  appendAudit((trusted and "trusted sandbox stop: " or "sandbox stop: ") .. tostring(fileName) .. " ok=" .. tostring(ok))

  if ok then
    messageBox("Sandbox", { "Application terminee." })
  else
    messageBox("Erreur sandbox", { truncate(tostring(runErr), w - 4) })
  end
end

function SERVER.startsWith(text, prefix)
  text = tostring(text or "")
  prefix = tostring(prefix or "")
  return text:sub(1, #prefix) == prefix
end

function SERVER.normalizePath(path)
  path = tostring(path or ""):gsub("\\", "/")
  if path == "" then path = "." end
  local raw = path
  if raw:sub(1, 1) == "/" then
    raw = raw:sub(2)
  else
    raw = SERVER.ROOT:gsub("^/", "") .. "/" .. raw
  end
  local parts = {}
  for part in raw:gmatch("[^/]+") do
    if part == ".." then return nil end
    if part ~= "." and part ~= "" then
      part = part:gsub("[^A-Za-z0-9_%.%-%s]", "_")
      if part == "" or part == ".." then return nil end
      parts[#parts + 1] = part
    end
  end
  if #parts == 0 then return "/" end
  return "/" .. table.concat(parts, "/")
end

function SERVER.isDiskPath(path)
  path = tostring(path or "")
  return path == "/disk"
    or path:match("^/disk%d+$") ~= nil
    or path:match("^/disk%d*/") ~= nil
end

function SERVER.isSecretPath(path)
  path = tostring(path or "")
  return path == STARTUP_PATH
    or path == MAINT.STARTUP_UPDATE_BACKUP_FILE
    or path == ROOT
    or SERVER.startsWith(path, ROOT .. "/")
    or path == RECOVERY_DIR
    or SERVER.startsWith(path, RECOVERY_DIR .. "/")
end

function SERVER.isWriteBlockedPath(path)
  path = tostring(path or "")
  return path == "/"
    or SERVER.isDiskPath(path)
    or SERVER.isSecretPath(path)
    or path == "/rom"
    or SERVER.startsWith(path, "/rom/")
end

function SERVER.guardPath(path, writing)
  local real = SERVER.normalizePath(path)
  if not real then return nil end
  if SERVER.isDiskPath(real) or SERVER.isSecretPath(real) then return nil end
  if writing and SERVER.isWriteBlockedPath(real) then return nil end
  return real
end

function SERVER.makeFs()
  ensureDir(SERVER.ROOT)
  local api = {}
  api.exists = function(path)
    local p = SERVER.guardPath(path, false)
    return p and fs.exists(p) or false
  end
  api.isDir = function(path)
    local p = SERVER.guardPath(path, false)
    return p and fs.isDir(p) or false
  end
  api.list = function(path)
    local p = SERVER.guardPath(path, false)
    if not p or not fs.exists(p) or not fs.isDir(p) then return {} end
    local out = {}
    for _, name in ipairs(fs.list(p)) do
      local child = p == "/" and ("/" .. name) or (p .. "/" .. name)
      if not SERVER.isDiskPath(child) and not SERVER.isSecretPath(child) then
        out[#out + 1] = name
      end
    end
    return out
  end
  api.makeDir = function(path)
    local p = SERVER.guardPath(path, true)
    if not p then return false end
    fs.makeDir(p)
    return true
  end
  api.delete = function(path)
    local p = SERVER.guardPath(path, true)
    if not p then return false end
    if fs.exists(p) then fs.delete(p) end
    return true
  end
  api.getSize = function(path)
    local p = SERVER.guardPath(path, false)
    if not p or not fs.exists(p) then return 0 end
    return fs.getSize(p)
  end
  api.combine = function(a, b) return fs.combine(tostring(a or ""), tostring(b or "")) end
  api.getName = function(path) return fs.getName(tostring(path or "")) end
  api.getDir = function(path) return fs.getDir(tostring(path or "")) end
  api.isReadOnly = function(path)
    local p = SERVER.normalizePath(path)
    if not p then return true end
    if SERVER.isWriteBlockedPath(p) then return true end
    return fs.isReadOnly and fs.isReadOnly(p) or false
  end
  api.getDrive = function(path)
    local p = SERVER.guardPath(path, false)
    if not p then return nil end
    return fs.getDrive and fs.getDrive(p) or "hdd"
  end
  api.getFreeSpace = function(path)
    local p = SERVER.guardPath(path or SERVER.ROOT, false)
    if not p then return 0 end
    return fs.getFreeSpace and fs.getFreeSpace(p) or 1048576
  end
  api.getCapacity = function(path)
    local p = SERVER.guardPath(path or SERVER.ROOT, false)
    if not p then return 0 end
    return fs.getCapacity and fs.getCapacity(p) or 1048576
  end
  api.attributes = function(path)
    local p = SERVER.guardPath(path, false)
    if not p or not fs.exists(p) then return nil end
    if fs.attributes then return fs.attributes(p) end
    return { size = fs.getSize(p), isDir = fs.isDir(p), isReadOnly = api.isReadOnly(p) }
  end
  api.copy = function(from, to)
    local src = SERVER.guardPath(from, false)
    local dst = SERVER.guardPath(to, true)
    if not src or not dst then error("Chemin serveur refuse.", 2) end
    if fs.isDir(src) then error("Copie dossier refusee.", 2) end
    local parent = fs.getDir(dst)
    if parent and parent ~= "" then ensureDir(parent) end
    fs.copy(src, dst)
    return true
  end
  api.move = function(from, to)
    local src = SERVER.guardPath(from, true)
    local dst = SERVER.guardPath(to, true)
    if not src or not dst then error("Chemin serveur refuse.", 2) end
    api.copy(src, dst)
    api.delete(src)
    return true
  end
  api.find = function(pattern)
    pattern = tostring(pattern or "*"):gsub("\\", "/")
    if pattern:find("%.%.", 1, true) or not fs.find then return {} end
    local realPattern = pattern
    if realPattern:sub(1, 1) ~= "/" then
      realPattern = SERVER.ROOT .. "/" .. realPattern
    end
    local found = fs.find(realPattern)
    local out = {}
    for _, path in ipairs(found) do
      local normalized = SERVER.normalizePath("/" .. tostring(path):gsub("^/", ""))
      if normalized and not SERVER.isDiskPath(normalized) and not SERVER.isSecretPath(normalized) then
        out[#out + 1] = normalized
      end
    end
    return out
  end
  api.open = function(path, mode)
    mode = tostring(mode or "r")
    local kind = mode:sub(1, 1)
    if kind ~= "r" and kind ~= "w" and kind ~= "a" then error("Mode fs refuse.", 2) end
    local writing = kind ~= "r"
    local p = SERVER.guardPath(path, writing)
    if not p then error("Chemin serveur refuse.", 2) end
    if writing then
      local parent = fs.getDir(p)
      if parent and parent ~= "" then ensureDir(parent) end
    end
    local f = fs.open(p, mode)
    if not f then return nil end
    local written = kind == "a" and (fs.exists(p) and fs.getSize(p) or 0) or 0
    local handle = {}
    handle.close = function() return f.close() end
    handle.readAll = function() if f.readAll then return f.readAll() end return nil end
    handle.readLine = function() if f.readLine then return f.readLine() end return nil end
    handle.read = function(n) if f.read then return f.read(n) end return nil end
    handle.write = function(data)
      if not writing then error("Fichier ouvert en lecture.", 2) end
      data = tostring(data or "")
      written = written + #data
      if written > SERVER.MAX_SAVE_LEN then error("Sauvegarde serveur trop grande.", 2) end
      return f.write(data)
    end
    handle.writeLine = function(data)
      if not writing then error("Fichier ouvert en lecture.", 2) end
      data = tostring(data or "")
      written = written + #data + 1
      if written > SERVER.MAX_SAVE_LEN then error("Sauvegarde serveur trop grande.", 2) end
      return f.writeLine(data)
    end
    handle.flush = function() if f.flush then return f.flush() end end
    return handle
  end
  return api
end

function SERVER.makeEnv(appTerm, appFs, watchdog, appName)
  local env = RUNNER.makeEnv(appTerm, appFs, watchdog, true, appName)
  env.loadstring = function(code, chunkName)
    if not loadstring then return nil, "loadstring indisponible" end
    code = tostring(code or "")
    if #code > SERVER.MAX_SOURCE_LEN then return nil, "code trop gros" end
    local fn, err = loadstring(code, tostring(chunkName or "server"))
    if not fn then return nil, err end
    if setfenv then setfenv(fn, env) end
    return fn
  end
  env.load = env.loadstring
  env.loadfile = function(path)
    local f = appFs.open(path, "r")
    if not f then return nil, "fichier introuvable" end
    local data = f.readAll() or ""
    f.close()
    return env.loadstring(data, "@" .. tostring(path))
  end
  env.dofile = function(path)
    local fn, err = env.loadfile(path)
    if not fn then error(err, 2) end
    return fn()
  end
  env._G = env
  return env
end

function SERVER.safeLuaName(name)
  local clean = safeFileName(name)
  if not clean then return nil end
  if not clean:lower():match("%.lua$") then clean = clean .. ".lua" end
  return clean
end

function SERVER.filePath(fileName)
  local clean = SERVER.safeLuaName(fileName)
  if not clean then return nil, nil end
  return SERVER.ROOT .. "/" .. clean, clean
end

function SERVER.listLuaFiles()
  ensureDir(SERVER.ROOT)
  local out = {}
  for _, name in ipairs(fs.list(SERVER.ROOT)) do
    local path = SERVER.ROOT .. "/" .. name
    if not fs.isDir(path) and tostring(name):lower():match("%.lua$") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

function SERVER.verifyIntegrityCode(sealCode)
  if #tostring(sealCode or "") < MAINT.INTEGRITY_MIN then return false end
  if type(integrity) ~= "table" or not integrity.sealSalt or not integrity.sealMac then return false end
  local mac = makeIntegrityMac(sealCode, integrity.sealSalt, integrity.startupHash, integrity.usersHash, integrity.configHash)
  return constantTimeEquals(mac, integrity.sealMac)
end

function SERVER.activateMode()
  if not isAdmin() then
    messageBox("Serveur", { "Admin seulement." })
    return false
  end
  local nextStep = messageBox("Mode serveur", {
    "Attention: activation irreversible.",
    "Apres activation, pas de bouton retour.",
    "Les scripts auront un fs large.",
    "Mais l'OS, les disques et /secureos restent bloques."
  }, {
    { id = "continue", label = "Continuer", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if nextStep ~= "continue" then return false end

  local action, fields = inputForm("Activer serveur", {
    { key = "admin", label = "Code admin", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "confirm", label = "Tape SERVEUR", maxLen = 16 }
  }, {
    { id = "ok", label = "Activer", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return false end

  local adminCode = fields[1].value
  local sealCode = fields[2].value
  local confirm = fields[3].value
  fields[1].value, fields[2].value, fields[3].value = "", "", ""
  local ok, user = verifyPassword(currentUser.name, adminCode)
  local sealOk = SERVER.verifyIntegrityCode(sealCode)
  adminCode = nil
  safeCollectGarbage()

  if ok and user.role == "admin" and sealOk and confirm == SERVER.CONFIRM then
    config.serverMode = true
    config.serverActivatedAt = now()
    config.serverActivatedBy = currentUser.name
    saveConfig()
    local sealed, err = sealSystem("server mode activated", currentUser.name, sealCode)
    sealCode = nil
    safeCollectGarbage()
    if not sealed then
      config.serverMode = false
      config.serverActivatedAt = nil
      config.serverActivatedBy = ""
      saveConfig()
      messageBox("Erreur", { err or "Sceau serveur refuse." })
      return false
    end
    ensureDir(SERVER.ROOT)
    appendAudit("server mode activated")
    messageBox("Serveur ON", {
      "Mode serveur active.",
      "Il reste actif pour toujours dans cette installation."
    })
    return true
  end

  sealCode = nil
  safeCollectGarbage()
  appendAudit("server mode activation refused")
  messageBox("Refuse", {
    "Code admin, code integrite ou confirmation invalide.",
    "Il faut taper exactement: " .. SERVER.CONFIRM
  })
  return false
end

function SERVER.newLuaFile()
  local action, fields = inputForm("Nouveau serveur Lua", {
    { key = "name", label = "Nom", maxLen = 32 }
  }, {
    { id = "ok", label = "Create", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return end
  local path, clean = SERVER.filePath(fields[1].value)
  if not path then messageBox("Erreur", { "Nom invalide." }); return end
  ensureDir(SERVER.ROOT)
  if fs.exists(path) then
    messageBox("Erreur", { "Fichier deja present." })
    return
  end
  writeFile(path, "-- Script serveur SecureClickOS\nprint('Serveur pret')\n")
  appendAudit("server lua created: " .. clean)
  return SERVER.editLuaFile(clean)
end

function SERVER.editLuaFile(fileName)
  local path, clean = SERVER.filePath(fileName)
  if not path then messageBox("Erreur", { "Nom invalide." }); return end
  ensureDir(SERVER.ROOT)
  local source = readFile(path)
  if #source > SERVER.MAX_TEXT_LEN then
    messageBox("Trop gros", { "Editeur serveur max: " .. tostring(SERVER.MAX_TEXT_LEN) .. " caracteres." })
    return
  end
  local action, content = readMultiline("Srv edit: " .. clean, source, SERVER.MAX_TEXT_LEN)
  if action == "auto_lock" then return "auto_lock" end
  if action == "save" then
    if writeFile(path, content) then
      appendAudit("server lua saved: " .. clean)
      messageBox("Sauve", { clean .. " enregistre dans " .. SERVER.ROOT })
    else
      messageBox("Erreur", { "Impossible d'ecrire le fichier." })
    end
  end
end

function SERVER.runLuaFile(fileName)
  if not isValidSession() then return "auto_lock" end
  if not config.serverMode then messageBox("Serveur", { "Mode serveur inactif." }); return end
  local path, clean = SERVER.filePath(fileName)
  if not path then messageBox("Erreur", { "Nom invalide." }); return end
  local source = readFile(path)
  if source == "" then messageBox("Serveur", { "Fichier vide ou illisible." }); return end
  if #source > SERVER.MAX_SOURCE_LEN then messageBox("Serveur", { "Programme serveur trop gros." }); return end
  if source:sub(1, 4) == "\27Lua" then messageBox("Serveur", { "Bytecode Lua refuse." }); return end

  local chunk, err
  if loadstring then
    chunk, err = loadstring(source, "@" .. clean)
  elseif load then
    chunk, err = load(source, "@" .. clean, "t", {})
  else
    messageBox("Serveur", { "loadstring indisponible." })
    return
  end
  if not chunk then messageBox("Erreur Lua", { truncate(tostring(err), w - 4) }); return end

  local appTerm = term
  if window and window.create and term.current then
    appTerm = window.create(term.current(), 1, 1, w, h, true)
  end
  if appTerm.setBackgroundColor then appTerm.setBackgroundColor(colors.black) end
  if appTerm.setTextColor then appTerm.setTextColor(colors.white) end
  appTerm.clear()
  appTerm.setCursorPos(1, 1)
  appTerm.write("Serveur Lua: " .. clean)
  RUNNER.newLine(appTerm)
  appTerm.write("Ctrl+T = quitter | OS/disques proteges")
  RUNNER.newLine(appTerm)
  RUNNER.newLine(appTerm)

  local watchdog = { steps = 0 }
  local env = SERVER.makeEnv(appTerm, SERVER.makeFs(), watchdog, clean)
  if setfenv then setfenv(chunk, env) end

  local hookEnabled = debug and debug.sethook
  if hookEnabled then
    pcall(debug.sethook, function()
      watchdog.steps = watchdog.steps + 1000
      if watchdog.steps > SERVER.MAX_STEPS then error("Serveur: trop d'instructions sans pause.", 2) end
    end, "", 1000)
  end
  appendAudit("server lua start: " .. clean)
  local ok, runErr = pcall(chunk)
  if hookEnabled then pcall(debug.sethook) end
  safeCollectGarbage()
  appendAudit("server lua stop: " .. clean .. " ok=" .. tostring(ok))

  if ok then
    messageBox("Serveur", { "Programme termine." })
  else
    messageBox("Erreur serveur", { truncate(tostring(runErr), w - 4) })
  end
end

local function appServer()
  if not isValidSession() then return "lock" end
  if not isAdmin() then
    messageBox("Serveur", { "Admin seulement." })
    return
  end
  local selected = 1
  while true do
    resetButtons()
    if not config.serverMode then
      drawTop("Serveur")
      writeAt(2, 4, "Mode serveur inactif.", theme.warn, theme.bg)
      writeAt(2, 6, "Activation irreversible.", theme.bad, theme.bg)
      writeAt(2, 8, "Demande code admin + code integrite.", theme.text, theme.bg)
      writeAt(2, 10, "Ensuite: editeur Lua + lanceur serveur.", theme.text, theme.bg)
      addButton("activate", 3, h - 4, 18, 2, "Activer", theme.warn, colors.black)
      addButton("back", 25, h - 4, 18, 2, "Back", theme.action, colors.black)
    else
      drawTop("Serveur ON")
      ensureDir(SERVER.ROOT)
      local files = SERVER.listLuaFiles()
      if selected > #files then selected = math.max(1, #files) end
      addButton("new", 2, 3, 7, 1, "New", theme.good, colors.black)
      addButton("edit", 10, 3, 7, 1, "Edit", theme.action, colors.black)
      addButton("run", 18, 3, 7, 1, "Run", theme.selected, colors.black)
      addButton("delete", 26, 3, 8, 1, "Delete", theme.bad, colors.white)
      addButton("info", 35, 3, 6, 1, "Info", theme.panel2, colors.black)
      addButton("back", 42, 3, 7, 1, "Back", theme.action, colors.black)
      writeAt(2, 5, "Racine: " .. SERVER.ROOT .. " | fs large, OS protege.", theme.muted, theme.bg)
      local maxRows = h - 8
      for i = 1, math.min(#files, maxRows) do
        local bg = (i == selected) and theme.panel2 or theme.panel
        fill(2, 6 + i, w - 3, 1, bg)
        writeAt(3, 6 + i, truncate(files[i], w - 5), theme.fieldText, bg)
        buttons[#buttons + 1] = { id = "srvfile:" .. i, x = 2, y = 6 + i, w = w - 3, h = 1 }
      end
      if #files == 0 then centerAt(10, "Aucun script serveur.", theme.muted, theme.bg) end
    end

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if not config.serverMode then
        if id == "activate" then
          local r = SERVER.activateMode()
          if r == "auto_lock" then return "auto_lock" end
        end
      else
        local files = SERVER.listLuaFiles()
        if id and id:sub(1, 8) == "srvfile:" then selected = tonumber(id:sub(9)) or 1 end
        if id == "new" then
          local r = SERVER.newLuaFile()
          if r == "auto_lock" then return "auto_lock" end
        elseif id == "edit" then
          if files[selected] then
            local r = SERVER.editLuaFile(files[selected])
            if r == "auto_lock" then return "auto_lock" end
          else
            messageBox("Serveur", { "Selectionne un .lua." })
          end
        elseif id == "run" then
          if files[selected] then
            local r = SERVER.runLuaFile(files[selected])
            if r == "auto_lock" then return "auto_lock" end
          else
            messageBox("Serveur", { "Selectionne un .lua." })
          end
        elseif id == "delete" then
          if files[selected] then
            local yes = messageBox("Confirmer", { "Supprimer " .. files[selected] .. " ?" }, {
              { id = "yes", label = "Yes", color = theme.bad, fg = colors.white },
              { id = "no", label = "No", color = theme.action, fg = colors.black }
            })
            if yes == "yes" then
              fs.delete(SERVER.ROOT .. "/" .. files[selected])
              appendAudit("server lua deleted: " .. files[selected])
              selected = 1
            end
          end
        elseif id == "info" then
          messageBox("Serveur", {
            "Actif depuis: " .. tostring(config.serverActivatedAt or "?"),
            "Par: " .. tostring(config.serverActivatedBy or "?"),
            "Autorise: fichiers hors systeme.",
            "Bloque: /startup.lua /secureos disques."
          })
        end
      end
    end
  end
end

function APPS.calculator()
  local last = "Resultat: ?"
  while true do
    local action, fields = inputForm("Calculatrice", {
      { key = "a", label = "Nombre A", maxLen = 16 },
      { key = "op", label = "Operation + - * /", maxLen = 1 },
      { key = "b", label = "Nombre B", maxLen = 16 }
    }, {
      { id = "calc", label = "Calcul", color = theme.good, fg = colors.black },
      { id = "back", label = "Back", color = theme.bad, fg = colors.white }
    })
    if action == "auto_lock" then return "auto_lock" end
    if action == "back" then return end
    local a, b = tonumber(fields[1].value), tonumber(fields[3].value)
    local op = fields[2].value
    if not a or not b then
      last = "Nombre invalide."
    elseif op == "+" then last = tostring(a + b)
    elseif op == "-" then last = tostring(a - b)
    elseif op == "*" then last = tostring(a * b)
    elseif op == "/" and b ~= 0 then last = tostring(a / b)
    else last = "Operation invalide."
    end
    messageBox("Calculatrice", { "Resultat:", last })
  end
end

function APPS.clock()
  local timer = os.startTimer(1)
  while true do
    resetButtons()
    drawTop("Horloge")
    centerAt(6, "Computer ID: " .. tostring(os.getComputerID()), theme.text, theme.bg)
    centerAt(8, "Temps OS: " .. tostring(os.time()), theme.good, theme.bg)
    centerAt(10, "Jour: " .. tostring(os.day and os.day() or "?"), theme.text, theme.bg)
    if os.epoch then centerAt(12, "Epoch: " .. tostring(os.epoch("utc")), theme.muted, theme.bg) end
    addButton("back", math.floor(w / 2) - 6, h - 2, 12, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" and buttonAt(ev[3], ev[4]) == "back" then return end
    if ev[1] == "timer" and ev[2] == timer then timer = os.startTimer(1) end
  end
end

function APPS.guessNumber()
  local secret = math.random(1, 50)
  local tries = 0
  while true do
    local action, fields = inputForm("Devine nombre", {
      { key = "guess", label = "Nombre 1-50", maxLen = 3 }
    }, {
      { id = "try", label = "Essayer", color = theme.good, fg = colors.black },
      { id = "new", label = "New", color = theme.warn, fg = colors.black },
      { id = "back", label = "Back", color = theme.bad, fg = colors.white }
    })
    if action == "auto_lock" then return "auto_lock" end
    if action == "back" then return end
    if action == "new" then secret = math.random(1, 50); tries = 0
    elseif action == "try" then
      local g = tonumber(fields[1].value)
      tries = tries + 1
      if not g then messageBox("Jeu", { "Entre un nombre." })
      elseif g < secret then messageBox("Jeu", { "Plus grand.", "Essais: " .. tostring(tries) })
      elseif g > secret then messageBox("Jeu", { "Plus petit.", "Essais: " .. tostring(tries) })
      else
        messageBox("Gagne", { "Bravo !", "Nombre: " .. tostring(secret), "Essais: " .. tostring(tries) })
        secret = math.random(1, 50)
        tries = 0
      end
    end
  end
end

function APPS.clicker()
  local score = 0
  local vip = false
  while true do
    resetButtons()
    drawTop("Clicker")
    centerAt(5, "Score: " .. tostring(score), theme.good, theme.bg)
    centerAt(6, vip and "VIP x2 actif" or "VIP x2: 25 banque vers shop", vip and theme.selected or theme.muted, theme.bg)
    addButton("click", math.floor(w / 2) - 8, 8, 16, 4, "CLICK", theme.selected, colors.black)
    addButton("vip", math.floor(w / 2) - 8, 13, 16, 1, vip and "VIP OK" or "Acheter VIP", vip and theme.panel2 or theme.good, colors.black)
    addButton("reset", 8, h - 2, 12, 1, "Reset", theme.warn, colors.black)
    addButton("back", w - 14, h - 2, 12, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "click" then score = score + (vip and 2 or 1)
      elseif id == "vip" and not vip then
        local paid = BANK.sandboxPay("Clicker", "shop", 25, "VIP Clicker x2")
        if paid and paid.ok then vip = true end
      elseif id == "reset" then score = 0
      elseif id == "back" then return
      end
    end
  end
end

function APPS.chatLan()
  if not tryOpenRednet() then messageBox("Chat LAN", { "Aucun modem rednet." }); return end
  local lines = { "Chat LAN pret." }
  while true do
    resetButtons()
    drawTop("Chat LAN")
    for i = math.max(1, #lines - (h - 7)), #lines do
      writeAt(2, 3 + i - math.max(1, #lines - (h - 7)), truncate(lines[i], w - 3), theme.text, theme.bg)
    end
    addButton("send", 2, h - 2, 12, 1, "Send", theme.good, colors.black)
    addButton("back", 16, h - 2, 12, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "rednet_message" and ev[4] == APPS.CHAT_PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.magic == APPS.CHAT_PROTOCOL then
        lines[#lines + 1] = "pc" .. tostring(ev[2]) .. " " .. tostring(msg.from or "?") .. ": " .. tostring(msg.text or "")
      end
    elseif ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "send" then
        local action, fields = inputForm("Message LAN", {
          { key = "text", label = "Message", maxLen = 96 }
        }, {
          { id = "send", label = "Send", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if action == "auto_lock" then return "auto_lock" end
        if action == "send" and fields[1].value ~= "" then
          local pkg = { magic = APPS.CHAT_PROTOCOL, from = currentUser and currentUser.name or "?", text = fields[1].value, time = now() }
          rednet.broadcast(pkg, APPS.CHAT_PROTOCOL)
          lines[#lines + 1] = "moi: " .. fields[1].value
        end
      end
    end
    while #lines > 30 do table.remove(lines, 1) end
  end
end

function APPS.diceDuelHost()
  if not tryOpenRednet() then messageBox("Duel des", { "Aucun modem rednet." }); return end
  local status = "En attente de joueur..."
  while true do
    resetButtons()
    drawTop("Duel des host")
    centerAt(6, "Host PC: " .. tostring(os.getComputerID()), theme.good, theme.bg)
    centerAt(8, status, theme.text, theme.bg)
    addButton("back", math.floor(w / 2) - 6, h - 2, 12, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" and buttonAt(ev[3], ev[4]) == "back" then return end
    if ev[1] == "rednet_message" and ev[4] == APPS.DICE_PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.magic == APPS.DICE_PROTOCOL and msg.kind == "discover" then
        rednet.send(ev[2], { magic = APPS.DICE_PROTOCOL, kind = "host", host = currentUser and currentUser.name or "host" }, APPS.DICE_PROTOCOL)
      elseif type(msg) == "table" and msg.magic == APPS.DICE_PROTOCOL and msg.kind == "join" then
        local hostRoll = math.random(1, 6)
        local clientRoll = math.random(1, 6)
        local result = hostRoll == clientRoll and "Egalite" or (hostRoll > clientRoll and "Host gagne" or "Client gagne")
        rednet.send(ev[2], { magic = APPS.DICE_PROTOCOL, kind = "result", hostRoll = hostRoll, clientRoll = clientRoll, result = result }, APPS.DICE_PROTOCOL)
        status = "pc" .. tostring(ev[2]) .. " " .. tostring(hostRoll) .. "-" .. tostring(clientRoll) .. " " .. result
      end
    end
  end
end

function APPS.diceDuelJoin()
  if not tryOpenRednet() then messageBox("Duel des", { "Aucun modem rednet." }); return end
  rednet.broadcast({ magic = APPS.DICE_PROTOCOL, kind = "discover" }, APPS.DICE_PROTOCOL)
  local hosts = {}
  local timer = os.startTimer(APPS.DISCOVER_SECONDS)
  while true do
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "rednet_message" and ev[4] == APPS.DICE_PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.magic == APPS.DICE_PROTOCOL and msg.kind == "host" then
        hosts[#hosts + 1] = { id = ev[2], name = tostring(msg.host or "host") }
      end
    end
  end
  if #hosts == 0 then messageBox("Duel des", { "Aucun host trouve." }); return end
  local selected = 1
  while true do
    resetButtons()
    drawTop("Choisir host")
    for i = 1, math.min(#hosts, h - 6) do
      local bg = i == selected and theme.panel2 or theme.panel
      fill(2, 3 + i, w - 3, 1, bg)
      writeAt(3, 3 + i, "pc" .. tostring(hosts[i].id) .. " " .. hosts[i].name, colors.black, bg)
      buttons[#buttons + 1] = { id = "host:" .. i, x = 2, y = 3 + i, w = w - 3, h = 1 }
    end
    addButton("join", 2, h - 2, 12, 1, "Join", theme.good, colors.black)
    addButton("back", 16, h - 2, 12, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id and id:sub(1, 5) == "host:" then selected = tonumber(id:sub(6)) or selected end
      if id == "join" and hosts[selected] then
        rednet.send(hosts[selected].id, { magic = APPS.DICE_PROTOCOL, kind = "join", from = currentUser and currentUser.name or "invite" }, APPS.DICE_PROTOCOL)
        local wait = os.startTimer(5)
        while true do
          local ev2 = { pullSecureEvent() }
          if ev2[1] == "auto_lock" then return "auto_lock" end
          if ev2[1] == "timer" and ev2[2] == wait then messageBox("Duel des", { "Timeout." }); return end
          if ev2[1] == "rednet_message" and ev2[2] == hosts[selected].id and ev2[4] == APPS.DICE_PROTOCOL then
            local msg = ev2[3]
            if type(msg) == "table" and msg.kind == "result" then
              messageBox("Resultat", {
                "Host: " .. tostring(msg.hostRoll),
                "Client: " .. tostring(msg.clientRoll),
                tostring(msg.result)
              })
              return
            end
          end
        end
      end
    end
  end
end

function APPS.diceDuel()
  while true do
    resetButtons()
    drawTop("Duel des LAN")
    centerAt(5, "Jeu reseau rednet.", theme.text, theme.bg)
    addButton("host", 5, 8, 16, 3, "Host", theme.good, colors.black)
    addButton("join", 29, 8, 16, 3, "Join", theme.action, colors.black)
    addButton("back", 17, 14, 16, 2, "Back", theme.panel2, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "host" then local r = APPS.diceDuelHost(); if r == "auto_lock" then return "auto_lock" end end
      if id == "join" then local r = APPS.diceDuelJoin(); if r == "auto_lock" then return "auto_lock" end end
    end
  end
end

local function appAppCenter()
  local items = {
    { id = "calc", label = "Calculatrice" },
    { id = "clock", label = "Horloge" },
    { id = "guess", label = "Devine nombre" },
    { id = "clicker", label = "Clicker" },
    { id = "chat", label = "Chat LAN" },
    { id = "dice", label = "Duel des LAN" }
  }
  while true do
    resetButtons()
    drawTop("Apps et jeux")
    writeAt(2, 4, currentUser and currentUser.guest and "Mode invite: apps sans donnees privees." or "Apps integrees SecureClickOS.", theme.muted, theme.bg)
    for i, item in ipairs(items) do
      local col = (i - 1) % 2
      local row = math.floor((i - 1) / 2)
      addButton(item.id, 4 + col * 24, 6 + row * 3, 20, 2, item.label, col == 0 and theme.action or theme.good, colors.black)
    end
    addButton("back", math.floor(w / 2) - 6, h - 2, 12, 1, "Back", theme.panel2, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      local r
      if id == "calc" then r = APPS.calculator()
      elseif id == "clock" then r = APPS.clock()
      elseif id == "guess" then r = APPS.guessNumber()
      elseif id == "clicker" then r = APPS.clicker()
      elseif id == "chat" then r = APPS.chatLan()
      elseif id == "dice" then r = APPS.diceDuel()
      end
      if r == "auto_lock" then return "auto_lock" end
    end
  end
end

function BANK.loadData()
  local data = loadTable(BANK.FILE, { config = nil, accounts = {}, logs = {} })
  if type(data.accounts) ~= "table" then data.accounts = {} end
  if type(data.logs) ~= "table" then data.logs = {} end
  return data
end

function BANK.saveData(data)
  ensureDir(ROOT)
  saveTable(BANK.FILE, data)
end

function BANK.log(data, text)
  data.logs[#data.logs + 1] = "[" .. tostring(now()) .. "] " .. tostring(text or "")
  while #data.logs > 12 do table.remove(data.logs, 1) end
  BANK.saveData(data)
end

function BANK.accessLabel(auth)
  return auth == "direct" and "Direct integrite" or "Code paiement"
end

function BANK.bankId()
  return "BNK-" .. secureRandomHex(3):upper()
end

function BANK.codeKey(bankId, code)
  return hmacSha256(tostring(code or ""), "bank-code|" .. tostring(bankId or ""))
end

function BANK.publicKey(bankId)
  return hmacSha256("SecureClickOS public bank access", "bank-public|" .. tostring(bankId or ""))
end

function BANK.directKey(bankId, name, password, sealCode)
  return hmacSha256(tostring(password or "") .. "|" .. tostring(sealCode or ""), "bank-direct|" .. tostring(bankId or "") .. "|" .. cleanName(name))
end

function BANK.accountSecret(name, password)
  return hashPassword(tostring(password or ""), "bank-account|" .. cleanName(name), HASH_ROUNDS)
end

function BANK.amount(value)
  local n = math.floor(tonumber(value) or 0)
  if n < 1 then return nil end
  if n > BANK.MAX_AMOUNT then n = BANK.MAX_AMOUNT end
  return n
end

function BANK.ensureTransactions(account)
  if type(account) ~= "table" then return {} end
  if type(account.transactions) ~= "table" then account.transactions = {} end
  return account.transactions
end

function BANK.addTransaction(account, tx)
  local list = BANK.ensureTransactions(account)
  tx = tx or {}
  tx.time = tx.time or now()
  table.insert(list, 1, tx)
  while #list > 30 do table.remove(list) end
end

function BANK.requestBase(packet)
  return table.concat({
    tostring(packet.magic or ""),
    tostring(packet.kind or ""),
    tostring(packet.action or ""),
    tostring(packet.accessMode or ""),
    tostring(packet.bankId or ""),
    tostring(packet.requestId or ""),
    tostring(packet.nonce or ""),
    tostring(packet.user or ""),
    tostring(packet.target or ""),
    tostring(packet.amount or ""),
    tostring(packet.appPayment or ""),
    tostring(packet.cashoutPayment or ""),
    tostring(packet.cashoutMarker or ""),
    tostring(packet.appName or ""),
    tostring(packet.label or ""),
    tostring(packet.accountProof or ""),
    tostring(packet.accountSecret or "")
  }, "|")
end

function BANK.accountBase(packet)
  return table.concat({
    "bank-account",
    tostring(packet.action or ""),
    tostring(packet.bankId or ""),
    tostring(packet.requestId or ""),
    tostring(packet.nonce or ""),
    tostring(packet.user or ""),
    tostring(packet.target or ""),
    tostring(packet.amount or ""),
    tostring(packet.appPayment or ""),
    tostring(packet.cashoutPayment or ""),
    tostring(packet.cashoutMarker or ""),
    tostring(packet.appName or ""),
    tostring(packet.label or "")
  }, "|")
end

function BANK.accountProof(secret, packet)
  return hmacSha256(tostring(secret or ""), BANK.accountBase(packet))
end

function BANK.signAccess(accessKey, packet)
  packet.sig = hmacSha256(tostring(accessKey or ""), BANK.requestBase(packet))
  return packet
end

function BANK.verifyAccess(configBank, packet)
  if type(configBank) ~= "table" then return false end
  local base = BANK.requestBase(packet)
  local privateExpected = hmacSha256(tostring(configBank.keyHash or ""), base)
  if configBank.auth == "direct" or packet.appPayment == "1" or packet.accessMode == "code" then
    return constantTimeEquals(packet.sig, privateExpected)
  end
  local publicExpected = hmacSha256(BANK.publicKey(packet.bankId or configBank.bankId), base)
  return constantTimeEquals(packet.sig, publicExpected) or constantTimeEquals(packet.sig, privateExpected)
end

function BANK.verifyAccount(account, packet)
  if type(account) ~= "table" or type(account.secret) ~= "string" then return false end
  return constantTimeEquals(packet.accountProof, BANK.accountProof(account.secret, packet))
end

function BANK.reply(to, req, ok, fields)
  local msg = fields or {}
  msg.magic = BANK.PROTOCOL
  msg.kind = "reply"
  msg.bankId = req.bankId
  msg.requestId = req.requestId
  msg.ok = ok == true
  rednet.send(to, msg, BANK.PROTOCOL)
end

function BANK.handleServerRequest(sender, packet, data, seen)
  if type(packet) ~= "table" or packet.magic ~= BANK.PROTOCOL then return end
  local cfg = data.config
  if packet.kind == "discover" and cfg then
    local accountCount = 0
    for _ in pairs(data.accounts) do accountCount = accountCount + 1 end
    rednet.send(sender, {
      magic = BANK.PROTOCOL,
      kind = "discover_reply",
      bankId = cfg.bankId,
      auth = cfg.auth or "code",
      computerId = os.getComputerID(),
      label = os.getComputerLabel() or "",
      accounts = accountCount
    }, BANK.PROTOCOL)
    return
  end
  if packet.kind ~= "request" or not cfg then return end
  if packet.bankId ~= cfg.bankId then
    return BANK.reply(sender, packet, false, { error = "Mauvaise banque." })
  end
  if not BANK.verifyAccess(cfg, packet) then
    BANK.log(data, "Acces refuse PC " .. tostring(sender))
    return BANK.reply(sender, packet, false, { error = "Acces banque refuse." })
  end
  local replayKey = tostring(sender) .. ":" .. tostring(packet.requestId or "")
  if seen[replayKey] then
    return BANK.reply(sender, packet, false, { error = "Requete deja vue." })
  end
  seen[replayKey] = true

  local user = cleanName(packet.user)
  if user == "" then return BANK.reply(sender, packet, false, { error = "Nom invalide." }) end
  local action = tostring(packet.action or "")
  local account = data.accounts[user]

  if action == "create" then
    local secret = tostring(packet.accountSecret or "")
    if #secret ~= 64 or not secret:match("^[0-9a-f]+$") then
      return BANK.reply(sender, packet, false, { error = "Secret compte invalide." })
    end
    if not constantTimeEquals(packet.accountProof, BANK.accountProof(secret, packet)) then
      return BANK.reply(sender, packet, false, { error = "Preuve compte refusee." })
    end
    if not account then
      data.accounts[user] = { secret = secret, balance = BANK.DEFAULT_BALANCE, createdAt = now(), transactions = {} }
      BANK.addTransaction(data.accounts[user], {
        kind = "credit",
        other = "banque",
        amount = BANK.DEFAULT_BALANCE,
        label = "Solde initial"
      })
      BANK.log(data, "Compte cree: " .. user)
    else
      BANK.ensureTransactions(account)
    end
    return BANK.reply(sender, packet, true, { balance = data.accounts[user].balance, created = account == nil })
  end

  if action == "cashout" then
    local seller = cleanName(packet.target)
    local amount = BANK.amount(packet.amount)
    local label = tostring(packet.label or "Retrait app"):sub(1, 48)
    if packet.cashoutPayment ~= "1" then
      return BANK.reply(sender, packet, false, { error = "Cashout invalide." })
    end
    if seller == "" then
      return BANK.reply(sender, packet, false, { error = "Compte casino vide." })
    end
    if seller == user then
      return BANK.reply(sender, packet, false, { error = "Compte casino identique au joueur." })
    end
    if not amount then
      return BANK.reply(sender, packet, false, { error = "Montant invalide." })
    end
    if amount > BANK.MAX_CASHOUT then
      return BANK.reply(sender, packet, false, { error = "Retrait max: " .. tostring(BANK.MAX_CASHOUT) })
    end
    if tostring(packet.cashoutMarker or "") ~= BANK.cashoutMarker(seller) then
      return BANK.reply(sender, packet, false, { error = "Marqueur cashout invalide." })
    end

    local playerAccount = data.accounts[user]
    local sellerAccount = data.accounts[seller]
    if not playerAccount then
      return BANK.reply(sender, packet, false, { error = "Compte joueur introuvable." })
    end
    if not sellerAccount then
      return BANK.reply(sender, packet, false, { error = "Compte casino introuvable." })
    end
    BANK.ensureTransactions(playerAccount)
    BANK.ensureTransactions(sellerAccount)
    if (sellerAccount.balance or 0) < amount then
      return BANK.reply(sender, packet, false, { error = "Solde casino insuffisant." })
    end

    local stamp = now()
    sellerAccount.balance = (sellerAccount.balance or 0) - amount
    playerAccount.balance = (playerAccount.balance or 0) + amount
    BANK.addTransaction(sellerAccount, {
      kind = "cashout",
      other = user,
      amount = -amount,
      label = label,
      time = stamp
    })
    BANK.addTransaction(playerAccount, {
      kind = "gain",
      other = seller,
      amount = amount,
      label = label,
      time = stamp
    })
    BANK.log(data, seller .. " -> " .. user .. " : " .. tostring(amount) .. " cashout " .. label)
    return BANK.reply(sender, packet, true, {
      balance = playerAccount.balance,
      sellerBalance = sellerAccount.balance,
      target = user,
      amount = amount
    })
  end

  if not account then return BANK.reply(sender, packet, false, { error = "Compte introuvable." }) end
  BANK.ensureTransactions(account)
  if not BANK.verifyAccount(account, packet) then
    BANK.log(data, "Mot de passe refuse: " .. user)
    return BANK.reply(sender, packet, false, { error = "Mot de passe refuse." })
  end

  if action == "balance" then
    return BANK.reply(sender, packet, true, { balance = account.balance or 0 })
  elseif action == "transactions" then
    local out = {}
    local list = BANK.ensureTransactions(account)
    for i = 1, math.min(#list, 20) do out[#out + 1] = list[i] end
    return BANK.reply(sender, packet, true, { balance = account.balance or 0, transactions = out })
  elseif action == "transfer" then
    local target = cleanName(packet.target)
    local amount = BANK.amount(packet.amount)
    if target == "" then
      local err = packet.appPayment == "1" and "Compte vendeur vide." or "Cible vide."
      if packet.cashoutPayment == "1" then err = "Compte joueur vide." end
      return BANK.reply(sender, packet, false, { error = err })
    end
    if target == user then
      local err = "Cible invalide."
      if packet.appPayment == "1" then err = "Vendeur identique au compte client." end
      if packet.cashoutPayment == "1" then err = "Compte casino identique au joueur." end
      return BANK.reply(sender, packet, false, { error = err })
    end
    if not amount then return BANK.reply(sender, packet, false, { error = "Montant invalide." }) end
    if not data.accounts[target] then
      local err = packet.appPayment == "1" and "Compte vendeur introuvable." or "Compte cible introuvable."
      if packet.cashoutPayment == "1" then err = "Compte joueur introuvable." end
      return BANK.reply(sender, packet, false, { error = err })
    end
    if (account.balance or 0) < amount then return BANK.reply(sender, packet, false, { error = "Solde insuffisant." }) end
    local label = packet.appPayment == "1" and tostring(packet.label or "Achat app") or "Virement"
    if packet.cashoutPayment == "1" then label = tostring(packet.label or "Retrait app") end
    local stamp = now()
    account.balance = (account.balance or 0) - amount
    data.accounts[target].balance = (data.accounts[target].balance or 0) + amount
    BANK.addTransaction(account, {
      kind = packet.cashoutPayment == "1" and "cashout" or (packet.appPayment == "1" and "achat" or "envoi"),
      other = target,
      amount = -amount,
      label = label,
      time = stamp
    })
    BANK.addTransaction(data.accounts[target], {
      kind = packet.cashoutPayment == "1" and "gain" or (packet.appPayment == "1" and "vente" or "recu"),
      other = user,
      amount = amount,
      label = label,
      time = stamp
    })
    BANK.log(data, user .. " -> " .. target .. " : " .. tostring(amount) .. ((packet.appPayment == "1" or packet.cashoutPayment == "1") and (" app " .. tostring(packet.label or "")) or ""))
    return BANK.reply(sender, packet, true, { balance = account.balance, target = target, amount = amount })
  end
  return BANK.reply(sender, packet, false, { error = "Action inconnue." })
end

function BANK.backgroundHandle(sender, packet)
  if type(packet) ~= "table" or packet.magic ~= BANK.PROTOCOL then return false end
  if packet.kind ~= "discover" and packet.kind ~= "request" then return false end
  if type(BANK.serverData) ~= "table" or type(BANK.serverData.config) ~= "table" then
    BANK.serverData = BANK.loadData()
  end
  if type(BANK.serverData) ~= "table" or type(BANK.serverData.config) ~= "table" then return false end
  if type(BANK.serverSeen) ~= "table" then BANK.serverSeen = {} end
  local ok, err = pcall(BANK.handleServerRequest, sender, packet, BANK.serverData, BANK.serverSeen)
  if not ok then
    pcall(appendAudit, "bank service error: " .. tostring(err))
  end
  return true
end

function BANK.requireDebug(title)
  local action, fields = inputForm(title or "Code debug", {
    { key = "debug", label = "Code debug", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "ok", label = "OK", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return false end
  local debugCode = fields[1].value
  fields[1].value = ""
  local ok = MAINT.verifyDebugCode(debugCode)
  debugCode = nil
  safeCollectGarbage()
  if not ok then messageBox("Refuse", { "Code debug invalide." }); return false end
  return true
end

function BANK.setupServer()
  if not isAdmin() then
    messageBox("Refuse", { "Admin seulement." })
    return nil
  end
  local bankId = BANK.bankId()
  local mode = messageBox("Mode banque", {
    "Code paiement: cle separee.",
    "Direct: pas de cle banque.",
    "Direct demande mdp admin + integrite."
  }, {
    { id = "code", label = "Code", color = theme.good, fg = colors.black },
    { id = "direct", label = "Direct", color = theme.warn, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if mode == "cancel" then return nil end

  local cfg = { bankId = bankId, auth = mode, createdAt = now(), createdBy = currentUser.name, computerId = os.getComputerID() }
  if mode == "code" then
    local action, fields = inputForm("Code paiement", {
      { key = "code", label = "Code paiement", mask = true, maxLen = MAX_PASSWORD_LEN }
    }, {
      { id = "ok", label = "Save", color = theme.good, fg = colors.black },
      { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
    })
    if action == "auto_lock" then return "auto_lock" end
    if action ~= "ok" then return nil end
    if #fields[1].value < 4 then messageBox("Refuse", { "Code paiement trop court." }); return nil end
    cfg.keyHash = BANK.codeKey(bankId, fields[1].value)
    fields[1].value = ""
  else
    local warn = messageBox("Avertissement serieux", {
      "Mode direct = tres sensible.",
      "Pas de code banque separe.",
      "Le mdp admin + code integrite",
      "deviennent la cle d'acces banque.",
      "Ne partage jamais ces secrets."
    }, {
      { id = "continue", label = "Continuer", color = theme.warn, fg = colors.black },
      { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
    })
    if warn ~= "continue" then return nil end
    local action, fields = inputForm("Direct integrite", {
      { key = "admin", label = "Admin", maxLen = 32 },
      { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "confirm", label = "Tape DIRECT", maxLen = 16 }
    }, {
      { id = "ok", label = "Save", color = theme.warn, fg = colors.black },
      { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
    })
    if action == "auto_lock" then return "auto_lock" end
    if action ~= "ok" then return nil end
    local adminName = cleanName(fields[1].value)
    local pass = fields[2].value
    local seal = fields[3].value
    local confirm = fields[4].value
    fields[2].value, fields[3].value = "", ""
    local ok, adminUser = verifyPassword(adminName, pass)
    local sealOk = SERVER.verifyIntegrityCode(seal)
    if not ok or adminUser.role ~= "admin" or not sealOk or confirm ~= "DIRECT" then
      pass, seal = nil, nil
      safeCollectGarbage()
      messageBox("Refuse", { "Admin, mdp, integrite ou confirmation invalide." })
      return nil
    end
    cfg.keyHash = BANK.directKey(bankId, adminName, pass, seal)
    cfg.directUser = adminName
    pass, seal = nil, nil
  end
  safeCollectGarbage()
  local data = { config = cfg, accounts = {}, logs = {} }
  BANK.log(data, "Serveur banque cree: " .. bankId)
  appendAudit("bank server configured: " .. bankId)
  return data
end

function BANK.adminGive(data)
  local action, fields = inputForm("Banque give", {
    { key = "debug", label = "Code debug", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "user", label = "Compte", maxLen = 32 },
    { key = "amount", label = "Montant", maxLen = 10 }
  }, {
    { id = "ok", label = "Give", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return end
  local debugCode = fields[1].value
  local user = cleanName(fields[2].value)
  local amount = BANK.amount(fields[3].value)
  fields[1].value = ""
  local debugOk = MAINT.verifyDebugCode(debugCode)
  debugCode = nil
  safeCollectGarbage()
  if not debugOk then messageBox("Refuse", { "Code debug invalide." }); return end
  if user == "" or not amount then messageBox("Erreur", { "Compte ou montant invalide." }); return end
  if not data.accounts[user] then messageBox("Erreur", { "Compte introuvable.", "Le client doit le creer d'abord." }); return end
  data.accounts[user].balance = (data.accounts[user].balance or 0) + amount
  BANK.addTransaction(data.accounts[user], {
    kind = "credit",
    other = "admin",
    amount = amount,
    label = "Ajout admin"
  })
  BANK.log(data, "Admin give " .. tostring(amount) .. " a " .. user)
  messageBox("Banque", { "Ajoute: " .. tostring(amount), "Compte: " .. user })
end

function BANK.runServer()
  if not isAdmin() then messageBox("Banque", { "Admin seulement." }); return end
  if not tryOpenRednet() then messageBox("Banque", { "Aucun modem rednet." }); return end
  local data = BANK.loadData()
  if not data.config then
    data = BANK.setupServer()
    if data == "auto_lock" then return "auto_lock" end
    if not data then return end
  end
  BANK.serverData = data
  if type(BANK.serverSeen) ~= "table" then BANK.serverSeen = {} end
  local seen = BANK.serverSeen
  local tick = os.startTimer(1)
  appendAudit("bank server dashboard opened")
  while true do
    resetButtons()
    drawTop("Banque serveur")
    local cfg = data.config
    local count = 0
    for _ in pairs(data.accounts) do count = count + 1 end
    writeAt(2, 4, "ID: " .. tostring(cfg.bankId), theme.good, theme.bg)
    writeAt(2, 5, "Acces: " .. BANK.accessLabel(cfg.auth), cfg.auth == "direct" and theme.warn or theme.text, theme.bg)
    writeAt(2, 6, "Comptes: " .. tostring(count), theme.text, theme.bg)
    writeAt(2, 7, "Service: ON permanent", theme.good, theme.bg)
    addButton("give", 2, 8, 10, 1, "Give", theme.good, colors.black)
    addButton("back", 14, 8, 10, 1, "Back", theme.action, colors.black)
    writeAt(2, 10, "Logs:", theme.muted, theme.bg)
    for i = 1, math.min(#data.logs, h - 13) do
      writeAt(3, 10 + i, truncate(data.logs[i], w - 4), theme.text, theme.bg)
    end
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then appendAudit("bank server dashboard closed"); return end
      if id == "give" then
        local r = BANK.adminGive(data)
        if r == "auto_lock" then return "auto_lock" end
        BANK.serverData = data
      end
    elseif ev[1] == "rednet_message" and ev[4] == BANK.PROTOCOL then
      BANK.handleServerRequest(ev[2], ev[3], data, seen)
    elseif ev[1] == "timer" and ev[2] == tick then
      tick = os.startTimer(1)
    end
  end
end

function BANK.discoverServers()
  local outMap = {}
  rednet.broadcast({ magic = BANK.PROTOCOL, kind = "discover" }, BANK.PROTOCOL)
  local timer = os.startTimer(BANK.DISCOVER_SECONDS)
  while true do
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "rednet_message" and ev[4] == BANK.PROTOCOL then
      local msg = ev[3]
      if type(msg) == "table" and msg.magic == BANK.PROTOCOL and msg.kind == "discover_reply" then
        msg.sender = ev[2]
        if msg.auth ~= "direct" then msg.auth = "code" end
        outMap[tostring(msg.sender) .. ":" .. tostring(msg.bankId)] = msg
      end
    end
  end
  local out = {}
  for _, item in pairs(outMap) do out[#out + 1] = item end
  table.sort(out, function(a, b) return tostring(a.bankId) < tostring(b.bankId) end)
  return out
end

function BANK.manualServer()
  local action, fields = inputForm("Banque manuel", {
    { key = "pc", label = "Computer ID", maxLen = 8 },
    { key = "bank", label = "Bank ID", maxLen = 16 }
  }, {
    { id = "ok", label = "OK", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return nil end
  local pc = tonumber(fields[1].value)
  if not pc or fields[2].value == "" then return nil end
  local auth = messageBox("Mode acces", {
    "Ce serveur manuel utilise quel mode ?"
  }, {
    { id = "code", label = "Code", color = theme.good, fg = colors.black },
    { id = "direct", label = "Direct", color = theme.warn, fg = colors.black }
  })
  return { sender = pc, bankId = fields[2].value, auth = auth == "direct" and "direct" or "code" }
end

function BANK.validPayProfile(profile)
  if type(profile) ~= "table" then return false end
  if profile.auth ~= "code" then return false end
  if tonumber(profile.sender or 0) == nil then return false end
  if tostring(profile.bankId or "") == "" then return false end
  if cleanName(profile.user) == "" then return false end
  if tonumber(profile.computerId or -1) ~= os.getComputerID() then return false end
  return true
end

function BANK.payProfileError(profile)
  if type(profile) ~= "table" then return "Profil paiement manquant." end
  if profile.auth ~= "code" then return "Profil paiement non compatible." end
  if tonumber(profile.computerId or -1) ~= os.getComputerID() then return "Profil cree sur un autre PC client." end
  if tostring(profile.bankId or "") == "" or cleanName(profile.user) == "" or not tonumber(profile.sender or 0) then return "Profil paiement incomplet." end
  return "Profil paiement invalide."
end

function BANK.cashoutProfileKey(appName, seller)
  return sha256("cashout|" .. tostring(appName or "") .. "|" .. cleanName(seller))
end

function BANK.cashoutProfile(appName, seller)
  if type(config.bankCashoutProfiles) ~= "table" then config.bankCashoutProfiles = {} end
  return config.bankCashoutProfiles[BANK.cashoutProfileKey(appName, seller)]
end

function BANK.validCashoutProfile(profile, appName, seller)
  if type(profile) ~= "table" then return false end
  if profile.enabled == false then return false end
  if tostring(profile.appName or "") ~= tostring(appName or "") then return false end
  if tonumber(profile.computerId or -1) ~= os.getComputerID() then return false end
  if cleanName(profile.seller) == "" or cleanName(profile.seller) ~= cleanName(seller) then return false end
  if tostring(profile.marker or "") ~= BANK.cashoutMarker(profile.seller) then return false end
  if tostring(profile.bankId or "") == "" or not tonumber(profile.sender or 0) then return false end
  if type(profile.accessKey) ~= "string" or #profile.accessKey ~= 64 then return false end
  if type(profile.accountSecret) ~= "string" or #profile.accountSecret ~= 64 then return false end
  if not BANK.amount(profile.maxAmount or 1) then return false end
  return true
end

function BANK.cashoutProfileError(profile)
  if type(profile) ~= "table" then return "Cashout non autorise pour cette app." end
  if profile.enabled == false then return "Cashout desactive pour cette app." end
  if tonumber(profile.computerId or -1) ~= os.getComputerID() then return "Cashout cree sur un autre PC." end
  return "Profil cashout invalide."
end

function BANK.cashoutMarker(seller)
  return "-- SecureClickOS-Cashout: " .. cleanName(seller)
end

function BANK.sourceAllowsCashout(source, seller)
  seller = cleanName(seller)
  if seller == "" then return false end
  local prefix = "-- secureclickos-cashout:"
  for line in tostring(source or ""):gmatch("[^\r\n]+") do
    local normalized = line:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if normalized:sub(1, #prefix) == prefix then
      return cleanName(normalized:sub(#prefix + 1)) == seller
    end
  end
  return false
end

function BANK.cashoutSellersFromSource(source)
  local out = {}
  local prefix = "-- secureclickos-cashout:"
  for line in tostring(source or ""):gmatch("[^\r\n]+") do
    local normalized = line:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if normalized:sub(1, #prefix) == prefix then
      local seller = cleanName(normalized:sub(#prefix + 1))
      if seller ~= "" then out[seller] = true end
    end
  end
  return out
end

function BANK.savePayProfile(server, user)
  if type(server) ~= "table" then return false end
  user = cleanName(user)
  if user == "" then return false end
  if server.auth ~= "code" then
    messageBox("Paiements", {
      "Les paiements sandbox demandent",
      "un serveur banque en mode Code.",
      "Mode direct refuse pour les apps."
    })
    return false
  end
  config.bankPayProfile = {
    sender = tonumber(server.sender),
    bankId = tostring(server.bankId or ""),
    auth = "code",
    user = user,
    computerId = os.getComputerID(),
    configuredBy = currentUser and currentUser.name or "unknown",
    configuredAt = now()
  }
  saveConfig()
  appendAudit("bank payment profile configured for " .. user)
  messageBox("Paiements", {
    "Profil configure.",
    "Compte: " .. user,
    "Banque: " .. tostring(server.bankId or "")
  })
  return true
end

function BANK.askPayUser(server)
  local action, fields = inputForm("Compte paiement", {
    { key = "user", label = "Nom compte", maxLen = 32 }
  }, {
    { id = "ok", label = "Save", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return nil end
  BANK.savePayProfile(server, fields[1].value)
end

function BANK.configurePayments()
  if currentUser and currentUser.guest then
    messageBox("Paiements", { "Mode invite refuse." })
    return
  end
  if not tryOpenRednet() then messageBox("Paiements", { "Aucun modem rednet." }); return end
  local servers = {}
  local selected = 1
  while true do
    resetButtons()
    drawTop("Paiements sandbox")
    local p = config.bankPayProfile
    if BANK.validPayProfile(p) then
      writeAt(2, 4, "Actuel: " .. tostring(p.user) .. " @ " .. tostring(p.bankId), theme.good, theme.bg)
    elseif type(p) == "table" then
      writeAt(2, 4, "Profil invalide: " .. BANK.payProfileError(p), theme.bad, theme.bg)
    else
      writeAt(2, 4, "Aucun profil configure.", theme.warn, theme.bg)
    end
    addButton("scan", 2, 6, 9, 1, "Scan", theme.good, colors.black)
    addButton("manual", 13, 6, 10, 1, "Manual", theme.warn, colors.black)
    addButton("clear", 25, 6, 9, 1, "Clear", theme.bad, colors.white)
    addButton("back", 36, 6, 9, 1, "Back", theme.action, colors.black)
    writeAt(2, 8, "Choisis une banque mode Code paiement.", theme.muted, theme.bg)
    for i = 1, math.min(#servers, h - 10) do
      local s = servers[i]
      local bg = i == selected and theme.panel2 or theme.panel
      fill(2, 8 + i, w - 3, 1, bg)
      writeAt(3, 8 + i, truncate(tostring(s.bankId) .. " PC:" .. tostring(s.sender) .. " " .. BANK.accessLabel(s.auth), w - 5), colors.black, bg)
      buttons[#buttons + 1] = { id = "paybank:" .. i, x = 2, y = 8 + i, w = w - 3, h = 1 }
    end
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "scan" then
        local found = BANK.discoverServers()
        if found == "auto_lock" then return "auto_lock" end
        servers = found
        selected = 1
      elseif id == "manual" then
        local server = BANK.manualServer()
        if server == "auto_lock" then return "auto_lock" end
        if server then
          local r = BANK.askPayUser(server)
          if r == "auto_lock" then return "auto_lock" end
        end
      elseif id == "clear" then
        config.bankPayProfile = nil
        saveConfig()
        appendAudit("bank payment profile cleared")
      elseif id and id:sub(1, 8) == "paybank:" then
        selected = tonumber(id:sub(9)) or 1
        if servers[selected] then
          local r = BANK.askPayUser(servers[selected])
          if r == "auto_lock" then return "auto_lock" end
        end
      end
    end
  end
end

function BANK.setupCashoutForApp(fileName)
  if not isAdmin() then messageBox("Cashout", { "Admin seulement." }); return end
  if not BANK.validPayProfile(config.bankPayProfile) then
    messageBox("Cashout", { "Configure d'abord Banque > Paiements.", "Utilise la meme banque que shop." })
    return
  end
  local path = FILES_DIR .. "/" .. currentUser.name .. "/" .. tostring(fileName or "")
  local source = readPrivateFile(path)
  if source == "" then messageBox("Cashout", { "App introuvable ou illisible." }); return end
  local action, fields = inputForm("Cashout app", {
    { key = "seller", label = "Compte vendeur", value = "shop", maxLen = 32 },
    { key = "max", label = "Max retrait", value = "100", maxLen = 10 },
    { key = "code", label = "Code paiement", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "pass", label = "Mot de passe vendeur", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "ok", label = "Autoriser", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return end
  local seller = cleanName(fields[1].value)
  local maxAmount = BANK.amount(fields[2].value)
  local bankCode = fields[3].value
  local pass = fields[4].value
  fields[3].value, fields[4].value = "", ""
  if seller == "" or not maxAmount then
    bankCode, pass = nil, nil
    safeCollectGarbage()
    messageBox("Cashout", { "Compte vendeur ou max invalide." })
    return
  end
  if seller == cleanName(config.bankPayProfile.user) then
    bankCode, pass = nil, nil
    safeCollectGarbage()
    messageBox("Cashout", { "Le vendeur ne doit pas etre", "le compte joueur du profil paiement." })
    return
  end
  if not BANK.sourceAllowsCashout(source, seller) then
    bankCode, pass = nil, nil
    safeCollectGarbage()
    messageBox("Cashout refuse", {
      "L'app n'a pas le marqueur:",
      BANK.cashoutMarker(seller),
      "Ajoute cette ligne au code."
    })
    return
  end
  local session = {
    server = { sender = tonumber(config.bankPayProfile.sender), bankId = tostring(config.bankPayProfile.bankId or ""), auth = "code" },
    user = seller,
    accessKey = BANK.codeKey(config.bankPayProfile.bankId, bankCode),
    accountSecret = BANK.accountSecret(seller, pass),
    accessMode = "code"
  }
  bankCode, pass = nil, nil
  safeCollectGarbage()
  local ok, res = BANK.clientRequest(session, "balance")
  if ok == "auto_lock" then return "auto_lock" end
  if not ok then
    messageBox("Cashout refuse", { tostring(res), "Verifie compte vendeur/code/mdp." })
    return
  end
  local key = BANK.cashoutProfileKey(fileName, seller)
  config.bankCashoutProfiles[key] = {
    enabled = true,
    appName = tostring(fileName or ""),
    seller = seller,
    sender = tonumber(config.bankPayProfile.sender),
    bankId = tostring(config.bankPayProfile.bankId or ""),
    auth = "code",
    marker = BANK.cashoutMarker(seller),
    accessKey = session.accessKey,
    accountSecret = session.accountSecret,
    maxAmount = maxAmount,
    computerId = os.getComputerID(),
    createdBy = currentUser and currentUser.name or "admin",
    createdAt = now()
  }
  saveConfig()
  appendAudit("cashout app allowed: " .. tostring(fileName) .. " seller " .. seller)
  messageBox("Cashout OK", {
    "App autorisee: " .. tostring(fileName),
    "Vendeur: " .. seller,
    "Max retrait: " .. tostring(maxAmount),
    "Solde vendeur: " .. tostring(res.balance or "?")
  })
end

function BANK.configureCashoutApps()
  local selected = 1
  while true do
    local apps = RUNNER.listLuaApps(currentUser.name)
    resetButtons()
    drawTop("Cashout direct")
    writeAt(2, 4, "Rien a autoriser ici: l'app doit juste avoir:", theme.text, theme.bg)
    writeAt(2, 5, "-- SecureClickOS-Cashout: shop", theme.warn, theme.bg)
    writeAt(2, 6, "Le serveur retire depuis shop vers ton profil Paiements.", theme.text, theme.bg)
    addButton("back", 2, 8, 10, 1, "Back", theme.action, colors.black)
    if #apps == 0 then
      centerAt(11, "Aucune app .lua dans tes fichiers.", theme.muted, theme.bg)
    end
    for i = 1, math.min(#apps, h - 11) do
      local name = apps[i]
      local source = readPrivateFile(FILES_DIR .. "/" .. currentUser.name .. "/" .. name)
      local sellers = source ~= "" and BANK.cashoutSellersFromSource(source) or {}
      local mark = ""
      for seller in pairs(sellers) do mark = mark .. " [" .. seller .. "]" end
      if mark == "" then mark = " [pas cashout]" end
      local bg = i == selected and theme.panel2 or theme.panel
      fill(2, 8 + i, w - 3, 1, bg)
      writeAt(3, 8 + i, truncate(name .. mark, w - 5), colors.black, bg)
      buttons[#buttons + 1] = { id = "app:" .. i, x = 2, y = 8 + i, w = w - 3, h = 1 }
    end
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id and id:sub(1, 4) == "app:" then selected = tonumber(id:sub(5)) or selected end
    end
  end
end

function BANK.paymentSessionFromProfile(profile)
  if not BANK.validPayProfile(profile) then return nil, BANK.payProfileError(profile) end
  local action, fields = inputForm("Valider paiement", {
    { key = "code", label = "Code paiement", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "pay", label = "Payer", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "pay" then return nil, "Paiement annule." end
  local user = cleanName(profile.user)
  local bankCode = fields[1].value
  local pass = fields[2].value
  fields[1].value, fields[2].value = "", ""
  local session = {
    server = { sender = tonumber(profile.sender), bankId = tostring(profile.bankId or ""), auth = "code" },
    user = user,
    accessKey = BANK.codeKey(profile.bankId, bankCode),
    accountSecret = BANK.accountSecret(user, pass),
    accessMode = "code"
  }
  bankCode, pass = nil, nil
  safeCollectGarbage()
  return session
end

function BANK.sandboxPay(appName, to, amount, label)
  if currentUser and currentUser.guest then
    return { ok = false, error = "mode invite refuse" }
  end
  if not tryOpenRednet() then
    return { ok = false, error = "rednet indisponible" }
  end
  local profile = config.bankPayProfile
  local target = cleanName(to)
  local value = BANK.amount(amount)
  label = tostring(label or "Achat app"):sub(1, 48)
  if not BANK.validPayProfile(profile) then
    local reason = BANK.payProfileError(profile)
    messageBox("Paiement", {
      reason,
      "Configure sur ce PC client:",
      "Banque > Paiements ou UsePay."
    })
    return { ok = false, error = reason }
  end
  if target == "" or not value then
    return { ok = false, error = "paiement invalide" }
  end
  if target == cleanName(profile.user) then
    messageBox("Paiement refuse", {
      "Le vendeur et le client sont pareils.",
      "Cree un compte vendeur separe:",
      "exemple: shop ou casino."
    })
    return { ok = false, error = "vendeur identique au client" }
  end
  local confirm = messageBox("Paiement demande", {
    "App: " .. truncate(appName, 24),
    "Objet: " .. truncate(label, 30),
    "Vendeur: " .. target,
    "Montant: " .. tostring(value),
    "Solde verifie avant paiement."
  }, {
    { id = "pay", label = "Payer", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if confirm ~= "pay" then return { ok = false, error = "annule" } end
  local session, err = BANK.paymentSessionFromProfile(profile)
  if session == "auto_lock" then return { ok = false, error = "auto_lock" } end
  if not session then return { ok = false, error = err or "session refusee" } end
  local okBalance, balanceRes = BANK.clientRequest(session, "balance")
  if okBalance == "auto_lock" then return { ok = false, error = "auto_lock" } end
  if not okBalance then
    messageBox("Paiement refuse", { balanceRes, "Compte client non valide ?" })
    return { ok = false, error = balanceRes }
  end
  if tonumber(balanceRes.balance or 0) < value then
    messageBox("Solde insuffisant", {
      "Solde: " .. tostring(balanceRes.balance or 0),
      "Prix: " .. tostring(value)
    })
    return { ok = false, error = "solde insuffisant", balance = balanceRes.balance }
  end
  local okPay, payRes = BANK.clientRequest(session, "transfer", { target = target, amount = value, appPayment = "1", label = label })
  if okPay == "auto_lock" then return { ok = false, error = "auto_lock" } end
  if not okPay then
    messageBox("Paiement refuse", { payRes })
    return { ok = false, error = payRes }
  end
  appendAudit("sandbox payment: " .. tostring(appName) .. " -> " .. target .. " amount " .. tostring(value))
  messageBox("Paiement OK", {
    "Paye: " .. tostring(value),
    "Vendeur: " .. target,
    "Solde: " .. tostring(payRes.balance or "?")
  })
  return { ok = true, amount = value, target = target, balance = payRes.balance, label = label }
end

function BANK.sandboxCashout(appName, appCashoutSellers, fromAccount, amount, label)
  if currentUser and currentUser.guest then
    return { ok = false, error = "mode invite refuse" }
  end
  if not tryOpenRednet() then
    return { ok = false, error = "rednet indisponible" }
  end
  local profile = config.bankPayProfile
  local seller = cleanName(fromAccount)
  local value = BANK.amount(amount)
  label = tostring(label or "Retrait app"):sub(1, 48)
  if not BANK.validPayProfile(profile) then
    local reason = BANK.payProfileError(profile)
    messageBox("Cashout", {
      reason,
      "Configure le compte joueur:",
      "Banque > Paiements ou UsePay."
    })
    return { ok = false, error = reason }
  end
  if type(appCashoutSellers) ~= "table" or not appCashoutSellers[seller] then
    messageBox("Cashout", {
      "Ligne cashout absente.",
      "Ajoute dans l'app:",
      BANK.cashoutMarker(seller)
    })
    return { ok = false, error = "marqueur cashout absent" }
  end
  local targetUser = cleanName(profile.user)
  if seller == "" or not value then
    return { ok = false, error = "cashout invalide" }
  end
  if value > BANK.MAX_CASHOUT then
    messageBox("Cashout refuse", {
      "Montant trop grand.",
      "Max: " .. tostring(BANK.MAX_CASHOUT)
    })
    return { ok = false, error = "montant cashout trop grand" }
  end
  if seller == targetUser then
    messageBox("Cashout refuse", {
      "Compte casino = compte joueur.",
      "Utilise un compte casino separe."
    })
    return { ok = false, error = "casino identique au joueur" }
  end
  local confirm = messageBox("Cashout demande", {
    "App: " .. truncate(appName, 24),
    "Objet: " .. truncate(label, 30),
    "De: " .. seller,
    "Vers: " .. targetUser,
    "Montant: " .. tostring(value)
  }, {
    { id = "cashout", label = "Retirer", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if confirm ~= "cashout" then return { ok = false, error = "annule" } end
  local session = {
    server = { sender = tonumber(profile.sender), bankId = tostring(profile.bankId or ""), auth = "code" },
    user = targetUser,
    accessKey = BANK.publicKey(profile.bankId),
    accountSecret = "",
    accessMode = "public_cashout"
  }
  local okPay, payRes = BANK.clientRequest(session, "cashout", {
    target = seller,
    amount = value,
    cashoutPayment = "1",
    cashoutMarker = BANK.cashoutMarker(seller),
    appName = tostring(appName or "app"),
    label = label
  })
  if okPay == "auto_lock" then return { ok = false, error = "auto_lock" } end
  if not okPay then
    messageBox("Cashout refuse", { payRes })
    return { ok = false, error = payRes }
  end
  appendAudit("sandbox cashout: " .. tostring(appName) .. " " .. seller .. " -> " .. targetUser .. " amount " .. tostring(value))
  messageBox("Cashout OK", {
    "Recu: " .. tostring(value),
    "De: " .. seller,
    "Vers: " .. targetUser
  })
  return { ok = true, amount = value, from = seller, target = targetUser, balance = payRes.balance, label = label }
end

function BANK.clientLogin(server)
  if server.auth == "direct" then
    local warn = messageBox("Direct integrite", {
      "Mode sensible.",
      "Tu vas utiliser mdp + code integrite.",
      "Fais ca seulement sur ton serveur."
    }, {
      { id = "continue", label = "Continuer", color = theme.warn, fg = colors.black },
      { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
    })
    if warn ~= "continue" then return nil end
    local action, fields = inputForm("Login banque", {
      { key = "user", label = "Nom", maxLen = 32 },
      { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN },
      { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN }
    }, {
      { id = "ok", label = "Login", color = theme.good, fg = colors.black },
      { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
    })
    if action == "auto_lock" then return "auto_lock" end
    if action ~= "ok" then return nil end
    local user = cleanName(fields[1].value)
    local pass = fields[2].value
    local seal = fields[3].value
    fields[2].value, fields[3].value = "", ""
    local accessKey = BANK.directKey(server.bankId, user, pass, seal)
    local accountSecret = BANK.accountSecret(user, pass)
    pass, seal = nil, nil
    safeCollectGarbage()
    return { server = server, user = user, accessKey = accessKey, accountSecret = accountSecret, accessMode = "direct" }
  end

  local action, fields = inputForm("Login banque", {
    { key = "user", label = "Nom", maxLen = 32 },
    { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "ok", label = "Login", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "ok" then return nil end
  local user = cleanName(fields[1].value)
  local pass = fields[2].value
  local accessKey = BANK.publicKey(server.bankId)
  local accountSecret = BANK.accountSecret(user, pass)
  fields[2].value = ""
  pass = nil
  safeCollectGarbage()
  return { server = server, user = user, accessKey = accessKey, accountSecret = accountSecret, accessMode = "public" }
end

function BANK.clientRequest(session, action, fields)
  local packet = fields or {}
  packet.magic = BANK.PROTOCOL
  packet.kind = "request"
  packet.action = action
  packet.accessMode = session.accessMode or "public"
  packet.bankId = session.server.bankId
  packet.user = session.user
  packet.requestId = secureRandomHex(8)
  packet.nonce = secureRandomHex(8)
  if action == "create" then packet.accountSecret = session.accountSecret end
  packet.accountProof = BANK.accountProof(session.accountSecret, packet)
  BANK.signAccess(session.accessKey, packet)
  rednet.send(session.server.sender, packet, BANK.PROTOCOL)
  local timer = os.startTimer(BANK.REPLY_SECONDS)
  while true do
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "timer" and ev[2] == timer then return false, "Timeout banque." end
    if ev[1] == "rednet_message" and ev[4] == BANK.PROTOCOL then
      local msg = ev[3]
      if ev[2] == session.server.sender and type(msg) == "table" and msg.kind == "reply" and msg.requestId == packet.requestId then
        if msg.ok then return true, msg end
        return false, msg.error or "Erreur banque."
      end
    end
  end
end

function BANK.transactionLine(tx)
  local amount = tonumber(tx.amount or 0) or 0
  local sign = amount >= 0 and "+" or ""
  local label = tostring(tx.label or tx.kind or "tx")
  local other = tostring(tx.other or "?")
  return sign .. tostring(amount) .. " " .. other .. " " .. label
end

function BANK.viewTransactions(session)
  local ok, res = BANK.clientRequest(session, "transactions")
  if ok == "auto_lock" then return "auto_lock" end
  if not ok then messageBox("Transactions", { res }); return end
  local list = type(res.transactions) == "table" and res.transactions or {}
  while true do
    resetButtons()
    drawTop("Transactions")
    writeAt(2, 4, "Compte: " .. tostring(session.user), theme.text, theme.bg)
    writeAt(2, 5, "Solde: " .. tostring(res.balance or "?"), theme.warn, theme.bg)
    if #list == 0 then
      centerAt(9, "Aucune transaction.", theme.muted, theme.bg)
    else
      for i = 1, math.min(#list, h - 8) do
        writeAt(2, 6 + i, truncate(BANK.transactionLine(list[i]), w - 3), theme.text, theme.bg)
      end
    end
    addButton("refresh", 2, h - 2, 12, 1, "Refresh", theme.action, colors.black)
    addButton("back", 16, h - 2, 10, 1, "Back", theme.panel2, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "refresh" then
        ok, res = BANK.clientRequest(session, "transactions")
        if ok == "auto_lock" then return "auto_lock" end
        if not ok then messageBox("Transactions", { res }); return end
        list = type(res.transactions) == "table" and res.transactions or {}
      end
    end
  end
end

function BANK.clientScreen(server)
  local session = BANK.clientLogin(server)
  if session == "auto_lock" then return "auto_lock" end
  if not session then return end
  local balanceText = "?"
  while true do
    resetButtons()
    drawTop("Banque client")
    writeAt(2, 4, "Serveur: " .. tostring(server.bankId), theme.good, theme.bg)
    writeAt(2, 5, "Compte: " .. session.user, theme.text, theme.bg)
    writeAt(2, 6, "Solde: " .. tostring(balanceText), theme.warn, theme.bg)
    addButton("create", 2, 8, 10, 1, "Creer", theme.good, colors.black)
    addButton("refresh", 14, 8, 10, 1, "Solde", theme.action, colors.black)
    addButton("send", 26, 8, 10, 1, "Envoyer", theme.warn, colors.black)
    addButton("paycfg", 2, 10, 14, 1, "UsePay", theme.selected, colors.black)
    addButton("tx", 18, 10, 10, 1, "Hist", theme.action, colors.black)
    addButton("back", 38, 10, 10, 1, "Back", theme.panel2, colors.black)
    writeAt(2, h - 1, "Cree le compte, puis regarde le solde ou envoie argent.", theme.muted, theme.bg)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "create" then
        local ok, res = BANK.clientRequest(session, "create")
        if ok == "auto_lock" then return "auto_lock" end
        if ok then balanceText = tostring(res.balance or 0); messageBox("Banque", { res.created and "Compte cree." or "Compte deja present.", "Solde: " .. balanceText }) else messageBox("Erreur", { res }) end
      elseif id == "refresh" then
        local ok, res = BANK.clientRequest(session, "balance")
        if ok == "auto_lock" then return "auto_lock" end
        if ok then balanceText = tostring(res.balance or 0) else messageBox("Erreur", { res, "Si nouveau: clique Creer." }) end
      elseif id == "send" then
        local actionForm, fields = inputForm("Envoyer argent", {
          { key = "to", label = "A", maxLen = 32 },
          { key = "amount", label = "Montant", maxLen = 10 }
        }, {
          { id = "send", label = "Send", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if actionForm == "auto_lock" then return "auto_lock" end
        if actionForm == "send" then
          local amount = BANK.amount(fields[2].value)
          if not amount then
            messageBox("Erreur", { "Montant invalide." })
          else
            local ok, res = BANK.clientRequest(session, "transfer", { target = cleanName(fields[1].value), amount = amount })
            if ok == "auto_lock" then return "auto_lock" end
            if ok then balanceText = tostring(res.balance or 0); messageBox("Envoye", { tostring(res.amount) .. " vers " .. tostring(res.target), "Solde: " .. balanceText }) else messageBox("Erreur", { res }) end
          end
        end
      elseif id == "paycfg" then
        BANK.savePayProfile(server, session.user)
      elseif id == "tx" then
        local r = BANK.viewTransactions(session)
        if r == "auto_lock" then return "auto_lock" end
      end
    end
  end
end

function BANK.clientChoose()
  if not tryOpenRednet() then messageBox("Banque", { "Aucun modem rednet." }); return end
  local servers = {}
  local selected = 1
  while true do
    resetButtons()
    drawTop("Banque client")
    addButton("scan", 2, 4, 10, 1, "Scan", theme.good, colors.black)
    addButton("connect", 14, 4, 12, 1, "Connect", theme.action, colors.black)
    addButton("manual", 28, 4, 10, 1, "Manual", theme.warn, colors.black)
    addButton("back", 40, 4, 9, 1, "Back", theme.panel2, colors.black)
    writeAt(2, 6, "Serveurs banque:", theme.text, theme.bg)
    for i = 1, math.min(#servers, h - 8) do
      local s = servers[i]
      local bg = i == selected and theme.panel2 or theme.panel
      fill(2, 6 + i, w - 3, 1, bg)
      writeAt(3, 6 + i, truncate(tostring(s.bankId) .. " PC:" .. tostring(s.sender) .. " " .. BANK.accessLabel(s.auth), w - 5), colors.black, bg)
      buttons[#buttons + 1] = { id = "bank:" .. i, x = 2, y = 6 + i, w = w - 3, h = 1 }
    end
    if #servers == 0 then centerAt(11, "Clique Scan.", theme.muted, theme.bg) end
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id and id:sub(1, 5) == "bank:" then
        selected = tonumber(id:sub(6)) or 1
        if servers[selected] then
          local r = BANK.clientScreen(servers[selected])
          if r == "auto_lock" then return "auto_lock" end
        end
      elseif id == "scan" then
        drawTop("Scan banque")
        centerAt(8, "Recherche serveurs banque...", theme.text, theme.bg)
        local found = BANK.discoverServers()
        if found == "auto_lock" then return "auto_lock" end
        servers = found
        selected = 1
      elseif id == "connect" then
        if servers[selected] then
          local r = BANK.clientScreen(servers[selected])
          if r == "auto_lock" then return "auto_lock" end
        else
          messageBox("Banque", { "Aucun serveur selectionne." })
        end
      elseif id == "manual" then
        local server = BANK.manualServer()
        if server == "auto_lock" then return "auto_lock" end
        if server then
          local r = BANK.clientScreen(server)
          if r == "auto_lock" then return "auto_lock" end
        end
      end
    end
  end
end

function appBank()
  if not isValidSession() then return "lock" end
  while true do
    resetButtons()
    drawTop("Banque")
    writeAt(2, 4, "Banque SecureClickOS.", theme.text, theme.bg)
    writeAt(2, 6, "Serveur: service permanent en arriere-plan.", theme.warn, theme.bg)
    writeAt(2, 7, "Client: nom + mot de passe.", theme.text, theme.bg)
    addButton("server", 4, 10, 16, 3, "Serveur", theme.warn, colors.black)
    addButton("client", 25, 10, 16, 3, "Client", theme.good, colors.black)
    addButton("paycfg", 4, 15, 12, 2, "Paiements", theme.selected, colors.black)
    addButton("cashout", 18, 15, 12, 2, "Cashout", theme.good, colors.black)
    addButton("back", 32, 15, 12, 2, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "server" then
        local r = BANK.runServer()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "client" then
        local r = BANK.clientChoose()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "paycfg" then
        local r = BANK.configurePayments()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "cashout" then
        local r = BANK.configureCashoutApps()
        if r == "auto_lock" then return "auto_lock" end
      end
    end
  end
end

function uniqueFileName(dir, fileName)
  fileName = transferFileName(fileName)
  if not fs.exists(dir .. "/" .. fileName) then return fileName end
  local base, ext = fileName:match("^(.*)(%.[^%.]+)$")
  if not base then base, ext = fileName, "" end
  for i = 1, 99 do
    local candidate = base .. "_" .. tostring(i) .. ext
    if not fs.exists(dir .. "/" .. candidate) then return candidate end
  end
  return base .. "_" .. tostring(now()) .. ext
end

function queuedFileCount(name)
  local box = ensureFileQueue(name)
  return #box
end

function verifyQueuedFile(item)
  local pkg = {
    magic = FILE_PROTOCOL,
    from = item.rawFrom or item.from,
    to = item.to,
    fileName = item.signedFileName or item.fileName,
    cipherHex = item.cipherHex,
    size = item.size,
    time = item.time,
    nonce = item.nonce,
    senderId = item.senderId,
    targetId = item.targetId
  }
  return constantTimeEquals(tostring(item.sig or ""), fileTransferSignature(pkg, config.networkKey))
end

function importQueuedFiles()
  if not isValidSession() then return "lock", 0, 0 end
  if config.networkKey == "" then return "nokey", 0, queuedFileCount(currentUser.name) end
  local dir = FILES_DIR .. "/" .. currentUser.name
  ensureDir(dir)
  local box = ensureFileQueue(currentUser.name)
  local imported, failed = 0, 0
  for i = #box, 1, -1 do
    local item = box[i]
    if verifyQueuedFile(item) then
      local content = decryptTransferContent(item.cipherHex, config.networkKey, item.nonce)
      if #content == tonumber(item.size or -1) and #content <= MAX_TRANSFER_FILE_LEN then
        local name = uniqueFileName(dir, item.fileName)
        if writePrivateFile(dir .. "/" .. name, content) then
          imported = imported + 1
          table.remove(box, i)
          appendAudit("network file imported: " .. name)
        else
          failed = failed + 1
        end
      else
        failed = failed + 1
      end
    else
      failed = failed + 1
    end
  end
  saveFileQueue()
  return "ok", imported, failed
end

function sendNetworkFile(fileName)
  if not isValidSession() then return "lock" end
  if not config.networkMail then messageBox("Erreur", { "Network OFF dans Reglages." }); return end
  if config.networkKey == "" then messageBox("Erreur", { "Definis une Net Key avant." }); return end
  if not tryOpenRednet() then messageBox("Erreur", { "Aucun modem rednet trouve." }); return end
  local safeName = transferFileName(fileName)
  local dir = FILES_DIR .. "/" .. currentUser.name
  local content = readPrivateFile(dir .. "/" .. tostring(fileName or ""))
  if #content > MAX_TRANSFER_FILE_LEN then
    messageBox("Trop gros", { "Max transfert: " .. tostring(MAX_TRANSFER_FILE_LEN) .. " caracteres." })
    return
  end
  local a, f = inputForm("Envoyer fichier", {
    { key = "to", label = "User cible", maxLen = 32 },
    { key = "pc", label = "PC cible", maxLen = 8 }
  }, {
    { id = "send", label = "Send", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if a == "auto_lock" then return "auto_lock" end
  if a ~= "send" then return end
  local to = cleanName(f[1].value)
  if to == "" then messageBox("Erreur", { "Utilisateur cible vide." }); return end
  local targetId = tonumber(f[2].value)
  local nonce = secureRandomHex(16)
  local pkg = {
    magic = FILE_PROTOCOL,
    from = currentUser.name,
    to = to,
    fileName = safeName,
    cipherHex = encryptTransferContent(content, config.networkKey, nonce),
    size = #content,
    time = now(),
    nonce = nonce,
    senderId = os.getComputerID(),
    targetId = targetId
  }
  pkg.sig = fileTransferSignature(pkg, config.networkKey)
  if targetId then
    rednet.send(targetId, pkg, FILE_PROTOCOL)
  else
    rednet.broadcast(pkg, FILE_PROTOCOL)
  end
  appendAudit("network file sent: " .. safeName .. " to " .. to)
  messageBox("Envoye", {
    safeName .. " envoye.",
    targetId and ("PC cible: " .. tostring(targetId)) or "Broadcast reseau."
  })
end

function editUserFile(fileName)
  local dir = FILES_DIR .. "/" .. currentUser.name
  local path = dir .. "/" .. fileName
  local action, content = readMultiline("Edit: " .. fileName, readPrivateFile(path))
  if action == "auto_lock" then return "auto_lock" end
  if action == "save" then
    writePrivateFile(path, content)
    appendAudit("file saved: " .. fileName)
  end
end

function appFiles()
  if not isValidSession() then return "lock" end
  local dir = FILES_DIR .. "/" .. currentUser.name
  ensureDir(dir)
  local selected = 1
  while true do
    resetButtons()
    drawTop("Fichiers prives")
    local pending = queuedFileCount(currentUser.name)
    addButton("new", 2, 3, 7, 1, "New", theme.good, colors.black)
    addButton("open", 10, 3, 7, 1, "Open", theme.action, colors.black)
    addButton("run", 18, 3, 7, 1, "Run", theme.selected, colors.black)
    addButton("send", 26, 3, 7, 1, "Send", theme.warn, colors.black)
    addButton("inbox", 34, 3, 7, 1, pending > 0 and ("In " .. tostring(pending)) or "Inbox", pending > 0 and theme.selected or theme.action, colors.black)
    addButton("delete", 42, 3, 7, 1, "Delete", theme.bad, colors.white)
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)

    local files = fs.list(dir)
    table.sort(files)
    local maxRows = h - 8
    for i = 1, math.min(#files, maxRows) do
      local bg = (i == selected) and theme.panel2 or theme.panel
      fill(2, 5 + i - 1, w - 3, 1, bg)
      writeAt(3, 5 + i - 1, truncate(files[i], w - 5), theme.fieldText, bg)
      buttons[#buttons + 1] = { id = "file:" .. i, x = 2, y = 5 + i - 1, w = w - 3, h = 1 }
    end
    if #files == 0 then centerAt(8, "Aucun fichier.", theme.muted, theme.bg) end

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id and id:sub(1, 5) == "file:" then selected = tonumber(id:sub(6)) or 1 end
      if id == "new" then
        local a, f = inputForm("Nouveau fichier", {
          { key = "name", label = "Nom du fichier", maxLen = 32 }
        }, {
          { id = "ok", label = "Create", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if a == "auto_lock" then return "auto_lock" end
        if a == "ok" then
          local name = safeFileName(f[1].value)
          if not name then
            messageBox("Erreur", { "Nom invalide." })
          else
            writePrivateFile(dir .. "/" .. name, "")
            local r = editUserFile(name)
            if r == "auto_lock" then return "auto_lock" end
          end
        end
      elseif id == "open" then
        if files[selected] then
          local r = editUserFile(files[selected])
          if r == "auto_lock" then return "auto_lock" end
        end
      elseif id == "send" then
        if files[selected] then
          local r = sendNetworkFile(files[selected])
          if r == "auto_lock" then return "auto_lock" end
        else
          messageBox("Erreur", { "Selectionne un fichier." })
        end
      elseif id == "run" then
        if files[selected] then
          local r = RUNNER.runLuaFile(files[selected])
          if r == "auto_lock" then return "auto_lock" end
        else
          messageBox("Erreur", { "Selectionne un fichier .lua." })
        end
      elseif id == "inbox" then
        local state, imported, failed = importQueuedFiles()
        if state == "lock" then return "auto_lock" end
        if state == "nokey" then
          messageBox("Inbox", { "Net Key manquante.", "Fichiers en attente: " .. tostring(failed) })
        else
          messageBox("Inbox", {
            "Importes: " .. tostring(imported),
            "Echecs: " .. tostring(failed)
          })
        end
      elseif id == "delete" then
        if files[selected] then
          local yes = messageBox("Confirmer", { "Supprimer " .. files[selected] .. " ?" }, {
            { id = "yes", label = "Yes", color = theme.bad, fg = colors.white },
            { id = "no", label = "No", color = theme.action, fg = colors.black }
          })
          if yes == "yes" then
            fs.delete(dir .. "/" .. files[selected])
            RUNNER.clearCaches()
            appendAudit("file deleted: " .. files[selected])
            selected = 1
          end
        end
      end
    end
  end
end

function appDownloader()
  if not isValidSession() then return "lock" end
  if currentUser and currentUser.guest then
    messageBox("Telechargeur", { "Mode invite refuse." })
    return
  end
  local action, fields = inputForm("Telecharger .lua", {
    { key = "url", label = "URL https .lua", maxLen = 180 }
  }, {
    { id = "download", label = "Download", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if action == "auto_lock" then return "auto_lock" end
  if action ~= "download" then return end

  local url = tostring(fields[1].value or ""):gsub("%s+", "")
  if not url:match("^https?://") then
    messageBox("Refuse", { "URL invalide.", "Utilise http:// ou https://." })
    return
  end
  local urlPath = url:gsub("[?#].*$", "")
  local fileName = safeFileName(urlPath:match("([^/]+)$") or "")
  if not fileName or not fileName:lower():match("%.lua$") then
    messageBox("Refuse", { "Seulement les fichiers .lua.", "L'URL doit finir par .lua." })
    return
  end

  MAINT.enableInternetAuto()
  if not http or type(http.get) ~= "function" then
    messageBox("Internet OFF", { "HTTP indisponible.", "Active HTTP cote serveur/modpack." })
    return
  end
  local ok, response, err = pcall(http.get, url)
  if not ok or not response then
    messageBox("Erreur", { "Telechargement impossible.", truncate(tostring(err or response or ""), w - 4) })
    return
  end
  local code = response.getResponseCode and response.getResponseCode() or 200
  local source = response.readAll and response.readAll() or ""
  if response.close then response.close() end
  if tonumber(code) and tonumber(code) >= 400 then
    messageBox("Erreur HTTP", { "Code: " .. tostring(code) })
    return
  end
  if source == "" then
    messageBox("Refuse", { "Fichier vide." })
    return
  end
  if #source > RUNNER.MAX_SOURCE_LEN then
    messageBox("Refuse", { "Programme trop gros.", "Max: " .. tostring(RUNNER.MAX_SOURCE_LEN) .. " caracteres." })
    return
  end
  if source:sub(1, 4) == "\27Lua" then
    messageBox("Refuse", { "Bytecode Lua refuse.", "Texte .lua seulement." })
    return
  end

  local chunk, syntaxErr
  if loadstring then
    chunk, syntaxErr = loadstring(source, "@" .. fileName)
  elseif load then
    chunk, syntaxErr = load(source, "@" .. fileName, "t", {})
  else
    messageBox("Erreur", { "loadstring indisponible." })
    return
  end
  if not chunk then
    messageBox("Erreur Lua", { truncate(tostring(syntaxErr), w - 4) })
    return
  end

  local dir = FILES_DIR .. "/" .. currentUser.name
  ensureDir(dir)
  local savedName = uniqueFileName(dir, fileName)
  if not writePrivateFile(dir .. "/" .. savedName, source) then
    messageBox("Erreur", { "Impossible d'enregistrer." })
    return
  end
  appendAudit("downloaded lua app: " .. tostring(savedName))
  local nextAction = messageBox("Telecharge", {
    "Fichier: " .. savedName,
    "Sauve dans Fichiers.",
    "Il apparaitra dans le menu Lua."
  }, {
    { id = "run", label = "Run", color = theme.good, fg = colors.black },
    { id = "ok", label = "OK", color = theme.action, fg = colors.black }
  })
  if nextAction == "run" then
    return RUNNER.runLuaFile(savedName)
  end
end

function changeOwnPassword()
  local a, f = inputForm("Changer mot de passe", {
    { key = "old", label = "Ancien", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "new", label = "Nouveau", mask = true, maxLen = MAX_PASSWORD_LEN },
    { key = "new2", label = "Confirmer", mask = true, maxLen = MAX_PASSWORD_LEN }
  }, {
    { id = "ok", label = "Save", color = theme.good, fg = colors.black },
    { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
  })
  if a == "auto_lock" then return "auto_lock" end
  if a ~= "ok" then return end
  local ok = verifyPassword(currentUser.name, f[1].value)
  if not ok then messageBox("Erreur", { "Ancien mot de passe incorrect." }); return end
  if f[2].value ~= f[3].value then messageBox("Erreur", { "Confirmation differente." }); return end
  local oldKey = currentFileKey
  local userName = currentUser.name
  local done, err = setPassword(currentUser.name, f[2].value)
  if done then
    local newKey = deriveFileKey(users[userName], f[2].value)
    reencryptUserFiles(userName, oldKey, newKey)
    RUNNER.clearCaches()
    createSession(users[userName], f[2].value)
  end
  f[1].value, f[2].value, f[3].value = "", "", ""
  safeCollectGarbage()
  messageBox(done and "OK" or "Erreur", { done and "Mot de passe change." or err })
end

function viewAudit()
  while true do
    resetButtons()
    drawTop("Audit")
    local lines = {}
    if fs.exists(AUDIT_FILE) then
      local f = fs.open(AUDIT_FILE, "r")
      while true do
        local line = f.readLine()
        if not line then break end
        lines[#lines + 1] = line
      end
      f.close()
    end
    local start = math.max(1, #lines - (h - 6) + 1)
    for i = start, #lines do
      writeAt(2, 3 + i - start, truncate(lines[i], w - 3), theme.text, theme.bg)
    end
    if #lines == 0 then centerAt(8, "Audit vide.", theme.muted, theme.bg) end
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)
    if isAdmin() then
      addButton("mirror", 14, h - 2, 12, 1, "Mirror", theme.warn, colors.black)
      addButton("mirroroff", 28, h - 2, 10, 1, "Off", theme.panel2, colors.black)
      local label = tostring(config.auditMirrorId or "")
      if label ~= "" then writeAt(40, h - 2, "PC " .. truncate(label, 6), theme.muted, theme.bg) end
    end
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "mirror" and isAdmin() then
        local a, f = inputForm("Audit mirror", {
          { key = "pc", label = "PC miroir ID", value = tostring(config.auditMirrorId or ""), maxLen = 8 }
        }, {
          { id = "ok", label = "Save", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if a == "auto_lock" then return "auto_lock" end
        if a == "ok" then
          config.auditMirrorId = tostring(tonumber(f[1].value) or "")
          saveConfig()
          appendAudit("audit mirror set to " .. tostring(config.auditMirrorId or ""))
        end
      elseif id == "mirroroff" and isAdmin() then
        config.auditMirrorId = ""
        saveConfig()
        appendAudit("audit mirror disabled")
      end
    end
  end
end

function appStorage()
  if not isValidSession() then return "lock" end
  while true do
    resetButtons()
    drawTop("Stockage")
    local root, side, mount = STORAGE.findExternal()
    local pcFree = STORAGE.free("/")
    local pcUsed = STORAGE.used("/")
    local pcCap = STORAGE.capacity("/")
    writeAt(2, 4, "PC libre: " .. STORAGE.formatBytes(pcFree) .. " (" .. tostring(pcFree) .. " o)", theme.text, theme.bg)
    if pcCap then writeAt(2, 5, "PC utilise/total: " .. STORAGE.formatBytes(pcUsed) .. " / " .. STORAGE.formatBytes(pcCap), theme.muted, theme.bg) end
    writeAt(2, 6, "Stockage externe: " .. (config.externalStorage and "ON" or "OFF"), config.externalStorage and theme.good or theme.warn, theme.bg)
    if root then
      local diskFree = STORAGE.free(root)
      local diskUsed = STORAGE.used(root)
      local diskCap = STORAGE.capacity(root)
      writeAt(2, 8, "Disquette SCOS: " .. tostring(mount) .. " (" .. tostring(side) .. ")", theme.good, theme.bg)
      writeAt(2, 9, "Disquette libre: " .. STORAGE.formatBytes(diskFree) .. " (" .. tostring(diskFree) .. " o)", theme.text, theme.bg)
      if diskCap then writeAt(2, 10, "Disquette utilise/total: " .. STORAGE.formatBytes(diskUsed) .. " / " .. STORAGE.formatBytes(diskCap), theme.muted, theme.bg) end
      writeAt(2, 11, "Mails + fichiers recus + audit archive peuvent aller dessus.", theme.muted, theme.bg)
    else
      writeAt(2, 8, "Aucune disquette stockage SecureClickOS.", theme.warn, theme.bg)
      writeAt(2, 9, "Prepare une disquette vide avec le bouton Prepare.", theme.muted, theme.bg)
    end
    addButton("clean", 2, h - 4, 12, 1, "Clean", theme.action, colors.black)
    if isAdmin() then
      addButton("prepare", 16, h - 4, 14, 1, "Prepare", theme.good, colors.black)
      addButton("toggle", 32, h - 4, 12, 1, config.externalStorage and "Disable" or "Enable", theme.warn, colors.black)
    end
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "clean" then
        STORAGE.emergencyCleanup("manual", 65536)
        messageBox("Stockage", { "Nettoyage termine.", "Libre PC: " .. tostring(STORAGE.free("/")) })
      elseif id == "toggle" and isAdmin() then
        config.externalStorage = not config.externalStorage
        saveConfig()
        appendAudit("external storage " .. (config.externalStorage and "enabled" or "disabled"))
      elseif id == "prepare" and isAdmin() then
        local ok = messageBox("Prepare Disk", {
          "Utilise une disquette a toi.",
          "Ne mets pas de startup.lua dessus.",
          "Elle stockera des donnees non critiques."
        }, {
          { id = "ok", label = "Prepare", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if ok == "ok" then
          local m, s = findInsertedDisk()
          if not m then
            messageBox("Erreur", { "Aucune disquette detectee." })
          elseif diskHasSuspiciousCode(m) then
            messageBox("Refuse", { "La disquette contient un boot/hack.", "Supprime startup.lua/install.lua avant." })
          else
            local r = STORAGE.rootFor(m)
            ensureDir(r)
            saveTable(STORAGE.markerPath(m), {
              magic = STORAGE.MAGIC,
              computerId = os.getComputerID(),
              version = VERSION,
              createdAt = now()
            })
            config.externalStorage = true
            saveConfig()
            if disk and disk.setLabel then pcall(disk.setLabel, s, "SCOS Storage") end
            appendAudit("external storage prepared on " .. tostring(s))
            messageBox("OK", { "Disquette stockage preparee.", "Elle ne boot pas. Elle stocke seulement." })
          end
        end
      end
    end
  end
end

function adminUsers()
  if not isAdmin() then messageBox("Refuse", { "Admin seulement." }); return end
  local selected = nil
  while true do
    resetButtons()
    drawTop("Gestion users")
    addButton("add", 2, 3, 10, 1, "Add", theme.good, colors.black)
    addButton("reset", 14, 3, 10, 1, "Reset", theme.action, colors.black)
    addButton("role", 26, 3, 10, 1, "Role", theme.warn, colors.black)
    addButton("delete", 38, 3, 10, 1, "Delete", theme.bad, colors.white)
    addButton("back", w - 11, 3, 10, 1, "Back", theme.action, colors.black)

    local names = {}
    for name in pairs(users) do names[#names + 1] = name end
    table.sort(names)
    if not selected and names[1] then selected = names[1] end
    for i, name in ipairs(names) do
      if i > h - 7 then break end
      local bg = (name == selected) and theme.panel2 or theme.panel
      fill(2, 5 + i - 1, w - 3, 1, bg)
      writeAt(3, 5 + i - 1, name .. " [" .. users[name].role .. "]", theme.fieldText, bg)
      buttons[#buttons + 1] = { id = "user:" .. name, x = 2, y = 5 + i - 1, w = w - 3, h = 1 }
    end

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id and id:sub(1, 5) == "user:" then selected = id:sub(6) end
      if id == "add" then
        local a, f = inputForm("Ajouter user", {
          { key = "name", label = "Nom", maxLen = 32 },
          { key = "pass", label = "Mot de passe", mask = true, maxLen = MAX_PASSWORD_LEN }
        }, {
          { id = "user", label = "User", color = theme.good, fg = colors.black },
          { id = "admin", label = "Admin", color = theme.warn, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if a == "auto_lock" then return "auto_lock" end
        if a == "user" or a == "admin" then
          local ok, err = createUser(f[1].value, f[2].value, a)
          f[2].value = ""
          safeCollectGarbage()
          messageBox(ok and "OK" or "Erreur", { ok and "Utilisateur cree." or err })
        end
      elseif id == "reset" and selected then
        local a, f = inputForm("Reset password", {
          { key = "pass", label = "Nouveau", mask = true, maxLen = MAX_PASSWORD_LEN }
        }, {
          { id = "ok", label = "Save", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if a == "auto_lock" then return "auto_lock" end
        if a == "ok" then
          local ok, err = setPassword(selected, f[1].value)
          f[1].value = ""
          safeCollectGarbage()
          messageBox(ok and "OK" or "Erreur", { ok and "Mot de passe reset." or err })
        end
      elseif id == "role" and selected then
        local u = users[selected]
        if u.role == "admin" and adminCount() <= 1 then
          messageBox("Impossible", { "Il faut garder au moins un admin." })
        else
          u.role = (u.role == "admin") and "user" or "admin"
          saveUsers()
          appendAudit("role changed for " .. selected .. " to " .. u.role)
        end
      elseif id == "delete" and selected then
        if selected == currentUser.name then
          messageBox("Impossible", { "Tu ne peux pas supprimer ta session." })
        elseif users[selected].role == "admin" and adminCount() <= 1 then
          messageBox("Impossible", { "Il faut garder au moins un admin." })
        else
          local yes = messageBox("Confirmer", { "Supprimer " .. selected .. " ?" }, {
            { id = "yes", label = "Yes", color = theme.bad, fg = colors.white },
            { id = "no", label = "No", color = theme.action, fg = colors.black }
          })
          if yes == "yes" then
            users[selected] = nil
            mail.boxes[selected] = nil
            saveUsers()
            saveMail()
            appendAudit("user deleted: " .. selected)
            selected = nil
          end
        end
      end
    end
  end
end

function appSecurity()
  if not isValidSession() then return "lock" end
  while true do
    resetButtons()
    drawTop("Securite")
    addButton("password", 4, 5, 18, 3, "Password", theme.good, colors.black)
    addButton("audit", 26, 5, 18, 3, "Audit", theme.action, colors.black)
    if isAdmin() then addButton("users", 4, 10, 18, 3, "Users", theme.warn, colors.black) end
    addButton("lock", 26, 10, 18, 3, "Lock", theme.bad, colors.white)
    if isAdmin() then addButton("seal", 4, 14, 18, 2, "Seal OS", theme.selected, colors.black) end
    if isAdmin() then addButton("recovery", 26, 14, 18, 2, "Recovery", theme.good, colors.black) end
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)
    writeAt(2, h - 1, "Protection: hash+sel, session, audit, integrite.", theme.muted, theme.bg)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "lock" then return "lock" end
      if id == "password" then
        local r = changeOwnPassword()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "audit" then
        local r = viewAudit()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "users" then
        local r = adminUsers()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "seal" and isAdmin() then
        local a, f = inputForm("Seal OS", {
          { key = "seal", label = "Code integrite", mask = true, maxLen = MAX_PASSWORD_LEN }
        }, {
          { id = "ok", label = "Seal", color = theme.good, fg = colors.black },
          { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
        })
        if a == "auto_lock" then return "auto_lock" end
        if a == "ok" then
          local sealed, err = sealSystem("manual admin seal", currentUser.name, f[1].value)
          if sealed then installSelfRecovery(true) end
          f[1].value = ""
          safeCollectGarbage()
          messageBox(sealed and "OK" or "Erreur", { sealed and "Empreinte systeme signee." or err })
        end
      elseif id == "recovery" and isAdmin() then
        makeRecoveryDisk()
      end
    end
  end
end

function appSettings()
  if not isValidSession() then return "lock" end
  while true do
    resetButtons()
    drawTop("Reglages")
    local netLabel = config.networkMail and "Network ON" or "Network OFF"
    addButton("network", 4, 5, 18, 3, netLabel, config.networkMail and theme.good or theme.bad, colors.black)
    addButton("key", 26, 5, 18, 3, "Net Key", theme.action, colors.black)
    addButton("lock60", 4, 10, 12, 2, "Lock 60", config.lockAfter == 60 and theme.selected or theme.panel2, colors.black)
    addButton("lock180", 18, 10, 12, 2, "Lock 180", config.lockAfter == 180 and theme.selected or theme.panel2, colors.black)
    addButton("lock300", 32, 10, 12, 2, "Lock 300", config.lockAfter == 300 and theme.selected or theme.panel2, colors.black)
    addButton("storage", 4, 14, 12, 2, "Storage", theme.selected, colors.black)
    addButton("power", 18, 14, 12, 2, "Shutdown", theme.bad, colors.white)
    addButton("reboot", 32, 14, 12, 2, "Reboot", theme.warn, colors.black)
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)
    writeAt(2, h - 1, "Network = mails + fichiers par cle partagee.", theme.muted, theme.bg)

    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
      if id == "network" then
        config.networkMail = not config.networkMail
        saveConfig()
        if config.networkMail then
          if tryOpenRednet() then
            appendAudit("network mail enabled")
          else
            messageBox("Attention", { "Aucun modem trouve.", "Le bouton reste active, mais rednet attendra un modem." })
          end
        else
          appendAudit("network mail disabled")
        end
      elseif id == "key" then
        if not isAdmin() then
          messageBox("Refuse", { "Admin seulement." })
        else
          local a, f = inputForm("Cle reseau", {
            { key = "key", label = "Cle partagee", mask = true, value = config.networkKey or "", maxLen = MAX_PASSWORD_LEN }
          }, {
            { id = "ok", label = "Save", color = theme.good, fg = colors.black },
            { id = "cancel", label = "Cancel", color = theme.bad, fg = colors.white }
          })
          if a == "auto_lock" then return "auto_lock" end
          if a == "ok" then
            config.networkKey = f[1].value
            saveConfig()
            appendAudit("network key changed")
            messageBox("OK", { "Cle reseau mise a jour." })
          end
        end
      elseif id == "lock60" or id == "lock180" or id == "lock300" then
        config.lockAfter = tonumber(id:match("%d+")) or 180
        saveConfig()
      elseif id == "storage" then
        local r = appStorage()
        if r == "auto_lock" then return "auto_lock" end
      elseif id == "power" then
        local yes = messageBox("Power", { "Eteindre le computer ?" }, {
          { id = "yes", label = "Yes", color = theme.bad, fg = colors.white },
          { id = "no", label = "No", color = theme.action, fg = colors.black }
        })
        if yes == "yes" then os.shutdown() end
      elseif id == "reboot" then
        local yes = messageBox("Reboot", { "Redemarrer le computer ?" }, {
          { id = "yes", label = "Yes", color = theme.warn, fg = colors.black },
          { id = "no", label = "No", color = theme.action, fg = colors.black }
        })
        if yes == "yes" then os.reboot() end
      end
    end
  end
end

function appHelp()
  if not isValidSession() then return "lock" end
  while true do
    resetButtons()
    drawTop("Aide")
    local lines = {
      "Ce OS est fait pour ComputerCraft / CC:Tweaked.",
      "",
      "Ce qui est protege:",
      "- login avec mot de passe hash+sel",
      "- refus des comptes modifies ou trop faibles",
      "- jeton de session interne",
      "- code integrite separe pour signer le sceau",
      "- blocage apres erreurs",
      "- ecran bleu recovery: verifier, reboot, continuer",
      "- journal audit",
      "- alerte si startup/users/config changent",
      "- backup cache et auto-repair de startup.lua",
      "- backup anti-downgrade apres mise a jour",
      "- demarrage disque CraftOS desactive",
      "- blocage/ejection stricte des disques de donnees",
      "- scan disque meme pendant crash/reboot",
      "- creation admin de disque recovery confirme",
      "- update debug signe depuis disque sans effacer /secureos",
      "- update GitHub auto au boot si version valide",
      "- audit miroir rednet optionnel vers un PC dedie",
      "- verrouillage automatique",
      "- fichiers prives chiffres + MAC anti-modif",
      "- menu deroulant pour lancer les apps .lua",
      "- telechargeur HTTPS limite aux fichiers .lua",
      "- lancement .lua en sandbox avec rednet + GPS limite",
      "- sandbox sans fs/shell reels ni acces disque systeme",
      "- clic droit app: info, masquer, admin trusted",
      "- mode serveur irreversible avec editeur + runner Lua protege",
      "- app banque: serveur debug, client nom+mot de passe",
      "- banque direct integrite avec avertissement serieux",
      "- paiements app: sandbox + serveur, profil PC client requis",
      "- cashout app direct avec marqueur + confirmation + limite",
      "- mode sans code limite aux apps/jeux + aide",
      "- apps integrees: calculatrice, horloge, jeux, chat LAN",
      "- mail reseau HMAC + computerID affiche en identite",
      "- envoi de fichiers avec Net Key partagee",
      "- stockage externe optionnel sur disquette SecureClickOS",
      "- nettoyage anti-out-of-space des logs/cache temporaires",
      "- paste limite dans les champs",
      "",
      "Limite importante:",
      "Le verrou disque agit apres une installation sans disque.",
      "Installe/reboote une fois, puis les disk startup sont bloques.",
      "Lua ne garantit pas l'effacement memoire instantane.",
      "Un serveur doit aussi proteger physiquement le computer."
    }
    for i, line in ipairs(lines) do
      if 3 + i > h - 3 then break end
      writeAt(2, 3 + i, truncate(line, w - 3), theme.text, theme.bg)
    end
    addButton("back", 2, h - 2, 10, 1, "Back", theme.action, colors.black)
    local ev = { pullSecureEvent() }
    if ev[1] == "auto_lock" then return "auto_lock" end
    if ev[1] == "mouse_click" then
      local id = buttonAt(ev[3], ev[4])
      if id == "back" then return end
    end
  end
end

function lockSession()
  if currentUser then appendAudit("lock") end
  currentUser = nil
  currentFileKey = nil
  sessionNonce = nil
  sessionToken = nil
  if RUNNER and RUNNER.clearCaches then RUNNER.clearCaches() end
  setStatus("Session verrouillee.")
end

function MAINT.loadCrashInfo()
  local ok, data = pcall(loadTable, MAINT.CRASH_FILE, {})
  if not ok or type(data) ~= "table" then data = {} end
  data.count = tonumber(data.count or 0) or 0
  data.lastError = tostring(data.lastError or "")
  return data
end

function MAINT.saveCrashInfo(data)
  pcall(ensureDir, ROOT)
  pcall(saveTable, MAINT.CRASH_FILE, data or {})
end

function MAINT.noteCrash(err)
  local data = MAINT.loadCrashInfo()
  data.count = (tonumber(data.count or 0) or 0) + 1
  data.lastError = tostring(err or "")
  data.lastAt = now()
  MAINT.saveCrashInfo(data)
  pcall(appendAudit, "protected crash #" .. tostring(data.count) .. ": " .. tostring(err))
  return data
end

function MAINT.clearCrashInfo()
  MAINT.saveCrashInfo({ count = 0, lastError = "", lastAt = now() })
end

function MAINT.repairAfterCrash(err)
  local lines = {}
  local function step(name, fn)
    local ok, res = pcall(fn)
    if ok then
      lines[#lines + 1] = "[OK] " .. name
    else
      lines[#lines + 1] = "[ERR] " .. name .. ": " .. truncate(tostring(res), 34)
    end
    return ok, res
  end
  step("Nettoyage espace", function()
    ensureDir(ROOT)
    STORAGE.emergencyCleanup("crash", 65536)
  end)
  step("Chargement config", function() initStorage() end)
  step("Disques suspects", function() scanDiskThreats(true) end)
  step("Validation startup", function()
    local ok, info = MAINT.validateSecureClickOSSource(rawRead(STARTUP_PATH))
    if not ok then error(info, 0) end
  end)
  step("Backup recovery", function() installSelfRecovery(false) end)
  step("Auto-repair startup", function() protectStartupFile() end)
  step("Durcissement boot", function() hardenCraftOSSettings() end)
  step("Erreur source", function()
    if tostring(err or "") == "" then return end
    lines[#lines + 1] = truncate(tostring(err), math.max(20, w - 6))
  end)
  return lines
end

function MAINT.safeBootStep(name, fn)
  if not MAINT.recoveryBypass then return fn() end
  local ok, res = pcall(fn)
  if not ok then
    MAINT.runtimeErrors = (MAINT.runtimeErrors or 0) + 1
    pcall(appendAudit, "startup error ignored in " .. tostring(name) .. ": " .. tostring(res))
    setStatus("Erreur ignoree: " .. tostring(name))
    return nil
  end
  return res
end

function MAINT.runAppGuard(name, fn)
  local ok, result = pcall(fn)
  if ok then
    MAINT.runtimeErrors = 0
    return result
  end
  MAINT.runtimeErrors = (MAINT.runtimeErrors or 0) + 1
  pcall(appendAudit, "runtime error ignored in " .. tostring(name) .. ": " .. tostring(result))
  if MAINT.runtimeErrors >= MAINT.RUNTIME_ERROR_LIMIT then
    error("Trop d'erreurs runtime: " .. tostring(result), 0)
  end
  messageBox("Erreur ignoree", {
    "App: " .. truncate(tostring(name), 24),
    truncate(tostring(result), w - 4),
    "L'OS continue."
  })
  return nil
end

function MAINT.crashScreen(err, crashInfo)
  local report = {}
  local choiceStatus = "Erreur bloquee. Choisis une action."
  local allowContinue = (tonumber(crashInfo.count or 0) or 0) < MAINT.CRASH_LIMIT
  while true do
    local okDraw = pcall(function()
      w, h = term.getSize()
      buttons = {}
      pcall(term.setCursorBlink, false)
      term.setBackgroundColor(colors.blue)
      term.setTextColor(colors.white)
      term.clear()
      fill(1, 1, w, h, colors.blue)
      writeAt(2, 1, "SecureClickOS " .. VERSION .. " - Ecran bleu recovery", colors.white, colors.blue)
      writeAt(2, 3, "Erreur grave detectee.", colors.red, colors.blue)
      writeAt(2, 4, "Crashs: " .. tostring(crashInfo.count or 0) .. " / " .. tostring(MAINT.CRASH_LIMIT), colors.yellow, colors.blue)
      writeAt(2, 6, "Erreur:", colors.white, colors.blue)
      writeAt(2, 7, truncate(tostring(err or ""), w - 3), colors.white, colors.blue)
      writeAt(2, 9, choiceStatus, colors.yellow, colors.blue)
      local y = 11
      for i = 1, math.min(#report, math.max(0, h - 16)) do
        writeAt(2, y + i - 1, truncate(report[i], w - 3), colors.white, colors.blue)
      end
      addButton("restart", 2, h - 5, 12, "Reboot", colors.white, colors.blue)
      addButton("verify", 16, h - 5, 12, "Verifier", colors.lime, colors.black)
      addButton("continue", 30, h - 5, 14, allowContinue and "Continuer" or "Bloque", allowContinue and colors.orange or colors.gray, colors.black)
      addButton("shutdown", 2, h - 3, 12, "Eteindre", colors.red, colors.white)
      writeAt(2, h - 2, "R=reboot  V=verifier  C=continuer  S=eteindre", colors.lightGray, colors.blue)
    end)
    if not okDraw then
      print("SecureClickOS recovery")
      print(tostring(err))
      print("[R] reboot  [V] verifier  [C] continuer")
    end
    local ev = { os.pullEventRaw() }
    if ev[1] == "disk" then pcall(scanDiskThreats, true) end
    local id = nil
    if ev[1] == "mouse_click" then id = buttonAt(ev[3], ev[4]) end
    if ev[1] == "char" then
      local c = tostring(ev[2] or ""):lower()
      if c == "r" then id = "restart" end
      if c == "v" then id = "verify" end
      if c == "c" then id = "continue" end
      if c == "s" then id = "shutdown" end
    end
    if id == "restart" then
      os.reboot()
    elseif id == "shutdown" then
      os.shutdown()
    elseif id == "verify" then
      report = MAINT.repairAfterCrash(err)
      choiceStatus = "Verification terminee. Reboot conseille."
      crashInfo = MAINT.loadCrashInfo()
      allowContinue = (tonumber(crashInfo.count or 0) or 0) < MAINT.CRASH_LIMIT
    elseif id == "continue" then
      if allowContinue then
        MAINT.recoveryBypass = true
        choiceStatus = "Lancement force..."
        return "continue"
      end
      choiceStatus = "Trop d'erreurs. Fais Verifier ou Reboot."
    end
  end
end

function main()
  MAINT.safeBootStep("random", function() randomSeed() end)
  MAINT.safeBootStep("harden", function() hardenCraftOSSettings() end)
  MAINT.safeBootStep("cleanup boot", function() STORAGE.emergencyCleanup("boot", 65536) end)
  MAINT.safeBootStep("config", function() initStorage() end)
  MAINT.safeBootStep("cleanup config", function() STORAGE.emergencyCleanup("boot-after-config", 65536) end)
  MAINT.safeBootStep("github update", function() MAINT.checkGithubUpdateOnBoot() end)
  MAINT.safeBootStep("harden 2", function() hardenCraftOSSettings() end)
  MAINT.safeBootStep("rednet", function() tryOpenRednet() end)
  MAINT.safeBootStep("timer", function() startTimer() end)
  MAINT.safeBootStep("disk boot", function() scanDiskThreats(true) end)
  MAINT.safeBootStep("setup", function() setupWizard() end)
  MAINT.safeBootStep("disk setup", function() scanDiskThreats(true) end)
  MAINT.safeBootStep("integrite", function() integrityGate() end)
  MAINT.safeBootStep("recovery", function() installSelfRecovery(false) end)
  MAINT.safeBootStep("startup protect", function() protectStartupFile() end)
  MAINT.safeBootStep("disk", function() scanDiskThreats() end)
  MAINT.clearCrashInfo()
  MAINT.recoveryBypass = false
  MAINT.runtimeErrors = 0
  while true do
    if not currentUser then loginScreen() end
    local choice = appDesktop()
    local result = nil
    if choice == "mail" then result = MAINT.runAppGuard("mail", appMail)
    elseif choice == "files" then result = MAINT.runAppGuard("files", appFiles)
    elseif choice == "downloader" then result = MAINT.runAppGuard("downloader", appDownloader)
    elseif choice == "security" then result = MAINT.runAppGuard("security", appSecurity)
    elseif choice == "settings" then result = MAINT.runAppGuard("settings", appSettings)
    elseif choice == "help" then result = MAINT.runAppGuard("help", appHelp)
    elseif choice == "server" then result = MAINT.runAppGuard("server", appServer)
    elseif choice == "bank" then result = MAINT.runAppGuard("bank", appBank)
    elseif choice == "appcenter" then result = MAINT.runAppGuard("appcenter", appAppCenter)
    elseif choice == "lock" then result = "lock"
    end
    if result == "auto_lock" or result == "lock" then
      lockSession()
    end
  end
end

while true do
  local ok, err = pcall(main)
  pcall(term.setCursorBlink, false)
  if ok then
    clearScreen(colors.black)
    print(OS_NAME .. " s'est arrete.")
    print("Redemarrage securise.")
    os.reboot()
  end
  local crashInfo = MAINT.noteCrash(err)
  pcall(hardenCraftOSSettings)
  pcall(protectStartupFile)
  pcall(scanDiskThreats, true)
  local screenOk, action = pcall(MAINT.crashScreen, err, crashInfo)
  if screenOk and action == "continue" then
    -- Relance main en mode recuperation, sans reboot.
  else
    clearScreen(colors.black)
    setColors(colors.red, colors.black)
    print(OS_NAME .. " recovery a plante:")
    setColors(colors.white, colors.black)
    print(tostring(action))
    print("Reboot dans 5 secondes.")
    if sleep then sleep(5) end
    os.reboot()
  end
end
