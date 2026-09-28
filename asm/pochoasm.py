"""pochoasm: assembler RV32E para el Espino Core (Pochoco SoC).

Traduce un archivo de assembly (.s) a una imagen de memoria (.hex): una
palabra de 32 bits en hexadecimal por linea, que es el formato que lee
$readmemh en rtl/pochoco_ram.v. La palabra de la linea k queda en la
direccion 4*k, asi que el programa arranca en 0x0 (BootAddr del core).

Uso:
    python asm/pochoasm.py sw/game.s -o sw/game.hex [-l game.lst] [-D NOMBRE=VALOR]

Trabaja en tres pasadas sobre el texto:
  0. Constantes: evalua las .equ, en orden.
  1. Direcciones: le da una direccion a cada instruccion y a cada etiqueta.
     Las pseudo-instrucciones se expanden aqui, porque cambian cuantas
     palabras ocupa el programa.
  2. Codificacion: con todas las etiquetas ya conocidas, traduce cada
     instruccion real a sus 32 bits.
"""
import argparse
import re
import sys

# El programa entero tiene que caber en la RAM del SoC (NumWords en rtl/pochoco_soc.v).
RAM_WORDS = 512

# --- Registros --------------------------------------------------------------
# RV32E tiene 16 registros, x0..x15. Cada uno se puede escribir por numero o por
# su nombre ABI.
ABI_NAMES = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2',
             's0', 's1', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5']
REGS = {name: i for i, name in enumerate(ABI_NAMES)}
REGS.update({f'x{i}': i for i in range(16)})
REGS['fp'] = 8
# Registros que existen en RV32I pero no en RV32E: dan un error explicativo.
RV32I_ONLY = re.compile(r'^(x(1[6-9]|2\d|3[01])|a[67]|s([2-9]|1[01])|t[3-6])$')

# --- Instrucciones reales ---------------------------------------------------
# mnemonico: (formato, opcode, funct3, funct7)
# El formato decide que operandos se leen y como se ordenan los bits.
#   R   rd, rs1, rs2          I   rd, rs1, imm         SH  rd, rs1, shamt
#   L   rd, imm(rs1)          S   rs2, imm(rs1)        B   rs1, rs2, etiqueta
#   U   rd, imm20             J   rd, etiqueta         FIX sin operandos
OPS = {
    'add':  ('R', 0x33, 0, 0x00), 'sub':  ('R', 0x33, 0, 0x20),
    'sll':  ('R', 0x33, 1, 0x00), 'slt':  ('R', 0x33, 2, 0x00),
    'sltu': ('R', 0x33, 3, 0x00), 'xor':  ('R', 0x33, 4, 0x00),
    'srl':  ('R', 0x33, 5, 0x00), 'sra':  ('R', 0x33, 5, 0x20),
    'or':   ('R', 0x33, 6, 0x00), 'and':  ('R', 0x33, 7, 0x00),

    'addi': ('I', 0x13, 0, 0), 'slti': ('I', 0x13, 2, 0), 'sltiu': ('I', 0x13, 3, 0),
    'xori': ('I', 0x13, 4, 0), 'ori':  ('I', 0x13, 6, 0), 'andi':  ('I', 0x13, 7, 0),

    'slli': ('SH', 0x13, 1, 0x00), 'srli': ('SH', 0x13, 5, 0x00), 'srai': ('SH', 0x13, 5, 0x20),

    'lb':  ('L', 0x03, 0, 0), 'lh':  ('L', 0x03, 1, 0), 'lw': ('L', 0x03, 2, 0),
    'lbu': ('L', 0x03, 4, 0), 'lhu': ('L', 0x03, 5, 0),
    'jalr': ('L', 0x67, 0, 0),

    'sb': ('S', 0x23, 0, 0), 'sh': ('S', 0x23, 1, 0), 'sw': ('S', 0x23, 2, 0),

    'beq':  ('B', 0x63, 0, 0), 'bne':  ('B', 0x63, 1, 0),
    'blt':  ('B', 0x63, 4, 0), 'bge':  ('B', 0x63, 5, 0),
    'bltu': ('B', 0x63, 6, 0), 'bgeu': ('B', 0x63, 7, 0),

    'lui': ('U', 0x37, 0, 0), 'auipc': ('U', 0x17, 0, 0),
    'jal': ('J', 0x6F, 0, 0),

    # Palabras fijas (el decoder del Espino las acepta y no hacen nada).
    'ecall': ('FIX', 0x00000073, 0, 0), 'ebreak': ('FIX', 0x00100073, 0, 0),
    'fence': ('FIX', 0x0FF0000F, 0, 0),
}
N_OPERANDS = {'R': 3, 'I': 3, 'SH': 3, 'L': 2, 'S': 2, 'B': 3, 'U': 2, 'J': 2, 'FIX': 0}

