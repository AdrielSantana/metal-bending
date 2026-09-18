# Bend 2.0.6 no Apple M5 — seis achados

*(English version: [REPORT.md](REPORT.md))*

> **Correção, 18/09/2026.** Os achados 2, 4 e 5 foram reescritos e o achado 1
> mantém a medição mas perde a explicação. A causa raiz foi minha: eu li o
> `--gpu` como a chave que liga o dispositivo, então a maioria dos meus A/Bs
> "GPU vs CPU" tinha GPU nos dois lados. Com o baseline correto — tirar o `!` —
> a variável que faltava é a granularidade do fork, que é invisível na CPU e
> vale até 8x na GPU. É isso que o achado 4 chamava de mistério inexplicado, e
> que também tinha inflado o achado 2 em até 25x. Reconferido na 2.0.6, agora
> com um controle de checksum provando que cada variante renderiza a mesma
> imagem. Achados 3 e 6 reproduziram iguais.

Anotações de dois dias construindo três renderizadores em Bend: um Mandelbrot,
um raycaster de voxel, e um mundo de voxel interativo com quebrar/colocar
bloco. Tudo aqui é reproduzível a partir de
<https://github.com/AdrielSantana/metal-bending>.

Obrigado pela indicação do `demos/app_slash_boss_3d/bend3d.bend` — ler aquilo
é o que gerou os achados 5 e 6.

**Método.** Bend 2.0.6, macOS 26.6.2, Apple M5 (10 núcleos de CPU / 8 de GPU).
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

Cada binário é determinístico nas três colunas. Eles diferem **entre si**.

Eu li isso originalmente como prova de que não é imprecisão de GPU, já que o
binário com `!` dá a mesma resposta com `--threads 1`. A inferência estava
errada: um binário que contém `!` carrega sua biblioteca Metal `.gpu` e roda no
dispositivo independente das flags (veja Notas menores), então as três colunas
da primeira linha são execuções na GPU. Uma diferença numérica GPU/CPU comum
explica tudo. Ainda vale reportar, porque o guia apresenta o `!` como escolha de
*onde* a chamada roda, não de *o que* ela devolve.

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

## 2. Ler uma árvore `Data` compartilhada é o custo dominante num mundo voxel (REVISADO)

`Array` é `Type`, então tem um dono só e não pode ser lido pelos dois lados de
uma chamada paralela — inutilizável para um renderizador onde todo pixel lê o
mundo. Por isso o demo interativo guarda o mundo como uma quadtree `Data` sobre
colunas 32×32, cada folha um `U32` cujo bit *y* significa "bloco na altura y",
compartilhada com `+`. Editar reconstrói um caminho de cinco nós; o resto
continua compartilhado. Quebrar e colocar são verificados bit a bit.

Custo por camada em 512², tudo na granularidade de fork do achado 4, 10 frames
por execução, mediana de 3:

| o que o DDA faz ao cruzar de coluna | ms/frame |
|---|---|
| nada — uma leitura no início do raio, depois reaproveita | 19 (18–19) |
| recalcula a coluna proceduralmente | 24 (22–34) |
| **lê da árvore compartilhada** | **176 (176–179)** |
| lê da árvore a *cada* passo do DDA, não só nas trocas | 241 (226–253) |

As linhas 2 e 3 são o isolamento que importa: estrutura idêntica, mesmo número
de consultas de coluna, só muda o mecanismo. Passar pela árvore compartilhada
custa **152 ms**, 7,3x o frame inteiro.

Então o achado qualitativo se mantém, e mais limpo que antes: leitura de árvore
`Data` compartilhada domina todo o resto neste programa.

**O que eu retiro da versão anterior deste achado.** Eu reportei 374 ns por
leitura, uma camada de 5950 ms para releitura, e a conclusão de que isso "trava
mundo voxel" e deixava o demo em 128² a ~360 ms/frame, sem fluidez. Os quatro
foram medidos na granularidade de fork faminta do achado 4:

