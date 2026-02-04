# Proof of Concept (HID Enumeration)

Goal: verify we can detect and inspect the Razer Tartarus Pro over HID on macOS.

## Build and Run
From repo root:

```bash
swift run GehennaCLI list
```

Filter by vendor or product ID (hex or decimal):

```bash
swift run GehennaCLI list --vendor 0x1532
swift run GehennaCLI list --vendor 0x1532 --product 0x022B
```

Output as JSON:

```bash
swift run GehennaCLI list --json
```

## Expected Output
- At least one HID device entry for the Tartarus Pro.
- Vendor/product IDs should match Razer (vendor id commonly 0x1532; confirm on your system).
- Device name should include "Tartarus".

If the device does not appear, check USB connection, power, and that the device is visible in System Information > USB.
