# metal-bending

Playground do [Bend 2](https://bend-lang.com) — linguagem com sintaxe Python,
semântica Haskell/Lean, afinidade tipo Rust, provas formais e paralelismo
CPU/GPU. Rodando em Apple M5 (10 CPU / 8 GPU cores) via Metal.

## Setup

Bend **2.0.9** já está instalado em `~/.bend`, com `~/.bend/bin` no PATH
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

Na tomada, LPM desligado, sem throttling, aquecimento descartado, 5 execuções,
mediana. 512×512 pixels × 200 iterações, checksum idêntico nos três backends:

| | ms/frame | ganho |
|---|---|---|
| sem `!`, 1 thread | 213 | — |
| sem `!`, 10 threads | 31 | 6,9x |
| **com `!`** | **8** | **26x** (3,9x sobre os 10 núcleos) |

Aqui os três checksums batem (`99630108`), ao contrário do raycaster — o que
reforça o achado do `!` não-neutro: a divergência vem do desempate do DDA, não
de qualquer conta em F32.

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

| | ms/frame |
|---|---|
| sem `!`, 1 thread | 222 (222–223) |
| sem `!`, 10 threads | 43 (42–46) |
| com `!` | 48 (47–65) |

Na janela os três dão 58 fps — teto do vsync, não do renderer.

Sim: no 03 a GPU **perde** dos 10 núcleos. Ele já forka por pixel, então não é
granularidade — falta o clip do raio contra a caixa do mundo, que o 04 tem.
Precisa dos dois. (A tabela anterior aqui dizia 432 / 85 / 28 com "15x"; aquilo
comparava um binário sem `!` contra um com `!` rodado com `--gpu`, e eu atribuía
a diferença toda ao dispositivo.)

### Achado: `!` não é neutro numericamente

Os checksums do mesmo frame divergem conforme o binário foi compilado com `!`
ou sem:

| binário | GPU | 10 cores | 1 thread |
|---|---|---|---|
| com `total!(...)` | 4171263204 | 4171263204 | 4171263204 |
| com `total(...)` | 4169746902 | 4169746902 | 4169746902 |

Cada um é determinístico; eles diferem **entre si**. Eu li isso como "não é
imprecisão de GPU, porque o binário com `!` dá o mesmo resultado em 1 thread".
Errado: um binário com `!` carrega o `.gpu` e roda no dispositivo independente
das flags, então as três colunas da primeira linha são GPU. É uma diferença
numérica GPU/CPU comum — que ainda vale notar, porque o guia descreve o `!` só
como *onde* a chamada roda, não como *o que* ela devolve.

O delta é `1516302`, que decompõe em `rgb(23,35,14)` = a cor da grama × 0,20 —
exatamente o vão entre o sombreamento da face-x (0,68) e da face-z (0,48). Ou
seja: **um único pixel** escolhe face diferente, num raio que bate na aresta
onde `tMaxX ≈ tMaxZ` e o desempate tomba pro outro lado.

Impacto prático nulo (as capturas da janela são idênticas pixel a pixel, com o
comparador validado por um controle de 22,6%). Mas numa linguagem que vende
correção demonstrável, `f!(x) ≠ f(x)` merece registro. Não consegui reduzir a
um caso mínimo — aritmética F32 simples com e sem `!` dá igual.

## Raycaster de voxel, versão rápida

`gfx/04_voxel_fast.bend` — mesma cena da 03, ~2,2x mais rápida, depois de ler
a `bend3d.bend` (em `demos/app_slash_boss_3d`) por indicação do Victor Taelin,
que observou que IAs escrevem Bend 3D lento por pensar em OpenGL.

Os comentários dele no próprio código são a aula:

> `Cell.fork`: *"a fork per pixel drowns in scheduling, a fork per cell leaves
> lanes idle"*
> `Tile.b16`: *"straight-line: a recursion costs a frame per square on the device"*
> `Frame.show`: *"one bang, since a launch costs a fixed fee"*

A 03 forkava nos 9 níveis da quadtree — 262 mil forks, um por pixel. A 04 forka
até tiles de 8×8 e resolve os 64 pixels do tile em linha reta.

### O que realmente comprou o ganho

> **Corrigido em 18/09/2026.** Esta seção dizia antes que a granularidade do
> fork não rendia nada e que a GPU empatava com a CPU no raycaster. As duas
> coisas estavam erradas, pela mesma causa: eu tratava rodar *sem* `--gpu` como
> baseline de CPU. Não é — veja abaixo.

**`--gpu` não liga a GPU; ele dimensiona a memória dela.** Um binário que contém
`!` carrega a biblioteca Metal `.gpu` e roda no dispositivo com ou sem a flag.
Dá pra verificar escondendo o arquivo `.gpu`: o binário reclama e recompila nos
dois casos. O baseline real de CPU é **tirar o `!`**.

Com o baseline certo, e com o benchmark imprimindo um checksum da soma de todos
os pixels — para provar que as variantes renderizam a mesma imagem — a
granularidade do fork é a variável que manda. 512², 40 frames por execução,
mediana de 5:

| profundidade do fork | folha | com `!` | sem `!`, 10 threads |
|---|---|---|---|
| 6 níveis | tile 8×8 | 16 (16–20) | 21 (20–22) |
| 7 níveis | tile 4×4 | **9 (9–12)** | — |
| 8 níveis | tile 2×2 | 14 (11–15) | — |

Checksum `3150485626` em todas as linhas. Na CPU a mesma varredura é plana
(19 / 19 / 20 / 21 ms): granularidade **não importa na CPU e vale 2,3x na GPU**.

No Bendcraft, que lê uma árvore compartilhada, o efeito é bem maior. 128²,
checksum `747218888` nas três linhas:

| profundidade do fork | folha | com `!` |
|---|---|---|
| 4 níveis | tile 8×8 — *o que estava aqui* | 234 (232–236) |
| 5 níveis | tile 4×4 | 87 (87) |
| 6 níveis | tile 2×2 | **28 (28–34)** |

Sem `!`, 10 threads: 178 ms. Ou seja: a versão publicada estava **mais lenta na
GPU do que na CPU**, e 8,4x mais lenta que o mesmo programa forkando dois níveis
mais fundo. Os dois demos agora estão no ótimo medido, e o ótimo **não é
universal** — o raycaster quer folha 4×4, o Bendcraft quer 2×2.

O clip do raio contra a caixa do mundo continua valendo o que valia: 45 → 24 ms.

Isso não contradiz o conselho do Taelin, refina: a `bend3d` binariza triângulos
por tile, então o tile é unidade de *trabalho compartilhado*. Num raycaster cada
pixel é independente, não há nada a compartilhar, e agrupar por tile só tira
paralelismo da GPU. O comentário do `Cell.fork` — *"um fork por pixel se afoga
em escalonamento, um fork por célula deixa lanes ociosas"* — está certo; eu
parei na metade errada dele.

### Aquecimento da GPU: cuidado ao medir

O mesmo mandelbrot dá **6 ms** medido como média de 10 execuções dentro de um
processo, e **50 ms** medido uma vez só por processo. A GPU tem aquecimento
significativo por processo (além dos ~150 ms de inicialização do Metal).

Para um loop de render o número quente é o certo. Para um cálculo de uma vez,
o frio. Medir uma vez e chamar de "custo por frame" infla o resultado ~8x — e
foi como eu concluí, errado, que a GPU perdia do mandelbrot.

### Duas otimizações que eu tentei e removi

- **Tile plano** (se os 4 cantos do tile não entram na caixa, o tile inteiro é
  céu): não acelerou **e comia 0,47% dos pixels**. A `bend3d` pode cortar por
  tile com segurança porque o binning sabe exatamente quais tiles cada forma
  toca. Quatro raios de amostra não sabem.
- **Colapso de bloco 2×2** num único `Pix`: correto, mas sem ganho medido aqui.
  Mantido, é barato.

### Como eu errei medindo (de novo)

Duas ablações minhas deram conclusão invertida porque o **controle** estava
quebrado, não o código sob teste:

1. Testei "sem clip" mantendo o fuel baixo (96) que só é suficiente *por causa*
   do clip. O controle truncava os raios: imagem errada, e artificialmente
   rápido. Conclusão errada: "o clip não serve pra nada".
2. Depois comparei clip vs sem-clip com fuel alto e vi 6,2% de pixels
   diferentes — e supus que o clip é que estava bugado. Era o contrário: sem o
   clip as paredes de pedra desciam infinitamente pra fora do quadro. Só vi
   isso **olhando as duas imagens**, não olhando os números.

Regra que ficou: antes de confiar num controle, confirme que ele produz a
imagem certa. Um controle mais rápido costuma estar fazendo menos trabalho
porque está errado.

## Bendcraft: mundo editável

`gfx/05_craft.bend` — primeira pessoa, voo livre, quebrar e colocar bloco.

```sh
bend gfx/05_craft.bend -o build/craft
./build/craft --gpu 2GB
```

`W A S D` move · setas olham · `I`/`K` sobe e desce · `J` quebra · `L` coloca · `Esc` sai

### O mundo é uma função mais uma árvore de edições

`Array` em Bend é `Type`: dono único, então **não pode ser lido pelos dois
lados de uma chamada paralela** — inútil num renderizador onde todo pixel lê o
mundo ao mesmo tempo. A primeira versão guardava as 32×32 colunas numa
quadtree `Data` compartilhada, e ler essa árvore era 85% do frame.

A versão atual guarda **só as edições**. O terreno é uma função pura de
`(x, z)`; a árvore começa como um único `WNone` e cada edição do jogador cria
um caminho de cinco nós. Um raio que encontra `WNone` calcula a coluna na hora.
Cada folha é **um U32 cujo bit `y` diz "tem bloco na altura y"**.

32 alturas em uma palavra é o que torna isso viável: uma coluna é uma palavra
de máquina, e quebrar/colocar é um bit.

Verificado sem GUI (`feed` e `step` são puros, dá pra simular eventos):

```
blocos, nada apertado : 102282128
blocos, J (quebrar)   : 102281872   (-256 = exatamente um bit da altura 8)
blocos, L (colocar)   : 102282384   (+256)
```

### O custo, particionado — e resolvido

A árvore compartilhada era o gargalo. 512², checksum idêntico em todas as
linhas, Bend 2.0.9, mediana de 5:

| o mundo | ms/frame |
|---|---|
| coluna procedural (teto: sem árvore nenhuma) | 23 |
| todas as colunas na árvore, leitura recursiva da raiz | 189 |
| + `Bool.pick` no lugar do `sel4` | 183 |
| + nó da região cacheado no raio **e** walk desenrolado | 155 |
| **só as edições na árvore, terreno procedural** | **26** |

Quatro coisas que não ajudaram, todas com checksum idêntico, registradas para
ninguém repetir: empacotar 2×2 colunas por folha (1.00x), tirar a base da
câmera do laço por pixel (1.00x), cachear o nó da região sozinho (1.00x),
desenrolar o walk sozinho (1.00x). As duas últimas só funcionam **juntas**
(1.2x) — dois gargalos em série, remove um e o outro domina.

O que resolveu foi a regra do Taelin: uma árvore com refcount compartilhada por
todos os pixels custa um atômico por uso, então toque nela o mínimo possível.
Com o overlay, quase todo raio toca um nó (`WNone`) e calcula o resto.

Na resolução do demo, 128²: **234 → 6 ms** ao longo da sessão. A edição segue
bit-exata: checksum do mundo vazio `102282128` (idêntico ao da árvore antiga),
quebrar/colocar dá exatamente ±2^y nos três caminhos do `wmod` novo, e o leitor
recursivo do picking concorda com o desenrolado do render.

### Duas armadilhas O(n) no Base

Ambas me custaram caro, e a causa raiz é a mesma:

- `U32.shln(a, n)` é **O(n)** — um `U32.shl` recursivo por unidade de `n`.
  Deslocar por 20 são 20 chamadas. Solução aqui: o DDA carrega a máscara
  `1<<y` e desloca **um** bit por passo, nunca por valor variável.
- `U32.from_nat(n)` é **O(valor)** — `U32.inc` recursivo n vezes.

As versões O(1) existem: `F32.to_u32`, `U32.to_f32`, `F32.sin`, `F32.sqrt`.
Mas são declaradas como **`law`** (primitivas do compilador), não `def` — então
`bend base | grep '^def F32'` **não as mostra**. Eu caí nessa duas vezes na
mesma sessão: primeiro achei que não havia trigonometria, depois que não havia
conversão direta F32↔U32.

### Aviso sobre as medições

Os primeiros benchmarks desta sessão foram feitos na bateria e em Low Power
Mode, e estavam inflados: rodando o mesmo binário em momentos diferentes vi
variação de até **1,7x**. Todos os números do README foram refeitos na tomada,
com LPM desligado, aquecimento descartado e 5 execuções. A lição fica: efeitos
grandes (6x, 38x) sobrevivem ao ruído, efeitos pequenos não — e eu publiquei
uma atribuição de ~4% que era zero antes de perceber.

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

> **Mudou na 2.0.8/2.0.9.** O que está descrito abaixo valia até a 2.0.7.

**Como é hoje.** O `bend --help` lista `bend update` — "install the latest bend
(curl | sh, shown first)" —, ou seja, atualizar virou ação explícita. O
instalador afirma que o binário pergunta a versão mais nova para o
`bend-lang.com` **uma vez por dia**, mandando só versão, SO e tipo de CPU, e que
`BEND_NO_TELEMETRY=1` desliga isso. Essa parte é declaração do instalador, não
medição minha; o `bend update` eu confirmei no `--help`.

**Como era até a 2.0.7.** O launcher fazia POST em `bend-lang.com/ping` a cada
execução (`{id, ver, os, arch, cmd, exit, ms}`) e era isso que disparava o
auto-update. `BEND_NO_TELEMETRY=1` desligava o ping **e junto o auto-update**,
congelando a versão.

Vi a transição acontecer: a instalação aqui ficou presa na 2.0.7 imprimindo
"Bend's installer changed" enquanto a 2.0.9 já estava publicada.

## Docs

- `docs/GUIDE.md` — saída de `bend guide`
- `docs/BASE-TYPES.txt` — saída de `bend base --types`

Esses dois são output literal do compilador, não obra original deste repo —
Bend é Apache-2.0, © Bend authors. Ver `docs/ATTRIBUTION.md`.

- [GUIDE.md upstream](https://github.com/bendlang/bend/blob/main/guide/GUIDE.md)
- Papers: [BendTT](https://github.com/bendlang/bend/blob/main/paper/BendTT.pdf) (teoria de tipos), [BendRT](https://github.com/bendlang/bend/blob/main/paper/BendRT.pdf) (runtime)