- a camada de 5950 ms é 241 ms, 25x menor;
- o número de 374 ns vinha de um salto de 17 → 115 ms para "uma leitura por
  raio", e essa camada agora custa 19 ms no total; não consigo reproduzir a
  derivação e não vou substituí-la por outro número por leitura — eu nunca
  contei as trocas de coluna por raio, então não teria como derivar um
  honestamente;
- o Bendcraft em 128² roda a **28 ms/frame**, uns 36 fps, não 360 ms. Está
  fluido.

Leitura de árvore continua sendo o alvo a atacar, mas não é o que separa o Bend
de um mundo voxel jogável.

**Repro:** `gfx/05_craft.bend`; as camadas são três variantes de uma linha do
`refetch`.

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

## 4. O `!` paga nas duas cargas — o "empate" era granularidade de fork (CORRIGIDO)

**Isto substitui o achado 4 que eu mandei antes.** Aquela versão reportava um
mistério: 5x num Mandelbrot, nada num raycaster, cinco explicações eliminadas. O
mistério era a minha própria medição. As cinco ablações foram todas rodadas na
única granularidade de fork que deixa a GPU faminta, e a resposta estava no meu
próprio achado 5 — que eu li como "sem efeito" porque só testei onde ele não tem
efeito nenhum.

Toda linha abaixo está verificada como renderizando a mesma imagem: o harness
soma a cor de todos os pixels e o checksum é idêntico ao longo de cada tabela.
Era exatamente esse controle que estava faltando antes.

Raycaster, 512², no caminho real do `gfx/04` que monta a quadtree, 40 frames por
execução, mediana de 5:

| profundidade do fork | folha | com `!` | sem `!`, 10 threads |
|---|---|---|---|
| 6 níveis | tile 8×8 — *o que eu publiquei* | 16 (16–20) | 21 (20–22) |
| 7 níveis | tile 4×4 | **9 (9–12)** | — |
| 8 níveis | tile 2×2 | 14 (11–15) | — |

A mesma varredura numa variante que soma cores em vez de montar a `Image`, para
poder varrer os dois backends barato:

| profundidade do fork | com `!` | sem `!`, 10 threads |
|---|---|---|
| 6 níveis (8×8) | 14 (14–15) | 19 (19) |
| 7 níveis (4×4) | **6 (6–8)** | 19 (19–20) |
| 8 níveis (2×2) | 8 (8) | 20 (19–20) |
| 9 níveis (pixel) | 7 (7–8) | 21 (20–21) |

A coluna da CPU é plana — ali granularidade é irrelevante, que é o que o meu
achado 5 dizia. A coluna do `!` varia 2,3x. Então o `!` vale 21 → 9 ms nesse
raycaster, e se ele parece um ganho ou um empate é decidido inteiramente pela
profundidade do fork.

Bendcraft, 128², que lê uma árvore `World` compartilhada a cada passo do DDA, 20
frames por execução, mediana de 3:

| profundidade do fork | folha | com `!` |
|---|---|---|
| 4 níveis | tile 8×8 — *o que eu publiquei* | 234 (232–236) |
| 5 níveis | tile 4×4 | 87 (87) |
| 6 níveis | tile 2×2 | **28 (28–34)** |

Sem `!`, 10 threads: 178 (178). Ou seja, a versão que eu publiquei estava **mais
lenta na GPU do que na CPU**, e 8,4x mais lenta que o mesmo programa forkando
dois níveis mais fundo. É o número mais útil deste documento.

O ótimo não é universal — o raycaster quer folha 4×4, o Bendcraft quer 2×2 —
então tem que ser varrido por programa.

**Onde granularidade não basta.** O `gfx/03`, a versão sem o clip do raio contra
a caixa, já forka por pixel e mesmo assim não ganha: 48 (47–65) com `!` contra
43 (42–46) em 10 threads sem ele. Ou seja, clip e granularidade são ambos
necessários — a minha ablação anterior de "tirar o clip", que mediu 48/45, foi
uma das poucas que usou baseline correto, e estava me dizendo algo real. A
afirmação aqui é só que granularidade era a variável que faltava no `gfx/04` e
no `gfx/05`, não que ela explica todos os casos.


