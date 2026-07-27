## BSA archive reader (CTPAX-X format).
##
## Ported from fsh32_port/src/loaders/archive_bsa.c. Supports all four
## game variants. Keys are derived lazily on first use of a variant.
##
## Usage:
##   var bsa := BSAReader.new()
##   bsa.open("C:/Games/SKYNET/GAMEDATA/MDMDOBJS.BSA", BSAReader.VARIANT_SKYNET)
##   var data := bsa.read("HUMMERTK.3D")    # PackedByteArray, or empty on miss
##   bsa.close()

extends RefCounted

const KEY_LEN: int = 21
const NAME_LEN: int = 13
const ENTRY_SIZE: int = 18  # 13 + 1 (flags) + 4 (size)
const FLAG_ENCRYPTED: int = 0x01

const VARIANT_FSDEMO: int = 0
const VARIANT_FSFULL: int = 1
const VARIANT_SKYNET: int = 2
const VARIANT_INSTALLER: int = 3
const VARIANT_COUNT: int = 4

const PASSPHRASES: Array[String] = [
	"d1mOforVIrring",   # FSDEMO
	"moRt1nErDej7lig",  # FSFULL
	"kaJogANDrea",      # SKYNET
	"",                  # INSTALLER (not used)
]

# Cached derived keys per variant: PackedByteArray of length KEY_LEN.
static var _keys: Array = [null, null, null, null]

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
	if file_size < 2:
		push_error("BSA too small: %s" % path)
		close()
		return false

	_file.seek(0)
	var count: int = _file.get_16()
	if count <= 0 or count > 50000:
		push_error("BSA bad entry count: %d in %s" % [count, path])
		close()
		return false

	var toc_bytes: int = count * ENTRY_SIZE
	if toc_bytes + 2 > file_size:
		push_error("BSA TOC overflow in %s" % path)
		close()
		return false

	_file.seek(file_size - toc_bytes)
	var toc: PackedByteArray = _file.get_buffer(toc_bytes)
	if toc.size() != toc_bytes:
		push_error("BSA TOC short read in %s" % path)
		close()
		return false

	# Parse TOC + compute offsets.
	var cursor: int = 2  # data starts after the 2-byte header
	_entries.clear()
	for i in count:
		var base := i * ENTRY_SIZE
		var e := Entry.new()
		# Name: NUL-padded 13-byte ASCII
		var name_bytes := toc.slice(base, base + NAME_LEN)
		var nul_at := name_bytes.find(0)
		if nul_at < 0: nul_at = NAME_LEN
		e.name = name_bytes.slice(0, nul_at).get_string_from_ascii()
		e.flags = toc[base + NAME_LEN]
		e.size = (toc[base + NAME_LEN + 1]
		       | (toc[base + NAME_LEN + 2] << 8)
		       | (toc[base + NAME_LEN + 3] << 16)
		       | (toc[base + NAME_LEN + 4] << 24))
		e.offset = cursor
		cursor += e.size
		_entries.append(e)

	return true

func close() -> void:
	if _file != null:
		_file.close()
		_file = null
	_entries.clear()
	_variant = -1

func count() -> int:
	return _entries.size()

func entries() -> Array[Entry]:
	return _entries

func find(name: String) -> Entry:
	var lname := name.to_lower()
	for e in _entries:
		if e.name.to_lower() == lname:
			return e
	return null

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
		# Decrypt: data[i] -= key[i % KEY_LEN]
		for i in data.size():
			data[i] = (data[i] - key[i % KEY_LEN]) & 0xFF
	return data
