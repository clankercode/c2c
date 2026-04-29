# Alias word pool: easy-pool subset research

**Author**: birch-coder
**Date**: 2026-04-29
**Type**: research + TaskCreate proposal
**Status**: READY

---

## Context

At sitrep, the alias pool surfaced as a usability concern: generated aliases like `jori-kuura` (Finnish root + Finnish root) are hard to type, hard to remember, and don't communicate identity well for human operators. The existing pool mixes Finnish roots (ilma, tuuli, lehto) with English naturals (meadow, fjord, starling), producing composites that are partially legible to English speakers but partly opaque.

The proposal: identify an **easy-pool** subset (~30 words) of clearly English-readable words. `generate_alias` could optionally draw from this subset for operators who prefer legible names.

---

## Pool Analysis

**Total words**: 131 (128 declared + 3 extras in the data file = 131)
**Source**: `ocaml/c2c_alias_words.ml`

### Categorization

| Category | Count | Examples |
|---|---|---|
| Finnish/nature roots | ~87 | tuuli, ilma, lehto, havu, nallo, kuura |
| English naturals | ~30 | meadow, fjord, harbor, hearth, starling |
| Other/mixed | ~14 | quill, sage, drift, clover, ember |

### Easy-pool candidate words (English-readable, easy to spell, easy to recall)

```
alder      birch family — tree
briar      thorny shrub
cedar      conifer
clover     plant
drift      snow/sand movement
ember      glowing coal
fennel     herb
fjord      narrow sea inlet
glade      clearing
harbor     safe port
hearth     fireplace
heron      wading bird
kelo       Finnish: old (legible cognate)
kesa       Finnish: summer (legible)
kuura      Finnish: frost (operators already use it)
lumi       Finnish: snow (widely used)
meadow     grassland
moro       Finnish: daylight (short, legible)
nova       new star / widely known
oak        deciduous tree
pebble     small stone
pilvi      Finnish: cloud
puro       Finnish: stream
quill      feather pen
rain       precipitation
reed       wetland plant
river      flowing water
rook       bird
rowan      mountain ash
sage       herb / wise person
sprig      small branch
starling   bird
suvi       Finnish: summer
taika      Finnish: magic
tuuli      Finnish: wind
tyyni      Finnish: calm
valo       Finnish: light
vireo      small songbird
vuono      Finnish: fjord-like inlet
willow     tree
yarrow     herb
yola       short, memorable
```

**Count: 42 words** — slightly larger than the 30 target but a reasonable first pool.

### Words to exclude (too Finnish, too obscure, too easy to misspell)

