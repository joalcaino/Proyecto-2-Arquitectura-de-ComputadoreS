# isa_test.s - prueba cada instruccion del Espino Core, ensamblada con NUESTRO assembler.
#
# Si el assembler codifica mal un bit, el procesador real (el RTL) ejecuta otra
# cosa y la prueba falla. Asi se verifica el assembler contra el hardware.
#
# Resultado (lo revisa sim/isa_tb.v):
#   todo bien  -> displays "AA" y LEDs 1111
#   falla      -> displays = numero de la prueba que fallo (en gp) y LEDs 1001
# El testbench deja los botones en 1010 para la prueba de lectura de perifericos.

.equ PERIPH,  0x80000000
.equ DISPLAY, 0x0
.equ LEDS,    0x4
.equ BUTTONS, 0x8
.equ CYCLES,  0xC
.equ SCRATCH, 0x700               # RAM libre, lejos del programa

_start:
    li   s0, PERIPH

# --- ALU registro-registro -------------------------------------------------
    li   gp, 1
    li   t0, 5
    li   t1, 7
    add  a0, t0, t1
    li   t2, 12
    bne  a0, t2, fail

    li   gp, 2
    sub  a0, t0, t1               # 5 - 7 = -2
    li   t2, -2
    bne  a0, t2, fail

    li   gp, 3
    li   t0, 0x0F0F
    li   t1, 0x00FF
    xor  a0, t0, t1
    li   t2, 0x0FF0
    bne  a0, t2, fail
    or   a0, t0, t1
    li   t2, 0x0FFF
    bne  a0, t2, fail
    and  a0, t0, t1
    li   t2, 0x000F
    bne  a0, t2, fail

    li   gp, 4
    li   t0, -1
    li   t1, 1
    slt  a0, t0, t1               # con signo: -1 < 1
    li   t2, 1
    bne  a0, t2, fail
    sltu a0, t0, t1               # sin signo: 0xFFFFFFFF < 1 es falso
    bnez a0, fail

# --- ALU con inmediato ------------------------------------------------------
    li   gp, 5
    li   t0, 100
    addi a0, t0, -2048
    li   t2, -1948
    bne  a0, t2, fail
    addi a0, t0, 2047
    li   t2, 2147
    bne  a0, t2, fail

    li   gp, 6
    slti  a0, t0, 101
    li    t2, 1
    bne   a0, t2, fail
    sltiu a0, t0, 100             # 100 < 100 es falso
    bnez  a0, fail
    li    t1, -5
    sltiu a0, t1, 5               # -5 sin signo es enorme
    bnez  a0, fail

    li   gp, 7
    li   t0, 0x5A5
    xori a0, t0, -1               # not
    li   t2, 0xFFFFFA5A
    bne  a0, t2, fail
    ori  a0, t0, 0x00F
    li   t2, 0x5AF
    bne  a0, t2, fail
    andi a0, t0, 0x0F0
    li   t2, 0x0A0
    bne  a0, t2, fail

# --- lui / auipc ------------------------------------------------------------
    li   gp, 8
    lui  a0, 0x12345
    li   t2, 0x12345000
    bne  a0, t2, fail
    li   a0, 0x12345800           # li que necesita redondear la parte alta
    li   t2, 0x12345000
    sub  a0, a0, t2
    li   t2, 0x800
    bne  a0, t2, fail

    li   gp, 9
    jal  ra, here                 # ra = direccion de 'here'
here:
    auipc a0, 0                   # a0 = pc de esta instruccion = here
    bne   a0, ra, fail
    auipc a1, 1                   # esta en here + 8: a1 = (here + 8) + 0x1000
    sub   a1, a1, ra
    li    t2, 0x1008
    bne   a1, t2, fail

# --- branches: cada uno tomado y no tomado ----------------------------------
    li   gp, 10
    li   t0, -1
    li   t1, 1
    beq  t0, t0, b1
    j    fail
b1: beq  t0, t1, fail
    bne  t0, t1, b2
    j    fail
b2: bne  t0, t0, fail
    blt  t0, t1, b3               # -1 < 1 con signo
    j    fail
