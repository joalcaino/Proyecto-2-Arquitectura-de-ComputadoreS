# game.s - Juego de reflejos para el Espino Core (Pochoco SoC, Go Board)
# Proyecto 2 - Arquitectura de Computadores 2026-2
#
# Se traduce con nuestro assembler:   python3 asm/pochoasm.py sw/game.s -o sw/game.hex
#
# Como se juega:
#   1. Los LEDs parpadean (0101 <-> 1010): el juego espera. Aprieta cualquier boton.
#   2. Cada ronda: los 4 LEDs encendidos 3 s; despues queda uno solo, el objetivo.
#   3. Aprieta el boton de ese LED (boton i = LED i). Los displays muestran tu
#      tiempo en decimas de segundo ("04" = 0,4 s).
#   4. Boton equivocado: los displays muestran "EE" y la ronda se repite.
#      Las rondas correctas que ya llevabas se conservan.
#   5. Tras ROUNDS respuestas correctas se ve el ultimo tiempo 3 s, y despues el
#      PROMEDIO con los LEDs parpadeando. Otro boton empieza una partida nueva.
#
# El procesador es RV32E sin multiplicacion, sin division y con los shifts
# deshabilitados (se ejecutan como ADD). Por eso:
#   x * 2   se hace con   add x, x, x
#   a / b   se hace con   restas sucesivas (subrutina divu)

# ---------------------------------------------------------------------------
# Constantes del juego: lo que se puede cambiar en la demo
# El reloj de la Go Board es de 25 MHz: 1 s = 25_000_000 ciclos.
# ---------------------------------------------------------------------------
.equ ROUNDS,          10          # respuestas correctas por partida
.equ WAIT_CYCLES,     75000000    # fase con los 4 LEDs: 3 s = 3 * 25_000_000
.equ TENTH_CYCLES,    2500000     # ciclos en una decima de segundo = 25_000_000 / 10
.equ DEBOUNCE_CYCLES, 500000      # 20 ms con los botones sueltos antes de mostrar el objetivo
.equ BLINK_CYCLES,    6250000     # 0,25 s: cada cuanto cambian los LEDs mientras se espera
.equ ERROR_CODE,      0xEE        # lo que muestran los displays ante un boton incorrecto

# ---------------------------------------------------------------------------
# Mapa de memoria de los perifericos (rtl/pochoco_periph.v)
# ---------------------------------------------------------------------------
.equ PERIPH,   0x80000000         # base; queda fija en s0 todo el programa
.equ DISPLAY,  0x0                # escritura: bits 7:4 display izquierdo, 3:0 derecho (hex)
.equ LEDS,     0x4                # escritura: bits 3:0, LED0..LED3
.equ BUTTONS,  0x8                # lectura:   bits 3:0, 1 = boton apretado
.equ CYCLES,   0xC                # lectura:   contador de ciclos de 32 bits (lo agregamos)

# ---------------------------------------------------------------------------
# Generador pseudoaleatorio: LFSR de Galois de 32 bits
# Polinomio x^32 + x^22 + x^2 + x + 1 (periodo maximo, 2^32 - 1 estados).
# ---------------------------------------------------------------------------
.equ LFSR_TAPS,  0x00400007       # bits 22, 2, 1 y 0
.equ LFSR_STEPS, 32               # pasos por ronda: una palabra completa de bits nuevos

# ---------------------------------------------------------------------------
# Registros (RV32E solo tiene x0..x15)
#   s0  base de perifericos 0x80000000      (fijo)
#   s1  estado del LFSR                      (vive toda la partida)
#   a2  ciclo en que se encendio el objetivo (inicio del cronometro)
#   a3  LED objetivo, en one-hot (0001, 0010, 0100 o 1000)
#   a4  suma de las decimas de las rondas correctas
#   a5  rondas correctas llevadas
#   a0, a1       argumentos y resultado de las subrutinas
#   t0, t1, t2   temporales: cualquier subrutina los pisa
# Todas las subrutinas son "hoja" (no llaman a otras), asi que ra nunca se
# pisa y no hace falta stack.
# ---------------------------------------------------------------------------

.text
.global _start

_start:
    li   s0, PERIPH
    li   a0, 0
    call show_number                # displays en "00"

# ===========================================================================
# Una partida
# ===========================================================================
game:
    call wait_release
    call wait_start                 # parpadea hasta que aprieten; a0 = ciclo del apreton
    ori  s1, a0, 1                  # semilla del LFSR: el instante humano (| 1: nunca 0)
    li   a5, 0                      # rondas correctas = 0
    li   a4, 0                      # suma de decimas  = 0
    li   a0, 0
    call show_number

# ===========================================================================
# Una ronda
# ===========================================================================
round:
    li   t0, 0xF
    sw   t0, LEDS(s0)               # 1) los cuatro LEDs encendidos...
    li   a0, WAIT_CYCLES
    call wait_cycles                #    ...durante 3 s
    call wait_release               #    ...y hasta que nadie este apretando

    call pick_target                # 2) a0 = LED objetivo al azar
    mv   a3, a0
    sw   a3, LEDS(s0)               #    solo el objetivo encendido
    lw   a2, CYCLES(s0)             # 3) y en ese mismo instante parte el cronometro

