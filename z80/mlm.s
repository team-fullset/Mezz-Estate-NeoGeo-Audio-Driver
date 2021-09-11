; DOESN'T BACKUP REGISTERS
MLM_irq:
	ld iyl,0 ; Clear active mlm channel counter

	; base time counter code
	ld a,(MLM_base_time)
	ld c,a
	ld a,(MLM_base_time_counter)	
	inc a
	cp a,c
	ld (MLM_base_time_counter),a
	ret nz ; skip update

	ld c,0
	dup CHANNEL_COUNT
		call MLM_update_channel_playback
		call MLM_update_channel_volume
		inc c
	edup

	; Clear MLM_base_time_counter
	xor a,a
	ld (MLM_base_time_counter),a

	; if active mlm channel counter is 0,
	; then all channels have stopped, proceed
	; to call MLM_stop
	ld a,iyl
	or a,a ; cp a,0
	call z,MLM_stop

MLM_update_skip:
	ret

; [INPUT]
; 	c: channel
; [OUTPUT]
;	iyl: active channel count
; Doesn't backup AF, HL, DE, B, HL', BC' and DE'
; OPTIMIZED
MLM_update_channel_playback:
	; if MLM_playback_control[ch] == 0 then
	; do not update this channel
	ld hl,MLM_playback_control
	ld b,0
	add hl,bc
	xor a,a   ; a = 0
	cp a,(hl) ; compare 0 to (hl)
	ret z

	inc iyl ; increment active mlm channel counter

	; decrement MLM_playback_timings[ch],
	; if afterwards it's 0 then update events
	ld de,MLM_playback_timings-MLM_playback_control
	add hl,de
	dec (hl)
	ld b,(hl)
	add hl,de ; get pointer to MLM_playback_set_timings[ch]
	cp a,b    ; compare 0 to MLM_playback_timings[ch]
	push bc   ; \
		exx   ; | Instead than using the stack, use exx since it's faster
	pop bc    ; /

MLM_update_channel_playback_exec_check:
	jr nz,MLM_update_channel_playback_check_set_t

	; ======== Update events ========
	; de = MLM_playback_pointers[ch]
	ld h,0
	ld l,c
	add hl,hl
	ld de,MLM_playback_pointers
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	
	; If the first byte's most significant bit is 0, then
	; parse it and evaluate it as a note, else parse 
	; and evaluate it as a command
	ex de,hl
	ld a,(hl)
	bit 7,a
	jp z,MLM_parse_command

	; ======== Parse note ========
	push bc
		ld a,(hl)
		and a,$7F ; Clear bit 7 of the note's first byte
		ld b,a
		ld a,c    ; move channel in a
		inc hl
		ld c,(hl)
		inc hl
		
		; if (channel < 6) MLM_parse_note_pa()
		cp a,6
		jp c,MLM_play_sample_pa

		cp a,10
		jp c,MLM_play_note_fm
		
		; Else, Play note SSG...
		sub a,MLM_CH_SSG1
		call SSGCNT_set_note
		call SSGCNT_enable_channel
		call SSGCNT_start_channel_macros

		add a,MLM_CH_SSG1
		ld c,b
		call MLM_set_timing

MLM_parse_note_end:
		; store playback pointer into WRAM
		ex de,hl
		ld (hl),d
		dec hl
		ld (hl),e
	pop bc

MLM_update_channel_playback_check_set_t:
	exx ; Get normal registers back

	; if MLM_playback_set_timings[ch] == 0
	; update events again
	xor a,a
	cp a,(hl) ; cp 0,(hl)
	jr z,MLM_update_channel_playback_exec_check

	exx ; select shadow registers again
	ret

; c: channel
; Doesn't backup AF, HL and B registers
; OPTIMIZED
MLM_update_channel_volume:
	ld a,c

	cp a,MLM_CH_FM1  ; if channel is ADPCMA...
	jp c,MLM_update_ch_vol_PA

	cp a,MLM_CH_SSG1 ; if channel is FM...
	jp c,MLM_update_ch_vol_FM

MLM_update_ch_vol_SSG: ; Else, channel is SSG...
	; Load channel volume
	ld b,0
	ld hl,MLM_channel_volumes
	add hl,bc
	ld a,(hl)

	; Scale down volume
	; ($00~$FF -> $00~$0F)
	rrca
	rrca
	rrca
	rrca
	and a,$0F

	; Store volume into SSGCNT WRAM
	ld hl,SSGCNT_volumes-MLM_CH_SSG1
	add hl,bc
	ld (hl),a
	ret

MLM_update_ch_vol_PA:
	; Load channel volume
	ld b,0
	ld hl,MLM_channel_volumes
	add hl,bc
	ld a,(hl)

	; Scale down volume
	; ($00~$FF -> $00~$1F)
	rrca
	rrca
	rrca
	and a,$1F

	call PA_set_channel_volume
	ret

