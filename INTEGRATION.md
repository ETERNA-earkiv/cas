# CAS ↔ ETERNA Integration Guide

This document explains how the Apereo CAS SSO server connects to ETERNA, what must be configured on each side, and how the authentication flow works end to end.

---

## Overview

ETERNA supports two authentication modes, controlled by a single flag in `roda-wui.properties`:

| Mode | Config flag | When to use |
|---|---|---|
| **Internal** (default) | `ui.filter.internal.enabled = true` | Local deployments, development, standalone installs |
| **CAS SSO** | `ui.filter.cas.enabled = true` | Production deployments with centralized identity management |

The two modes are **mutually exclusive**. When CAS is enabled, set `ui.filter.internal.enabled = false` to avoid conflicts.

---

## Authentication Flow

```
Browser                   ETERNA                         CAS Server
  │                          │                               │
  │  GET /login               │                               │
  │──────────────────────────>│                               │
  │                          │  302 → /cas/login?service=...  │
  │                          │──────────────────────────────>│
  │<─────────────────────────────────────────────────────────│
  │  GET /cas/login           │                               │
  │──────────────────────────────────────────────────────────>
  │  (user enters credentials)                               │
  │  302 → /login?ticket=ST-xxx                              │
  │<─────────────────────────────────────────────────────────│
  │  GET /login?ticket=ST-xxx │                               │
  │──────────────────────────>│                               │
  │                          │  Validate ST-xxx               │
  │                          │──────────────────────────────>│
  │                          │  OK + principal attributes     │
  │                          │<──────────────────────────────│
  │                          │  casLogin(username)            │
  │                          │  (create/lookup user in LDAP)  │
  │  302 → /                  │                               │
  │<─────────────────────────│                               │
```

**Logout flow:**
1. User visits `/logout` on ETERNA
2. ETERNA clears the local session
3. ETERNA redirects to `/cas/logout?service=<eterna-url>`
4. CAS terminates the SSO session and redirects back to ETERNA

---

## ETERNA Configuration

All CAS settings live in `roda-wui.properties`, which is loaded from `$RODA_HOME/config/roda-wui.properties` (or the bundled default inside the WAR).

### Minimal working configuration

```properties
# Disable internal auth
ui.filter.internal.enabled = false

# Enable CAS
ui.filter.cas.enabled = true

# URL of the CAS server (no trailing slash)
ui.filter.cas.casServerUrlPrefix = https://cas.example.com/cas

# CAS login and logout endpoints
ui.filter.cas.casServerLoginUrl = https://cas.example.com/cas/login
ui.filter.cas.casServerLogoutUrl = https://cas.example.com/cas/logout

# ETERNA's own public URL — used to construct the service callback URL
# that CAS redirects back to after authentication
ui.filter.cas.serverName = https://eterna.example.com
```

### All available CAS properties

| Property | Default | Description |
|---|---|---|
| `ui.filter.cas.enabled` | `false` | Enable or disable CAS mode |
| `ui.filter.cas.casServerUrlPrefix` | `https://localhost:8443/cas` | CAS server base URL |
| `ui.filter.cas.casServerLoginUrl` | `https://localhost:8443/cas/login` | CAS login endpoint |
| `ui.filter.cas.casServerLogoutUrl` | `https://localhost:8443/cas/logout` | CAS logout endpoint |
| `ui.filter.cas.serverName` | `https://localhost:8888` | ETERNA's public-facing URL (used as CAS service URL) |
| `ui.filter.cas.exclusions` | `^/swagger.json,^/v1/theme/?,^/v1/auth/ticket?` | API paths excluded from CAS auth (regex, comma-separated) |
| `ui.filter.cas.exceptionOnValidationFailure` | `false` | Throw exception if ticket validation fails |
| `ui.filter.cas.redirectAfterValidation` | `false` | Redirect after CAS ticket validation |

### Filter chain

ETERNA registers six servlet filters for CAS, all wrapped in an `OnOffFilter` that respects `ui.filter.cas.enabled`:

| Filter | URL pattern | Role |
|---|---|---|
| `CasSingleSignOutFilter` | `/*` | Handles CAS single sign-out callbacks from CAS server |
| `CasValidationFilter` | `/*` | Validates CAS service tickets (CAS 3.0 protocol) |
| `CasAuthenticationFilter` | `/login` | Redirects unauthenticated users to CAS login |
| `CasRequestWrapperFilter` | `/*` | Wraps request so `getUserPrincipal()` returns the CAS principal |
| `CasWebAuthFilter` | `/login`, `/logout` | Custom: maps CAS principal to ETERNA user, handles logout redirect |
| `CasApiAuthFilter` | `/api/v1/*` | Custom: handles CAS auth for REST API; see API auth section below |

---

## CAS Server Configuration

### 1. Service Registration

ETERNA must be registered as a service in CAS. Create a JSON file in `etc/cas/services/` (the directory is present but empty in this repo — you must add the file):

**`etc/cas/services/ETERNA-1.json`**
```json
{
  "@class": "org.apereo.cas.services.CasRegisteredService",
  "serviceId": "https://eterna.example.com/.*",
  "name": "ETERNA E-Archive",
  "id": 1,
  "description": "ETERNA digital preservation system",
  "evaluationOrder": 1,
  "attributeReleasePolicy": {
    "@class": "org.apereo.cas.services.ReturnAllowedAttributeReleasePolicy",
    "allowedAttributes": ["java.util.ArrayList", ["email", "fullname"]]
  }
}
```

