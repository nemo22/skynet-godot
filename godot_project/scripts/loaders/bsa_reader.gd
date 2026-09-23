## BSA archive reader (CTPAX-X format).
##
## Ported from fsh32_port/src/loaders/archive_bsa.c. Supports all four
## game variants. Keys are derived lazily on first use of a variant.
##
## Usage:
##   var bsa := BSAReader.new()
##   bsa.open(SkynetPaths.gamedata_path("MDMDOBJS.BSA"), SkynetPaths.variant)
##   var data := bsa.read("HUMMERTK.3D")    # PackedByteArray, or empty on miss
##   bsa.close()

extends RefCounted

const KEY_LEN: int = 21
const NAME_LEN: int = 13
const ENTRY_SIZE: int = 18  # 13 + 1 (flags) + 4 (size)
const FLAG_ENCRYPTED: int = 0x01

const VARIANT_COUNT: int = 4

const PASSPHRASES: Array[String] = [
	"d1mOforVIrring",   # FSDEMO
	"moRt1nErDej7lig",  # FSFULL
	"kaJogANDrea",      # SKYNET
	"",                  # INSTALLER (not used)
]

# Cached derived keys per variant: PackedByteArray of length KEY_LEN.
static var _keys: Array = [null, null, null, null]

# Parsed tables of contents shared by every reader, keyed "path|variant":
# {"size", "mtime", "entries" (read-only Array[Entry]), "by_name"
# (lower-case name -> first Entry of that name)}. The import opens
# MDMDOBJS.BSA ~4 000 times, and re-parsing its 4 044-entry TOC in GDScript
# on every open cost most of a minute.
static var _toc_cache: Dictionary = {}

class Entry:
	var name: String = ""
	var flags: int = 0
	var size: int = 0
	var offset: int = 0
	func _to_string() -> String:
		return "Entry(%s, flags=0x%02x, off=%d, size=%d)" % [name, flags, offset, size]

var _file: FileAccess = null
var _variant: int = -1
var _entries: Array[Entry] = []
var _by_name: Dictionary = {}

## Derive the 21-byte key from a passphrase. 28 mixing rounds of base-62
## accumulation. Matches `derive_key` in archive_bsa.c.
static func derive_key(passphrase: String) -> PackedByteArray:
	if passphrase.is_empty():
		return PackedByteArray()

	var digits := PackedByteArray()
	digits.resize(passphrase.length())
	for i in passphrase.length():
		var c := passphrase.unicode_at(i)
		# a-z → 0..25, 0-9 → 26..35, A-Y → 36..60 (Z excluded as sentinel)
		if c >= 0x61 and c <= 0x7A:
			digits[i] = c - 0x61
		elif c >= 0x30 and c <= 0x39:
			digits[i] = (c - 0x30) + 26
		elif c >= 0x41 and c <= 0x59:
			digits[i] = (c - 0x41) + 36
		else:
			push_error("BSA passphrase contains invalid char: %s" % passphrase)
			return PackedByteArray()

	var key := PackedByteArray()
	key.resize(KEY_LEN)
	for r in 28:
		var carry := int(digits[r % digits.size()])
		for i in KEY_LEN:
			var v := int(key[i]) * 62 + carry
			key[i] = v & 0xFF
			carry = v >> 8
	return key

## Returns the cached 21-byte key for the variant.
static func get_key(variant: int) -> PackedByteArray:
	if variant < 0 or variant >= VARIANT_COUNT:
		return PackedByteArray()
	if _keys[variant] == null:
		_keys[variant] = derive_key(PASSPHRASES[variant])
	return _keys[variant]

## Open a BSA. Returns true on success. After opening, call entries() to
## list, find() to locate by name, read()/read_at() to extract.
func open(path: String, variant: int) -> bool:
	close()
	_variant = variant
	_file = FileAccess.open(path, FileAccess.READ)
	if _file == null:
		push_error("BSA open failed: %s — %s" % [path, error_string(FileAccess.get_open_error())])
		return false

	var file_size: int = _file.get_length()
	var mtime: int = FileAccess.get_modified_time(path)
	var key: String = "%s|%d" % [path, variant]
	var hit: Variant = _toc_cache.get(key)
	if hit != null and int(hit["size"]) == file_size and int(hit["mtime"]) == mtime:
		_entries = hit["entries"]
		_by_name = hit["by_name"]
		return true
	if not _parse_toc(path, file_size):
		close()
		return false
	_entries.make_read_only()        # shared by every reader of this archive
	_toc_cache[key] = {"size": file_size, "mtime": mtime,
		"entries": _entries, "by_name": _by_name}
	return true