MLM_update_ch_vol_FM:
	; Load channel volume
	ld b,0
	ld hl,MLM_channel_volumes
	add hl,bc
	ld a,(hl)

	; Scale down volume ($00~$FF -> $00 $7F)
	srl a

	; Store volume into FMCNT WRAM
	ld hl,FM_channel_volumes-MLM_CH_FM1
	add hl,bc
	ld (hl),a
	ret

; stop song
MLM_stop:
	push hl
	push de
	push bc
	push af
		; Stop SSG Controller
		call SSGCNT_init
		call FMCNT_init

		; clear MLM WRAM
		ld hl,MLM_wram_start
		ld de,MLM_wram_start+1
		ld bc,MLM_wram_end-MLM_wram_start-1
		ld (hl),0
		ldir

		; Set WRAM variables
		;ld a,1
		;ld (MLM_base_time),a

		; Clear other WRAM variables
		xor a,a
		ld (EXT_2CH_mode),a

		call ssg_stop
		call fm_stop
		call PA_reset
		call pb_stop
	pop af
	pop bc
	pop de
	pop hl
	ret

; a: song
MLM_play_song:
	push hl
	push bc
	push de
	push ix
	push af
		call MLM_stop
		call set_default_banks 

		; First song index validity check
		;	If the song is bigger or equal to 128
		;   (thus bit 7 is set), the index is invalid.
		bit 7,a
		call nz,softlock ; if a's bit 7 is set then ..

		; Second song index validity check
		;	If the song is bigger or equal to the
		;   song count, the index is invalid.
		ld hl,MLM_HEADER
		ld c,(hl)
		cp a,c
		call nc,softlock ; if a >= c then ...

		; Load song header offset 
		; from MLM header into de,
		; then add MLM_songs to it
		; to obtain a pointer.
		inc hl
		sla a
		ld d,0
		ld e,a
		add hl,de
		ld e,(hl)
		inc hl
		ld d,(hl)
		ld hl,MLM_HEADER
		add hl,de

		;     For each channel...
		ld de,MLM_playback_pointers
		ld ix,MLM_playback_control
		ld b,CHANNEL_COUNT
MLM_play_song_loop:
		call MLM_playback_init
		djnz MLM_play_song_loop

		; Load timer a counter load
		; from song header and set it
		ld e,(hl)
		inc hl
		ld d,(hl)
		ex de,hl
		call ta_counter_load_set
		ex de,hl

		; Load base time from song
		; header and store it into WRAM
		inc hl
		ld a,(hl)
		ld (MLM_base_time),a

		; Load instrument offset into de
		inc hl
		ld e,(hl)
		inc hl
		ld d,(hl)

		; Calculate actual address, then
		; load said address into WRAM
		ld hl,MLM_HEADER
		add hl,de
		ld a,l
		ld (MLM_instruments),a
		ld a,h
		ld (MLM_instruments+1),a

		; Copy MLM_playback_pointers
		; to MLM_playback_start_pointers
		ld hl,MLM_playback_pointers
		ld de,MLM_playback_start_pointers
		ld bc,2*CHANNEL_COUNT
		ldir

		; Set all the channel's
		; volumes to $FF
		ld hl,MLM_channel_volumes
		ld de,MLM_channel_volumes+1
		ld bc,CHANNEL_COUNT-1
		ld (hl),$FF
		ldir

		; Set ADPCM-A master volume
		ld de,REG_PA_MVOL<<8 | $3F
		rst RST_YM_WRITEB

		; Enable all FM channels
		ld c,0
		call FM_enable_channel
		ld c,1
		call FM_enable_channel
		ld c,2
		call FM_enable_channel
		ld c,3
		call FM_enable_channel

		ld b,CHANNEL_COUNT
MLM_play_song_loop2:
		call MLM_ch_parameters_init
		djnz MLM_play_song_loop2
	pop af
	pop ix
	pop de
	pop bc
	pop hl
	ret

; [INPUT]
;	b:	channel+1
;	de:	$MLM_playback_pointers[ch]
;	ix:	$MLM_playback_control[ch]
; [OUTPUT]
;	de:	$MLM_playback_pointers[ch+1]
;	ix:	$MLM_playback_control[ch+1]
MLM_playback_init:
	push bc
	push af
		; Set all channel timings to 1
		ld a,b
		dec a
		ld bc,1
		call MLM_set_timing

		; Load channel's playback offset
		; into bc
		ld c,(hl)
		inc hl
		ld b,(hl)
		inc hl

		; Obtain ptr to channel's playback
		; data by adding MLM_HEADER to its
		; playback offset.
		;	Only the due words' MSB need
		;	to be added together, since
		;	the LSB is always equal to $00.
		ld a,MLM_HEADER>>8
		add a,b

		; store said pointer into
		; MLM_playback_pointers[ch]
		ex de,hl
			ld (hl),c
			inc hl
			ld (hl),a
			inc hl
		ex de,hl

		; If the playback pointer isn't
		; equal to 0, set the channel's
		; playback control to $FF
		push hl
			ld hl,0
			or a,a ; Clear carry flag
			sbc hl,bc
			jr z,MLM_playback_init_no_playback
			ld (ix+0),$FF
