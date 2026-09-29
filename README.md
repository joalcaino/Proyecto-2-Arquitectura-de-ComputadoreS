# Proyecto 2: Juego de reflejos en assembly sobre Pochoco SoC

Arquitectura de Computadores 2026-2, Universidad de los Andes. Profesor Jorge Gómez Mir.

Grupo: Josefa Alcaíno Lira, Felipe Izcúe Ferrer, Martín Norton Haigis.

Un juego de reflejos escrito en assembly RV32E, que corre sobre el procesador Espino
del [Pochoco SoC](https://github.com/nic0villegasc/pochoco_soc) en una Nandland Go Board
(FPGA Lattice iCE40 HX1K). El assembly se traduce a código de máquina con un assembler
propio escrito en Python (`asm/pochoasm.py`), sin usar ningún assembler RISC-V externo.

## Cómo se juega

1. Al encender, los LEDs parpadean (0101 y 1010) y los displays muestran `00`. Aprieta cualquier botón para empezar.
2. En cada ronda los cuatro LEDs se encienden 3 segundos. Después queda encendido uno solo: el objetivo.
3. Aprieta el botón de ese LED (el botón 1 corresponde al LED 1, y así). Los displays muestran tu tiempo en décimas de segundo: `04` son 0,4 s.
4. Si aprietas otro botón, los displays muestran `EE` y la ronda se repite. Las rondas correctas que llevabas se conservan.
5. Después de 10 respuestas correctas se ve el último tiempo 3 segundos, y luego el promedio, con los LEDs parpadeando. Otro botón empieza una partida nueva.

## Estructura

```
rtl/game_top.v         top-level que se sintetiza: instancia el SoC con sw/game.hex
rtl/pochoco_periph.v   periféricos del SoC + el contador de ciclos que agregamos (0x8000000C)
rtl/pochoco_soc.v      el SoC; alargamos su reset de encendido (ver abajo)
rtl/...                resto del SoC y del core Espino, sin cambios
sw/game.s              el juego, en assembly
sw/game.hex            el juego en código de máquina (lo genera el assembler)
asm/pochoasm.py        el assembler
asm/test_pochoasm.py   pruebas del assembler
asm/golden/            ejemplos del repo original con su .hex hecho por el assembler de GNU
sim/isa_test.s         programa que prueba cada instrucción sobre el procesador simulado
sim/isa_tb.v           testbench que corre isa_test en el SoC
sim/game_tb.v          testbench que juega dos partidas completas y revisa cada regla
goboard.pcf            pines de la Go Board
pochoco_soc.svg        diagrama del SoC (del repositorio original)
game_top.bin           bitstream ya compilado (respaldo para la demo)
informe/               informe en LaTeX
docs/                  explicación completa del proyecto
```

## Requisitos

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build): trae yosys, nextpnr, icepack, iceprog, iverilog y python3.
- `make`. En Windows: `winget install ezwinports.make`.
- La Go Board conectada por USB.

## Compilar y programar la placa

1. Abre la terminal de OSS CAD Suite. En Windows, en PowerShell:
   ```
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   & "$HOME\oss-cad-suite\environment.ps1"
   ```
   La primera línea permite ejecutar scripts solo en esa ventana; sin ella PowerShell responde "la ejecución de scripts está deshabilitada". Alternativa sin tocar nada: en `cmd`, ejecutar `%USERPROFILE%\oss-cad-suite\environment.bat`.
   En Linux: `source <ruta>/oss-cad-suite/environment`.
2. Ve a la carpeta del proyecto y ejecuta:
   ```
   make prog
   ```
   Esto ensambla `sw/game.s`, sintetiza, hace place and route, genera `game_top.bin` y programa la placa. Tarda menos de un minuto.

Checkpoint: iceprog termina con `VERIFY OK`, y en la placa los LEDs parpadean con los displays en `00`.

Para generar el bitstream sin programar: `make`.