b3: blt  t1, t0, fail
    bge  t1, t0, b4
    j    fail
b4: bge  t0, t1, fail
    bgeu t0, t1, b5               # 0xFFFFFFFF >= 1 sin signo
    j    fail
b5: bgeu t1, t0, fail
    bltu t1, t0, b6
    j    fail
b6: bltu t0, t1, fail
    bge  t0, t0, b7               # igual cuenta como >=
    j    fail
b7:

# --- jal / jalr -------------------------------------------------------------
    li   gp, 11
    li   a0, 0
    call add_three                # a0 += 3
    call add_three
    li   t2, 6
    bne  a0, t2, fail

    li   gp, 12
    jal  ra, get_ra
got_ra:
    jalr t0, 8(ra)                # salta a got_ra + 8 y guarda la vuelta en t0
    j    fail                     # got_ra + 4: no debe ejecutarse
    sub  t1, t0, ra               # got_ra + 8: t0 = got_ra + 4
    li   t2, 4
    bne  t1, t2, fail

# --- memoria: palabras, medias palabras y bytes -----------------------------
    li   gp, 13
    li   t0, SCRATCH
    li   t1, 0x11223344
    sw   t1, 0(t0)
    lw   a0, 0(t0)
    bne  a0, t1, fail

    li   gp, 14
    li   t1, 0xA1
    sb   t1, 0(t0)
    li   t1, 0xB2
    sb   t1, 1(t0)
    li   t1, 0xC3
    sb   t1, 2(t0)
    li   t1, 0x84
    sb   t1, 3(t0)
    lw   a0, 0(t0)
    li   t2, 0x84C3B2A1
    bne  a0, t2, fail

    li   gp, 15
    lb   a0, 3(t0)                # 0x84 con signo = -124
    li   t2, -124
    bne  a0, t2, fail
    lbu  a0, 3(t0)
    li   t2, 0x84
    bne  a0, t2, fail
    lbu  a0, 1(t0)
    li   t2, 0xB2
    bne  a0, t2, fail

    li   gp, 16
    li   t1, 0x8001
    sh   t1, 2(t0)                # la mitad alta pasa a 0x8001
    lw   a0, 0(t0)
    li   t2, 0x8001B2A1
    bne  a0, t2, fail
    lh   a0, 2(t0)
    li   t2, 0xFFFF8001
    bne  a0, t2, fail
    lhu  a0, 2(t0)
    li   t2, 0x8001
    bne  a0, t2, fail

    li   gp, 17
    sw   t1, -4(t0)               # desplazamiento negativo
    addi t2, t0, -4
    lw   a0, 0(t2)
    bne  a0, t1, fail

# --- perifericos --------------------------------------------------------------
    li   gp, 18
    lw   a0, BUTTONS(s0)          # el testbench deja los botones en 1010
    li   t2, 0xA
    bne  a0, t2, fail

    li   gp, 19
    lw   t0, CYCLES(s0)
    lw   t1, CYCLES(s0)
    sub  a0, t1, t0               # avanza, y poco (cada lw toma unos pocos ciclos)
    beqz a0, fail
    li   t2, 20
    bgeu a0, t2, fail

# --- detalles del Espino ------------------------------------------------------
    li   gp, 20
    addi zero, zero, 5            # x0 siempre vale 0
    bnez zero, fail

    li   gp, 21
    li   t0, 5
    slli a0, t0, 3                # el "catch" del Espino: shift = ADD, da 5 + 3
    li   t2, 8
    bne  a0, t2, fail

    li   gp, 22
    nop
    ecall                         # el decoder los acepta y no hacen nada
    ebreak
    fence
    li   t2, 8
    bne  a0, t2, fail

pass:
    li   t0, 0xAA
    sw   t0, DISPLAY(s0)
    li   t0, 0xF
    sw   t0, LEDS(s0)
pass_loop:
    j    pass_loop

fail:
    sw   gp, DISPLAY(s0)
    li   t0, 0x9
    sw   t0, LEDS(s0)
fail_loop:
    j    fail_loop

add_three:
    addi a0, a0, 3
    ret

get_ra:
    ret                           # vuelve a got_ra con ra = got_ra
