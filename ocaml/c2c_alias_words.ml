(* c2c_alias_words.ml — single canonical home for the alias word pool.

   This 128-word array is the source of all randomly-generated agent
   aliases. Cartesian product gives 16,384 ordered pairs. Previously
   duplicated verbatim in [c2c_start.ml] and [cli/c2c_setup.ml]; #388
   converged both call sites onto this module. *)

let words = [| "aalto"; "aimu"; "aivi"; "alder"; "alm"; "alto"; "anvi"; "arvu"; "aska"; "aster"; "auru"; "briar"; "brio"; "cedar"; "clover"; "corin"; "drift"; "eira"; "elmi"; "ember"; "fenna"; "fennel"; "ferni"; "fjord"; "glade"; "harbor"; "havu"; "hearth"; "helio"; "heron"; "hilla"; "hovi"; "ilma"; "ilmi"; "isvi"; "jara"; "jori"; "junna"; "kaari"; "kajo"; "kalla"; "karu"; "keiju"; "kelo"; "kesa"; "ketu"; "kielo"; "kiru"; "kiva"; "kivi"; "koru"; "kuura"; "laine"; "laku"; "lehto"; "leimu"; "lemu"; "linna"; "lintu"; "lumi"; "lumo"; "lyra"; "marli"; "meadow"; "meru"; "miru"; "mire"; "moro"; "muoto"; "naava"; "nallo"; "niva"; "nori"; "nova"; "nuppu"; "nyra"; "oak"; "oiva"; "olmu"; "ondu"; "orvi"; "otava"; "paju"; "palo"; "pebble"; "pihla"; "pilvi"; "puro"; "quill"; "rain"; "reed"; "revna"; "rilla"; "river"; "roan"; "roihu"; "rook"; "rowan"; "runna"; "sage"; "saima"; "sarka"; "selka"; "silo"; "sirra"; "sola"; "solmu"; "sora"; "sprig"; "starling"; "sula"; "suvi"; "taika"; "tala"; "tavi"; "tilia"; "tovi"; "tuuli"; "tyyni"; "ulma"; "usva"; "valo"; "veru"; "velu"; "vesi"; "viima"; "vireo"; "vuono"; "willow"; "yarrow"; "yola" |]

(* easy_pool — 52 English-readable nature-themed words drawn from the full
   128-word pool. Used for --easy-pool alias generation. Cartesian product
   gives ~2,652 easy-pool pairs. Nature themes: trees, birds, plants, weather,
   landscape features. *)
let easy_pool = [| "alder"; "cedar"; "clover"; "ember"; "fennel"; "fern"; "fjord"; "glade"; "harbor"; "hearth"; "heron"; "keiju"; "kielo"; "kuura"; "laine"; "lehto"; "lemu"; "lintu"; "lumi"; "lumo"; "meadow"; "mire"; "naava"; "nuppu"; "nyra"; "oak"; "otava"; "paju"; "pebble"; "puro"; "quill"; "rain"; "reed"; "rilla"; "river"; "rook"; "rowan"; "sage"; "saima"; "solmu"; "sula"; "suvi"; "tilia"; "tuuli"; "tyyni"; "usva"; "valo"; "vesi"; "viima"; "vuono"; "willow"; "yarrow" |]
