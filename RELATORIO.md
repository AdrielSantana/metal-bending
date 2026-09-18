# Bend 2.0.5 no Apple M5 — seis achados

*(English version: [REPORT.md](REPORT.md))*

Anotações de dois dias construindo três renderizadores em Bend: um Mandelbrot,
um raycaster de voxel, e um mundo de voxel interativo com quebrar/colocar
bloco. Tudo aqui é reproduzível a partir de
<https://github.com/AdrielSantana/metal-bending>.

Obrigado pela indicação do `demos/app_slash_boss_3d/bend3d.bend` — ler aquilo
é o que gerou os achados 5 e 6.

**Método.** Bend 2.0.5, macOS 26.6.2, Apple M5 (10 núcleos de CPU / 8 de GPU).
Na tomada, Low Power Mode desligado, nenhum aviso térmico registrado. Toda
medição é `IO.now()` em volta da computação *dentro* do processo, primeira
execução descartada como warm-up, 5 execuções, reportando mediana com o range
min–max. Os números que eu tinha antes foram medidos na bateria e estavam
inflados em até 1,7x; esses não estão aqui.

---

## 1. `f!(x)` e `f(x)` não computam a mesma coisa

O mesmo frame 512², com checksum feito pela soma das cores dos pixels:

| binário | GPU | 10 núcleos | 1 thread |
|---|---|---|---|
| compilado com `total!(...)` | 4171263204 | 4171263204 | 4171263204 |
| compilado com `total(...)` | 4169746902 | 4169746902 | 4169746902 |

Cada binário é determinístico nos três backends. Eles diferem **entre si**.
Então não é imprecisão de GPU: o binário com `!` dá a mesma resposta rodando
numa única thread de CPU.

O delta, 1516302, decompõe exato. Como cor é `rgb(23, 35, 14)`, e a cor da
grama naquela cena é `rgb(117, 176, 73)`: 117·0,20 = 23,4, 176·0,20 = 35,2,
73·0,20 = 14,6. Os fatores de sombreamento no código são 1,0 pra face de cima,
0,68 pra face x e 0,48 pra face z — e 0,68 − 0,48 = 0,20.

Ou seja, exatamente **um pixel** escolhe a face x em vez da face z. O raio
desse pixel bate numa aresta de voxel onde `tMaxX ≈ tMaxZ`, e o desempate do
`<` tomba pro outro lado.

O guia descreve o `!` só como *onde* a chamada roda, então eu não esperava que
mudasse resultado.

**Repro:** `gfx/03_voxel.bend`, com e sem o `!` no `view()`.
**Não reduzi:** aritmética F32 simples com e sem `!` dá igual, então parece
amarrado ao desempate da comparação, não a uma operação isolada.

---

## 2. Ler uma árvore `Data` compartilhada custa ~374 ns, e isso trava mundo voxel

`Array` é `Type`, então tem dono único e não pode ser lido pelos dois lados de
uma chamada paralela — inviável num renderizador onde todo pixel lê o mundo.
Então a demo interativa guarda o mundo como uma quadtree `Data` sobre 32×32
colunas, cada folha um `U32` cujo bit *y* significa "tem bloco na altura y",
compartilhada com `+`. Editar reconstrói um caminho de cinco nós; o resto
continua compartilhado. Quebrar e colocar estão verificados bit a bit.

Custo, isolado por camada, a 512²:

| | ms/frame |
|---|---|
| zero leituras de árvore (coluna procedural) | 17 (16–17) |
| **uma** leitura por raio | 115 (111–116) |
| relendo conforme o DDA cruza colunas | ~5950 |

98 ms para 262144 leituras dá **374 ns por leitura** — cinco níveis de ponteiro
mais tráfego de refcount numa árvore compartilhada.

A consequência é que mesmo uma leitura por pixel custa 98 ms a 512², então a
demo roda a 128² (~360 ms/frame): responde ao teclado, mas não é fluida. Pelo
que eu consegui ver, é isso que está entre o Bend e um mundo de voxel com
chunks, e é uma questão de runtime, não algo que eu conserte no programa.

