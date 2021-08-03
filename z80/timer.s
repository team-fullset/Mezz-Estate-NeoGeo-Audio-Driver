; hl: counter load (%------TTTTTTTTTT) 
ta_counter_load_set:
	push hl
	push de
	push af
		; Set Timer A counter load LSB
		ld d,REG_TMA_COUNTER_LSB
		ld a,l
		and a,%00000011
		ld e,a
		rst RST_YM_WRITEA

		srl_hl
		srl_hl
		dec d
		ld e,l
		rst RST_YM_WRITEA
	pop af
	pop de
	pop hl
	ret