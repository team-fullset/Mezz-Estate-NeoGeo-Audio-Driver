; stop song
MLM_stop:
	push hl
	push de
	push bc
	push af
		; clear MLM WRAM
		ld hl,MLM_playback_pointers
		ld de,MLM_playback_pointers+1
		ld bc,MLM_wram_end-MLM_playback_pointers-2
		ld (hl),0
		ldir

		; Stop ADPCM-A channels
		ld b,6
MLM_stop_pa_loop:
		ld c,b
		dec c
		call PA_stop_sample
		djnz MLM_stop_pa_loop

		; Stop SSG channels
		ld b,3
MLM_stop_ssg_loop:
		ld a,b
		dec a
		call SSG_stop_note
		djnz MLM_stop_ssg_loop

		; Set all channel volumes to their
		; default values.
		ld hl,MLM_default_channel_volumes
		ld de,MLM_channel_volumes
		ld bc,CHANNEL_COUNT
		ldir
		
		; Set all pannings to center (%11000000)
		ld hl,MLM_channel_pannings
		ld de,MLM_channel_pannings+1
		ld bc,CHANNEL_COUNT-1
		ld (hl),PANNING_CENTER
		ldir
	pop af
	pop bc
	pop de
	pop hl
	ret

MLM_default_channel_volumes:
	db &1F, &1F, &1F, &1F, &1F, &1F ; ADPCM-A channels
	db &00, &00, &00, &00           ; FM channels
	db &0F, &0F, &0F                ; SSG channels

; a: song
MLM_play_song:
	push hl
	push de
	push af
	push bc
		call MLM_stop
		call set_defaults

		; set all channel timings to 1
		ld b,13
		ld hl,MLM_playback_timings
MLM_play_song_set_timing_loop:
		ld (hl),1
		inc hl
		inc hl
		djnz MLM_play_song_set_timing_loop

		; Load MLM song header (hl = MLM_header[song])
		ld h,0
		ld l,a
		add hl,hl
		ld de,MLM_header
		add hl,de
		ld e,(hl)
		inc hl
		ld d,(hl)
		ld hl,MLM_header
		add hl,de

		; Load MLM playback pointers
		;
		; u16* src = MLM_header[song];
		; u16* dst = MLM_playback_pointers;
		;
		; for (int i = 13; i > 0; i--)
		; { 
		;     *dst = *src + MLM_header; 
		;     
		;	  u8 playback_cnt = 0;
		; 
		;     if (*src != NULL)
		;        playback_cnt++;
		;	  MLM_playback_control[ch] = playback_cnt;
		;
		;     dst++; 
		;     src++; 
	    ; }
		ld de,MLM_playback_pointers
		ld ix,MLM_playback_control		
		ld b,13

MLM_play_song_loop:
		push bc
		push hl
		push de
			ld c,(hl)
			inc hl
			ld b,(hl)

			ld hl,MLM_header
			add hl,bc

			ex de,hl
			ld (hl),e
			inc hl
			ld (hl),d

			xor a,a ; clear a
			add a,c
			add a,b
			ld a,0
			jr c,MLM_play_song_loop_dont_skip
			jr z,MLM_play_song_loop_skip

MLM_play_song_loop_dont_skip:
			inc a

MLM_play_song_loop_skip:
			ld (ix+0),a
		pop de
		pop hl
		pop bc

		inc hl
		inc hl
		inc de
		inc de
		inc ix
		djnz MLM_play_song_loop
	pop bc
	pop af
	pop de
	pop hl
	ret

; c: channel
MLM_update_events:
	push hl
	push de
	push af
	push ix
		; de = MLM_playback_pointers[ch]
		ld h,0
		ld l,c
		add hl,hl
		ld de,MLM_playback_pointers
		add hl,de
		ld e,(hl)
		inc hl
		ld d,(hl)

		; if MLM_playback_pointers[ch] == NULL then return
		xor a,a ; clear a
		add a,d
		add a,e
		jr c,MLM_update_events_do_update
		jr z,MLM_update_events_skip

