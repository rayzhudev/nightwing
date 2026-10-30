## Connect YouTube and Spotify playlists

Optional, macOS only. Local music playback needs no account or developer credentials.

Nightwing uses OAuth 2.0 with PKCE and never asks for a Spotify or Google password. In the macOS app, open **Settings > Connections** once to add the developer credentials for each service you want to enable. After setup, use the separate **Connected Services** area in the main sidebar to connect accounts, browse remote playlists, and import them.

- YouTube: create a Google Cloud **Desktop app** OAuth client, enable **YouTube Data API v3**, and configure the OAuth consent screen. Add its client ID and client secret to Nightwing; the secret is stored in the macOS Keychain. Nightwing requests only `youtube.readonly` access.
- Spotify: create a Spotify developer app and register `http://127.0.0.1/callback` as a redirect URI. Spotify Development Mode is restricted to approved users and currently requires the app owner to have Premium.

Remote playlists remain visibly separate from the local Nightwing library. Account import creates a labelled local copy containing playlist metadata, order, and source links—not service audio. Tracks already present in Nightwing are matched automatically and are playable. Other items remain visible with a link to the originating service. YouTube's public API exposes the authenticated user's owned YouTube playlists; it does not expose every YouTube Music-only library collection as a separate API.

OAuth access and refresh tokens are stored in the macOS Keychain as device-only items available while the Mac is unlocked. Google access is revoked when the account is disconnected; Spotify does not provide a public token-revocation endpoint, so Spotify disconnect removes Nightwing's local token and access can also be revoked from the Spotify account page.

See [privacy and network access](PRIVACY.md) for data handling, retention and revocation details.
