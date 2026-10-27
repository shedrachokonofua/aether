# Local image-generation engines vs ComfyUI

Researched 2026-10-15. Question: is there an engine faster than ComfyUI on
talos-neo's GPU for the image workloads we actually run? Engine claims come
from the primary source cited per row; anything inferred is marked
**[INFERENCE]**, third-party numbers **[THIRD-PARTY]**. No engine here
publishes sm_120 numbers for these exact models — every candidate below still
needs a local benchmark against the baseline.

## Hardware and workloads

- GPU: RTX PRO 6000 Blackwell Max-Q, 96 GB, sm_120, driver 580.178 (CUDA 13.0),
  shared with llama-swap.
- ComfyUI at research time (`tofu/home/kubernetes/comfyui.tf`, image
  `yanwk/comfyui-boot:cu129-slim`): torch 2.8.0+cu129, comfy-kitchen 0.2.31,
  ComfyUI v0.33.1, SageAttention not installed — read from the running pod.
  Upgraded the same day; see "ComfyUI upgrade, 2026-10-15" below.
- Workloads, from ComfyUI history and outputs:
  1. Z-Image Turbo bf16 text-to-image, 1080×1920, 9 steps — frame-gallery
     (20/day) and the shdrch background job (20/week).
  2. `Qwen-Rapid-AIO-NSFW-v23` edit, ~1080×1920, 6 steps — manual. A
     ComfyUI single-file merge: Qwen-Image-Edit-2511 fp8 with NSFW, Lightning
     and realism LoRAs baked into the model, plus text encoder and VAE.
  3. CyberRealisticPony V18 (SDXL single file), 832×1216, 30 steps — manual.

## Measured baseline (this GPU)

Same settings on both engines; engine-only generation time; GPU freed before
each cold run. sd.cpp ran under llama-swap's `unified-cuda13` image during a
spike on 2026-10-15.

| Workload | ComfyUI warm | ComfyUI cold | sd.cpp warm | sd.cpp cold |
|---|---|---|---|---|
| Z-Image Turbo | 8.52 s | 16.5 s | 10.25 s | 15.5 s |
| Pony | 3.85 s | 13.1 s | 9.02 s | 9.1 s |
| Rapid-AIO edit | 11.15 s | 22.1 s | 18.98 s | 26.3 s |

ComfyUI history agrees: 152 warm frame-gallery runs at 8.46 s median.

## Constraint that decides most options

No engine other than ComfyUI (and ComfyUI wrappers such as SwarmUI) documents
loading the Rapid-AIO single file as-is. Every alternative needs it split into
transformer / text encoder / VAE, or rebuilt as base Qwen-Image-Edit-2511 plus
runtime LoRAs. sd.cpp worked with the AIO only by pairing it with the stock
`qwen_2.5_vl_7b_fp8_scaled` text encoder.

## Option 1: make ComfyUI faster (no engine change)

