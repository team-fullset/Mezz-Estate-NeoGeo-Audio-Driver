; DOESN'T BACKUP REGISTERS  
FADE_irq:
    ; If the fade offset is 0, 
    ; the fade system is disabled.
    ld a,(FADE_offset)
    or a,a
    ret z

    ld b,a  ; store fade ofs in b
    ld a,(master_volume)
    ld c,a  ; backup old mvol in c
    add a,b ; new mvol is in a

    ; If FADE_offset is positive, check for overflow...
    bit 7,b 
    jp z,check_overflow$

    ; ...Else, check for underflow.
    or a,a ; cp a,0
    jp z,solve_underflow$  ; mvol has reached 0.
    cp a,c                 ; new_mvol >= old_mvol. (with a negative 
    jp nc,solve_underflow$ ; offset it means an underflow happened)

check_end$:
    ld (master_volume),a
    ld a,$FF 
    ld (do_reset_chvols),a
    ret

solve_underflow$:
    ; Solve underflow (or do nothing if mvol was 0), then disable the fade.
    ; In a pause cycle we hold at 0 instead of stopping the song (that stop
    ; path would wipe the playback position we're trying to preserve).
    ld a,(pause_flag)
    or a,a
    jr nz,underflow_hold$
        ld a,255
        ld (do_stop_song),a
underflow_hold$:
    xor a,a ; clear a (target master_volume = 0)
    ld (FADE_offset),a
    jp check_end$

check_overflow$:
    ; A resume fade-in (pause_flag==2) clamps at the song's saved master
    ; volume instead of running all the way up to 255.
    ld b,a                  ; preserve new mvol in b
    ld a,(pause_flag)
    cp a,2
    jr z,overflow_resume$
        ld a,b              ; not resuming: restore new mvol
        jr overflow_check$
overflow_resume$:
        ld a,(pause_saved_mvol)
        cp a,b              ; saved - new : carry if saved < new
        jr c,resume_done$   ; overshot the saved volume
        jr z,resume_done$   ; reached it exactly
        ld a,b              ; saved > new: keep fading in
        jr overflow_check$
resume_done$:
        xor a,a
        ld (FADE_offset),a
        ld (pause_flag),a   ; pause cycle complete, back to normal
        ld a,(pause_saved_mvol)
        jp check_end$

overflow_check$:
    cp a,255
    jp z,solve_overflow$ ; mvol has reached 255... (fade in needs to be disabled)
    cp a,c
    jp nc,check_end$     ; if new_mvol >= old_mvol, no overflow has accured.

solve_overflow$:
    ; solve overflow (or change nothing if 
    ; mvol was 255), then disable fade in.
    xor a,a ; clear a
    ld (FADE_offset),a
    dec a ; a becomes 255
    jp check_end$

; UCOM $0E/$0F live here, after all other code, so adding them moved nothing.
; Samples 128..254: the parameter byte only carries 7 bits.
; b: %0SSSSSSS (sample $80+S)
UCOM_CMD_sfxps_play_smp_hi:
    set 7,b
    jp UCOM_CMD_sfxps_play_smp

; b: %0SSSSSSS (sample $80+S)
UCOM_CMD_sfxps_retrig_smp_hi:
    set 7,b
    jp UCOM_CMD_sfxps_retrig_smp

; The chip's ADPCM-A master level (music and SFX), as Knight's Chance's
; original driver changes it. A song's own master volume command overrides it.
; b: %00VVVVVV
UCOM_CMD_set_pa_master_vol:
    push de
        ld d,REG_PA_MVOL
        ld e,b
        rst RST_YM_WRITEB
    pop de
    jp UCOM_run_command_return

; b: %0DDDDDDD, shifted into com_raw_addr from the bottom.
;   Five pushes carry (end << 16) | start, both in 256-byte units.
UCOM_CMD_raw_push:
    push af
    push bc
    push hl
        ld c,7
loop$:
        ld hl,com_raw_addr
        sla (hl)
        inc hl
        rl (hl)
        inc hl
        rl (hl)
        inc hl
        rl (hl)
        dec c
        jr nz,loop$
        ld hl,com_raw_addr
        ld a,(hl)
        or a,b
        ld (hl),a
    pop hl
    pop bc
    pop af
    jp UCOM_run_command_return

; b: %0B000XXX
;   B=0: ADPCM-A on channel XXX (6, 7: all six) at full volume, both sides
;   B=1: ADPCM-B at pitch XXX, delta-N ($44 + XXX * 8) << 8
;   The range is the last five raw pushes.
UCOM_CMD_raw_play:
    push af
    push bc
    push de
    push ix
        ld ix,com_raw_addr
        bit 6,b
        jr nz,adpcm_b$

        ld a,b
        and a,7
        cp a,6
        jr c,one_channel$
        ld b,0
all_channels$:
        ld a,b
        call raw_play_pa$
        inc b
        ld a,b
        cp a,6
        jr nz,all_channels$
        jr return$
one_channel$:
        call raw_play_pa$
        jr return$

adpcm_b$:
        ld de,REG_PB_CTRL<<8 | $01
        rst RST_YM_WRITEA
        ld de,REG_PB_VOL<<8 | $FF
        rst RST_YM_WRITEA
        ld de,REG_PB_LRSEL<<8 | $C0
        rst RST_YM_WRITEA
        ld de,REG_PB_FREQL<<8 | $00
        rst RST_YM_WRITEA
        ld a,b
        and a,7
        sla a
        sla a
        sla a
        add a,$44
        ld d,REG_PB_FREQH
        ld e,a
        rst RST_YM_WRITEA
        ld d,REG_PB_STARTL
        ld e,(ix+0)
        rst RST_YM_WRITEA
        ld d,REG_PB_STARTH
        ld e,(ix+1)
        rst RST_YM_WRITEA
        ld d,REG_PB_ENDL
        ld e,(ix+2)
        rst RST_YM_WRITEA
        ld d,REG_PB_ENDH
        ld e,(ix+3)
        rst RST_YM_WRITEA
        ld de,REG_PB_CTRL<<8 | $80
        rst RST_YM_WRITEA
return$:
    pop ix
    pop de
    pop bc
    pop af
    jp UCOM_run_command_return

; a: ADPCM-A channel
raw_play_pa$:
    push bc
        call PA_set_sample_addr
        ld c,192
        call PA_set_channel_panning
        ld c,a
        push af
            ld a,$1F
            call PA_set_channel_volume
        pop af
        ld e,a
        call PA_play_sample
    pop bc
    ret