**Repro:** `gfx/05_craft.bend`; a partição são três variantes do `refetch`.

---

## 3. Duas funções O(n) no Base, e as versões O(1) são invisíveis ao `grep`

- `U32.shln(a, n)` é **O(n)** — um `U32.shl` recursivo por unidade de `n`.
  Deslocar por 20 são 20 chamadas.
- `U32.from_nat(n)` é **O(valor)** — `U32.inc` recursivo, n vezes.

As versões O(1) existem: `F32.to_u32`, `U32.to_f32`, `F32.sin`, `F32.cos`,
`F32.sqrt`, `F32.exp`, `F32.log`, `F32.atan`. Mas são declaradas como **`law`**
(primitivas do compilador), não `def` — então

```
bend base | grep '^def F32'
```

não lista nenhuma delas, enquanto `U32.from_nat` e `F32.to_nat` estão ali como
`def`, com nome óbvio.

Eu caí nisso duas vezes na mesma sessão. Primeiro concluí que o Base não tinha
trigonometria e comecei a escrever uma série de Taylor na mão. Depois concluí
que não havia conversão direta F32↔U32 e usei o caminho via `Nat`, que é
O(valor), dentro de um laço interno.

**Ressalva honesta:** quando depois troquei os caminhos via `Nat` pelas
primitivas, **não mediu ganho nenhum** (dentro do ruído, nos dois programas).
Então isso aqui é reclamação de descoberta, não de performance — o código
O(valor) pode muito bem estar sendo otimizado. O que me custou foi tempo e uma
hipótese errada, não milissegundos.

Esse aqui me parece o mais relevante dado o teu comentário sobre IAs
escreverem Bend lento: no meu caso não foi mentalidade de OpenGL, foi que o
caminho rápido é invisível à busca óbvia e o caminho lento tem o nome óbvio.
Uma linha na doc, ou listar as primitivas declaradas como `law` no
`bend base`, teria evitado os dois erros.

---

## 4. O `!` rende 5x numa carga e nada na outra; cinco explicações eliminadas

Mandelbrot, 512² × 200 iterações, em regime quente:

| | ms/frame |
|---|---|
| 1 thread | 213 (213–214) |
| 10 núcleos | 31 (30–33) |
| **GPU** | **6 (6–7)** |

Raycaster de voxel, 512²: 10 núcleos 23 ms, GPU 24 ms. Empate, e levemente
negativo.

Tentei achar a diferença e não consegui. Testadas e refutadas:

| hipótese | teste | resultado |
|---|---|---|
| montar a `Image` serializa | somar as cores em vez de montar a árvore | 17 GPU / 17 CPU |
| divergência entre raios | tirar o clip, todo raio faz 96 passos idênticos | 48 GPU / 45 CPU |
| pressão de registradores | Mandelbrot com 14 F32 vivos em vez de 6 | 7 GPU / 33 CPU — mantém os 5x |
| `F32.sin`/`cos` no laço | terreno plano, zero trigonometria | 8 GPU / 8 CPU |
| carga pequena demais por dispatch | escalar pra 1024² e 2048² | 15/13 e 29/25 |

A trigonometria acabou custando metade do frame (18 → 8 ms ao remover), mas
custa igual nos dois backends.

Então: um caso reproduzível em que o `!` não paga, com cinco causas eliminadas.
Suspeito que você veja de imediato o que eu não vi.

**Repro:** `gfx/04_voxel_fast.bend`; as ablações são variantes pequenas dele.

---

## 5. Forkar por tile não fez diferença mensurável num raycaster

Do `bend3d.bend`:

> `Cell.fork`: *"a fork per pixel drowns in scheduling, a fork per cell leaves
> lanes idle"*