# Los shifts se codifican bien, pero espino_alu.v los tiene comentados y el
# core los ejecuta como ADD. El assembler avisa para que nadie se confunda.
SHIFTS = {'sll', 'srl', 'sra', 'slli', 'srli', 'srai'}

# --- Pseudo-instrucciones ---------------------------------------------------
# No existen en el hardware: se reescriben como una instruccion real.
# nombre: (cantidad de operandos, reescritura)
PSEUDO = {
    'nop':  (0, lambda: ('addi', 'zero', 'zero', '0')),
    'mv':   (2, lambda rd, rs: ('addi', rd, rs, '0')),
    'not':  (2, lambda rd, rs: ('xori', rd, rs, '-1')),
    'neg':  (2, lambda rd, rs: ('sub', rd, 'zero', rs)),
    'j':    (1, lambda dst: ('jal', 'zero', dst)),
    'call': (1, lambda dst: ('jal', 'ra', dst)),
    'jr':   (1, lambda rs: ('jalr', 'zero', f'0({rs})')),
    'ret':  (0, lambda: ('jalr', 'zero', '0(ra)')),
    'beqz': (2, lambda rs, dst: ('beq', rs, 'zero', dst)),
    'bnez': (2, lambda rs, dst: ('bne', rs, 'zero', dst)),
    'bgt':  (3, lambda a, b, dst: ('blt', b, a, dst)),
    'ble':  (3, lambda a, b, dst: ('bge', b, a, dst)),
    'bgtu': (3, lambda a, b, dst: ('bltu', b, a, dst)),
    'bleu': (3, lambda a, b, dst: ('bgeu', b, a, dst)),
}

# Directivas del ensamblador de GNU que aparecen en los ejemplos del repo y
# que aqui no hacen falta: hay un solo programa, en una sola memoria, desde 0x0.
IGNORED_DIRECTIVES = {'.text', '.section', '.global', '.globl'}

IDENT = re.compile(r'^[A-Za-z_.][\w.]*$')
LABEL = re.compile(r'^([A-Za-z_.][\w.]*)\s*:(.*)$')
MEM_OPERAND = re.compile(r'^(.*)\(\s*(\w+)\s*\)$')


class AsmError(Exception):
    """Un error en una linea del programa."""


class AsmErrors(Exception):
    """Todos los errores del archivo juntos, ordenados por linea."""
    def __init__(self, errors):
        super().__init__(f'{len(errors)} error(es)')
        self.errors = sorted(errors, key=lambda e: e[0])


# --- Lectura de operandos ---------------------------------------------------

def reg(tok):
    name = tok.strip().lower()
    if name in REGS:
        return REGS[name]
    if RV32I_ONLY.match(name):
        raise AsmError(f"'{tok}' no existe en RV32E: solo hay 16 registros (x0-x15)")
    raise AsmError(f"registro desconocido: '{tok}'")