MLM_playback_init_no_playback:
			inc ix
		pop hl
	pop af
	pop bc
	ret

; b: channel+1
;	Initializes channel parameters
MLM_ch_parameters_init:
	push af
	push bc
		ld a,b
		dec a
		ld c,PANNING_CENTER
		call MLM_set_channel_panning

		ld a,0
		ld c,b
		dec c
		call MLM_set_instrument
	pop bc
	pop af
	ret

; c: channel
MLM_update_events:
	push hl
	push de
	push af
	push ix
		

MLM_update_events_skip:
	pop ix
	pop af
	pop de
	pop hl
	jp MLM_update_channel_playback_check_set_t

; [INPUT]
;   a:  channel
;   bc: source   (-TTTTTTT SSSSSSSS (Timing; Sample))
MLM_play_sample_pa:
	push de
	push bc
	push hl
	push ix
		; Load current instrument index into hl
		ld h,0
		ld l,a 
		ld de,MLM_channel_instruments
		add hl,de
		ld l,(hl)
		ld h,0

		; Load pointer to instrument data
		; from WRAM into de
		push af
			ld a,(MLM_instruments)
			ld e,a
			ld a,(MLM_instruments+1)
			ld d,a
		pop af

		; Calculate pointer to the current
		; instrument's data and store it in hl
		add hl,hl ; \
		add hl,hl ;  \
		add hl,hl ;   | hl *= 32
		add hl,hl ;  /
		add hl,hl ; /
		add hl,de

		; Store offset to ADPCM 
		; sample table in hl
		ld e,(hl)
		inc hl
		ld d,(hl)

		; Add MLM_header offset to
		; it to obtain the actual address
		ld hl,MLM_HEADER
		add hl,de
		ld e,l
		ld d,h

		; Check if sample id is valid;
		; if it isn't softlock.
		push af
			ld a,c
			cp a,(hl)
			jp nc,softlock ; if smp_id >= smp_count
			inc de ; Increment past sample count
		pop af

		; ix = $ADPCM_sample_table[sample_idx]
		ld h,0
		ld l,c
		add hl,hl ; - hl *= 4
		add hl,hl ; /
		add hl,de
		ex de,hl
		ld ixl,e
		ld ixh,d

		call PA_set_sample_addr

		; Set timing
		ld c,b
		ld b,0
		call MLM_set_timing
		
		; play sample
		ld h,0
		ld l,a
		ld de,PA_channel_on_masks
		add hl,de
		ld d,REG_PA_CTRL
		ld e,(hl) 
		rst RST_YM_WRITEB
	pop ix
	pop hl
	pop bc
	pop de
	jp MLM_parse_note_end

; [INPUT]
;   a:  channel+6
;   bc: source (-TTTTTTT -OOONNNN (Timing; Octave; Note))
MLM_play_note_fm:
	push af
	push ix
	push bc
		sub a,MLM_CH_FM1
		ld ixh,c
		ld ixl,a
		call FMCNT_set_note
		ld c,a
		call FMCNT_play_channel

		add a,MLM_CH_FM1
		ld c,b
		ld b,0
		call MLM_set_timing
	pop bc
	pop ix
	pop af
	jp MLM_parse_note_end

;   a:  channel+10
;   bc: source (-TTTTTTT NNNNNNNN (Timing; Note))
MLM_play_note_ssg:
		
	jp MLM_parse_note_end

; a: instrument
; c: channel
MLM_set_instrument:
	push bc
	push hl
	push af
		; Store instrument in MLM_channel_instruments
		ld b,0
		ld hl,MLM_channel_instruments
		add hl,bc
		ld (hl),a

		; if the channel is ADPCM-A nothing
		; else needs to be done: return
		ld a,c
		cp a,MLM_CH_FM1                ; if a < MLM_CH_FM1 
		jr c,MLM_set_instrument_return ; then ...

		; If the channel is FM, branch
		cp a,MLM_CH_SSG1               ; if a < MLM_CH_SSG1
		jr c,MLM_set_instrument_fm     ; then ...

		; Else the channel is SSG, branch
		jr MLM_set_instrument_ssg
MLM_set_instrument_return:
	pop af
	pop hl
	pop bc
	ret