MLM_update_events_do_update:
		; If the first byte's most significant bit is 0, then
		; parse it and evaluate it as a note, else parse 
		; and evaluate it as a command
		ex de,hl
		ld a,(hl)
		bit 7,a
		call z,MLM_parse_command
		call nz,MLM_parse_note

		; store playback pointer into WRAM
		ex de,hl
		ld (hl),d
		dec hl
		ld (hl),e

MLM_update_events_skip:
	pop ix
	pop af
	pop de
	pop hl
	ret

; [INPUT]
;   c:  channel
;   hl: source
; [OUTPUT]
;   hl: source+2
MLM_parse_note:
	push af
	push bc
		ld a,c
		ld b,(hl)
		inc hl
		ld c,(hl)
		inc hl
		
		; if (channel < 6) MLM_parse_note_pa()
		cp a,6
		jp c,MLM_play_sample_pa

		cp a,10
		jp c,MLM_play_note_fm
		jp MLM_play_note_ssg


MLM_parse_note_end:
	pop bc
	pop af
	ret

; [INPUT]
;   a:  channel
;   bc: source   (-TTTTTTS SSSSSSSS (Timing; Sample))
MLM_play_sample_pa:
	push de
	push bc
	push hl
		; Set sample
		push af
			ld a,b
			and a,%00000001
			ld d,a
			ld e,c
		pop af
		call PA_set_sample_addr

		; Set timing
		push af
			ld a,b
			srl a
			and a,%00111111
			ld c,a
			ld b,0
		pop af
		call MLM_set_timing

		; Set volume
		ld h,0
		ld l,a
		ld de,MLM_channel_volumes
		add hl,de
		ld c,(hl)
		call PA_set_channel_volume

		; play sample
		ld h,0
		ld l,a
		ld de,PA_channel_on_masks
		add hl,de
		ld d,REG_PA_CTRL
		ld e,(hl) 
		rst RST_YM_WRITEB
	pop hl
	pop bc
	pop de
	jp MLM_parse_note_end

; [INPUT]
;   a:  channel+6
;   bc: source
MLM_play_note_fm:
	; Set Timing
	push bc
		; Mask timing
		push af
			ld a,b
			and a,%01111111
			ld c,a
			ld b,0
		pop af

		call MLM_set_timing
	pop bc

	; Play note
	push af
	push hl
	push de
	push bc
		; backup MLM channel number into b
		ld b,a

		; Lookup correct FM channel number
		sub a,6
		ld h,0
		ld l,a
		ld de,FM_channel_LUT
		add hl,de
		ld a,(hl)

		call FM_stop_channel

		push bc
			ld h,0
			ld l,b
			ld de,MLM_channel_pannings
			add hl,de
			ld c,(hl)
			call FM_set_panning
		pop bc

		; Load instrument
		push bc
			ld h,0
			ld l,b
			ld de,MLM_channel_instruments
			add hl,de
			ld b,a
			ld c,(hl)
			call FM_load_instrument
		pop bc

		; Set attenuator
		push bc
			ld l,b
			ld h,0
			ld de,MLM_channel_volumes
			add hl,de
			ld c,(hl)
			call FM_set_attenuator
		pop bc

		ld b,a
		call FM_set_note

		ld d,REG_FM_KEY_ON
		or a,%11110000
		ld e,a
		rst RST_YM_WRITEA
	pop bc
	pop de
	pop hl
	pop af
	jp MLM_parse_note_end

; [INPUT]
;   a:  channel+10
;   bc: source (-TTTTTTT NNNNNNNN (Timing; Note))
MLM_play_note_ssg:
	push af
	push hl
	push bc
	push de
		; Set timing
		push bc
			push af
				ld a,b
				and a,%01111111
				ld c,a
			pop af

			ld b,0
			call MLM_set_timing
		pop bc

		ld b,a   ; backup MLM channel into b
		sub a,10 ; MLM channel to SSG channel (0~2)
		call SSG_set_note

		; Set attenuator
		ld h,0
		ld l,b
		ld de,MLM_channel_volumes
		add hl,de
		ld c,(hl)
		call SSG_set_attenuator

		; Set instrument
		ld h,0
		ld l,b
		ld de,MLM_channel_instruments
		add hl,de
		ld c,(hl)
		call SSG_set_instrument
	pop de
	pop bc
	pop hl
	pop af
	jp MLM_parse_note_end

