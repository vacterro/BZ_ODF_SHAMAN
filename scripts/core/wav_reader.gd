class_name WavReader
extends RefCounted
## Minimal RIFF/WAVE reader for BZCC sounds. Supports uncompressed PCM (8/16
## bit) playback and waveform extraction; other codecs keep metadata only.

var ok := false
var error := ""
var format_code := 0
var channels := 0
var sample_rate := 0
var bits := 0
var data_bytes := PackedByteArray()
var duration := 0.0
var stream: AudioStreamWAV = null
var path := ""


static func read(p_path: String) -> WavReader:
	var r := WavReader.new()
	r.path = p_path
	if not FileAccess.file_exists(p_path):
		r.error = "file not found"
		return r
	var bytes := FileAccess.get_file_as_bytes(p_path)
	return parse_bytes(bytes, p_path)


static func parse_bytes(bytes: PackedByteArray, p_path: String = "") -> WavReader:
	var r := WavReader.new()
	r.path = p_path
	if bytes.size() < 44:
		r.error = "file too small for RIFF/WAVE"
		return r
	if bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		r.error = "not a RIFF/WAVE file"
		return r
	var off := 12
	var fmt_ok := false
	while off + 8 <= bytes.size():
		var id := bytes.slice(off, off + 4).get_string_from_ascii()
		var size := bytes.decode_u32(off + 4)
		var body := off + 8
		if id == "fmt " and body + 16 <= bytes.size():
			r.format_code = bytes.decode_u16(body)
			r.channels = bytes.decode_u16(body + 2)
			r.sample_rate = int(bytes.decode_u32(body + 4))
			r.bits = bytes.decode_u16(body + 14)
			fmt_ok = true
		elif id == "data":
			var end := mini(body + size, bytes.size())
			r.data_bytes = bytes.slice(body, end)
		off = body + size + (size & 1)
	if not fmt_ok:
		r.error = "missing fmt chunk"
		return r
	if r.sample_rate <= 0 or r.channels <= 0 or r.bits <= 0:
		r.error = "invalid fmt values"
		return r
	var frame_bytes := r.channels * (r.bits / 8)
	if frame_bytes > 0 and not r.data_bytes.is_empty():
		r.duration = float(r.data_bytes.size()) / float(r.sample_rate * frame_bytes)
	if r.format_code == 1 and (r.bits == 16 or r.bits == 8) and not r.data_bytes.is_empty():
		var pcm := r.data_bytes
		if r.bits == 8:
			pcm = pcm.duplicate()
			for i in range(pcm.size()):
				pcm[i] = (int(pcm[i]) - 128) & 0xFF
		var s := AudioStreamWAV.new()
		s.format = AudioStreamWAV.FORMAT_16_BITS if r.bits == 16 else AudioStreamWAV.FORMAT_8_BITS
		s.stereo = r.channels == 2
		s.mix_rate = r.sample_rate
		s.data = pcm
		r.stream = s
	r.ok = true
	return r


func format_name() -> String:
	if format_code == 1:
		return "PCM %d-bit %s" % [bits, "stereo" if channels == 2 else "mono"]
	if format_code == 2:
		return "MS ADPCM"
	if format_code == 0x11:
		return "IMA ADPCM"
	return "codec %d" % format_code


## Downsampled absolute peaks (0..1) for waveform drawing.
func peaks(count: int = 1200) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if data_bytes.is_empty() or sample_rate <= 0 or count <= 0:
		return out
	var bytes_per_sample := maxi(1, bits / 8)
	var frame_bytes := bytes_per_sample * maxi(1, channels)
	var frames := data_bytes.size() / frame_bytes
	if frames <= 0:
		return out
	out.resize(count)
	var bucket := maxi(1, frames / count)
	for i in range(count):
		var start := i * bucket
		var peak := 0.0
		var j := start
		var end := mini(start + bucket, frames)
		while j < end:
			var idx := j * frame_bytes
			if bits == 16:
				var v := absf(float(data_bytes.decode_s16(idx)))
				peak = maxf(peak, v / 32768.0)
			elif bits == 8:
				var v8 := absf(float(data_bytes[idx]) - 128.0)
				peak = maxf(peak, v8 / 128.0)
			else:
				peak = 1.0
				break
			j += maxi(1, bucket / 400)
		out[i] = clampf(peak, 0.0, 1.0)
	return out