; a:  channel
; hl: $MLM_channel_instruments[channel]
MLM_set_instrument_fm:
	push hl
	push de
	push bc
	push af
		; Load pointer to instrument data
		; from WRAM into de
		push af
			ld a,(MLM_instruments)
			ld e,a
			ld a,(MLM_instruments+1)
			ld d,a
		pop af

		; Calculate pointer to instrument
		ld l,(hl)
		ld h,0
		add hl,hl ; \
		add hl,hl ;  \
		add hl,hl ;  | hl *= 32
		add hl,hl ;  /
		add hl,hl ; /
		add hl,de

		; Set feedback $ algorithm
		sub a,MLM_CH_FM1
		ld c,a
		ld a,(hl)
		call FMCNT_set_fbalgo

		; Set AMS and PMS
		inc hl
		ld a,(hl)
		call FMCNT_set_amspms

		; Set OP enable
		inc hl
		ld a,(hl)
		call FMCNT_set_op_enable

		; Set operators
		ld b,0
		inc hl
		ld de,7 ; operator data size

		; Set OP 1
		call FMCNT_set_operator
		add hl,de
		inc b

		; Set OP 2
		call FMCNT_set_operator
		add hl,de
		inc b

		; Set OP 3
		call FMCNT_set_operator
		add hl,de
		inc b

		; Set OP 4
		call FMCNT_set_operator
		add hl,de
	pop af
	pop bc
	pop de
	pop hl
	jr MLM_set_instrument_return

; a:  channel
; hl: $MLM_channel_instruments[channel]
MLM_set_instrument_ssg:
	push de
	push hl
	push bc
	push af
	push ix
		; Load pointer to instrument data
		; from WRAM into de
		push af
			ld a,(MLM_instruments)
			ld e,a
			ld a,(MLM_instruments+1)
			ld d,a
		pop af

		; Calculate pointer to instrument
		ld l,(hl)
		ld h,0
		add hl,hl ; \
		add hl,hl ;  \
		add hl,hl ;  | hl *= 32
		add hl,hl ;  /
		add hl,hl ; /
		add hl,de

		; Calculate SSG channel
		; in 0~2 range
		sub a,MLM_CH_SSG1
		ld d,a                    ; Channel parameter

		; Enable tone if the mixing's byte
		; bit 0 is 1, else disable it
		ld a,(hl)
		and a,%00000001 ; Get tone enable bit
		ld c,a                    ; Enable/Disable parameter
		ld e,SSGCNT_MIX_EN_TUNE   ; Tune/Noise select parameter
		call SSGCNT_set_mixing

		; Enable noise if the mixing's byte
		; bit 1 is 1, else disable it
		ld a,(hl)
		and a,%00000010 ; Get noise enable bit
		srl a
		ld c,a                   ; Enable/Disable parameter
		ld e,SSGCNT_MIX_EN_NOISE ; Tune/Noise select parameter
		call SSGCNT_set_mixing

		; Skip EG parsing (TODO: parse EG information)
		inc hl
		inc hl
		inc hl
		inc hl
		inc hl

		; Calculate pointer to channel's mix macro
		ld ixh,0
		ld ixl,d 
		add ix,ix ; \
		add ix,ix ; | ix *= 8
		add ix,ix ; /
		ld bc,SSGCNT_mix_macro_A
		add ix,bc

		; Set mix macro
		ld e,(hl) ; \
		inc hl    ; | Store macro data
		ld d,(hl) ; | offset in hl
		ex de,hl  ; /
		push de              ; \
			ld de,MLM_HEADER ; | Add MLM header offset to
			add hl,de        ; | obtain the actual address
		pop de               ; /
		call SSGCNT_MACRO_set
		
		; Calculate pointer to volume macro
		; initialization data (hl) and pointer
		; to the volume macro in WRAM (ix)
		ex de,hl
		inc hl
		ld bc,ControlMacro.SIZE*3
		add ix,bc

		; Set volume macro
		ld e,(hl)
		inc hl
		ld d,(hl)
		ex de,hl
		push de              ; \
			ld de,MLM_HEADER ; | Add MLM header offset to
			add hl,de        ; | obtain the actual address
		pop de               ; /
		call SSGCNT_MACRO_set

		; Set arpeggio macro
		ex de,hl
		inc hl
		add ix,bc
		ld e,(hl)
		inc hl
		ld d,(hl)
		ex de,hl
		push de              ; \
			ld de,MLM_HEADER ; | Add MLM header offset to
			add hl,de        ; | obtain the actual address
		pop de               ; /
		call SSGCNT_MACRO_set
	pop ix
	pop af
	pop bc
	pop hl
	pop de
	jp MLM_set_instrument_return

; a: channel
; c: timing
MLM_set_timing:
	push hl
	push de
	push af
		; MLM_playback_timings[channel] = c
		ld hl,MLM_playback_timings
		ld e,a
		ld d,0
		add hl,de
		ld (hl),c

		; MLM_playback_set_timings[channel] = c
		ld de,MLM_playback_set_timings-MLM_playback_timings
		add hl,de
		ld (hl),c
	pop af
	pop de
	pop hl
	ret

; a: channel (MLM)
MLM_stop_note:
	push hl
	push de
	push af
		ld h,0
		ld l,a
		ld de,MLM_stop_note_vectors
		add hl,hl
		add hl,de
		ld e,(hl)
		inc hl
		ld d,(hl)
		ex de,hl
		jp (hl)
MLM_stop_note_return:
	pop af
	pop de
	pop hl
	ret

