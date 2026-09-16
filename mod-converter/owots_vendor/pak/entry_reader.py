"""Selected verified RE Asset Library PAK reader functions; GPL source attribution in SOURCE-NOTICE.json."""
import zlib
import zstandard as zstd
from ..encryption.re_pak_encryption import decryptResource

class CompressionTypes:
	COMPRESSION_TYPE_NONE = 0
	COMPRESSION_TYPE_DEFLATE = 1
	COMPRESSION_TYPE_ZSTD = 2

def _getPakEntryValue(entry,key,default = 0):
	if isinstance(entry,dict):
		return entry.get(key,default)
	return getattr(entry,key,default)

def _getPakEntryOffsetType(entry):
	offsetType = _getPakEntryValue(entry,"offsetType",None)
	if offsetType is None:
		# Cache entries created before the explicit field used the top byte of
		# attributes for this information.
		offsetType = (_getPakEntryValue(entry,"attributes",0) >> 24) & 0x0F
	return offsetType

def readPakEntryData(entry,pakStream,chunkTable = None,decompressorZSTD = None):
	"""Read one PAK entry, including v4.2 chunk content table entries."""
	compressionType = _getPakEntryValue(entry,"compressionType",0)
	encryptionType = _getPakEntryValue(entry,"encryptionType",0)
	offset = _getPakEntryValue(entry,"offset",0)
	compressedSize = _getPakEntryValue(entry,"compressedSize",0)
	decompressedSize = _getPakEntryValue(entry,"decompressedSize",0)
	offsetType = _getPakEntryOffsetType(entry)
	if offsetType not in (0,1):
		raise Exception(f"Unsupported PAK content table type: {offsetType}")
	if compressionType not in (CompressionTypes.COMPRESSION_TYPE_NONE, CompressionTypes.COMPRESSION_TYPE_DEFLATE, CompressionTypes.COMPRESSION_TYPE_ZSTD):
		raise Exception(f"Unsupported PAK compression type: {compressionType}")

	if offsetType == 1:
		if chunkTable is None:
			raise Exception("PAK chunk entry requires a chunk content table")
		if compressionType != CompressionTypes.COMPRESSION_TYPE_NONE or encryptionType != 0:
			raise Exception("Compressed or encrypted chunk-table entries are unsupported")
		remainingSize = int(compressedSize)
		chunkIndex = int(offset)
		fileData = bytearray()
		if decompressorZSTD is None:
			decompressorZSTD = zstd.ZstdDecompressor()
		while remainingSize > 0:
			if chunkIndex < 0 or chunkIndex >= len(chunkTable.entryList):
				raise Exception(f"PAK chunk index is out of range: {chunkIndex}")
			chunk = chunkTable.entryList[chunkIndex]
			chunkSize = int(chunk.compressedSize)
			if chunkSize <= 0:
				raise Exception(f"Invalid PAK chunk size at index {chunkIndex}")
			if chunkSize > remainingSize:
				raise Exception(f"PAK chunk size exceeds entry size at index {chunkIndex}")
			pakStream.seek(chunk.fileOffset)
			chunkData = pakStream.read(chunkSize)
			if len(chunkData) != chunkSize:
				raise Exception(f"PAK chunk is truncated at index {chunkIndex}")
			if chunkSize == chunkTable.blockSize:
				fileData.extend(chunkData)
			else:
				fileData.extend(decompressorZSTD.decompress(chunkData))
			remainingSize -= chunkSize
			chunkIndex += 1
		if remainingSize != 0:
			raise Exception("PAK chunk table does not cover the entry")
		# ZSTD frames in the chunk table are padded to the block size.  The
		# entry's decompressed size removes that padding from the final block.
		if len(fileData) < int(decompressedSize):
			raise Exception("PAK chunk data is shorter than the entry decompressed size")
		return bytes(fileData[:int(decompressedSize)])

	readSize = int(compressedSize if compressedSize != 0 else decompressedSize)
	pakStream.seek(offset)
	fileData = pakStream.read(readSize)
	if len(fileData) != readSize:
		raise Exception("PAK entry is truncated")
	if encryptionType > 0:
		fileData = decryptResource(fileData)
	if decompressorZSTD is None:
		decompressorZSTD = zstd.ZstdDecompressor()
	match compressionType:
		case CompressionTypes.COMPRESSION_TYPE_DEFLATE:
			fileData = zlib.decompress(fileData,wbits=-zlib.MAX_WBITS)
		case CompressionTypes.COMPRESSION_TYPE_ZSTD:
			fileData = decompressorZSTD.decompress(fileData)
	if decompressedSize > 0 and len(fileData) != int(decompressedSize):
		raise Exception(f"PAK entry decompressed size mismatch: expected {decompressedSize}, got {len(fileData)}")
	return fileData
