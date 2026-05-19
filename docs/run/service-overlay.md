# Service Overlay

`service-overlay@1.0` is the generic AO/P4 paid-route pack for a HyperBEAM
service node. In the post-#915 layout, the MC service devices are packaged from
`src/preloaded/mystical` with the normal Forge flow. Fixed route prices can use
`router-opts/offered`; work-unit pricing uses `service-overlay-pricing-routes`
to hand selected routes to `metering@1.0` or another pricing device.

## Source Layout

`xylophonez/mystical.computer` tracks `permaweb/HyperBEAM` on `edge`. MC-specific
devices live under `src/preloaded/mystical` and are packaged into generated
`_hb_device_*` modules during `rebar3 compile`, `rebar3 device test`, and
`rebar3 device package`.

`rb.mystical.computer` is the service-node deployment target for this combined
pack. Keep `bundler.mystical.computer` separate unless intentionally deploying
the paid bundler profile.

## Devices

The MC preload adds these devices:

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

Use this when `service-overlay@1.0` and `whisper@1.0` are both in the packaged
preloaded device set. This charges by fetched input size, not by a flat route
price.

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

`hyperbalance` is the client-side helper for this flow. It does not define a new
paid-service standard; it orchestrates existing HyperBEAM P4 discovery, AO token
transfers, AO payment import, local ledger balance checks, and signed requests.

For a live rb Whisper call, use `hyperbalance` to fund/import AO credit, then
send the paid service request with HyperBEAM's native signer. The current JS
example validates funding and import; the rb execution transport should remain
the native smoke script until the browser/JS `httpsig@1.0` request adapter is
validated against P4.

```sh
cd /home/fn/Dev/hyperbalance
npm run build
ARWEAVE_WALLET=/path/to/funded-jwk.json node examples/pay-rb-whisper.mjs --verbose

cd /home/fn/Dev/mystical.computer
WALLET_FILE=/path/to/funded-jwk.json scripts/rb-whisper-smoke.sh
```

The script defaults to:

- node: `https://rb.mystical.computer`
- route: `/~whisper@1.0/transcribe`
- tx: `9OaHLWDaAjSSBeGhYOyBm2BRG-SG5ppEt2rWi_z2AIs`
- gateway: `https://rb.mystical.computer`
- language: `en`

Use `--execute` with `examples/pay-rb-whisper.mjs` only when explicitly testing
the JS signed-request transport. It is not the rb production smoke path yet.

The caller does not upload to a fixture directory. For user-facing flows, upload
or otherwise publish the media first, then pass the resulting tx id or direct
request body to the paid device. `gateway` can be omitted only when the node's
configured stores can resolve the tx from Arweave or its peers. Passing
`gateway=https://rb.mystical.computer` is useful for immediate availability
after uploading a bundle directly to rb.

For CPU-only Whisper nodes, set `WHISPER_THREADS` to the number of vCPUs
available to the service. If it is unset, `whisper@1.0` uses the runtime's
available parallelism instead of a fixed thread count.

## Inline Ruby Transforms

HyperPATH composition can run a transform device after a paid media device. For
Whisper, the useful output key is `transcript`; `body` is the JSON-encoded
payload returned for HTTP clients.

Ruby inline code is loaded from a message with `content-type=application/ruby`
and a `body`, or from a `module` message/map. The `script=` shorthand used in
some Lua examples is not an alias for Ruby modules.

Use a module map when passing Ruby source through query fields. Structured-field
byte sequences avoid quote-stripping in typed query parsing:

```sh
NODE=https://rb.mystical.computer
ruby_code='module AOProcess; def self.first5(process,message,opts); text = process["transcript"] || message["transcript"] || ""; {"body" => text.split[0,5].join(" "), "content-type" => "text/plain"}; end; end'
body_b64=$(printf '%s' "$ruby_code" | base64 -w0)
ct_b64=$(printf 'application/ruby' | base64 -w0)
module_map="body=:$body_b64:,content-type=:$ct_b64:"

curl -G "$NODE/~ruby@mruby-3.3a/first5" \
  --data-urlencode "module+map=$module_map" \
  --data-urlencode 'transcript=Hello from Hyper Beam Whisper and more words'
```

Expected body:

```text
Hello from Hyper Beam Whisper
```

The intended composed path shape is:

```text
/~whisper@1.0/transcribe/~ruby@mruby-3.3a/first5
```

with `tx`, `gateway`, and `language` supplied to Whisper, and the Ruby `module`
message supplied to the Ruby step. Ruby receives the prior device output as the
`process` argument, so the transform should read `process["transcript"]`.

As of the current rb deployment, standalone inline Ruby is live and Whisper is
live behind the paid overlay, but the single paid
`Whisper -> Ruby` composed request still returns HTTP `400`. Treat that as the
remaining integration bug before documenting the full chain as production-ready.
The likely fix is in how the service overlay/P4 wrapper handles a metered
substep whose output is then transformed by a later path step. Do not rely on
Ruby's `AO.resolve` helper for this; it is currently a stub, so path composition
is the correct pattern.

## Caching

Caching paid media work is viable, but the cache must not bypass the paid route.
Prefer one of these patterns:

- charge every request through P4, then serve a cached transcript/transcode from
  device-private storage when the media tx and options match;
- cache the underlying fetched media or model output, but keep the public route
  wrapped by `service-overlay@1.0`;
- avoid exposing a free cache URL for outputs that were produced by paid work
  unless that is an intentional product decision.

For media-ingest devices, cache keys should include the media id or body hash,
device name, version, and work options such as language, model, output format,
sample rate, or codec.

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
