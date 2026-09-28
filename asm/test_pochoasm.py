"""Pruebas del assembler.   Correr con:  python3 -m unittest discover -s asm -v

Cuatro tipos de prueba:
  1. Referencia GNU: los .hex de asm/golden/ los genero el assembler oficial de
     RISC-V (vienen en el repo original). El nuestro debe dar lo mismo, bit a bit.
  2. Ida y vuelta: se codifica cada inmediato posible y se decodifica con las
     formulas de rtl/espino_core/espino_decoder.v. Tiene que volver el mismo
     numero. Asi se prueba contra el hardware real, no contra nosotros mismos.
  3. Palabras conocidas de la especificacion (nop, ret, ecall...) y pseudo-instrucciones.
  4. Validacion: cada error debe detectarse y decir en que linea esta.
"""
import os
import random
import unittest

import pochoasm as pa

HERE = os.path.dirname(os.path.abspath(__file__))


def words(src, **defines):
    return [w for _, w, _ in pa.assemble(src, defines)[0]]


def one(line):
    [w] = words(line)
    return w


def sext(x, bits):
    return x - (1 << bits) if x >> (bits - 1) & 1 else x


def bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


# Decodificadores copiados de espino_decoder.v (las lineas "assign imm_x = ...").
def imm_i(w): return sext(bits(w, 31, 20), 12)
def imm_s(w): return sext(bits(w, 31, 25) << 5 | bits(w, 11, 7), 12)
def imm_b(w): return sext(bits(w, 31, 31) << 12 | bits(w, 7, 7) << 11 | bits(w, 30, 25) << 5 | bits(w, 11, 8) << 1, 13)
def imm_j(w): return sext(bits(w, 31, 31) << 20 | bits(w, 19, 12) << 12 | bits(w, 20, 20) << 11 | bits(w, 30, 21) << 1, 21)


class GoldenGNU(unittest.TestCase):
    def test_ejemplos_del_repo(self):
        for name in ('blink', '7seg', 'buttons_leds'):
            with self.subTest(programa=name):
                with open(os.path.join(HERE, 'golden', name + '.s'), encoding='utf-8') as f:
                    got = words(f.read())
                with open(os.path.join(HERE, 'golden', name + '.hex')) as f:
                    expected = [int(line, 16) for line in f if line.strip()]
                self.assertEqual([f'{w:08x}' for w in got], [f'{w:08x}' for w in expected])


class IdaYVuelta(unittest.TestCase):
    def test_tipo_i_todos_los_inmediatos(self):
        for imm in range(-2048, 2048):
            w = pa.enc_i(imm, 5, 0, 6, 0x13)
            self.assertEqual(imm_i(w), imm)
            self.assertEqual((bits(w, 19, 15), bits(w, 11, 7)), (5, 6))

    def test_tipo_s_todos_los_inmediatos(self):
        for imm in range(-2048, 2048):
            w = pa.enc_s(imm, 7, 9, 2, 0x23)
            self.assertEqual(imm_s(w), imm)
            self.assertEqual((bits(w, 24, 20), bits(w, 19, 15)), (7, 9))

    def test_tipo_b_todos_los_saltos(self):
        for off in range(-4096, 4096, 2):
            w = pa.enc_b(off, 3, 4, 1, 0x63)
            self.assertEqual(imm_b(w), off)
            self.assertEqual((bits(w, 24, 20), bits(w, 19, 15), bits(w, 14, 12)), (3, 4, 1))

    def test_tipo_j_todos_los_saltos(self):
        for off in range(-(1 << 20), 1 << 20, 2):
            self.assertEqual(imm_j(pa.enc_j(off, 1, 0x6F)), off)

    def test_saltos_con_etiquetas_reales(self):
        # un branch hacia atras y otro hacia adelante, medidos desde el pc del branch
        src = 'a: nop\nnop\nbeq x1, x2, a\nbne x1, x2, b\nnop\nb: nop\njal x0, a'
        w = words(src)
        self.assertEqual(imm_b(w[2]), -8)
        self.assertEqual(imm_b(w[3]), 8)
        self.assertEqual(imm_j(w[6]), -24)


