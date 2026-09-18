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

## Gráficos: renderizando no Metal

Renderizar **já funciona**, sem lib de terceiro. `gfx/` tem três programas:

| arquivo | o quê |
|---|---|
| `gfx/00_window.bend`     | quatro quadrantes coloridos — o "hello world" da janela |
| `gfx/01_mandelbrot.bend` | Mandelbrot 512×512 estático |
| `gfx/02_zoom.bend`       | zoom animado, re-renderizado por frame |

```sh
bend gfx/01_mandelbrot.bend -o build/mandel
./build/mandel --gpu 2GB      # precisa do build/mandel.gpu ao lado
```

Dois detalhes bonitos:

**O rasterizador do Bend já é um kernel Metal.** Em `effs/window_frame.c` há um
`kernel void window_dev` em MSL que percorre a quadtree por pixel na GPU. Então
a janela renderiza no Metal mesmo sem você escrever `!`.

**A restrição da linguagem cai bem na GPU.** Bend proíbe recursão mútua, logo
não existe early return: o laço de escape queima as 200 iterações em *todo*
pixel, até nos que escapam no passo 2. Na CPU é desperdício puro. Na GPU é o
caso ideal — toda lane roda o mesmo número de passos, divergência zero.

### Benchmark

Cronometrado **por dentro do processo** com `IO.now()`, 10 execuções, checksum
verificado idêntico nos três backends. 512×512 pixels × 200 iterações:

| | ms/frame | ganho |
|---|---|---|
| 1 thread | 428 | — |
| 10 cores | 47 | 9,1x |
| **GPU (Metal)** | **20** | **21x** (2,4x sobre os 10 cores) |

Bate com o medido na janela: 58 fps ≈ 17 ms/frame.

### Limite: precisão, e por quê

O zoom animado bate no teto do `F32` depois de ~7 s e a imagem vira bloco. Base
tem só `U32` e `F32` — não existe `F64`.

Isso **não é feature faltando, é restrição de hardware**. O modelo do Bend é que
o mesmo C vira programa de CPU e kernel de GPU, então um tipo que a GPU não
suporta quebraria qualquer chamada com `!`. E a GPU da Apple não suporta: as
GPUs Apple são FP32/FP16.

Verificado aqui, compilando MSL em tempo de execução num M5
(`makeLibrary(source:)`):

| tipo em MSL | resultado |
|---|---|
| `float` (32) | aceito |
| `half` (16) | aceito |
| `long` (int 64) | **aceito** |
| `double` (64) | **`error: 'double' is not supported in Metal`** |

Repare que inteiro de 64 bits passa — o veto é específico a ponto flutuante de
64 bits. Um `U64` seria viável no Metal hoje; um `F64` não.

Para zoom profundo o caminho usual em GPU é aritmética *double-float*: representar
um double como par de floats e fazer as operações à mão. Cabe em `F32`, roda no
Metal, e é o que renderizadores de fractal em GPU usam.

### Como medir errado (três vezes seguidas)

Vale registrar, porque cada um desses produziu um número convincente e falso:

1. **`ps -o %cpu`** no macOS dá a média desde o início do processo, não o
   instantâneo. Deu ~7% pros três backends, escondendo tudo.
2. **`time ./binario`** inclui o startup. Um binário Bend sobe em ~30 ms, mas
   **com `--gpu` são ~150 ms** de inicialização do Metal — que afogam uma
   computação de 20 ms e fazem a GPU parecer 3x mais lenta que a CPU. Foi esse
   que me fez concluir, erradamente, que a GPU não ganhava aqui.
3. **Contar frames sem conferir a ordem de grandeza.** 92 fps em 1 thread seriam
   4,7 bilhões de iterações/s num core — impossível, e era o sinal de que a
   medição estava quebrada, não o hardware sendo incrível.

O jeito certo: `IO.now()` em volta só da computação, repetida N vezes, com a
entrada variando a cada volta pra nada ser compartilhado.

## Raycaster de voxel

`gfx/03_voxel.bend` — terreno de voxels renderizado na GPU, câmera orbitando.