```
aalto      (Finnish wave — obscure)
aimu       (Finnish — obscure)
aivi       (Finnish — obscure)
alm        (Swedish to English — ambiguous with "alm tree")
anvi       (Finnish — obscure)
arvu       (Finnish — obscure)
aska       (Finnish — obscure)
aster      (looks like English "aster" but is Finnish)
auru       (Finnish — obscure)
elmi       (Finnish — obscure)
eira       (Finnish — obscure)
ferni      (looks like "fern" but is Finnish variant)
havu       (Finnish — obscure)
ilma       (Finnish — obscure)
ilmi       (Finnish — obscure)
isvi       (Finnish — obscure)
jara       (Finnish — obscure)
jori       (Finnish — obscure)
junna      (Finnish — obscure)
kaari      (Finnish arc — partially legible but obscure)
kajo       (Finnish — obscure)
kalla      (Finnish — obscure)
karu       (Finnish — obscure)
keiju      (Finnish — obscure)
kielo      (Finnish lily — obscure)
kiru       (Finnish — obscure)
kiva       (Finnish — widely known "kiva" in Estonian/Finnish)
kivi       (Finnish stone — partially known)
koru       (Finnish — obscure)
laine      (Finnish wave — obscure)
laku       (Finnish — obscure)
lehto      (Finnish grove — obscure)
leimu      (Finnish — obscure)
lemu       (Finnish — obscure)
linna      (Finnish: castle — obscure)
lintu      (Finnish bird — partially known)
lumo       (Finnish — obscure)
marli      (obscure)
meru       (Sanskrit — obscure)
miru       (Finnish — obscure)
mire       (English "mire" — misleading, means swamp)
muoto      (Finnish — obscure)
naava      (Finnish — obscure)
nallo      (Finnish — obscure)
niva       (Finnish — obscure)
nori       (Japanese — obscure)
nuppu      (Finnish — obscure)
nyra       (Finnish — obscure)
oiva       (Finnish — obscure)
olmu       (Finnish — obscure)
ondu       (Finnish — obscure)
orvi       (Finnish — obscure)
otava      (Finnish: Big Dipper — obscure)
paju       (Finnish — obscure)
palo       (Finnish: fire — partially known)
pihla      (Finnish rowan — obscure)
revna      (Nordic — partially known)
rilla      (Finnish — obscure)
roan       (horse color — obscure)
roihu      (Finnish — obscure)
runna      (Finnish — obscure)
saima      (Finnish lake — obscure)
sarka      (Finnish — obscure)
selka      (Finnish — obscure)
silo       (English: silo — unrelated)
sirra      (Finnish — obscure)
sola       (Finnish/solar — partially known)
solmu      (Finnish knot — obscure)
sora       (Finnish/sorrel — obscure)
sula       (Finnish — obscure)
tala       (Finnish — obscure)
tavi       (Finnish — obscure)
tilia      (Finnish linden — obscure)
ulma       (Finnish — obscure)
usva       (Finnish mist — obscure)
veru       (Finnish — obscure)
velu       (Finnish — obscure)
vesi       (Finnish water — partially known)
viima      (Finnish — obscure)
```

---

## Proposal: `easy_pool` subset

```ocaml
(* c2c_alias_words.ml *)
let easy_pool = [
  "alder"; "briar"; "cedar"; "clover"; "drift"; "ember";
  "fennel"; "fjord"; "glade"; "harbor"; "hearth"; "heron";
  "kelo"; "kesa"; "kuura"; "lumi"; "meadow"; "moro";
  "nova"; "oak"; "pebble"; "pilvi"; "puro"; "quill";
  "rain"; "reed"; "river"; "rook"; "rowan"; "sage";
  "sprig"; "starling"; "suvi"; "taika"; "tuuli"; "tyyni";
  "valo"; "vireo"; "vuono"; "willow"; "yarrow"; "yola"
]
```

**Count**: 42 words → 1,764 distinct pairs — still plenty of namespace.

---

## TaskCreate proposal

**Title**: Implement `easy_pool` alias subset for `generate_alias`

**AC**:
- `easy_pool` subset defined in `c2c_alias_words.ml` (~42 words, English-readable)
- `generate_alias` gains optional `~easy_pool:true` flag
- CLI: `c2c generate-alias --easy-pool` draws from the easy pool
- MCP: `generate_alias` tool accepts `easy_pool` boolean parameter
- Existing `generate_alias` behavior (full pool) unchanged by default

**Est**: ~30 LOC

---

## Notes

- The easy pool skews toward nature words (trees, birds, water, weather) — this is a feature, not a bug; aligns with the existing naming aesthetic
- "kelo", "kesa", "kuura", "lumi", "moro", "pilvi", "puro", "suvi", "taika", "tuuli", "tyyni", "valo", "viima", "vuono" are retained despite Finnish origin because operators already recognize them (they appear in existing swarm names like `kuura-viima`, `lumi-tyyni`, `tyyni`)
- "yola" is short, memorable, and already in use

---

## Files examined

| File | Purpose |
|---|---|
| `ocaml/c2c_alias_words.ml` | Full 131-word pool |
| `ocaml/c2c_start.ml` (grep `generate_alias`) | Existing alias generation call sites |
| `ocaml/cli/c2c_setup.ml` (grep `generate_alias`) | CLI alias generation |