MLM_stop_note_vectors:
	dw MLM_stop_note_PA,MLM_stop_note_PA
	dw MLM_stop_note_PA,MLM_stop_note_PA
	dw MLM_stop_note_PA,MLM_stop_note_PA
	dw MLM_stop_note_FM,MLM_stop_note_FM
	dw MLM_stop_note_FM,MLM_stop_note_FM
	dw MLM_stop_note_SSG,MLM_stop_note_SSG
	dw MLM_stop_note_SSG

; a: channel
MLM_stop_note_PA:
	call PA_stop_sample
	jp MLM_stop_note_return

; a: channel
MLM_stop_note_FM:
	push bc
	push af
		sub a,MLM_CH_FM1
		ld c,a
		call FMCNT_stop_channel
	pop af
	pop bc
	jp MLM_stop_note_return

; a: channel
MLM_stop_note_SSG:
	sub a,MLM_CH_SSG1
	call SSGCNT_disable_channel
	jp MLM_stop_note_return

; a: volume
; c: channel
;	This sets MLM_channel_volumes,
;   the register writes are done in
;   the IRQ
MLM_set_channel_volume:
	push hl
	push bc
	push af
		ld hl,MLM_channel_volumes
		ld b,0
		add hl,bc
		ld (hl),a
MLM_set_channel_volume_return:
	pop af
	pop bc
	pop hl
	ret

; a: channel
; c: panning (LR------)
MLM_set_channel_panning:
	push hl
	push de
	push af
		ld h,0
		ld l,a
		ld de,MLM_set_ch_pan_vectors
		add hl,hl
		add hl,de
		ld e,(hl)
		inc hl
		ld d,(hl)
		ex de,hl
		jp (hl)
MLM_set_ch_pan_ret:
	pop af
	pop de
	pop hl
	ret

MLM_set_ch_pan_vectors:
	dw MLM_set_ch_pan_PA,MLM_set_ch_pan_PA
	dw MLM_set_ch_pan_PA,MLM_set_ch_pan_PA
	dw MLM_set_ch_pan_PA,MLM_set_ch_pan_PA
	dw MLM_set_ch_pan_FM,MLM_set_ch_pan_FM
	dw MLM_set_ch_pan_FM,MLM_set_ch_pan_FM
	dw MLM_set_ch_pan_ret,MLM_set_ch_pan_ret
	dw MLM_set_ch_pan_ret ; SSG is mono

MLM_set_ch_pan_PA:
	call PA_set_channel_panning
	jr MLM_set_ch_pan_ret

MLM_set_ch_pan_FM:
	push bc
	push af
		sub a,MLM_CH_FM1
		ld b,c ; \
		ld c,a ; | swap a and c
		ld a,b ; /
		call FMCNT_set_panning
	pop af
	pop bc
	jr MLM_set_ch_pan_ret

;   c:  channel
;   hl: source (playback pointer)
;   de: $MLM_playback_pointers[channel]+1
MLM_parse_command:
	push af
	push bc
	push ix
	push hl
	push de
	push iy
		; Backup $MLM_playback_pointers[channel]+1
		; into ix
		ld ixl,e
		ld ixh,d

		; backup the command's first byte into iyl
		ld a,(hl)
		ld iyl,a

		; Lookup command argc and store it into a
		push hl
			ld l,(hl)
			ld h,0
			ld de,MLM_command_argc
			add hl,de
			ld a,(hl)
		pop hl

		; Lookup command vector and store it into de
		push hl
			ld l,(hl)
			ld h,0
			ld de,MLM_command_vectors
			add hl,hl
			add hl,de
			ld e,(hl)
			inc hl
			ld d,(hl)
		pop hl

		inc hl

		; If the command's argc is 0, 
		; just execute the command
		or a,a ; cp a,0
		jr z,MLM_parse_command_execute

		; if it isn't, load arguments into
		; MLM_event_arg_buffer beforehand
		; and add argc to hl
		push de
		push bc
			ld de,MLM_event_arg_buffer
			ld b,0
			ld c,a
			ldir
		pop bc
		pop de

MLM_parse_command_execute:
		ex de,hl
		jp (hl)

MLM_parse_command_end:
		ex de,hl
		
		; Load $MLM_playback_pointers[channel]+1
		; back into de
		ld e,ixl
		ld d,ixh

		; store playback pointer into WRAM
		ex de,hl
		ld (hl),d
		dec hl
		ld (hl),e

MLM_parse_command_end_skip_playback_pointer_set:
	pop iy
	pop de
	pop hl
	pop ix
	pop bc
	pop af
	jp MLM_update_channel_playback_check_set_t

MLM_command_vectors:
	dw MLMCOM_end_of_list,         MLMCOM_note_off
	dw MLMCOM_set_instrument,      MLMCOM_wait_ticks_byte
	dw MLMCOM_wait_ticks_word,     MLMCOM_set_channel_volume
	dw MLMCOM_set_channel_panning, MLMCOM_set_master_volume
	dw MLMCOM_set_base_time,       MLMCOM_jump_to_sub_el
	dw MLMCOM_small_position_jump, MLMCOM_big_position_jump
	dw MLMCOM_portamento_slide,    MLMCOM_porta_write
	dw MLMCOM_portb_write,         MLMCOM_set_timer_a
	dup 16
		dw MLMCOM_wait_ticks_nibble
	edup
	dw MLMCOM_return_from_sub_el
	dup 15
		dw MLMCOM_invalid ; Invalid commands
	edup
	dup 16
		dw MLMCOM_set_channel_volume_byte
	edup
	dup 64
		dw MLMCOM_invalid ; Invalid commands
	edup