```sh
bend gfx/03_voxel.bend -o build/voxel
./build/voxel --gpu 2GB
```

Sem triângulo, sem z-buffer, sem malha. Cada pixel é um raio, o raio atravessa
a grade com **DDA** (Amanatides & Woo), e a face por onde ele entra no voxel é o
eixo cujo limite veio primeiro — normal exata, sem adivinhar por coordenada
fracionária.

**O mundo é uma função pura da posição.** Isso não é preguiça, é obrigatório:
`Array` no Bend é `Type`, tem dono único, e **não pode ser lido pelos dois lados
de uma chamada paralela** (testado: `consumed more than once`). Um mundo
procedural contorna isso e fica perfeitamente paralelo. Um mundo com chunks
precisaria de árvore `+Data` imutável — compartilhável, mas com busca O(log n)
em vez de O(1).

Sem early return também significa que o DDA sempre queima os 110 passos, mesmo
tendo achado o bloco no passo 3.

### Desempenho

512×512 raios, cronometrado por dentro com `IO.now()`:

| | ms/frame | ganho |
|---|---|---|
| 1 thread | 432 | — |
| 10 cores | 85 | 5,1x |
| **GPU (Metal)** | **28** | **15x** |

Na janela os três dão 58 fps — teto do vsync, não do renderer.

### Achado: `!` não é neutro numericamente

Os checksums do mesmo frame divergem conforme o binário foi compilado com `!`
ou sem:

| binário | GPU | 10 cores | 1 thread |
|---|---|---|---|
| com `total!(...)` | 4171263204 | 4171263204 | 4171263204 |
| com `total(...)` | 4169746902 | 4169746902 | 4169746902 |

Cada um é determinístico; eles diferem **entre si**. Não é imprecisão de GPU —
o binário com `!` dá o mesmo resultado rodando em 1 thread de CPU. É o `!` em
si, que o guia descreve só como onde a chamada roda.

O delta é `1516302`, que decompõe em `rgb(23,35,14)` = a cor da grama × 0,20 —
exatamente o vão entre o sombreamento da face-x (0,68) e da face-z (0,48). Ou
seja: **um único pixel** escolhe face diferente, num raio que bate na aresta
onde `tMaxX ≈ tMaxZ` e o desempate tomba pro outro lado.

Impacto prático nulo (as capturas da janela são idênticas pixel a pixel, com o
comparador validado por um controle de 22,6%). Mas numa linguagem que vende
correção demonstrável, `f!(x) ≠ f(x)` merece registro. Não consegui reduzir a
um caso mínimo — aritmética F32 simples com e sem `!` dá igual.

## Publicado no BendHub

O conjunto provado está no [BendHub](https://hub.bend-lang.com), importável por
content hash:

```python
import 0x983079cc7642e53dbc9aaf7fa2636b20/PROOF.bend as PROOF
```

Isso traz `PROOF.bend`, `LAWS.bend` e `src/math.bend` juntos (3 arquivos,
1666 bytes). A primeira execução baixa pra `~/.bend/lib` e confere contra o
hash; as seguintes leem de lá, offline.

Sobre o hub: **sem conta e sem versão**. No lugar do cadastro, o comando minera
um proof-of-work — aqui deu 23 s de relógio e 137 s de CPU em 6 cores. Pacote é
imutável e endereçado pelo conteúdo: qualquer alteração vira outro hash, e não
existe despublicar. Arquivo com `?TODO` ou lei em aberto é recusado na entrada.

```sh
bend PROOF.bend --publish
```

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

Esses dois são output literal do compilador, não obra original deste repo —
Bend é Apache-2.0, © Bend authors. Ver `docs/ATTRIBUTION.md`.

- [GUIDE.md upstream](https://github.com/bendlang/bend/blob/main/guide/GUIDE.md)
- Papers: [BendTT](https://github.com/bendlang/bend/blob/main/paper/BendTT.pdf) (teoria de tipos), [BendRT](https://github.com/bendlang/bend/blob/main/paper/BendRT.pdf) (runtime)