Si iceprog responde `Can't find iCE FTDI USB device` en Windows, falta el driver WinUSB: con [Zadig](https://zadig.akeo.ie/) elige "Dual RS232-HS (Interface 0)" y reemplaza el driver por WinUSB. En WSL, conecta la placa con `usbipd attach --wsl --busid <BUSID>`.

## Regenerar game.hex desde game.s

```
make hex
```

o, sin make:

```
python3 asm/pochoasm.py sw/game.s -o sw/game.hex -l sw/game.lst
```

Checkpoint: imprime `sw/game.s -> sw/game.hex: 114 palabras (456 de 2048 bytes)`.

`-l` escribe además un listado con la dirección, la palabra de 32 bits y la línea de origen de cada instrucción.

## Cambiar una constante del juego

Las constantes están al inicio de `sw/game.s`:

| Constante | Valor | Qué es |
|---|---|---|
| `ROUNDS` | 10 | respuestas correctas por partida |
| `WAIT_CYCLES` | 75000000 | fase con los 4 LEDs (3 s a 25 MHz) |
| `TENTH_CYCLES` | 2500000 | ciclos en una décima de segundo |
| `DEBOUNCE_CYCLES` | 500000 | 20 ms sin botones antes de mostrar el objetivo |
| `BLINK_CYCLES` | 6250000 | 0,25 s de cada estado del parpadeo |
| `ERROR_CODE` | 0xEE | lo que muestran los displays ante un error |

1. Edita el valor en `sw/game.s`. Por ejemplo, `.equ ROUNDS, 5`.
2. Ejecuta `make prog`. Make detecta que `game.s` cambió, regenera `game.hex` y vuelve a sintetizar.

## Pruebas

```
make test     # 20 pruebas del assembler
make sim      # prueba de instrucciones + dos partidas completas en simulación
make sim-post # la misma partida sobre el circuito ya sintetizado (unos 7 minutos)
```

Checkpoint: `make test` termina en `OK`; `make sim` imprime `ISA: OK - las 22 pruebas pasaron` y `JUEGO: OK - todas las reglas se cumplen`.

El aviso `$readmemh(...): Not enough words in the file` es normal: el programa ocupa menos que las 512 palabras de la RAM y el resto queda vacío.

## Sin make

Los mismos pasos, uno por uno, desde la carpeta del proyecto y en la terminal de OSS CAD Suite. Yosys no expande `*.v` en Windows, por eso va la lista completa:

```
python3 asm/pochoasm.py sw/game.s -o sw/game.hex
yosys -p "read_verilog rtl/game_top.v rtl/pochoco_periph.v rtl/pochoco_ram.v rtl/pochoco_soc.v rtl/pochoco_spi_slave.v rtl/espino_core/espino_alu.v rtl/espino_core/espino_controller.v rtl/espino_core/espino_core.v rtl/espino_core/espino_decoder.v rtl/espino_core/espino_id_stage.v rtl/espino_core/espino_if_stage.v rtl/espino_core/espino_load_store_unit.v rtl/espino_core/espino_register_file.v; synth_ice40 -top game_top -json game_top.json"
nextpnr-ice40 --hx1k --package vq100 --freq 25 --json game_top.json --pcf goboard.pcf --asc game_top.asc
icepack game_top.asc game_top.bin
iceprog game_top.bin
```

## El reset de encendido (defecto del SoC original)

El SoC original soltaba el reset del procesador 15 ciclos (0,6 µs) después de configurarse la FPGA. En la Go Board eso es antes de que los bloques de RAM entreguen su contenido: el procesador leía ceros, los ejecutaba como instrucciones sin efecto y, cuando la RAM respondía, estaba en la mitad del programa con los registros en cero. Los programas de ejemplo funcionaban igual porque son cortos: el contador de programa daba la vuelta a los 2 KB y volvía a empezar. El juego, de 114 palabras, no arrancaba.

En `rtl/pochoco_soc.v` el contador del reset pasó de 4 a 12 bits: el procesador arranca a los 4.095 ciclos (164 µs). Ninguna simulación detecta este problema, porque los modelos de la RAM entregan su contenido desde el primer ciclo. El diagnóstico completo está en el informe.

## Mapa de memoria

| Dirección | Acceso | Qué es |
|---|---|---|
| `0x0000_0000` | lectura y escritura | RAM unificada de 512 palabras: programa y datos |
| `0x8000_0000` | escritura | displays: bits 7:4 el izquierdo, 3:0 el derecho (hexadecimal) |
| `0x8000_0004` | escritura | LEDs, bits 3:0 |
| `0x8000_0008` | lectura | botones, bits 3:0 (1 = apretado) |
| `0x8000_000C` | lectura | contador de ciclos de 32 bits, +1 por ciclo de reloj (agregado por nosotros) |
| `0x8001_0000` | | SPI esclavo (del SoC original; el juego no lo usa) |

El reloj es de 25 MHz, así que una décima de segundo son 2.500.000 ciclos, y el contador da la vuelta cada 2^32 / 25.000.000 ≈ 171,8 s.

## El assembler

Acepta RV32I completo con los 16 registros de RV32E (`x0`–`x15` o nombres ABI), las pseudo-instrucciones `li`, `mv`, `nop`, `not`, `neg`, `j`, `jal etiqueta`, `jr`, `ret`, `call`, `beqz`, `bnez`, `bgt`, `ble`, `bgtu`, `bleu`, y la directiva `.equ`. Las directivas `.text`, `.section`, `.global` y `.globl` se aceptan y se ignoran. El detalle, con ejemplos de traducción, está en el informe y en `docs/`.

Avisa si el programa usa shifts: el Espino Core los decodifica pero los ejecuta como ADD, porque están deshabilitados en `espino_alu.v` para ahorrar celdas.

## Créditos

El SoC y el core Espino son de Nicolás Villegas (Universidad de los Andes), del repositorio
[nic0villegasc/pochoco_soc](https://github.com/nic0villegasc/pochoco_soc), bajo licencia Solderpad 0.51.
El primer commit de este repositorio es ese código sin modificar, así que `git diff` desde ahí muestra exactamente qué cambiamos.