class PalabrasConocidas(unittest.TestCase):
    def test_especificacion(self):
        casos = {
            'nop': 0x00000013, 'ret': 0x00008067, 'ecall': 0x00000073,
            'ebreak': 0x00100073, 'fence': 0x0FF0000F,
            'add x1, x2, x3': 0x003100B3, 'sub x1, x2, x3': 0x403100B3,
            'srai x1, x2, 3': 0x40315093, 'lui x2, 0x80000': 0x80000137,
            'addi x1, x0, -1': 0xFFF00093, 'sb x5, -1(x6)': 0xFE530FA3,
            'lw ra, (sp)': 0x00012083,
        }
        for src, expected in casos.items():
            with self.subTest(src=src):
                self.assertEqual(one(src), expected)

    def test_nombres_abi_iguales_a_numeros(self):
        self.assertEqual(one('add a0, s0, t2'), one('add x10, x8, x7'))
        self.assertEqual(one('addi fp, zero, 1'), one('addi x8, x0, 1'))

    def test_pseudo_instrucciones(self):
        pares = {
            'mv a0, a1':        'addi a0, a1, 0',
            'not a0, a1':       'xori a0, a1, -1',
            'neg a0, a1':       'sub a0, zero, a1',
            'jr t0':            'jalr zero, 0(t0)',
            'x: bgt a0, a1, x':  'x: blt a1, a0, x',
            'x: ble a0, a1, x':  'x: bge a1, a0, x',
            'x: bgtu a0, a1, x': 'x: bltu a1, a0, x',
            'x: bleu a0, a1, x': 'x: bgeu a1, a0, x',
            'x: beqz a0, x':     'x: beq a0, zero, x',
            'x: bnez a0, x':     'x: bne a0, zero, x',
            'x: j x':            'x: jal zero, x',
            'x: call x':         'x: jal ra, x',
            'x: jal x':          'x: jal ra, x',
        }
        for pseudo, real in pares.items():
            with self.subTest(pseudo=pseudo):
                self.assertEqual(words(pseudo), words(real))

    def test_li_elige_la_traduccion_mas_corta(self):
        self.assertEqual(len(words('li a0, 2047')), 1)       # cabe en addi
        self.assertEqual(len(words('li a0, -2048')), 1)
        self.assertEqual(len(words('li a0, 0x80000000')), 1)  # solo lui
        self.assertEqual(len(words('li a0, 2048')), 2)       # lui + addi
        self.assertEqual(len(words('li a0, 75000000')), 2)

    def test_li_da_el_valor_correcto(self):
        # Se "ejecuta" lui + addi en Python y se compara con el valor pedido.
        # 0x800 y 0xFFF son los casos donde addi resta y lui tiene que redondear.
        valores = [0, 1, -1, 2047, 2048, -2048, -2049, 0x7FF, 0x800, 0xFFF, 0x1000,
                   0x12345800, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 75000000, 2500000]
        rng = random.Random(0)
        valores += [rng.randrange(-(1 << 31), 1 << 32) for _ in range(2000)]
        for v in valores:
            regs = 0
            for w in words(f'li a0, {v}'):
                if w & 0x7F == 0x37:       # lui
                    regs = w & 0xFFFFF000
                else:                      # addi (desde zero o desde a0)
                    base = regs if bits(w, 19, 15) == 10 else 0
                    regs = (base + imm_i(w)) & 0xFFFFFFFF
            self.assertEqual(regs, v & 0xFFFFFFFF, f'li a0, {v}')

    def test_equ_y_numeros(self):
        src = '.equ LEDS, 0x4\n.equ N, 0b101\n.equ M, -N\nsw t0, LEDS(s0)\naddi t0, t0, N\naddi t1, t1, M'
        w = words(src)
        self.assertEqual(w[0], one('sw t0, 4(s0)'))
        self.assertEqual(w[1], one('addi t0, t0, 5'))
        self.assertEqual(w[2], one('addi t1, t1, -5'))

    def test_D_reemplaza_una_equ(self):
        src = '.equ WAIT, 75000000\nli a0, WAIT'
        self.assertEqual(words(src, WAIT=100), words('li a0, 100'))

    def test_aviso_de_shifts(self):
        _, avisos = pa.assemble('nop\nslli a0, a0, 1')
        self.assertEqual([n for n, _ in avisos], [2])

    def test_etiquetas_y_comentarios(self):
        src = '# comentario\ninicio:  # otro\n  otra: addi a0, a0, 1 # fin\n j inicio'
        self.assertEqual(words(src), words('x: addi a0, a0, 1\nj x'))