def value(tok, symbols):
    """Numero (decimal, 0x hex, 0b binario, con signo) o constante .equ."""
    tok = tok.strip()
    try:
        return int(tok, 0)
    except ValueError:
        pass
    neg = tok.startswith('-')
    name = tok[1:] if neg else tok
    if name in symbols:
        return -symbols[name] if neg else symbols[name]
    if IDENT.match(name):
        raise AsmError(f"constante no definida: '{name}' (las .equ se definen antes de usarse)")
    raise AsmError(f"valor invalido: '{tok}'")


def mem_operand(tok, symbols):
    """'imm(rs1)' -> (imm, rs1). 'imm' puede omitirse: '(s0)' es 0(s0)."""
    m = MEM_OPERAND.match(tok.strip())
    if not m:
        raise AsmError(f"se esperaba desplazamiento(registro), por ejemplo 4(s0): '{tok}'")
    imm = value(m[1], symbols) if m[1].strip() else 0
    return imm, reg(m[2])


def check_range(x, lo, hi, what):
    if not lo <= x <= hi:
        raise AsmError(f"{what} fuera de rango: {x} (permitido {lo} a {hi})")


# --- Codificacion: un formato = una forma de repartir los bits --------------

def enc_r(f7, rs2, rs1, f3, rd, op):
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op

def enc_i(imm, rs1, f3, rd, op):
    return (imm & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op

def enc_s(imm, rs2, rs1, f3, op):
    return ((imm >> 5) & 0x7F) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 0x1F) << 7 | op

