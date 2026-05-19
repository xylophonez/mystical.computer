# Service Overlay

`service-overlay@1.0` is the generic AO/P4 paid-route pack for a HyperBEAM
service node. It is meant to be composed with feature branches such as
`feat/dev-whisper`: merge the overlay branch and the device branch, then price
the route you want to sell. Fixed route prices can use `router-opts/offered`;
work-unit pricing uses `service-overlay-pricing-routes` to hand selected routes
to `metering@1.0` or another pricing device.

## Devices

The branch preloads these devices:

- `service-overlay@1.0`: start-hook bootstrap and P4 wrapper.
- `ao-payment@1.0`: verifies AO transfers and imports them into the local
  process ledger.
- `process-ledger@1.0`: P4 ledger adapter for an AO-Core process ledger.
- `pricing-router@1.0`: routes P4 pricing requests by path.
- `bundler-settlement@1.0`: optional bundle-completion settlement hook.
- `arweave-byte-pricing@1.0`: optional Arweave byte pricing in AO units.
- `simple-oracle@1.0`: AR/AO price oracle used by dynamic byte pricing.

The overlay does not include LapEE-specific devices such as
`lapee-p4-bootstrap@1.0`, `lapee-bundler-gc@1.0`, or the LapEE bundler/copycat
replacements.

## Minimal Paid Whisper Config

Use this after composing `service-overlay` with a branch that provides
`whisper@1.0`. This charges by fetched input size, not by a flat route price.

```json
{
  "service-overlay": true,
  "simple-pay-price": 0,
  "service-overlay-pricing-routes": [
    {
      "template": "/~whisper@1.0/.*",
      "pricing-device": "metering@1.0"
    }
  ],
  "metering-rates": {
    "media-input-bytes": 1,
    "whisper-input-bytes": 0,
    "beam-reductions": 0
  },
  "on": {
    "start": [
      { "device": "service-overlay@1.0", "path": "start" }
    ],
    "request": [
      { "device": "manifest@1.0" }
    ]
  }
}
```

Rates are denominated in AO base units. `media-input-bytes` is the shared
counter for fetched media payload size; `whisper-input-bytes` lets an operator
add a Whisper-specific surcharge or discount without changing the shared media
rate. `simple-pay-price` is set to `0` so only explicitly routed pricing
devices charge.

At startup, the overlay creates or reuses a local process ledger named `ledger`,
sets `ao-payment-deposit-address` to the node wallet by default, and replaces
the request hook with its P4 wrapper. If a manifest request hook is already
configured, the overlay folds it into that wrapper so plain transaction reads
continue to work.

## Media-Ingest Metering

Use file size as the baseline metering unit for media-ingest devices. It is the
stable pre-work quantity both the node and caller can reason about, and it maps
cleanly across Whisper transcription, FFmpeg transcoding, and future media
devices.

Current media counters:

- `media-input-bytes`: shared input-byte counter emitted by media ingest
  devices.
- `whisper-input-bytes`: Whisper-specific input-byte counter.
- `ffmpeg-input-bytes`: FFmpeg-specific input-byte counter.

For uniform media pricing, set only `media-input-bytes` and leave the
device-specific counters at `0`. For device-specific pricing, set both the
shared counter and the device counter. `metering@1.0/estimate` currently starts
at `0` and `metering@1.0/price` returns the exact post-execution amount after
the device records consumed units, so public deployments should combine this
with funded balances or a future preflight estimator.

Example for both Whisper and FFmpeg:

```json
{
  "service-overlay": true,
  "simple-pay-price": 0,
  "service-overlay-pricing-routes": [
    {
      "template": "/~whisper@1.0/.*",
      "pricing-device": "metering@1.0"
    },
    {
      "template": "/~ffmpeg-audio@1.0/.*",
      "pricing-device": "metering@1.0"
    }
  ],
  "metering-rates": {
    "media-input-bytes": 1,
    "whisper-input-bytes": 0,
    "ffmpeg-input-bytes": 0,
    "beam-reductions": 0
  }
}
```

## Funding Flow

1. Read the live deposit address:

   ```sh
   curl -fsS "$NODE/~service-overlay@1.0/status"
   ```

2. Send an AO token `Transfer` to the reported `deposit-address`.

3. Import the verified transfer into the local ledger:

   ```sh
   curl -fsS "$NODE/~ao-payment@1.0/ingest?message-id=$MSG_ID&slot=$SLOT&sender=$SENDER&quantity=$QUANTITY"
   ```

4. Call the paid route with the same funded signer. Unsigned or unfunded
   callers receive HTTP `402`.

## Paid Bundler Mode

The canonical LapEE paid bundler profile used the same core devices plus
LapEE-only boot and cleanup pieces. The generic equivalent is opt-in:

```json
{
  "service-overlay": true,
  "service-overlay-paid-bundler": true,
  "service-overlay-bundler-settlement": true,
  "arweave-byte-price": "dynamic",
  "metering-rates": {
    "beam-reductions": 0
  },
  "bundler-ans104": "https://up.arweave.net:443",
  "on": {
    "start": [
      { "device": "service-overlay@1.0", "path": "start" }
    ]
  }
}
```

`service-overlay-paid-bundler` routes `~bundler@1.0/tx` and
`~bundler@1.0/item` through `arweave-byte-pricing@1.0`.
`service-overlay-bundler-settlement` installs the completion hook that settles
the metered bundle cost after the bundle completes.

## Useful Options

- `service-overlay-beneficiary`: account that receives paid-route charges.
  Defaults to the node address.
- `service-overlay-p4-recipient`: local ledger account charged as the P4
  recipient. Defaults to the beneficiary.
- `service-overlay-ledger`: local ledger process name. Defaults to `ledger`.
- `ao-payment-token`: AO token process. Defaults to the canonical AO token.
- `ao-payment-mainnet-url`: AO state endpoint used for payment verification.
- `service-overlay-pricing-routes`: explicit `pricing-router@1.0` route list
  for dynamic pricing devices such as `metering@1.0`.
- `metering-rates`: AO base-unit rates used by `metering@1.0`; media ingest
  devices emit `media-input-bytes` plus a device-specific byte counter.