A tabela do Mandelbrot do relatório anterior continua válida: 214 (1 thread) /
31 (10 threads) / 7 com `!`. Ele já forkava até o pixel individual, e é por isso
que mostrou o ganho inteiro de imediato e fez o raycaster parecer quebrado na
comparação.

**Repro:** `gfx/04_voxel_fast.bend` e `gfx/05_craft.bend` agora estão no ótimo
medido. Mude a profundidade do `fork!` e a função de folha juntas — profundidade
*k* com folha *n*×*n* tem que satisfazer n·2^k = resolução — e confira que o
checksum não se move.

---

## 5. Granularidade de fork é grátis na CPU e decisiva na GPU

Do `bend3d.bend`:

> `Cell.fork`: *"um fork por pixel se afoga em escalonamento, um fork por célula
> deixa lanes ociosas"*

O comentário está certo e eu apliquei errado. Forkei até tiles 8×8 porque é o
idioma da biblioteca, não medi diferença, e concluí que granularidade não
importava para um raycaster. O que eu tinha mostrado de fato é que não importa
*na CPU*, onde a varredura dá 19 / 19 / 20 / 21 ms e é genuinamente plana.

Na GPU a mesma varredura dá 14 / 6 / 8 / 7 ms. Então o achado não é
"granularidade é irrelevante num raycaster", é "granularidade é invisível na CPU
e vale até 8x na GPU" — o que é bem mais útil de colocar na frente de quem chega
com cabeça de OpenGL. O instinto de agrupar trabalho por tile é exatamente o
errado aqui, e rodar na CPU não vai te avisar.

A minha tabela anterior para esse achado reportava 24 vs 25 ms para tile vs
por-pixel na GPU. Não confio mais nela: ela nunca verificou que as duas
variantes renderizavam os mesmos pixels, e a varredura de hoje, que verifica
isso por checksum, a contradiz.

O que ajudou de forma independente, e continua ajudando: clipar cada raio contra
a bounding box do mundo antes, 45 → 24 ms.

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

- **`--gpu` não liga a GPU; ele dimensiona a memória dela.** Um binário que
  contém `!` carrega a biblioteca Metal `.gpu` e roda no dispositivo com ou sem
  a flag — verifiquei escondendo o arquivo `.gpu`, o que faz o binário
  recompilá-lo nos *dois* casos. O guia diz
  `./file --gpu 4GB  # enables the GPU, with max 4GB memory`, e eu levei o
  "enables" ao pé da letra, então passei um bom tempo tratando execução sem a
  flag como baseline de CPU. Qualquer A/B montado assim é GPU contra GPU e vai
  dar empate. O baseline real de CPU é tirar o `!`. Um texto como "define o
  tamanho do heap da GPU" teria me economizado quase um dia.

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
- Passei um dia inteiro fazendo um A/B "GPU vs CPU" em que os dois lados
  rodavam na GPU, porque li o `--gpu` como a chave que liga o dispositivo. Todo
  empate da primeira versão do achado 4 veio daí.
- Publiquei dois demos numa granularidade de fork que deixava a GPU mais lenta
  que a CPU, e aí escrevi um relatório chamando aquilo de mistério no
  compilador. A variável que eu precisava era uma que eu já tinha medido e
  descartado — no achado seguinte.
- Escrevi "isso nos custou 60x aqui" num comentário de código sobre as
  conversões O(valor), publiquei, e só depois medi que trocá-las não muda nada.

A lição geral, que me custou mais tempo: um controle que roda mais rápido
geralmente está fazendo menos trabalho porque está quebrado. A segunda lição,
mais nova: faça o programa imprimir um checksum do que ele renderizou, e compare
as variantes por ele antes de comparar por tempo. Toda conclusão errada da
primeira versão deste documento teria sido pega por essa única linha.
