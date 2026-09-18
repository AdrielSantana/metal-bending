# metal-bending

Playground do [Bend 2](https://bend-lang.com) — linguagem com sintaxe Python,
semântica Haskell/Lean, afinidade tipo Rust, provas formais e paralelismo
CPU/GPU. Rodando em Apple M5 (10 CPU / 8 GPU cores) via Metal.

## Setup

Bend **2.0.5** já está instalado em `~/.bend`, com `~/.bend/bin` no PATH
(o instalador escreveu em `~/.zshrc`). Precisa de um shell novo, ou:

```sh
export PATH="$HOME/.bend/bin:$HOME/.bun/bin:$PATH"
```

O runtime é `bun` (instalado junto, em `~/.bun`). `clang` vem do Xcode.

## Comandos

```sh
bend file.bend              # checa e roda main (backend JS)
bend file.bend -o out       # binário nativo (clang)
bend file.bend -o out.c     # emite o C
bend file.bend --checkup    # checa cada import isolado
bend PROOF.bend             # o portão de provas
bend base [--types|<nome>]  # a stdlib
bend guide                  # o guia (cópia local em docs/GUIDE.md)

./out --threads 8           # binário nativo em 8 threads
./out --gpu 4GB             # habilita a GPU (precisa do <out>.gpu ao lado)
```

## Exemplos

Todos verificados rodando:

| arquivo | assunto |
|---|---|
| `examples/01_hello.bend`     | IO monad, `do` block |
| `examples/02_types.bend`     | `type ... is Data`, `match`, `+` para reuso |
| `examples/03_recursion.bend` | recursão terminante, contadores em `Nat` |
| `examples/04_parallel.bend`  | `a b = f(x) g(y)`, chamada paralela |
| `examples/05_arrays.bend`    | mutação in-place sem abrir mão da pureza |
| `examples/06_io.bend`        | `IO.fork` / `IO.join`, canais |
| `examples/07_monads.bend`    | `do` sobre `Maybe` |

```sh
for f in examples/*.bend; do echo "== $f"; bend "$f"; done
```

## Law-driven development

O fluxo que é a razão de ser da linguagem:

- `LAWS.bend` — o **humano** escreve as leis. Cada `law` é uma afirmação aberta.
- `PROOF.bend` — a **IA** escreve as provas. Uma `def` de mesmo nome por lei.
- `src/` — o código.

```sh
bend PROOF.bend    # → "All terms check."
```

O portão reprova de verdade — verificado:

- lei deixada aberta com `?TODO` → `Error: 1 TODO found. The code is incomplete,
  and not a valid proof yet.`
- lei falsa (`Nat.add(x, 1n) == x`) → `Error: expected 1n / observed 0n`

Sem táticas: proposição é tipo, prova é `def` desse tipo. `{==}` fecha por
reflexividade, `%e : P` reescreve, e a chamada recursiva **é** a hipótese de
indução.

## Benchmark medido aqui (`pow2`, M5)

| carga | 1 thread | 10 cores | GPU (Metal) |
|---|---|---|---|
| 2^27 | 0,83 s | **0,10 s** | 0,88 s |
| 2^31 | —      | 1,66 s     | **1,22 s** |

A GPU só compensa quando a carga cresce; abaixo disso o dispatch domina.
Note o custo de CPU da run em GPU: 0,01 s de user time.

## Pegadinhas que já custaram caro

- **Afinidade**: variável é usada no máximo uma vez. Reusar exige `+x` no
  parâmetro, e o tipo tem que ser `Data`.
- **`match` / destructuring let** só aceitam parâmetro ou variável ligada por
  padrão — nunca valor computado. Passe o valor para uma `def` auxiliar.
- **Não existe `if`**: é `match` em `True{}` / `False{}`.
- **Terminação é obrigatória** e recursão mútua não existe. O parâmetro que
  encolhe vem primeiro. `U32` não tem padrão `1n+p`, então contador é `Nat`.
- **Operadores precisam de espaço dos dois lados** e de anotação de tipo:
  `(a + b : U32)`.
- `==` é só o *tipo* de igualdade; comparar valores é `T.is_eq(a, b)`.

## Telemetria e auto-update

Por padrão o launcher faz um POST em `bend-lang.com/ping` a cada execução
(`{id, ver, os, arch, cmd, exit, ms}`) e é isso que dispara o auto-update.
`BEND_NO_TELEMETRY=1` desliga o ping — **e junto o auto-update**: a versão
instalada congela. Para atualizar depois, rode o install.sh de novo.

## Docs

- `docs/GUIDE.md` — saída de `bend guide`
- `docs/BASE-TYPES.txt` — saída de `bend base --types`
- [GUIDE.md upstream](https://github.com/bendlang/bend/blob/main/guide/GUIDE.md)
- Papers: [BendTT](https://github.com/bendlang/bend/blob/main/paper/BendTT.pdf) (teoria de tipos), [BendRT](https://github.com/bendlang/bend/blob/main/paper/BendRT.pdf) (runtime)