Minha primeira versão forkava nos 9 níveis da quadtree — um fork por pixel,
exatamente o que aquele comentário alerta. Reescrevi pra forkar até tiles de
8×8 e resolver os 64 pixels do tile em linha reta. Ablação isolada, mesmo
código, mudando só a profundidade do fork:

| | GPU | CPU |
|---|---|---|
| fork por pixel (9 níveis) | 25 (24–26) | 23 (23–26) |
| fork por tile 8×8 (6 níveis) | 24 (23–24) | 24 (23–25) |

Com esses ranges isso não é ruído, é zero.

Leio isso como específico da carga, não como correção. A `bend3d` binariza
triângulos por tile, então o tile é uma unidade de *trabalho compartilhado* —
os 256 pixels dele leem a mesma lista de triângulos. Num raycaster cada pixel é
independente e não há nada a compartilhar, então o escalonamento nunca domina.
Mantive o fork por tile porque é o idioma da lib, não porque mediu mais rápido.

O que de fato deixou o raycaster 1,9x mais rápido foi fazer o clip de cada raio
contra a caixa envolvente do mundo — 45 → 24 ms — porque aí um raio que olha
pro céu percorre zero voxels em vez de 96.

---

## 6. O warm-up da GPU distorce medição de uma execução em ~8x

A mesma computação do Mandelbrot:

- **6 ms** medido como média de 10 execuções dentro de um processo
- **50 ms** medido uma vez por processo

Separadamente, subir o processo custa ~30 ms num binário só de CPU e **~150 ms
com `--gpu`** (inicialização do Metal).

Os dois números estão certos pro caso deles — quente pra loop de render, frio
pra trabalho de uma vez. Mas medir uma execução e chamar de "custo por frame"
infla o resultado em ~8x, e `time ./binario` num build com `--gpu` soma outros
150 ms por cima. Foi assim que eu concluí, errado, que a GPU perdia da CPU no
Mandelbrot.

Talvez valha uma linha no guia junto da flag `--gpu`.

---

## Notas menores

- **Metal não tem FP64.** Confirmado no device compilando MSL em runtime:
  `float`, `half` e `long` são aceitos, `double` dá
  `error: 'double' is not supported in Metal`. Ou seja, o veto é específico a
  ponto flutuante de 64 bits, não à largura de 64 bits — um `U64` seria viável
  hoje. Pra zoom profundo de fractal, o contorno usual em GPU é aritmética
  double-float (um double como par de floats), que cabe em `F32`.
- **O rasterizador da janela já é um kernel Metal.** O `effs/window_frame.c`
  percorre a quadtree da `Image` por pixel em MSL, então uma janela renderiza
  na GPU mesmo sem `!`. Foi uma surpresa boa e acho que valeria estar explícito
  no guia.
- **O `bend PROOF.bend` reprova o que deve.** Um `?TODO` em aberto dá
  *"1 TODO found"*, e uma lei falsa dá *"expected 1n / observed 0n"*. O portão
  funciona.

---

## Onde eu errei no caminho

Incluo porque os erros dizem algo sobre o tooling:

- Publiquei uma atribuição de 4% pro achado 5 antes de perceber que estava
  dentro do ruído de rodar na bateria. É zero.
- Removi o clip raio/caixa por causa de uma medição ruim — meu controle "sem
  clip" manteve um valor de fuel que só é suficiente *por causa* do clip, então
  o controle estava truncando os raios silenciosamente, o que o fazia parecer
  rápido. Depois culpei o clip pela diferença na imagem. O errado era o
  controle.
- Comparei dois renders com um differ de imagem e deu "0 pixels diferentes".
  Os dois PNGs tinham o mesmo MD5, o que também é o que se obtém capturando a
  mesma janela duas vezes. Só passei a confiar na comparação depois de validar
  o differ contra um controle que corretamente reportou 22,6%.

A lição geral, que foi a que me custou mais tempo: um controle que roda mais
rápido normalmente está fazendo menos trabalho porque está quebrado.