def enc_b(off, rs2, rs1, f3, op):
    # imm[12|10:5] en 31:25, imm[4:1|11] en 11:7 (el bit 0 no se guarda: siempre es 0)
    return (((off >> 12) & 1) << 31 | ((off >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15
            | f3 << 12 | ((off >> 1) & 0xF) << 8 | ((off >> 11) & 1) << 7 | op)

def enc_u(imm20, rd, op):
    return (imm20 & 0xFFFFF) << 12 | rd << 7 | op

def enc_j(off, rd, op):
    # imm[20|10:1|11|19:12] en 31:12
    return (((off >> 20) & 1) << 31 | ((off >> 1) & 0x3FF) << 21 | ((off >> 11) & 1) << 20
            | ((off >> 12) & 0xFF) << 12 | rd << 7 | op)


def encode(mnem, ops, pc, labels, symbols):
    fmt, op, f3, f7 = OPS[mnem]
    if len(ops) != N_OPERANDS[fmt]:
        raise AsmError(f"'{mnem}' lleva {N_OPERANDS[fmt]} operandos y tiene {len(ops)}")

    if fmt == 'R':
        return enc_r(f7, reg(ops[2]), reg(ops[1]), f3, reg(ops[0]), op)
    if fmt == 'I':
        imm = value(ops[2], symbols)
        check_range(imm, -2048, 2047, 'inmediato de 12 bits')
        return enc_i(imm, reg(ops[1]), f3, reg(ops[0]), op)
    if fmt == 'SH':
        shamt = value(ops[2], symbols)
        check_range(shamt, 0, 31, 'shamt')
        return enc_i(f7 << 5 | shamt, reg(ops[1]), f3, reg(ops[0]), op)
    if fmt == 'L':
        imm, rs1 = mem_operand(ops[1], symbols)
        check_range(imm, -2048, 2047, 'desplazamiento de 12 bits')
        return enc_i(imm, rs1, f3, reg(ops[0]), op)
    if fmt == 'S':
        imm, rs1 = mem_operand(ops[1], symbols)
        check_range(imm, -2048, 2047, 'desplazamiento de 12 bits')
        return enc_s(imm, reg(ops[0]), rs1, f3, op)
    if fmt == 'U':
        imm = value(ops[1], symbols)
        check_range(imm, 0, 0xFFFFF, 'inmediato de 20 bits')
        return enc_u(imm, reg(ops[0]), op)
    if fmt == 'B':
        off = target(ops[2], pc, labels)
        check_range(off, -4096, 4094, 'salto de branch')
        return enc_b(off, reg(ops[1]), reg(ops[0]), f3, op)
    if fmt == 'J':
        off = target(ops[1], pc, labels)
        check_range(off, -(1 << 20), (1 << 20) - 2, 'salto de jal')
        return enc_j(off, reg(ops[0]), op)
    return op  # FIX


def target(tok, pc, labels):
    """Los saltos son relativos: se guarda (direccion de la etiqueta - pc)."""
    name = tok.strip()
    if name not in labels:
        raise AsmError(f"etiqueta no definida: '{name}'")
    return labels[name] - pc


# --- Expansion: de una linea de texto a instrucciones reales ----------------

def expand_li(ops, symbols):
    """li rd, valor -> addi, lui, o lui+addi, segun lo que necesite el valor."""
    if len(ops) != 2:
        raise AsmError(f"'li' lleva 2 operandos y tiene {len(ops)}")
    rd, v = ops[0], value(ops[1], symbols)
    check_range(v, -(1 << 31), (1 << 32) - 1, 'valor de li (32 bits)')
    v &= 0xFFFFFFFF
    signed = v - (1 << 32) if v >> 31 else v
    if -2048 <= signed <= 2047:
        return [('addi', rd, 'zero', str(signed))]
    # addi suma un inmediato CON signo: si el bit 11 de los 12 bits bajos es 1,
    # addi va a restar, y por eso la parte alta se redondea hacia arriba.
    lo = (v & 0xFFF) - ((v & 0x800) << 1)
    hi = ((v - lo) >> 12) & 0xFFFFF
    if lo == 0:
        return [('lui', rd, str(hi))]
    return [('lui', rd, str(hi)), ('addi', rd, rd, str(lo))]


def expand(mnem, ops, symbols):
    """Devuelve la lista de instrucciones reales (mnemonico, *operandos)."""
    if mnem == 'li':
        return expand_li(ops, symbols)
    if mnem == 'jal' and len(ops) == 1:   # 'jal etiqueta' guarda el retorno en ra
        return [('jal', 'ra', ops[0])]
    if mnem in PSEUDO:
        n, rewrite = PSEUDO[mnem]
        if len(ops) != n:
            raise AsmError(f"'{mnem}' lleva {n} operandos y tiene {len(ops)}")
        return [rewrite(*ops)]
    if mnem in OPS:
        return [(mnem, *ops)]
    raise AsmError(f"instruccion desconocida: '{mnem}'")


def split_line(text):
    """'loop: addi t0, t0, 1  # comentario' -> (['loop'], 'addi', ['t0', 't0', '1'])"""
    code = text.split('#', 1)[0].strip()
    labels = []
    while (m := LABEL.match(code)):
        labels.append(m[1])
        code = m[2].strip()
    if not code:
        return labels, None, []
    parts = code.split(None, 1)
    ops = [o.strip() for o in parts[1].split(',')] if len(parts) > 1 else []
    if '' in ops:
        raise AsmError('operando vacio (sobra o falta una coma)')
    return labels, parts[0].lower(), ops


# --- Las tres pasadas -------------------------------------------------------

def assemble(source, defines=None):
    """Devuelve (lista de (pc, palabra, n_linea), avisos). Lanza AsmErrors si hay errores."""
    errors, warnings = [], []
    symbols = dict(defines or {})   # -D tiene prioridad sobre las .equ del archivo
    fixed = set(symbols)

    # Pasada 0: separar cada linea y evaluar las .equ
    lines = []
    for n, text in enumerate(source.splitlines(), 1):
        try:
            labels, mnem, ops = split_line(text)
            if mnem == '.equ':
                if len(ops) != 2 or not IDENT.match(ops[0]):
                    raise AsmError('se esperaba: .equ NOMBRE, valor')
                name = ops[0]
                if name.lower() in REGS or name.lower() in OPS or name.lower() in PSEUDO:
                    raise AsmError(f"'{name}' es un nombre reservado")
                if name in fixed:
                    pass  # definida con -D: se ignora el valor del archivo
                elif name in symbols:
                    raise AsmError(f"constante definida dos veces: '{name}'")
                else:
                    symbols[name] = value(ops[1], symbols)
                mnem = None
            elif mnem and mnem.startswith('.') and mnem not in IGNORED_DIRECTIVES:
                raise AsmError(f"directiva no soportada: '{mnem}'")
            lines.append((n, labels, mnem, ops))
        except AsmError as e:
            errors.append((n, e))

    # Pasada 1: direcciones de etiquetas e instrucciones
    labels_at, program, pc = {}, [], 0
    for n, labels, mnem, ops in lines:
        try:
            for lab in labels:
                if lab in labels_at:
                    raise AsmError(f"etiqueta definida dos veces: '{lab}'")
                if lab in symbols:
                    raise AsmError(f"'{lab}' ya es una constante .equ")
                labels_at[lab] = pc
            if mnem is None or mnem in IGNORED_DIRECTIVES:
                continue
            for real in expand(mnem, ops, symbols):
                program.append((pc, n, real))
                pc += 4
        except AsmError as e:
            errors.append((n, e))

    if pc > 4 * RAM_WORDS:
        errors.append((0, AsmError(f'el programa ocupa {pc // 4} palabras y la RAM tiene {RAM_WORDS}')))

    # Pasada 2: codificar
    words = []
    for pc, n, (mnem, *ops) in program:
        try:
            words.append((pc, encode(mnem, ops, pc, labels_at, symbols), n))
            if mnem in SHIFTS:
                warnings.append((n, f"'{mnem}' se ejecuta como ADD en el Espino Core (shifts deshabilitados en espino_alu.v)"))
        except AsmError as e:
            errors.append((n, e))

    if errors:
        raise AsmErrors(errors)
    return words, warnings


# --- Linea de comandos ------------------------------------------------------

def parse_define(text):
    name, sep, val = text.partition('=')
    if not sep or not IDENT.match(name):
        raise argparse.ArgumentTypeError(f"se esperaba NOMBRE=VALOR: '{text}'")
    return name, int(val, 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Assembler RV32E para el Espino Core (Pochoco SoC)')
    ap.add_argument('source', help='archivo de assembly, por ejemplo sw/game.s')
    ap.add_argument('-o', '--output', help='archivo .hex de salida (por defecto: mismo nombre que source)')
    ap.add_argument('-l', '--listing', help='escribe tambien un listado: direccion, palabra y linea de origen')
    ap.add_argument('-D', dest='defines', action='append', type=parse_define, default=[],
                    metavar='NOMBRE=VALOR', help='reemplaza una constante .equ (se usa para simular con tiempos cortos)')
    args = ap.parse_args(argv)

    with open(args.source, encoding='utf-8') as f:
        source = f.read()
    src_lines = source.splitlines()

    try:
        words, warnings = assemble(source, dict(args.defines))
    except AsmErrors as e:
        for n, err in e.errors:
            where = f'{args.source}:{n}' if n else args.source
            print(f'{where}: error: {err}', file=sys.stderr)
            if n:
                print(f'    {src_lines[n - 1].strip()}', file=sys.stderr)
        print(f'{len(e.errors)} error(es); no se escribio ningun archivo.', file=sys.stderr)
        return 1

    for n, msg in warnings:
        print(f'{args.source}:{n}: aviso: {msg}', file=sys.stderr)

    output = args.output or re.sub(r'\.s$', '', args.source) + '.hex'
    with open(output, 'w', newline='\n') as f:
        f.writelines(f'{w:08x}\n' for _, w, _ in words)

    if args.listing:
        with open(args.listing, 'w', encoding='utf-8', newline='\n') as f:
            last = None
            for pc, w, n in words:
                src = src_lines[n - 1].strip() if n != last else ''
                f.write(f'{pc:08x}  {w:08x}  {src}\n')
                last = n

    print(f'{args.source} -> {output}: {len(words)} palabras ({4 * len(words)} de {4 * RAM_WORDS} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
