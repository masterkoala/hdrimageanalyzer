# Visual QA Checklist: Scopes vs AJA HDR Image Analyzer 12G PDF Reference

**Tasks:** INT-007 — Compare all scopes against AJA PDF reference. **SC-025 (Phase 3)** — Scope visual quality audit: compare renders against AJA PDF screenshots.  
**Reference:** AJA HDR Image Analyzer 12G PDF manual (visual quality standard per project roadmap).

## Visual quality criteria (AJA reference standard)

Per *HDR_Analyzer_Pro_Master_Roadmap.md* (AGENT-03 / Phase 3), scopes must have:

- [ ] **Phosphor-glow effect** — accumulation resolved with non-linear tone mapping
- [ ] **Smooth intensity gradients** — no banding; appropriate accumulation/resolve
- [ ] **Precise graticule lines with labels** — IRE/nits, angles, or scale as applicable
- [ ] **Color-coded traces** — RGB/YCbCr/luma as per scope type
- [ ] **Professional dark background** — dark scope background (not washed out)
- [ ] **Anti-aliased text overlays** — readable labels and scale markers

## Scope-by-scope checklist

Use the same test signal (e.g. SDI color bars or known test pattern) in the app and compare visually to the AJA PDF screenshots for each scope.

| Scope        | App view / quadrant option | Checklist |
|-------------|----------------------------|-----------|
| **Video**   | Video                      | N/A (preview only; no scope rendering). |
| **Waveform**| Waveform                   | [ ] Luminance mode matches reference. [ ] RGB Overlay / YCbCr modes if shown in PDF. [ ] Graticule (0–100 IRE or 0–10k nits). [ ] Glow and dark background. [ ] HDR log scale option (SC-019) if in PDF. |
| **Vectorscope** | Vectorscope            | [ ] 75%/100% targets, skin tone line. [ ] Center = neutral, radius = saturation. [ ] Graticule and labels. [ ] Color-coded trace, dark background. |
| **Histogram**   | Histogram               | [ ] R/G/B/Luma (or combined) match reference. [ ] Linear/Log scale. [ ] Graticule and labels. [ ] Smooth gradients, dark background. |
| **RGB Parade**  | RGB Parade              | [ ] Three columns R, G, B. [ ] Graticule and scale. [ ] Visual style consistent with AJA. |
| **CIE xy**      | CIE xy                  | [ ] Spectral locus / gamut triangles (709, P3, 2020) if in PDF. [ ] D65 white point. [ ] xy distribution, labels, dark background. |

## How to run this QA

1. Obtain the **AJA HDR Image Analyzer 12G** PDF manual (vendor documentation).
2. Start HDRAnalyzerProApp with a live SDI signal or file source (e.g. color bars).
3. For each scope type, set one quadrant to that scope (Switch to → Waveform / Vectorscope / Histogram / RGB Parade / CIE xy).
4. Compare app output side-by-side with the corresponding scope screenshots in the PDF.
5. Tick the criteria above and the per-scope checkboxes when they match or exceed the reference.

## SC-025 Phase 3 render audit (compare app renders vs AJA PDF)

Use this checklist when performing the **scope visual quality audit** (SC-025):

1. **Setup:** Open the AJA HDR Image Analyzer 12G PDF to the scope screenshot pages. Run HDRAnalyzerProApp with the same (or equivalent) test signal (e.g. SDI color bars).
2. **Per-scope render comparison:** For each of Waveform, Vectorscope, Histogram, RGB Parade, CIE xy:
   - [ ] App render matches or exceeds the reference in the six criteria above (phosphor-glow, smooth gradients, graticule, color-coded traces, dark background, anti-aliased text).
   - [ ] No visible banding, jagged lines, or washed-out background.
   - [ ] Scale/units (IRE, nits, angles) and labels align with the PDF where applicable.
3. **Sign-off:** When all scope types pass the comparison, the SC-025 audit is complete. Record date and any notes in agent result or project docs.

## Automated tests

- `ScopesTests` includes `testVisualQAScopeTypesCoverage`, `testVisualQACriteriaDocumented`, and `testSC025AuditChecklistPresent` to ensure the list of scope types, the AJA criteria, and the SC-025 audit checklist remain under test coverage and are not accidentally reduced or removed.