> The `serviceId` is a regular expression matched against the `service` parameter in the CAS login URL. Ensure it exactly covers your ETERNA deployment URL.

> **Important:** CAS uses `cas-server-support-json-service-registry`, which reads service definitions from `etc/cas/services/`. The directory is empty by default — no services are registered until you add JSON files.

### 2. Required CAS Attributes

ETERNA's user provisioning reads two optional attributes from the CAS principal:

| CAS attribute name | ETERNA field | Behaviour if missing |
|---|---|---|
| `email` | `user.email` | Left blank on auto-created user |
| `fullname` | `user.fullName` | Left blank on auto-created user |

Configure these in your CAS attribute repository (LDAP, Active Directory, JDBC, etc.) and release them via the service's `attributeReleasePolicy` as shown above.

### 3. CAS Properties

CAS is configured via `etc/cas/config/cas.properties` (not committed — sensitive). Key properties for an ETERNA integration:

```properties
# Server URLs
cas.server.name=https://cas.example.com
cas.server.prefix=${cas.server.name}/cas

# Service registry — reads JSON files from etc/cas/services/
cas.service-registry.core.init-from-json=true
cas.service-registry.json.location=file:/etc/cas/services

# Ticket Granting Cookie (must be HTTPS in production)
cas.tgc.secure=true
cas.tgc.same-site-policy=Lax
```

---

## User Provisioning

When a user authenticates through CAS for the first time, ETERNA's `UserLoginHelper.casLogin()` runs the following logic:

```
1. Look up username in ETERNA's user store (LDAP)
2. If found → use existing user
3. If not found:
   a. Create a new User object with the CAS username
   b. Map CAS attribute "fullname" → user.fullName
   c. Map CAS attribute "email"    → user.email
   d. If email matches an existing user → use that user (handles username changes)
   e. Otherwise → create a new user in ETERNA's LDAP
4. Check user.isActive() — throws InactiveUserException if false
5. Store user in HTTP session
```

**Implication:** Users are created on first login with no groups or roles. An ETERNA administrator must assign roles after first login, or roles must be pre-provisioned before the user logs in.

---

## API Authentication

The REST API (`/api/v1/*`) supports multiple authentication methods, tried in order:

1. **CAS session** — If the user already has a CAS-authenticated session (`request.getUserPrincipal() != null`), it is used
2. **Bearer JWT token** — `Authorization: Bearer <token>` header. Token subject is looked up in ETERNA's user store
3. **HTTP Basic auth** — `Authorization: Basic <base64>`. Only valid for users in ETERNA's internal LDAP
4. **Session cookie** — Existing authenticated session from prior login

The following API paths are excluded from CAS authentication by default:
- `^/swagger.json` — OpenAPI spec
- `^/v1/theme/?` — Theme/branding assets
- `^/v1/auth/ticket?` — Ticket endpoint (used by eterna-portal)

To add exclusions, append to `ui.filter.cas.exclusions` as a comma-separated list of regex patterns.

---

## Local Development Setup

To run ETERNA locally with CAS auth (instead of the default internal auth):

1. Start the CAS server:
   ```bash
   cd cas
   ./gradlew run
   # CAS available at https://localhost:8443/cas
   ```

2. Add a service registration for localhost:
   **`cas/etc/cas/services/ETERNA-local-2.json`**
   ```json
   {
     "@class": "org.apereo.cas.services.CasRegisteredService",
     "serviceId": "^(http|https)://localhost:8080/.*",
     "name": "ETERNA Local Dev",
     "id": 2,
     "evaluationOrder": 2,
     "attributeReleasePolicy": {
       "@class": "org.apereo.cas.services.ReturnAllowedAttributeReleasePolicy",
       "allowedAttributes": ["java.util.ArrayList", ["email", "fullname"]]
     }
   }
   ```

3. Set ETERNA to use CAS by overriding `roda-wui.properties` in `$HOME/.roda/config/roda-wui.properties`:
   ```properties
   ui.filter.internal.enabled = false
   ui.filter.cas.enabled = true
   ui.filter.cas.casServerUrlPrefix = https://localhost:8443/cas
   ui.filter.cas.casServerLoginUrl = https://localhost:8443/cas/login
   ui.filter.cas.casServerLogoutUrl = https://localhost:8443/cas/logout
   ui.filter.cas.serverName = http://localhost:8080
   ```

4. Start ETERNA:
   ```bash
   cd ETERNA
   mvn -pl roda-ui/roda-wui -am spring-boot:run -Pdebug-main
   ```

> **Note:** CAS runs on HTTPS by default (`8443`). For local development you may need to trust the self-signed certificate. Run `./gradlew createKeystore` in the `cas` directory to generate it, and import `cas.crt` into your JVM trust store or browser.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Redirect loop at `/login` | `ui.filter.cas.serverName` doesn't match ETERNA's actual URL | Set `serverName` to the exact URL the browser uses to reach ETERNA |
| `401` after CAS login | Service not registered in CAS | Add a JSON file to `etc/cas/services/` matching ETERNA's URL |
| User created with no email | CAS not releasing `email` attribute | Add `email` to `allowedAttributes` in the service registration |
| `InactiveUserException` on first login | User account is inactive | Activate the user in ETERNA's user management UI |
| CAS ticket validation fails with SSL error | Self-signed cert not trusted | Import CAS cert into ETERNA's JVM truststore, or set `exceptionOnValidationFailure = false` during development |
| CAS filters active when `enabled = false` | Internal and CAS filters both enabled | Set exactly one of `ui.filter.internal.enabled` / `ui.filter.cas.enabled` to `true` |
