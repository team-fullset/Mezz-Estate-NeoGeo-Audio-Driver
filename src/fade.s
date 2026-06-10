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