| Lever | Applies to | Evidence | Catch |
|---|---|---|---|
| NVFP4 checkpoints | Z-Image (official `z_image_turbo_nvfp4`); Qwen-Edit-2511 via comfy-quants config `qwen_image_edit_2511_nvfp4.yaml`; not SDXL | Comfy claims ~2× vs fp8/bf16 on Blackwell ([blog](https://blog.comfy.org/p/new-comfyui-optimizations-for-nvidia)); [Comfy-Org/z_image_turbo](https://huggingface.co/Comfy-Org/z_image_turbo); [comfy-quants](https://github.com/Comfy-Org/comfy-quants). [THIRD-PARTY] Edit-2511 NVFP4 on RTX 5090: 3.45 s vs 6.09 s fp8mixed ([Bedovyy](https://huggingface.co/Bedovyy/Qwen-Image-Edit-2511-NVFP4)) | Needs torch built for CUDA 13 (cu130); without it NVFP4 can be up to 2× slower than fp8 (same blog). Our image is cu129. Rapid-AIO must be split before comfy-quants can quantize it. 4-bit quality needs a same-seed check. |
| MXFP8 | Qwen-Edit-2511 (comfy-quants config) | Same tooling as NVFP4, 8-bit block scales | Fallback if NVFP4 quality is poor |
| SageAttention2++ | All three, including Pony | Kernel-only 2.7× vs FlashAttention2 on RTX 5090 ([thu-ml/SageAttention](https://github.com/thu-ml/SageAttention)); ComfyUI flag `--use-sage-attention` ([startup flags](https://docs.comfy.org/development/comfyui-server/startup-flags)) | End-to-end gain is smaller than the kernel number; not installed today |
| Cache-DiT | Z-Image only | 1.5× at Z-Image Turbo's 9 steps ([ComfyUI-CacheDiT](https://github.com/Jasonzzt/ComfyUI-CacheDiT)) | Other step-caching (TeaCache, MagCache, EasyCache) is tuned for 20–50 steps; skip at 6–9 steps |
| torch.compile | Fixed-shape Z-Image job | [THIRD-PARTY] "20–30% at best" ([KJNodes #502](https://github.com/kijai/ComfyUI-KJNodes/issues/502)) | Compile cost on every cold start |
| Nunchaku (4-bit SVDQuant) | Z-Image official; Edit-2511 community-only ([QuantFunc](https://huggingface.co/QuantFunc/Nunchaku-Qwen-Image-EDIT-2511)); no SDXL | NVFP4 3.1× vs BF16 for FLUX on RTX 5090 ([nunchaku](https://github.com/nunchaku-ai/nunchaku)) | Largely duplicates native NVFP4 via a second plugin |
| TensorRT / DeepCache | Pony only | TensorRT FP8 1.95× SDXL on RTX 6000 Ada ([NVIDIA](https://developer.nvidia.com/blog/tensorrt-accelerates-stable-diffusion-nearly-2x-faster-with-8-bit-post-training-quantization)) | TensorRT engines are per checkpoint and resolution, no LoRA ([ComfyUI_TensorRT](https://github.com/comfyanonymous/ComfyUI_TensorRT)); Pony is already 3.85 s |

Dead or paused, do not adopt: stable-fast (author paused), OneDiff (no news
since 2024-07).

## Option 2: a different serving engine

| Engine | Z-Image | Edit-2511 | SDXL/Pony | API for llama-swap | Notes |
|---|---|---|---|---|---|
| [SGLang Diffusion](https://docs.sglang.io/docs/sglang-diffusion) | yes | yes; runtime Lightning LoRA verified | **no** | OpenAI generations + edits; `/health` returns 503 until warm | FP8, INT8-ConvRot (validated on CC 12.0), Cache-DiT. Its own Qwen-Image-2.1 cookbook says TRT-LLM FP4 GEMM "does not support SM12.x", so NVFP4 on this card is unverified. CUDA 13 images. ComfyUI plugin can run one SGLang DiT step per sampler step. |
| [vLLM-Omni](https://docs.vllm.ai/projects/vllm-omni/en/stable/models/supported_models) | yes | yes; LoRA "not verified" | yes, diffusers layout only | OpenAI generations + edits, `/health` | Only server listing all three families; Pony and Rapid-AIO both need conversion; no NVFP4; no sm_120 numbers |
| diffusers + own server | yes | yes | yes, `from_single_file` | build it yourself | torchao NVFP4 1.39× on QwenImage, B200 ([PyTorch blog](https://pytorch.org/blog/faster-diffusion-on-blackwell-mxfp8-and-nvfp4-with-diffusers-and-torchao/)); we would own the server |
| [LightX2V](https://github.com/ModelTC/LightX2V) | yes | yes, via its own Lightning FP8 checkpoint | no | OpenAI-shaped FastAPI | Vendor-claimed ~1.4× on H100 for Edit-2511; means replacing our merge |
| TensorRT-LLM VisualGen | no | yes (beta) | no | OpenAI generations + edits | NVFP4 paths gated to SM100/SM103 in places ([docs](https://raw.githubusercontent.com/NVIDIA/TensorRT-LLM/main/docs/source/models/visual-generation.md)) |
| stable-diffusion.cpp | yes | yes, split files | yes | OpenAI + sdapi | Measured slower than ComfyUI above |

Skip: LocalAI (wraps sd.cpp, no Z-Image/Edit diffusers pipelines), xDiT
(multi-GPU design), NVIDIA NIM (fixed catalog, no Z-Image/SDXL), Ollama image
generation (removed in [v0.32.6](https://github.com/ollama/ollama/releases/tag/v0.32.6)).

## Option 3: a different UI app

| App | Covers all three | API | Speed evidence | Notes |
|---|---|---|---|---|
| [Forge Neo](https://github.com/Haoming02/sd-webui-forge-classic/tree/neo) | yes, Rapid-AIO split | A1111 sdapi | none published | torch 2.13.0+cu130 pin; NVFP4/MXFP8/Sage; single maintainer; Docker image still cu126 |
| [SD.Next](https://github.com/vladmandic/sdnext) | yes, Rapid-AIO as UNET over base | A1111 sdapi | none published | torch 2.14.1+cu132 pin; SDNQ incl. NVFP4; Docker image cu12.8 |
| [InvokeAI](https://github.com/invoke-ai/InvokeAI) | yes; Rapid-AIO transformer needs separate encoder + VAE | own graph-queue API, not sdapi or OpenAI | none published | Best-maintained UI; can't sit behind llama-swap without a shim |
| [SwarmUI](https://github.com/mcmonkeyprojects/SwarmUI) | yes, AIO as-is | own API | same as ComfyUI | It runs ComfyUI as its backend; changes the UI, not the speed |
| [KoboldCpp](https://koboldcpp.net/docs/features/image-generation) | yes, AIO split | OpenAI + sdapi + ComfyUI-style | same as sd.cpp | sd.cpp engine |

Not candidates: WanGP (no SDXL, no HTTP API), Krita AI Diffusion (desktop
ComfyUI client), upstream Forge / reForge / Fooocus (unmaintained or
superseded).

## Conclusion

- No published evidence shows another engine beating ComfyUI on this GPU for
  these models. The UI apps publish no speed data at all.
- The largest documented gains are inside ComfyUI: a cu130 torch build plus
  NVFP4 Z-Image, then NVFP4 or MXFP8 for a split Rapid-AIO, SageAttention, and
  Cache-DiT on Z-Image.
- The only engine worth benchmarking against ComfyUI is SGLang Diffusion, and
  only for Z-Image and Qwen-Edit: it has no SDXL, so ComfyUI would stay for Pony.

## ComfyUI upgrade, 2026-10-15

Image `yanwk/comfyui-boot:cu130-slim-20261012` (Python 3.13, torch
2.14.1+cu130, comfy-kitchen 0.2.37); ComfyUI code on the PV moved v0.33.1 →
v0.40.0. Backup of the old code tree and its git ref sit next to it in
`/root` (`comfyui-preupgrade-20261015.tar.gz`, `comfyui-preupgrade-ref-20261015.txt`).
All custom nodes still import.

Same workflows, settings and method as the baseline table (llama-swap models
unloaded, ComfyUI freed before each cold run):

| Workload | Before warm | After warm | After cold |
|---|---|---|---|
| Z-Image Turbo bf16 | 8.52 s | 6.73 s | 21.8 s |
| Z-Image Turbo `z_image_turbo_nvfp4` | — | 4.59 s | 30.3 s (first load of the file) |
| Pony | 3.85 s | 4.13 s | 14.4 s |
| Rapid-AIO edit | 11.15 s | 10.32 s | 29.9 s |

- NVFP4 Z-Image is 1.47× faster than bf16 on the new stack and 1.86× faster
  than the old baseline. A same-seed pair looked equivalent in quality
  (different composition, same scene and style). The file is downloaded to
  `models/diffusion_models/`; frame-gallery and the shdrch job still request
  `z_image_turbo_bf16.safetensors`.
- Cold runs got slower on every workload. The cause was not investigated.
- SageAttention: PyPI only ships v1.0.6 (Triton). Through the KJNodes patch
  node it took NVFP4 Z-Image from 4.59 s to 4.27 s; with Pony it failed
  (`attention_sage() got an unexpected keyword argument 'preferred_attention'`,
  the installed KJNodes predates ComfyUI v0.40). SageAttention2++ needs a CUDA
  toolkit build that the slim image lacks. Not adopted; uninstalled.

## Next measurements

1. Split Rapid-AIO, quantize the transformer with comfy-quants NVFP4 (MXFP8
   fallback), compare speed and output.
2. Optional: SGLang Diffusion behind llama-swap for Z-Image and base
   Edit-2511 + Lightning LoRA, FP8 first.
