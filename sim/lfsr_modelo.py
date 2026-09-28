"""Modelo del generador aleatorio de game.s: por que el LFSR avanza 32 pasos por ronda.

Correr con:  python3 sim/lfsr_modelo.py

La semilla es el valor del contador de ciclos cuando el jugador aprieta el boton
de inicio. Ese valor es aleatorio en sus bits medios (depende de cuando aprieta una
persona), pero NO en todos:
  - bits altos: en los primeros 43 s tras encender, el bit 30 del contador aun es 0;
  - bits bajos: el programa lee los botones cada P ciclos fijos, asi que la semilla
    solo puede tomar valores base + k*P.
Se simulan 20.000 partidas con semillas de esa forma y se mira que tan parejo sale
el LED objetivo, avanzando el LFSR 2 o 32 pasos antes de cada eleccion.
"""
import random
from collections import Counter

TAPS = 0x00400007          # x^32 + x^22 + x^2 + x + 1, igual que LFSR_TAPS en game.s
MASK = 0xFFFFFFFF


def pick(state, steps):
    """Lo mismo que pick_target en game.s: avanza el LFSR y devuelve (estado, LED 0..3)."""
    for _ in range(steps):
        state = ((state << 1) & MASK) ^ (TAPS if state >> 31 else 0)
    return state, state & 3


def main():
    rng = random.Random(1)
    print('pasos  P   1er LED (% de partidas)        pares de LEDs seguidos   secuencias distintas')
    for steps in (2, 32):
        for period in (1, 8, 16):
            first, pairs, sequences = Counter(), Counter(), set()
            for _ in range(20000):
                # apreton entre 0,5 s y 5 s despues de encender, leido cada `period` ciclos
                k = rng.randrange(12_500_000 // period, 125_000_000 // period)
                state = (1000 + period * k) | 1
                seq = []
                for _ in range(10):
                    state, led = pick(state, steps)
                    seq.append(led)
                first[seq[0]] += 1
                pairs[seq[0], seq[1]] += 1
                sequences.add(tuple(seq))
            pct = ' '.join(f'{first[i] / 200:5.1f}' for i in range(4))
            lo, hi = min(pairs.values()) * 16 / 200, max(pairs.values()) * 16 / 200
            print(f'{steps:5d} {period:3d}   {pct}   {len(pairs):2d}/16, {lo:4.0f}% a {hi:4.0f}% del ideal'
                  f'   {len(sequences)}/20000')


if __name__ == '__main__':
    main()
