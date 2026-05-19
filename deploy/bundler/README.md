# HyperBEAM Open Bundler Deploy

This deploy intentionally uses upstream HyperBEAM `edge` with runtime config only.
There is no source patch required for an open test bundler.

The live deployment pattern is:

- HTTP listener on `127.0.0.1:28734` / `0.0.0.0:28734`.
- Caddy exposes the node as `https://bundler.mystical.computer`.
- `node-host` is set to `https://bundler.mystical.computer` so HyperBEAM's
  default name hook treats the public hostname as this node, not as a subdomain
  name lookup.
- The bundler wallet is kept outside the repo at `/etc/hyperbeam-bundler/wallet.json`.
- `bundler-ans104` points back to the same node so uploaded ANS-104 items are bundled by this node.
- `bundler-max-items` is `1` and dispatch delay is `2000` ms for immediate smoke-test bundles.

Do not commit a wallet JWK, `hyperbeam-key.json`, `_build/`, `priv/`, logs, cache, or machine-local root `config.*` files.

## Files

- `hyperbeam-bundler.flat.example`: flat config carrying the wallet path and simple runtime toggles.
- `hyperbeam-bundler.json.example`: JSON config carrying dashed keys and numeric values.
- `hyperbeam-bundler.service.example`: systemd unit for a release installed at `/opt/hyperbeam-bundler`.
- `Caddyfile.example`: Caddy reverse proxy block for `bundler.mystical.computer`.

## Build On Target Host

Build the release on the target host so native NIFs link against that host's OpenSSL and system libraries:

```sh
cd /opt/hyperbeam-bundler-src
RUSTUP_TOOLCHAIN=stable CMAKE_POLICY_VERSION_MINIMUM=3.5 rebar3 release
rsync -a --delete \
  --exclude cache-mainnet \
  --exclude log \
  --exclude logs \
  --exclude hyperbeam-key.json \
  --exclude config.flat \
  --exclude config.json \
  _build/default/rel/hb/ /opt/hyperbeam-bundler/
```

Install the examples as live config:

```sh
install -d -m 700 /etc/hyperbeam-bundler
cp deploy/bundler/hyperbeam-bundler.flat.example /etc/hyperbeam-bundler/config.flat
cp deploy/bundler/hyperbeam-bundler.json.example /etc/hyperbeam-bundler/config.json
install -m 600 /path/to/funded-wallet.json /etc/hyperbeam-bundler/wallet.json
cp deploy/bundler/hyperbeam-bundler.service.example /etc/systemd/system/hyperbeam-bundler.service
systemctl daemon-reload
systemctl enable --now hyperbeam-bundler.service
```

After Caddy is reloaded, verify:

```sh
curl -I https://bundler.mystical.computer/~meta@1.0/info
```
