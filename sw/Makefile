# Ensambla los .s de esta carpeta con NUESTRO assembler (../asm/pochoasm.py):
#   make            todos
#   make blink      solo blink.s -> blink.hex
#
# El Makefile original usaba el toolchain de GNU (riscv64-unknown-elf-as). El
# enunciado pide no invocar un assembler externo, asi que se reemplazo. Los .hex
# originales de GNU quedaron guardados en asm/golden/ y las pruebas comparan
# contra ellos.

PYTHON ?= python3
SRCS  = $(wildcard *.s)
HEXS  = $(SRCS:.s=.hex)
PROGS = $(basename $(SRCS))

all: $(HEXS)

.PHONY: all $(PROGS)
$(PROGS): %: %.hex

%.hex: %.s ../asm/pochoasm.py
	$(PYTHON) ../asm/pochoasm.py $< -o $@