; [INPUT]
;   c:  channel
;   hl: source
; [OUTPUT]
;   hl: source+command_argc
MLM_parse_command:
	push af
	push de
	push bc
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
		cp a,0
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
	pop bc
	pop de
	pop af
	ret

MLM_command_vectors:
	dw MLMCOM_end_of_list,     MLMCOM_note_off
	dw MLMCOM_set_instrument,  MLMCOM_wait_ticks_byte
	dw MLMCOM_wait_ticks_word, MLMCOM_set_channel_volume
	dw MLMCOM_set_channel_panning

MLM_command_argc:
	db &00, &01, &01, &01, &02, &02, &01

; a:  channel
; bc: timing
MLM_set_timing:
	push hl
	push de
		ld h,0
		ld l,a
		ld de,MLM_playback_timings
		add hl,hl
		add hl,de
		ld (hl),c
		inc hl
		ld (hl),b

		ld de,MLM_playback_set_timings-MLM_playback_timings
		add hl,de
		ld (hl),b
		dec hl
		ld (hl),c
	pop de
	pop hl
	ret

; c: channel
;   Sets MLM_playback_control[channel] to 0 (false)
MLMCOM_end_of_list:
	push hl
	push de
		ld h,0
		ld l,c
		ld de,MLM_playback_control
		add hl,de

		ld (hl),0
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
		; switch (channel) {
		; case is_adpcma:
		;   PA_stop_sample(channel);
		;   break;
		;
		; case is_ssg:
		;   SSG_stop_channel(channel-10);
		;   break;
		;
		; default: // is fm
		;   FM_stop_channel(FM_channel_LUT[channel-6]);
		;   break;
		; }
		ld a,c
		cp a,6
		call c,PA_stop_sample
		jr c,MLMCOM_note_off_break

		cp a,10
		sub a,10
		call nc,SSG_stop_note
		jr nc,MLMCOM_note_off_break

		ld a,c
		sub a,6
		ld h,0
		ld l,a 
		ld de,FM_channel_LUT
		add hl,de
		ld a,(hl)
		call FM_stop_channel

MLMCOM_note_off_break:
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
	push hl
	push bc
		ld hl,MLM_event_arg_buffer
		ld a,(hl)
		ld b,0
		ld hl,MLM_channel_instruments
		add hl,bc
		ld (hl),a

		ld a,c
		ld bc,0
		call MLM_set_timing
	pop bc
	pop hl
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
;   2. Timing
MLMCOM_set_channel_volume:
	push ix
	push af
	push hl
	push de
	push bc
		ld ix,MLM_event_arg_buffer
		ld a,c
		ld c,(ix+0)

		; Store channel volume/attenuator into WRAM
		ld h,0
		ld l,a
		ld de,MLM_channel_volumes
		add hl,de
		ld (hl),c

		; Set timing
		ld c,(ix+1)
		ld b,0
		call MLM_set_timing
	pop bc
	pop de
	pop hl
	pop af
	pop ix
	jp MLM_parse_command_end

; c: channel
; Arguments:
;   1. %LRTTTTTT (Left on; Right on; Timing)
MLMCOM_set_channel_panning:
	push af
	push bc
	push hl
		; Set panning
		ld hl,MLM_event_arg_buffer
		ld a,(hl)
		and a,%11000000 ; get panning
		ld hl,MLM_channel_pannings
		ld b,0
		add hl,bc
		ld (hl),a

		ld hl,MLM_event_arg_buffer
		ld a,(hl)
		and a,%00111111 ; get timing
		ld l,c ; \
		ld c,a ;  | Swap registers a and c
		ld b,0 ;  | using l as an intermediate
		ld a,l ; /
		call MLM_set_timing
	pop hl
	pop bc
	pop af
	jp MLM_parse_command_end