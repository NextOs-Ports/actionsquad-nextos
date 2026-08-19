# Action Squad — 2 missões deixadas (19/08, madrugada)

## Missão 1 — CONTROLES NO MENU não respondem (RG CubeXX / Knulli) 🔴 causa-raiz ACHADA

**Sintoma de campo (bbilford83):** com v1.0.3 o pop-up "Controller detected" some
sozinho (nosso auto-confirm funcionou), mas **nenhum botão navega o menu** — só
SELECT+START sai. Instala/imagem/áudio/pad-conectado: tudo OK no log.

**Causa-raiz (RE do `libAndroidEntryPoint.so` aarch64):**
- O diálogo é a layer `LAYER_ID_SWITCHCONTROL` da UI do jogo
  (`assets/all/media/interfaces/interfaces.xml:419`), com
  `focusedControlID="BUT_SWITCH_YES"` → é um menu de **FOCO navegável por
  botão/D-pad**, não por toque. Botões: `BUT_SWITCH_YES` (CONFIRM, X=-42 Y=75),
  `BUT_SWITCH_NO` (CANCEL, X=-42 Y=97).
- `ShowControllerDetected` (0x339848) chama
  `CControllersManager::ReceiveCommand(12, true)` — o menu consome input pelo
  caminho **`CControllersManager`**, NÃO pelo Paddleboat.
- **Nossa ponte (`src/android_shim.c`) só manda input pro Paddleboat**
  (`pb_processKey`/`pb_processMotion`). Paddleboat alimenta o GAMEPLAY; o
  **menu de UI não escuta Paddleboat** → foco nunca move → menu morto.
  (Por isso o gameplay do tester chegou a rodar mas o menu não responde.)

**Fix a implementar (canal oficial do menu, já mapeado):**
- `_Z20SendControllerButtonbi` @ **0x339df0** = `SendControllerButton(bool pressed, int command)`
  → `CControllersManager::ReceiveControllerButtonInput(u8,u8)` (0x89b50 plt). É a
  ponte oficial que alimenta os DOIS caminhos (menu + jogo).
- `_Z18SendControllerAxisfh` @ **0x339e18** = `SendControllerAxis(float, u8)` (analógico).
- **Plano:** resolver esses 2 símbolos no loader e, no pump de input
  (SDL_CONTROLLERBUTTONDOWN/UP + eixos em `android_shim.c` ~linha 1038), enviar
  TAMBÉM por `SendControllerButton`/`SendControllerAxis` (além do Paddleboat),
  mapeando SDL button → `EControllerCommand`. Precisa descobrir o enum
  `EControllerCommand` (ver `GetKeyMappingForCommand` 0x255e08 / `KeyPressed`
  0x255448) — provável ordem: UP/DOWN/LEFT/RIGHT/CONFIRM(A)/CANCEL(B)/...
- Validar no .137: pad virtual/real navega o menu SWITCHCONTROL e entra no PLAY.
- **Auto-confirm do pop-up pode até sair** depois disso (o menu passa a ser
  navegável de verdade) — decidir na hora.

**Artefatos:** `.so` puxado em
`…/scratchpad/as-re/libAndroidEntryPoint.so`; rizin/objdump aarch64 disponíveis.

## Missão 2 — Titan Souls no Miyoo Flip/spruce: CAMADA 7 🔴 (nova, do último log)

**Progresso:** camadas 1-6 MORTAS e confirmadas em campo — o log v1.0.6 agora
chega a `gamedir` certo, preflight `missing=0`, save pronto, language-menu OK.
**Nova parede (a 7ª):**
```
[egl_shim/nxgl:error] nxgl-v2 graphics stack unavailable
[egl_shim] nxgl_open_v2 falhou: status=-2 stage=4 reason=6
egl_shim: janela real nao foi criada  → exit 1
```
- `stage=4` = `NXGL_OPEN_STAGE_V2_VIDEO_START`; `reason=6` =
  `NXGL_OPEN_REASON_V2_VIDEO_UNAVAILABLE` (ver `framework/nxgl/include/nxgl.h`).
  Ou seja: **SDL_InitSubSystem(VIDEO) falhou no Flip** — provável driver de
  vídeo do SDL não inicia nesse ambiente (KMSDRM/fbdev do Mali-G52 do Flip),
  DIFERENTE do R36S. Lembrar: o nxsplash conseguiu via **fbdev /dev/fb0** —
  pista de que o caminho bom no Flip é fbdev, não KMSDRM.
- **Investigar:** o que o SDL do jogo tenta (o egl_shim/nxgl escolhe driver) e
  por que VIDEO_START falha no Flip mas funciona no R36S. Régua = horizonchase
  (roda no mesmo tipo de tela) e o próprio nxsplash que JÁ desenhou via fbdev.
- Provável fix de framework (nxgl) ou do egl_shim do TS: permitir/priorizar o
  caminho fbdev quando o KMSDRM não sobe, como o nxsplash faz.
- **Regra #37/#38/#39:** NÃO forçar SDL_VIDEODRIVER; achar por que o driver
  nativo não sobe.

Ambos os aparelhos são de TESTER (não temos Flip nem CubeXX na mão) — usar as
IMAGENS já baixadas: `cfw-images/knulli-h700-rg-cubexx-...img.gz` (CubeXX) e
`cfw-images/spruceV4.3.4.7z` (Flip) + o .137 pra regressão.