wait_press:
    lw   t0, BUTTONS(s0)
    beqz t0, wait_press             # 4) esperar un boton
    lw   t1, CYCLES(s0)             #    fin del cronometro
    bne  t0, a3, wrong              #    boton incorrecto (o mas de uno a la vez)

    sub  a0, t1, a2                 # 5) ciclos de reaccion. La resta sin signo
                                    #    da bien aunque el contador se haya desbordado
    li   a1, TENTH_CYCLES
    call divu                       #    decimas = ciclos / 2_500_000 (trunca)
    add  a4, a4, a0                 #    acumular para el promedio
    call show_number                #    y mostrar

    addi a5, a5, 1
    li   t0, ROUNDS
    bltu a5, t0, round              # 6) otra ronda hasta completar ROUNDS

    sw   zero, LEDS(s0)             # 7) fin: se deja ver el ultimo tiempo 3 s
    li   a0, WAIT_CYCLES
    call wait_cycles
    mv   a0, a4
    li   a1, ROUNDS
    call divu                       #    promedio = suma / ROUNDS (trunca)
    call show_number
    j    game                       #    wait_start lo deja en pantalla, parpadeando

wrong:
    li   t0, ERROR_CODE
    sw   t0, DISPLAY(s0)            # 8) "EE" y se repite la ronda. a4 y a5 no
    j    round                      #    cambian: las correctas se conservan

# ===========================================================================
# Subrutinas
# ===========================================================================

# wait_cycles: espera a0 ciclos de reloj.
wait_cycles:
    lw   t0, CYCLES(s0)             # t0 = inicio
wc_loop:
    lw   t1, CYCLES(s0)
    sub  t1, t1, t0                 # t1 = ciclos transcurridos
    bltu t1, a0, wc_loop
    ret

# wait_release: vuelve cuando los botones llevan DEBOUNCE_CYCLES seguidos sin
# apretarse. Filtra los rebotes del boton al soltarlo.
wait_release:
    li   a1, DEBOUNCE_CYCLES
    lw   t0, CYCLES(s0)             # t0 = ultima vez que se vio un boton apretado
wr_loop:
    lw   t1, CYCLES(s0)
    lw   t2, BUTTONS(s0)
    beqz t2, wr_quiet
    mv   t0, t1                     # hay un boton: la cuenta parte de cero otra vez
wr_quiet:
    sub  t1, t1, t0
    bltu t1, a1, wr_loop
    ret

# wait_start: parpadea los LEDs 0101 <-> 1010 hasta que se apriete un boton.
# Devuelve a0 = valor del contador en ese instante (la semilla aleatoria).
wait_start:
    li   t2, 0b0101                 # patron de LEDs
    li   a1, BLINK_CYCLES
    lw   t0, CYCLES(s0)             # t0 = inicio del medio periodo actual
ws_loop:
    sw   t2, LEDS(s0)
    lw   t1, BUTTONS(s0)
    bnez t1, ws_pressed
    lw   t1, CYCLES(s0)
    sub  t1, t1, t0
    bltu t1, a1, ws_loop
    xori t2, t2, 0xF                # 0101 <-> 1010
    add  t0, t0, a1                 # siguiente medio periodo
    j    ws_loop
ws_pressed:
    lw   a0, CYCLES(s0)
    ret

# pick_target: avanza el LFSR (s1) LFSR_STEPS pasos y devuelve en a0 el LED
# objetivo en one-hot: a0 = 1 << (s1 & 3).
#
# Un paso del LFSR de Galois hacia la izquierda:
#     si el bit 31 es 1:  s1 = (s1 << 1) xor LFSR_TAPS
#     si no:              s1 = (s1 << 1)
# Sin shifts: s1 << 1 es s1 + s1, y "bit 31 = 1" es lo mismo que "s1 < 0".
pick_target:
    li   t2, LFSR_TAPS
    li   t1, LFSR_STEPS
pt_step:
    add  t0, s1, s1                 # t0 = s1 << 1
    bge  s1, zero, pt_no_tap        # bit 31 era 0: sin realimentacion
    xor  t0, t0, t2
pt_no_tap:
    mv   s1, t0
    addi t1, t1, -1
    bnez t1, pt_step

    andi t0, s1, 3                  # indice del LED: 0..3
    li   a0, 1
pt_mask:
    beqz t0, pt_done
    add  a0, a0, a0                 # a0 <<= 1, indice veces
    addi t0, t0, -1
    j    pt_mask
pt_done:
    ret

# divu: a0 = a0 / a1, division entera sin signo por restas sucesivas.
# El resultado es la cantidad de veces que cabe a1 en a0 (trunca).
divu:
    li   t0, 0                      # t0 = cociente
du_loop:
    bltu a0, a1, du_done
    sub  a0, a0, a1
    addi t0, t0, 1
    j    du_loop
du_done:
    mv   a0, t0
    ret

# show_number: muestra a0 en decimal en los dos displays.
# Los displays dibujan un digito hexadecimal cada uno, asi que se escribe
# decenas * 16 + unidades: el 37 se escribe como 0x37 y se lee "37".
# Mas de 99 no cabe en dos digitos: se muestra 99.
show_number:
    li   t0, 99
    bleu a0, t0, sn_fits
    mv   a0, t0
sn_fits:
    li   t1, 0                      # t1 = decenas
    li   t2, 10
sn_tens:
    bltu a0, t2, sn_write           # lo que queda en a0 son las unidades
    sub  a0, a0, t2
    addi t1, t1, 1
    j    sn_tens
sn_write:
    add  t1, t1, t1                 # decenas * 2
    add  t1, t1, t1                 #         * 4
    add  t1, t1, t1                 #         * 8
    add  t1, t1, t1                 #         * 16
    add  t1, t1, a0                 # + unidades
    sw   t1, DISPLAY(s0)
    ret
