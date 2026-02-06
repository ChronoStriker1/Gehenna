# OpenRazer Attribution (Tartarus Pro Lighting)

Gehenna includes protocol logic derived from OpenRazer for the Razer Tartarus Pro (`VID:PID 1532:0244`).

Upstream project:
- https://github.com/openrazer/openrazer
- License: GPL-2.0-or-later

Referenced upstream commits:
- `aae37f193e1da14bb8544e48f729a91d4344d0cf` ("Add support for Tartarus Pro (1532:0244)")
- `24a18d85ba433f8c38976f45d1a3bddd1a751a27` ("Use razer_chroma_extended_matrix_effect_static in Tartarus Pro")
- `e81b32df6b02631b804b149fd10278f32796e656` ("Add led_state to memorize the Tartarus Pro's LEDs")

Implemented behavior based on these commits:
- Extended matrix static-effect packet layout for `SIDE_STRIPE_LED` (`0x0B`).
- Extended matrix brightness packet layout with `ZERO_LED` (`0x00`).
- Transaction ID and report framing for Tartarus Pro (`0x1F`, 90-byte report, XOR CRC over bytes `2...87`).
- Layer indicator mapping using RGB channel state (layer 1 = red, layer 2 = green, layer 3 = blue).

No OpenRazer source files are vendored directly; protocol framing and constants were reimplemented in Swift for Gehenna.