MLM_command_argc:
	db $00, $01, $01, $01, $02, $01, $01, $01
	db $01, $02, $01, $02, $01, $02, $02, $02
	ds 16, $00 ; Wait ticks nibble
	db $00
	ds 15, 0   ; Invalid commands all have no arguments
	ds 16, 0   ; Set Channel Volume (byte sized)
	ds 64, 0   ; Invalid commands all have no arguments

; c: channel
MLMCOM_end_of_list:
	push hl
	push de
	push af
	push bc
		; Set playback control to 0
		ld h,0
		ld l,c
		ld de,MLM_playback_control
		add hl,de
		ld (hl),0

		; Set timing to 1
		; (This is done to be sure that
		;  the next event won't be executed)
		ld a,c
		ld bc,1
		call MLM_set_timing
MLMCOM_end_of_list_return:
	pop bc
	pop af
	pop de
	pop hl
	jp MLM_parse_command_end

; c: channel
; Arguments:
; 	1. timing
MLMCOM_note_off:
	push hl
	push af
	push de
	push bc
		ld a,c
		call MLM_stop_note
		ld hl,MLM_event_arg_buffer
		ld a,c
		ld b,0
		ld c,(hl)
		call MLM_set_timing
	pop bc
	pop de
	pop af
	pop hl
	jp MLM_parse_command_end

; c: channel
; Arguments
;   1. instrument
MLMCOM_set_instrument:
	push af
	push bc
		ld a,(MLM_event_arg_buffer)
		call MLM_set_instrument
		ld a,c
		ld bc,0
		call MLM_set_timing
	pop bc
	pop af
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. timing
MLMCOM_wait_ticks_byte:
	push hl
	push bc
	push af
		ld hl,MLM_event_arg_buffer
		ld a,c
		ld b,0
		ld c,(hl)
		inc bc
		call MLM_set_timing
	pop af
	pop bc
	pop hl
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. timing (LSB)
;   2. timing (MSB)
MLMCOM_wait_ticks_word:
	jp softlock
	push hl
	push bc
	push af
	push ix
		ld ix,MLM_event_arg_buffer
		ld a,c
		ld b,(ix+1)
		ld c,(ix+0)
		call MLM_set_timing
	pop ix
	pop af
	pop bc
	pop hl
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. Volume
MLMCOM_set_channel_volume:
	push ix
	push af
	push hl
	push bc
		ld ix,MLM_event_arg_buffer
		ld a,c ; backup channel into a

		; Store volume in 
		; MLM_channel_volumes[channel]
		ld h,0
		ld l,a
		ld bc,MLM_channel_volumes
		add hl,bc
		ld c,(ix+0)
		ld (hl),c

		; Set timing
		ld bc,0
		call MLM_set_timing
	pop bc
	pop hl
	pop af
	pop ix
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %LRTTTTTT (Left on; Right on; Timing)
MLMCOM_set_channel_panning:
	push af
	push hl
	push bc
	push de
		; Load panning into c
		ld a,(MLM_event_arg_buffer)
		and a,%11000000
		ld b,a ; \
		ld a,c ;  |- Swap a and c sacrificing b
		ld c,b ; /

		call MLM_set_channel_panning

MLMCOM_set_channel_panning_set_timing:
		ld b,a ; backup channel in b
		ld a,(MLM_event_arg_buffer)
		and a,%00111111 ; Get timing
		ld c,a
		ld a,b
		ld b,0
		call MLM_set_timing
	pop de
	pop bc
	pop hl
	pop af
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %VVVVVVTT (Volume; Timing MSB)
MLMCOM_set_master_volume:
	push ix
	push af
	push de
	push bc
		ld ix,MLM_event_arg_buffer

		; Set master volume
		ld a,(ix+0)
		srl a ; %VVVVVV-- -> %-VVVVVV-
		srl a ; %-VVVVVV- -> %--VVVVVV
		ld d,REG_PA_MVOL
		ld e,a
		rst RST_YM_WRITEB

		; Set timing
		ld a,(ix+0)
		and a,%00000011
		ld b,a
		ld a,c
		ld c,b
		ld b,0
		call MLM_set_timing
	pop bc
	pop de
	pop af
	pop ix
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %BBBBBBBB (Base time)
MLMCOM_set_base_time:
	push ix
	push af
		ld ix,MLM_event_arg_buffer

		; Set base time
		ld a,(ix+0)
		ld (MLM_base_time),a

		; Set timing
		ld a,c
		ld bc,0
		call MLM_set_timing
	pop af
	pop ix
	jp MLM_parse_command_end

; c: channel
; ix: $MLM_playback_pointers[channel]+1
; de: source (playback pointer; points to next command)
; Arguments:
;	1. %AAAAAAAA (Address LSB)
;	2. %AAAAAAAA (Address MSB)
MLMCOM_jump_to_sub_el:
	push hl
	push af
	push bc
	push de
		; Store playback pointer in WRAM
		ld b,0
		ld hl,MLM_sub_el_return_pointers
		add hl,bc
		add hl,bc
		ld (hl),e
		inc hl
		ld (hl),d

		; Load address to jump to in de
		ld hl,MLM_event_arg_buffer
		ld e,(hl)
		inc hl
		ld d,(hl)

		; Add MLM_HEADER ($4000) to it 
		; to obtain the actual address
		ld hl,MLM_HEADER
		add hl,de

		; Store the actual address in WRAM
		ld (ix-1),l
		ld (ix-0),h

		; Set timing to 0
		; (Execute next command immediately)
		ld a,c
		ld bc,0
		call MLM_set_timing
	pop de
	pop bc
	pop af
	pop hl
	jp MLM_parse_command_end_skip_playback_pointer_set

; c:  channel
; ix: $MLM_playback_pointers[channel]+1
; de: source (playback pointer)
; Arguments:
;   1. %OOOOOOOO (Offset)
MLMCOM_small_position_jump:
	push hl
	push de
	push ix
		ld hl,MLM_event_arg_buffer

		; Load offset and sign extend 
		; it to 16bit (result in bc)
		ld a,(hl)
		ld l,c     ; Backup channel into l
		call AtoBCextendendsign

		; Add offset to playback 
		; pointer and store it into 
		; MLM_playback_pointers[channel]
		ld a,l ; Backup channel into a
		ld l,e
		ld h,d
		add hl,bc
		ld (ix-1),l
		ld (ix-0),h

		; Set timing to 0
		ld bc,0
		call MLM_set_timing
	pop ix
	pop de
	pop hl
	jp MLM_parse_command_end_skip_playback_pointer_set

; c:  channel
; ix: $MLM_playback_pointers[channel]+1
; de: source (playback pointer)
; Arguments:
;   1. %AAAAAAAA (Address LSB)
;   2. %AAAAAAAA (Address MSB)
MLMCOM_big_position_jump:
	push hl
	push ix
	push af
	push bc
		ld hl,MLM_event_arg_buffer

		; Load offset into bc
		ld a,c ; Backup channel into a
		ld c,(hl)
		inc hl
		ld b,(hl)

		; Add MLM header offset to 
		; obtain the actual address
		ld hl,MLM_HEADER
		add hl,bc
		ld (ix-1),l
		ld (ix-0),h

		; Set timing to 0
		ld bc,0
		call MLM_set_timing
	pop bc
	pop af
	pop ix
	pop hl
	jp MLM_parse_command_end_skip_playback_pointer_set

; c: channel
; Arguments:
;   1. %SSSSSSSS (Signed pitch offset per tick)
MLMCOM_portamento_slide:
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %AAAAAAAA (Address)
;   2. %DDDDDDDD (Data)
MLMCOM_porta_write:
	push de
	push ix
	push af
	push bc
		ld ix,MLM_event_arg_buffer

		ld d,(ix+0)
		ld e,(ix+1)
		rst RST_YM_WRITEA

		ld a,c
		ld bc,0
		call MLM_set_timing

		; If address isn't equal to 
		; REG_TIMER_CNT return
		ld a,d
		cp a,REG_TIMER_CNT
		jr nz,MLMCOM_porta_write_return

		; If address is equal to $27, then
		; store the data's 7th bit in WRAM
		ld a,e
		and a,%01000000 ; bit 6 enables 2CH mode
		ld (EXT_2CH_mode),a
		
MLMCOM_porta_write_return:
	pop bc
	pop af
	pop ix
	pop de
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %AAAAAAAA (Address)
;   2. %DDDDDDDD (Data)
MLMCOM_portb_write:
	push de
	push ix
	push af
	push bc
		ld ix,MLM_event_arg_buffer

		ld d,(ix+0)
		ld e,(ix+1)
		rst RST_YM_WRITEB

		ld a,c
		ld bc,0
		call MLM_set_timing
	pop bc
	pop af
	pop ix
	pop de
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %AAAAAAAA (timer A MSB) 
;   2. %TTTTTTAA (Timing; timer A LSB)
MLMCOM_set_timer_a:
	push ix
	push bc
	push af
	push de
		ld ix,MLM_event_arg_buffer
		ld e,c ; backup channel in e

		; Set timer a counter load
		ld d,REG_TMA_COUNTER_MSB
		ld e,(ix+0)
		rst RST_YM_WRITEA
		inc d
		ld e,(ix+1)
		rst RST_YM_WRITEA
		ld de,REG_TIMER_CNT<<8 | %10101
		RST RST_YM_WRITEA

		ld b,0
		ld a,(ix+1)
		srl a
		srl a
		ld c,a
		ld a,e
		call MLM_set_timing
	pop de
	pop af
	pop bc
	pop ix
	jp MLM_parse_command_end

; c: channel
; de: playback pointer
MLMCOM_wait_ticks_nibble:
	push hl
	push af
	push bc
		; Load command ($1T) in a
		ld h,d
		ld l,e
		dec hl
		ld a,(hl)
		ld l,c ; backup channel

		and a,$0F ; get timing
		ld c,a
		ld b,0
		ld a,l
		inc c ; 0~15 -> 1~16
		call MLM_set_timing
	pop bc
	pop af
	pop hl
	jp MLM_parse_command_end

; c: channel
; ix: $MLM_playback_pointers[channel]+1
; de: source (playback pointer)
MLMCOM_return_from_sub_el:
	push hl
	push af
	push bc
		; Load playback pointer in WRAM
		; and store it into MLM_playback_pointers[channel]
		ld b,0
		ld hl,MLM_sub_el_return_pointers
		add hl,bc
		add hl,bc
		ld a,(hl)   ; - Load and store address LSB
		ld (ix-1),a ; /
		inc hl		; \
		ld a,(hl)   ; | Load and store address MSB
		ld (ix-0),a ; /

		; Set timing to 0
		; (Execute next command immediately)
		ld a,c
		ld bc,0
		call MLM_set_timing
	pop bc
	pop af
	pop hl
	jp MLM_parse_command_end_skip_playback_pointer_set


; c: channel
; de: playback pointer
MLMCOM_set_channel_volume_byte:
	push af
	push bc

		ld a,c
		cp a,MLM_CH_FM1
		jp c,MLMCOM_set_channel_volume_byte_ADPCMA

		cp a,MLM_CH_SSG1
		jp c,MLMCOM_set_channel_volume_byte_FM

		jp MLMCOM_set_channel_volume_byte_SSG

MLMCOM_set_channel_volume_byte_ret:

		ld a,c
		ld bc,0
		call MLM_set_timing
	pop bc
	pop af
	jp MLM_parse_command_end

; a: channel
; c: channel
; de: playback pointer
MLMCOM_set_channel_volume_byte_ADPCMA:
	push af
	push hl
	push bc
	push de
		; Load command byte in l
		ex de,hl
		dec hl
		ld e,(hl)
		ex de,hl

		; Store offset from com byte
		; in a and increment it by 1
		ld a,l
		and a,$07
		inc a

		; Shift offset to the left
		; to adjust the offset to
		; the ADPCM-A range ($00~$1F)
		sla a
		sla a
		sla a

		; If the sign bit is set, 
		; negate offset
		bit 3,l
		jr z,MLMCOM_set_channel_volume_byte_ADPCMA_pos
		neg ; negates a

MLMCOM_set_channel_volume_byte_ADPCMA_pos:
		; Calculate address to channel volume
		ld hl,MLM_channel_volumes
		ld b,0
		add hl,bc

		; Add offset to channel volume
		add a,(hl)
		call MLM_set_channel_volume
	pop de
	pop bc
	pop hl
	pop af
	jp MLMCOM_set_channel_volume_byte_ret

; a: channel
; c: channel
; de: playback pointer
MLMCOM_set_channel_volume_byte_FM:
	push af
	push hl
	push bc
	push de
		; Load command byte in l
		ex de,hl
		dec hl
		ld e,(hl)
		ex de,hl

		; Store offset from com byte
		; in a and increment it by 1
		ld a,l
		and a,$07
		inc a

		; Shift offset to the left
		; to adjust the offset to
		; the FM range ($00~$7F)
		sla a

		; If the sign bit is set, 
		; negate offset
		bit 3,l
		jr z,MLMCOM_set_channel_volume_byte_FM_pos
		neg ; negates a

MLMCOM_set_channel_volume_byte_FM_pos:
		; Calculate address to channel volume
		ld hl,MLM_channel_volumes
		ld b,0
		add hl,bc

		; Add offset to channel volume
		add a,(hl)
		call MLM_set_channel_volume
	pop de
	pop bc
	pop hl
	pop af
	jp MLMCOM_set_channel_volume_byte_ret


; a: channel
; c: channel
; de: playback pointer
MLMCOM_set_channel_volume_byte_SSG:
	push af
	push de
		; Load command byte in a, and 
		; then get the volume from the 
		; least significant nibble of it
		ex de,hl
		dec hl
		ld a,(hl)
		ex de,hl
		and a,$0F

		; Transform SSG Volume ($00~$0F)
		; into an MLM volume ($00~$FF)
		sla a ; -\
		sla a ;  | a <<= 4
		sla a ;  /
		sla a ; /

		call MLM_set_channel_volume
	pop de
	pop af
	jp MLMCOM_set_channel_volume_byte_ret

; invalid command, plays a noisy beep
; and softlocks the driver
MLMCOM_invalid:
	call softlock