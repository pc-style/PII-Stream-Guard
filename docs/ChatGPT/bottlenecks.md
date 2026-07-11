# Bottlenecks

The main constraints are:

- **OCR throughput vs. FPS**: higher frame rates increase detection cost.  
  Mitigation: adjustable FPS modes, sampling strategy, and optional low-latency mode.

- **Low-contrast/small text recognition**: OCR misses weak rendering.  
  Mitigation: enhanced contrast mode and lockdown mode for stricter passes.

- **Accessibility permission dependence**: AX-enhanced detections require user-granted accessibility access.  
  Mitigation: degrade gracefully to OCR-only when permissions are missing.

- **Memory/IO pressure during recording**: high-resolution recording plus sidecar JSONL output can spike resource use.  
  Mitigation: codec, quality, and fps tuning; periodic sidecar rotation/cleanup in ops workflows.

- **Remote path reliability**: network latency and token/auth mismatches can cause client blackouts or stalls.  
  Mitigation: strict token checks, fail-closed behavior, and simpler local-mode fallback where possible.
