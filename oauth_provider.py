"""Simple OAuth authorization server for Claude Custom Connectors.

Issues tokens after a username/password login form. Supports Dynamic Client
Registration (DCR) so Claude can register itself without a pre-shared client id.
"""

from __future__ import annotations

import logging
import secrets
import time
from typing import Any

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    OAuthAuthorizationServerProvider,
    RefreshToken,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from pydantic import AnyHttpUrl
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import HTMLResponse, RedirectResponse, Response

logger = logging.getLogger(__name__)

SCOPE = "hey"
ACCESS_TTL = 3600
REFRESH_TTL = 30 * 24 * 3600
AUTH_CODE_TTL = 300


class SimpleOAuthProvider(OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]):
    def __init__(
        self,
        *,
        username: str,
        password: str,
        public_url: str,
        static_bearer: str | None = None,
    ):
        self.username = username
        self.password = password
        self.public_url = public_url.rstrip("/")
        self.login_url = f"{self.public_url}/login"
        self.static_bearer = static_bearer or ""
        self.clients: dict[str, OAuthClientInformationFull] = {}
        self.auth_codes: dict[str, AuthorizationCode] = {}
        self.tokens: dict[str, AccessToken] = {}
        self.refresh_tokens: dict[str, RefreshToken] = {}
        self.state_mapping: dict[str, dict[str, str | None]] = {}

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return self.clients.get(client_id)

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        if not client_info.client_id:
            raise ValueError("No client_id provided")
        self.clients[client_info.client_id] = client_info
        logger.info("Registered OAuth client %s", client_info.client_id)

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        state = params.state or secrets.token_hex(16)
        self.state_mapping[state] = {
            "redirect_uri": str(params.redirect_uri),
            "code_challenge": params.code_challenge,
            "redirect_uri_provided_explicitly": str(params.redirect_uri_provided_explicitly),
            "client_id": client.client_id,
            "resource": params.resource,
        }
        return f"{self.login_url}?state={state}"

    async def get_login_page(self, state: str) -> HTMLResponse:
        if not state or state not in self.state_mapping:
            raise HTTPException(400, "Missing or invalid state")

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>hey-mcp login</title>
  <style>
    :root {{ color-scheme: light dark; }}
    body {{ font-family: ui-sans-serif, system-ui, sans-serif; max-width: 420px;
           margin: 4rem auto; padding: 0 1.25rem; line-height: 1.45; }}
    h1 {{ font-size: 1.35rem; margin-bottom: 0.25rem; }}
    p {{ color: #666; margin-top: 0; }}
    label {{ display: block; font-size: 0.85rem; margin: 1rem 0 0.35rem; }}
    input {{ width: 100%; box-sizing: border-box; padding: 0.65rem 0.75rem;
            border: 1px solid #ccc; border-radius: 8px; font-size: 1rem; }}
    button {{ margin-top: 1.25rem; width: 100%; padding: 0.75rem;
             border: 0; border-radius: 8px; background: #111; color: #fff;
             font-size: 1rem; cursor: pointer; }}
    @media (prefers-color-scheme: dark) {{
      p {{ color: #aaa; }}
      input {{ border-color: #444; background: #1a1a1a; color: #eee; }}
      button {{ background: #eee; color: #111; }}
    }}
  </style>
</head>
<body>
  <h1>hey-mcp</h1>
  <p>Sign in to authorize Claude to access your HEY MCP server.</p>
  <form method="post" action="{self.public_url}/login/callback">
    <input type="hidden" name="state" value="{state}"/>
    <label for="username">Username</label>
    <input id="username" name="username" autocomplete="username" required/>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required/>
    <button type="submit">Authorize</button>
  </form>
</body>
</html>"""
        return HTMLResponse(html)

    async def handle_login_callback(self, request: Request) -> Response:
        form = await request.form()
        username = form.get("username")
        password = form.get("password")
        state = form.get("state")
        if not isinstance(username, str) or not isinstance(password, str) or not isinstance(state, str):
            raise HTTPException(400, "Missing username, password, or state")

        if len(username) != len(self.username) or len(password) != len(self.password):
            raise HTTPException(401, "Invalid credentials")
        if not secrets.compare_digest(username, self.username) or not secrets.compare_digest(
            password, self.password
        ):
            raise HTTPException(401, "Invalid credentials")

        state_data = self.state_mapping.get(state)
        if not state_data:
            raise HTTPException(400, "Invalid state parameter")

        redirect_uri = state_data["redirect_uri"]
        code_challenge = state_data["code_challenge"]
        client_id = state_data["client_id"]
        resource = state_data.get("resource")
        redirect_uri_provided_explicitly = state_data["redirect_uri_provided_explicitly"] == "True"
        assert redirect_uri and code_challenge and client_id

        code = f"mcp_{secrets.token_hex(16)}"
        self.auth_codes[code] = AuthorizationCode(
            code=code,
            client_id=client_id,
            redirect_uri=AnyHttpUrl(redirect_uri),
            redirect_uri_provided_explicitly=redirect_uri_provided_explicitly,
            expires_at=time.time() + AUTH_CODE_TTL,
            scopes=[SCOPE],
            code_challenge=code_challenge,
            resource=resource,
            subject=username,
        )
        del self.state_mapping[state]
        return RedirectResponse(
            url=construct_redirect_uri(redirect_uri, code=code, state=state),
            status_code=302,
        )

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        return self.auth_codes.get(authorization_code)

    async def exchange_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode
    ) -> OAuthToken:
        if authorization_code.code not in self.auth_codes:
            raise ValueError("Invalid authorization code")
        if not client.client_id:
            raise ValueError("No client_id provided")

        access = f"mcp_{secrets.token_hex(32)}"
        refresh = f"mcp_rt_{secrets.token_hex(32)}"
        now = int(time.time())

        self.tokens[access] = AccessToken(
            token=access,
            client_id=client.client_id,
            scopes=authorization_code.scopes,
            expires_at=now + ACCESS_TTL,
            resource=authorization_code.resource,
            subject=authorization_code.subject,
        )
        self.refresh_tokens[refresh] = RefreshToken(
            token=refresh,
            client_id=client.client_id,
            scopes=authorization_code.scopes,
            expires_at=now + REFRESH_TTL,
            subject=authorization_code.subject,
        )
        del self.auth_codes[authorization_code.code]

        return OAuthToken(
            access_token=access,
            refresh_token=refresh,
            token_type="Bearer",
            expires_in=ACCESS_TTL,
            scope=" ".join(authorization_code.scopes),
        )

    async def load_access_token(self, token: str) -> AccessToken | None:
        # Accept MCP_AUTH_TOKEN as a permanent API key alongside OAuth tokens.
        if self.static_bearer and len(token) == len(self.static_bearer):
            if secrets.compare_digest(token, self.static_bearer):
                return AccessToken(
                    token=token,
                    client_id="static-bearer",
                    scopes=[SCOPE],
                    expires_at=None,
                    subject="static-bearer",
                )

        access = self.tokens.get(token)
        if not access:
            return None
        if access.expires_at and access.expires_at < time.time():
            del self.tokens[token]
            return None
        return access

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        token = self.refresh_tokens.get(refresh_token)
        if not token:
            return None
        if token.client_id != client.client_id:
            return None
        if token.expires_at and token.expires_at < time.time():
            del self.refresh_tokens[refresh_token]
            return None
        return token

    async def exchange_refresh_token(
        self,
        client: OAuthClientInformationFull,
        refresh_token: RefreshToken,
        scopes: list[str],
    ) -> OAuthToken:
        if refresh_token.token not in self.refresh_tokens:
            raise ValueError("Invalid refresh token")
        if not client.client_id:
            raise ValueError("No client_id provided")

        del self.refresh_tokens[refresh_token.token]
        access = f"mcp_{secrets.token_hex(32)}"
        new_refresh = f"mcp_rt_{secrets.token_hex(32)}"
        now = int(time.time())
        use_scopes = scopes or refresh_token.scopes

        self.tokens[access] = AccessToken(
            token=access,
            client_id=client.client_id,
            scopes=use_scopes,
            expires_at=now + ACCESS_TTL,
            subject=refresh_token.subject,
        )
        self.refresh_tokens[new_refresh] = RefreshToken(
            token=new_refresh,
            client_id=client.client_id,
            scopes=use_scopes,
            expires_at=now + REFRESH_TTL,
            subject=refresh_token.subject,
        )
        return OAuthToken(
            access_token=access,
            refresh_token=new_refresh,
            token_type="Bearer",
            expires_in=ACCESS_TTL,
            scope=" ".join(use_scopes),
        )

    async def revoke_token(self, token: str, token_type_hint: str | None = None) -> None:  # type: ignore[override]
        self.tokens.pop(token, None)
        self.refresh_tokens.pop(token, None)
