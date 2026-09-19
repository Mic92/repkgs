# Evaluation cost: repkgs against nixpkgs

Nix evaluates before it builds, and on nixpkgs that step is what a user waits for on every
`nix build` and what keeps whole-set tools (search, rebuild estimation) expensive. repkgs
claims cheap evaluation ([design.md](design.md) §1). This note measures it.

## Method

`nix-instantiate` to `.drv` files, for every repkgs package that is supported on the build
platform and has a nixpkgs counterpart: 175 on 2026-09-19 (`bench/eval.nix` pairs them, 34
under a different attribute name). nixpkgs is the revision in `flake.lock`, imported with
`overlays = [ ]`. Three workloads: the whole set in one call, one package per fresh process, a
growing random prefix in the same order on both sides. Times are the minimum of three runs,
peak RSS is from GNU time, thunks and attribute-set elements from `NIX_SHOW_STATS` (these are
deterministic). Ryzen 7 laptop, Nix 2.34.

## Results

![set](https://github.com/Mic92/repkgs/releases/download/eval-2026-09-19/eval-set.png)

| 175 packages, one call | repkgs | nixpkgs | ratio |
| ---------------------- | -----: | ------: | ----: |
| wall time              | 0.41 s | 10.25 s |    25 |
| peak RSS               |  44 MB |  574 MB |    13 |
| thunks                 |   46 k |  4.18 M |    90 |
| attribute-set elements |   38 k |  21.4 M |   561 |
| derivations written    |    541 |   9 491 |    17 |

![packages](https://github.com/Mic92/repkgs/releases/download/eval-2026-09-19/eval-packages.png)
![scaling](https://github.com/Mic92/repkgs/releases/download/eval-2026-09-19/eval-scaling.png)

| packages in one call | wall (s), repkgs / nixpkgs | RSS (MB)  |
| -------------------- | -------------------------- | --------- |
| 1                    | 0.21 / 0.67                | 41 / 92   |
| 10                   | 0.27 / 1.59                | 41 / 174  |
| 50                   | 0.32 / 4.97                | 43 / 362  |
| 175                  | 0.41 / 10.47               | 44 / 571  |

## Analysis

repkgs is a constant plus a small slope. A trivial `nix-instantiate` costs 0.09 s and 40 MB.
Importing the set and instantiating the first package adds 0.10 s and 1 MB (≈6 k thunks: the
package, its toolchain and the seed, 120–170 derivations). Each further package adds about
1.2 ms, 20 KB and 230 thunks, which is why the scaling curve is flat.

nixpkgs is a larger constant plus a term that follows the build closure. Its cheapest package
costs 0.67 s, 92 MB and 143 k thunks, because `lib`, the stdenv stages and the top-level
fixpoint are forced first and one package already means ≈800 derivations (git: 1 479).

Per derivation written, nixpkgs spends ≈440 thunks to our ≈86, a factor of 5. The other factor
of 17 in the thunk ratio is nixpkgs writing that many more derivations for the same names.

## Threats to validity

1. **Unequal derivations.** Pairing is by name, and nixpkgs derivations do more. Its git has
   perl and python support and builds the manual (asciidoc, docbook, texinfo, xmlto, fifteen
   perl modules). Even jq gains autoreconf, bison and tzdata there. The ratios therefore mix
   *less package* with *cheaper machinery*: roughly 5× is machinery, 17× is derivation count,
   and the derivation count is itself part design (one toolchain derivation instead of a stdenv
   chain) and part scope.
2. **Features repkgs does not have.** No overlay fixpoint, no `override`/`overrideAttrs`, no
   `pkgsCross`. Part of the ratio is their price, not waste. A repkgs cross set (a second
   `import` with `platform = "aarch64-linux"`) costs 0.54 s and 47 MB, a third more than
   native, since two toolchains are instantiated.
3. **nixpkgs measured favourably.** No flakes, no overlays, no NixOS modules.
4. **One machine.** Times will differ elsewhere, the counters will not.

## Reproducing

```console
$ bench/eval.nu --save eval.json
$ nix-shell -p 'python3.withPackages (p: [ p.matplotlib ])' --run 'bench/eval-plot.py eval.json out/'
```

Data and figures of this run: release [`eval-2026-09-19`](https://github.com/Mic92/repkgs/releases/tag/eval-2026-09-19).
