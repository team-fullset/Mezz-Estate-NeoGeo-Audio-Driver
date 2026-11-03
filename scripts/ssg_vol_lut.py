LUT = bytearray()

for i in range(0,16):
	for j in range(0,16):
		# i: channel volume, j: volume macro value; the macro
		# lowers the volume as the tracker does
		byte = max(0, min(15, j) - (15 - i))
		LUT.append(byte & 0xFF)

output_file = open("ssg_vol_lut.bin", "wb")
output_file.write(LUT)