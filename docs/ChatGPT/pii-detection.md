# PII Detection

PII Stream Guard detects sensitive text using a multi-source approach:

- **OCR engine** (primary): detects text in frame pixels with adaptive confidence policies.
- **Accessibility tree** (when permitted): provides structured UI text and usually lower-latency exact geometry.

### Detected classes

- email addresses,
- phone numbers,
- user-defined needles/keywords.

### Fusion logic

- Both sources are converted into normalized bounding boxes in shared coordinate space.
- OCR gives broad visual coverage.
- Accessibility boxes are preferred when both sources agree because they are often tighter and semantically cleaner.
- Remaining OCR-only boxes are kept for full-coverage safety.

### Masking output

Detections are masked according to active mode:

- **Boxes**: draw a privacy overlay rectangle around sensitive regions,
- **Blackout**: fully blank sensitive pixels for stricter concealment.