## Read and index the table of contents of the open file.
func _parse_toc(path: String, file_size: int) -> bool:
	if file_size < 2:
		push_error("BSA too small: %s" % path)
		return false

	_file.seek(0)
	var n_entries: int = _file.get_16()
	if n_entries <= 0 or n_entries > 50000:
		push_error("BSA bad entry count: %d in %s" % [n_entries, path])
		return false

	var toc_bytes: int = n_entries * ENTRY_SIZE
	if toc_bytes + 2 > file_size:
		push_error("BSA TOC overflow in %s" % path)
		return false

	_file.seek(file_size - toc_bytes)
	var toc: PackedByteArray = _file.get_buffer(toc_bytes)
	if toc.size() != toc_bytes:
		push_error("BSA TOC short read in %s" % path)
		return false

	# Parse TOC + compute offsets.
	var cursor: int = 2  # data starts after the 2-byte header
	var list: Array[Entry] = []
	var by_name: Dictionary = {}
	var dropped: int = 0
	for i in n_entries:
		var base := i * ENTRY_SIZE
		var size: int = toc.decode_u32(base + NAME_LEN + 1)
		var offset: int = cursor
		cursor += size
		# Name: NUL-padded 13-byte ASCII
		var name_bytes := toc.slice(base, base + NAME_LEN)
		var nul_at := name_bytes.find(0)
		if nul_at < 0: nul_at = NAME_LEN
		name_bytes = name_bytes.slice(0, nul_at)
		# An entry whose data would run past the end of the file (a size of
		# 0xFFFFFFFF made read_at() allocate 4 GB before the short read was
		# noticed) or whose name is not a plain DOS name is left out.
		if offset + size > file_size or not _name_is_safe(name_bytes):
			dropped += 1
			continue
		var e := Entry.new()
		e.name = name_bytes.get_string_from_ascii()
		e.flags = toc[base + NAME_LEN]
		e.size = size
		e.offset = offset
		list.append(e)
		var lname: String = e.name.to_lower()
		if not by_name.has(lname):
			by_name[lname] = e       # find() returns the first of a name
	if dropped > 0:
		push_warning("BSA %s: %d of %d entries ignored (bad name, or data past the end of the file)"
			% [path, dropped, n_entries])
	_entries = list
	_by_name = by_name
	return true

## Archive names end up in cache file names, so only a plain DOS name is
## accepted: letters, digits, "_", "." and "-", where "." and "-" may not
## open the name or follow a "." (so never ".."); no separators or anything
## else a path could be built from. Every entry of the SkyNET and Future
## Shock archives passes.
static func _name_is_safe(name_bytes: PackedByteArray) -> bool:
	if name_bytes.is_empty():
		return false
	var prev: int = 0x2E                 # as if after a ".": no leading "." / "-"
	for c in name_bytes:
		var ok: bool = (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) \
			or (c >= 0x61 and c <= 0x7A) or c == 0x5F \
			or (prev != 0x2E and (c == 0x2E or c == 0x2D))
		if not ok:
			return false
		prev = c
	return true

func close() -> void:
	if _file != null:
		_file.close()
		_file = null
	# The entry list is the shared cached one: drop the reference, never
	# clear() it.
	var none: Array[Entry] = []
	_entries = none
	_by_name = {}
	_variant = -1

func count() -> int:
	return _entries.size()

## The archive's entries. Read-only: the list is shared by every reader of
## the same file.
func entries() -> Array[Entry]:
	return _entries

func find(name: String) -> Entry:
	return _by_name.get(name.to_lower())

## Read the entry's bytes. Decrypts if FLAG_ENCRYPTED. Returns empty on
## failure.
func read(name: String) -> PackedByteArray:
	var e := find(name)
	if e == null:
		return PackedByteArray()
	return read_at(e)

func read_at(entry: Entry) -> PackedByteArray:
	if _file == null or entry == null or entry.size == 0:
		return PackedByteArray()
	_file.seek(entry.offset)
	var data: PackedByteArray = _file.get_buffer(entry.size)
	if data.size() != entry.size:
		push_error("BSA short read for %s (got %d, want %d)" % [entry.name, data.size(), entry.size])
		return PackedByteArray()
	if entry.flags & FLAG_ENCRYPTED:
		var key := get_key(_variant)
		if key.is_empty():
			push_error("BSA no key for variant %d" % _variant)
			return PackedByteArray()
		_decrypt(data, key)
	return data

## Decrypt in place: data[i] -= key[i % KEY_LEN] (mod 256).
##
## Byte by byte that is six GDScript operations per byte over archives of
## several megabytes (MDMDSFXS.BSA, MDMDMAP2.BSA, Future Shock's
## MDMDOBJS.BSA), so whole 4-byte words are subtracted at once with the
## borrow-free SWAR form ((a | H) - (b & ~H)) ^ ((a ^ ~b) & H), H =
## 0x80808080: every minuend byte has its top bit set and every
## subtrahend byte has it clear, so no borrow crosses a byte boundary, and
## the xor restores each byte's true top bit. Everything stays inside 32
## bits, so there is no int64 overflow either.
static func _decrypt(data: PackedByteArray, key: PackedByteArray) -> void:
	# The key word under data offset i depends only on i % KEY_LEN.
	var k_low := PackedInt64Array()      # key word & 0x7F7F7F7F
	var k_top := PackedInt64Array()      # ~key word & 0x80808080
	k_low.resize(KEY_LEN)
	k_top.resize(KEY_LEN)
	for j in KEY_LEN:
		var kw: int = key[j] | (key[(j + 1) % KEY_LEN] << 8) \
			| (key[(j + 2) % KEY_LEN] << 16) | (key[(j + 3) % KEY_LEN] << 24)
		k_low[j] = kw & 0x7F7F7F7F
		k_top[j] = (kw ^ 0x80808080) & 0x80808080
	var n: int = data.size()
	var words_end: int = n - n % 4
	var i: int = 0
	var j: int = 0
	while i < words_end:
		var a: int = data.decode_u32(i)
		data.encode_u32(i, ((a | 0x80808080) - k_low[j]) ^ ((a ^ k_top[j]) & 0x80808080))
		i += 4
		j = (j + 4) % KEY_LEN
	while i < n:
		data[i] = (data[i] - key[i % KEY_LEN]) & 0xFF
		i += 1