class Validacion(unittest.TestCase):
    def assertError(self, src, linea, texto):
        with self.assertRaises(pa.AsmErrors) as ctx:
            pa.assemble(src)
        encontrados = [(n, str(err)) for n, err in ctx.exception.errors]
        self.assertTrue(any(n == linea and texto in err for n, err in encontrados), encontrados)

    def test_errores(self):
        self.assertError('nop\nbeq a0, a1, nada', 2, 'etiqueta no definida')
        self.assertError('x: nop\nx: nop', 2, 'dos veces')
        self.assertError('add x16, x1, x2', 1, 'RV32E')
        self.assertError('mv a6, a0', 1, 'RV32E')
        self.assertError('add q1, x1, x2', 1, 'registro desconocido')
        self.assertError('addi a0, a0, 2048', 1, 'fuera de rango')
        self.assertError('lw a0, -2049(s0)', 1, 'fuera de rango')
        self.assertError('slli a0, a0, 32', 1, 'fuera de rango')
        self.assertError('lui a0, 0x100000', 1, 'fuera de rango')
        self.assertError('li a0, 0x100000000', 1, 'fuera de rango')
        self.assertError('mul a0, a0, a1', 1, 'instruccion desconocida')
        self.assertError('add a0, a1', 1, 'operandos')
        self.assertError('addi a0,, 1', 1, 'operando vacio')
        self.assertError('lw a0, s0', 1, 'desplazamiento(registro)')
        self.assertError('.word 5', 1, 'directiva no soportada')
        self.assertError('.equ A, 1\n.equ A, 2', 2, 'dos veces')
        self.assertError('li a0, NADA', 1, 'constante no definida')
        self.assertError('.equ t0, 1', 1, 'reservado')
        self.assertError('addi a0, a0, 12x', 1, 'valor invalido')

    def test_branch_demasiado_lejos(self):
        src = 'x: nop\n' + 'nop\n' * 1030 + 'beq a0, a1, x'
        self.assertError(src, 1032, 'fuera de rango')

    def test_programa_mas_grande_que_la_ram(self):
        with self.assertRaises(pa.AsmErrors) as ctx:
            pa.assemble('nop\n' * (pa.RAM_WORDS + 1))
        self.assertIn('RAM', str(ctx.exception.errors[0][1]))

    def test_reporta_todos_los_errores_juntos(self):
        with self.assertRaises(pa.AsmErrors) as ctx:
            pa.assemble('add x16, x1, x2\nnop\nbeq a0, a1, nada')
        self.assertEqual([n for n, _ in ctx.exception.errors], [1, 3])


class ElJuego(unittest.TestCase):
    def test_game_s_ensambla_sin_avisos_y_cabe(self):
        with open(os.path.join(HERE, '..', 'sw', 'game.s'), encoding='utf-8') as f:
            w, avisos = pa.assemble(f.read())
        self.assertEqual(avisos, [])
        self.assertLessEqual(len(w), pa.RAM_WORDS)


if __name__ == '__main__':
    unittest.main()
