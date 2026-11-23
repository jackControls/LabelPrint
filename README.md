# Label Print

A Mac app and command line tool for Katasymbol / Supvan Bluetooth label printers — the handheld ones
that normally only work with the phone app.

- **App:** design a label with text, QR codes, barcodes, pictures and boxes, then print it. The canvas
  shows exactly what will be printed, and the label takes its size from the roll in the printer.
- **Command line:** `labelprint text "Spare keys"`, `labelprint qr https://example.com --caption "Scan me"`,
  `labelprint barcode INV-00412`, `labelprint image logo.png`, `labelprint status`. Run `labelprint help`
  for everything.

It talks to the printer directly over Bluetooth LE. No driver, no account, no phone.

## Printers

**Tested with:** Katasymbol E11 (Bluetooth name starting `T0224`), on 12 × 40 mm die-cut labels.

**Should work, untested:** other Supvan / Katasymbol models with the same 12 mm print head and
protocol — E10, E11, E12, E16 and their Supvan-branded equivalents. Wider printers (T50, T80 and so on)
use a different head and are not supported.

## Build

Needs macOS 14 or later and Xcode.

```bash
./scripts/build_app.sh
```

This produces `build/Label Print.app` and `build/labelprint`. The app is signed with a Developer ID
or Apple Development certificate if one is in your keychain, otherwise ad-hoc.

The first time you run it, macOS asks for Bluetooth access. Close the phone app first if it is
connected to the printer; the printer only talks to one device at a time.

## Credits

The printer protocol was worked out by others. This project is written from the notes in
[heeen/supvan-cups](https://github.com/heeen/supvan-cups) (MIT), with help from reading
[PardosTechSamples/BLEPrint-MacOS](https://github.com/PardosTechSamples/BLEPrint-MacOS) (MIT) and
[vheinitz/SUPVAN_KS_LM_E12](https://github.com/vheinitz/SUPVAN_KS_LM_E12).

`Sources/CLzma/include` holds the public liblzma headers from [xz-utils](https://tukaani.org/xz/) (0BSD),
used to call the copy of liblzma that ships with macOS.

Not affiliated with Katasymbol or Supvan.
