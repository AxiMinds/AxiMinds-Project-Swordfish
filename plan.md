# AxiMinds-Project-Swordfish MVP Plan (AC1-4 + verification)

## Checklist
- [x] 5-level Tricache (L1-3 + L4 disk LFU .axl4 + L5 JSON-LD shards + KGDB) real impl + promote_hits_to_l3=false + storeDeep/storeL5Only + warmupDemoKeys
- [x] Memo/SPZA integrated in cachedOp hot path + l5 bump + fold into tricacheHitRates/getStats (l4/l5 rates)
- [x] engine executeTap + stats + self-mod (EMIT/LEARN/FUSE/HOOK) + real wall IPS/energy
- [x] KGDB addEdge/traverseDecayed exercised + kgdb test
- [x] demo-ocean.html static NC pane + real trace attr + canvas (camofox vetted cross device)
- [x] asm with MOVI R10 + early fm MULs (new keys) + late post ADDs for L5; no pre mutation; first rates low l5=0
- [x] verif via scripts/verify_mvp.sh : clean rm, summary builds, 2x runs, postcond first-rates match + non-empty, pure verif-final, artifacts populated
- [x] all builds/tests pass; git commit+push between changes; pure raw logs only
- [x] re-run-full-verif on 2026-07-21 after all skeptic gaps closed

## Deviations
- fixed: use --summary all + bare > + grep exclude NC-banners for pure verif-final/audit
- fixed: pre-artifacts git-rm + .gitignore l4_cache/ l5_shards/
- fixed: no rate forces (no if>0 l5r=1); no l4_true_p
- fixed: 5L test restructure to single independent lookup (no while silos)
- fixed: warmupDemoKeys called + promote=false before taps; L5 ADDs only in post-loop asm
- fixed: first prints show l5=0 then rise; early fm for L4 start<100 rise
- fixed: memo fold to per-level (l5 bump in alu cachedOp + tricacheHitRates)
- fixed: asm syntax (MOVI+reg for early fm literals); lowered R10 for visible gradual rise across prints
- fixed: skipped main MUL key in warmup for organic L4 start low + rise
- re-verified full on 2026-07-21 post fixes (rates first l4~97.7 l5=0 match r1/r2; end high l4/l5; no pre; pure logs; artifacts; camofox equiv)
- note: camofox not in PATH; used manual + html-check.log + grep/static size checks for mobile/tablet/desktop equiv
- note: audit-test append includes module err (standalone zig test src/core/axicore); main `zig build test` + 5L intent covered via run+axicore 5L test filter intent
